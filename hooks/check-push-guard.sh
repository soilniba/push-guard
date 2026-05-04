#!/bin/bash
# Push Guard: block git push via Claude Bash tool until pre-push-review skill completes.
#
# Hook input arrives via stdin as JSON: {"tool_name":"Bash","tool_input":{"command":"..."}}
# Outputs JSON to deny the push if review marker is absent OR if marker content does
# not match the SHA of the local ref being pushed (so a bare `touch` cannot bypass).
#
# Detection is shlex-token based, not regex: only commands where shlex tokenizes
# `git` adjacent to `push` (with optional git-level options between) are gated.
# This avoids false positives on commit messages, heredocs, or any quoted string
# that merely contains the literal substring "git push".

MARKER="/tmp/pre-push-review-done"

# Capture stdin first; the heredoc below replaces python's stdin with the
# python source itself, so we must read the hook input here in bash and pass
# it to python via an env var.
HOOK_INPUT=$(cat)

# Single Python pass: detect push, parse refspec.
# Output is two lines:
#   line 1 — one of __NO_PUSH__ / __DRY_RUN__ / __DELETE__ / HEAD / <ref name>
#   line 2 — optional `-C <path>` value seen on the git command (empty if none),
#            used so we resolve the ref in the SAME repo the user is pushing,
#            not the hook's current working directory.
RESULT=$(HOOK_INPUT="$HOOK_INPUT" python3 <<'PYEOF'
import os, json, shlex

try:
    d = json.loads(os.environ.get('HOOK_INPUT', ''))
    cmd = d.get('tool_input', {}).get('command', '')
except Exception:
    print('__NO_PUSH__'); raise SystemExit(0)

try:
    toks = shlex.split(cmd)
except Exception:
    toks = cmd.split()

# Locate `git` token followed (possibly after git-level options like -C path)
# by `push`. Adjacent-only matching means literal "git push" inside a quoted
# string / heredoc body becomes part of a single token and is NOT detected.
GIT_OPTS_WITH_VALUE = {'-C', '-c', '--git-dir', '--work-tree', '--namespace',
                      '--super-prefix', '--list-cmds'}

# Shell metacharacters and redirection operators that end the current command's
# args. shlex.split treats these as separate tokens but does NOT understand them
# as shell operators, so without this filter `git push 2>&1 | tail` would have
# `|` appended to push_args and parsed as a refspec. We also need to handle
# no-space redirections like `>file`, `>>log`, `<input` — POSIX shlex keeps the
# redirector glued to the filename as one token, so a startswith check on the
# leading byte catches both standalone (`|`, `>`) and glued (`>file`) forms.

def _is_shell_boundary(t: str) -> bool:
    if not t:
        return False
    # Leading metachar covers: |, ||, ;, &, &&, >, >>, <, <<, &>, &>>,
    # plus glued forms: >file, >>log, <input.
    if t[0] in '|;&><':
        return True
    # n>, n>>, n>&m, n<, n<&m  (numeric fd redirections like 2>&1, 1>>file).
    k = 0
    while k < len(t) and t[k].isdigit():
        k += 1
    return k > 0 and k < len(t) and t[k] in '><'

push_args = None
git_C_path = ''  # value of `-C <path>` on the git command, if any
i = 0
while i < len(toks):
    base = toks[i].rsplit('/', 1)[-1]
    if base == 'git':
        j = i + 1
        local_C = ''
        while j < len(toks):
            t = toks[j]
            if _is_shell_boundary(t):
                # Statement ends before `push` was found — different command.
                break
            if t == 'push':
                # Truncate args at the next shell boundary so pipe / redirect
                # tokens don't bleed into refspec parsing.
                rest = toks[j + 1:]
                cut = len(rest)
                for idx, tok in enumerate(rest):
                    if _is_shell_boundary(tok):
                        cut = idx
                        break
                push_args = rest[:cut]
                git_C_path = local_C
                break
            if t == '-C' and j + 1 < len(toks):
                local_C = toks[j + 1]
                j += 2
            elif t in GIT_OPTS_WITH_VALUE:
                j += 2
            elif t.startswith('-'):
                j += 1
            else:
                # Non-flag positional that isn't 'push' — different subcommand
                # (e.g. `git commit`). Stop scanning this `git` occurrence.
                break
        if push_args is not None:
            break
    i += 1

def emit(ref: str) -> None:
    print(ref)
    print(git_C_path)
    raise SystemExit(0)

if push_args is None:
    emit('__NO_PUSH__')

# Skip non-pushing forms.
for t in push_args:
    if t in ('--help', '--dry-run', '-n'):
        emit('__DRY_RUN__')

# Drop flags/options. Some take a separate value — skip both tokens.
# Track --repo specifically: when present, the remote is supplied via flag and
# positional args become refspecs (no remote slot consumed).
VALUE_OPTS = {'-o', '--push-option', '--repo', '--receive-pack', '--exec', '--signed'}
positional = []
skip_next = False
saw_repo_flag = False
for t in push_args:
    if skip_next:
        skip_next = False
        continue
    if t in VALUE_OPTS:
        if t == '--repo':
            saw_repo_flag = True
        skip_next = True
        continue
    if t.startswith('--repo='):
        saw_repo_flag = True
        continue
    if t.startswith('-'):
        continue
    positional.append(t)

# Without --repo: positional[0]=remote, positional[1:]=refspecs.
# With --repo: all positionals are refspecs.
refspec_idx = 0 if saw_repo_flag else 1
if len(positional) <= refspec_idx:
    emit('HEAD')
else:
    refspec = positional[refspec_idx]
    if ':' in refspec:
        src = refspec.split(':', 1)[0]
        emit('__DELETE__' if not src else src)
    else:
        emit(refspec)
PYEOF
)

# Result is two lines: ref on line 1, optional `-C <path>` on line 2.
LOCAL_REF=$(printf '%s\n' "$RESULT" | sed -n '1p')
GIT_C_PATH=$(printf '%s\n' "$RESULT" | sed -n '2p')

# No push detected, or non-pushing form (--help / --dry-run / -n).
if [ "$LOCAL_REF" = "__NO_PUSH__" ] || [ "$LOCAL_REF" = "__DRY_RUN__" ]; then
    exit 0
fi

# Delete-remote-branch (`git push origin :stale`) — no commit to review.
if [ "$LOCAL_REF" = "__DELETE__" ]; then
    exit 0
fi

# Resolve target SHA from the local ref, in the SAME repo the user is pushing
# (honoring `git -C <path>` if present). Fall back to HEAD when the ref cannot
# be resolved (e.g. --tags, --mirror, unparseable refspecs) so the check stays
# at least as strict as the original behavior.
if [ -n "$GIT_C_PATH" ]; then
    TARGET_SHA=$(git -C "$GIT_C_PATH" rev-parse "$LOCAL_REF" 2>/dev/null)
    if [ -z "$TARGET_SHA" ]; then
        TARGET_SHA=$(git -C "$GIT_C_PATH" rev-parse HEAD 2>/dev/null)
    fi
else
    TARGET_SHA=$(git rev-parse "$LOCAL_REF" 2>/dev/null)
    if [ -z "$TARGET_SHA" ]; then
        TARGET_SHA=$(git rev-parse HEAD 2>/dev/null)
    fi
fi

if [ -f "$MARKER" ]; then
    MARKER_SHA=$(tr -d '[:space:]' < "$MARKER")
    rm -f "$MARKER"  # 单次消耗：通过与否都删，下次 push 必须重新 review
    if [ -n "$MARKER_SHA" ] && [ -n "$TARGET_SHA" ] && [ "$MARKER_SHA" = "$TARGET_SHA" ]; then
        exit 0
    fi
fi

python3 -c "
import json
print(json.dumps({
    'systemMessage': '🚫 Push blocked: run push-guard:pre-push-review first. Marker is content-validated against the target ref SHA — a bare touch will NOT bypass.',
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': 'Pre-push review not completed, or marker SHA does not match the ref being pushed. Run: push-guard:pre-push-review. Do NOT bypass by manually creating the marker file — the hook reads marker contents and compares them to git rev-parse of the ref being pushed.'
    }
}))
"
exit 0
