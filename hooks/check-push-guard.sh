#!/bin/bash
# Push Guard: block git push via Claude Bash tool until pre-push-review skill
# emits a verifiable 5-dimension report with file:line citations inside the diff.
#
# Hook input arrives via stdin as JSON:
#   {"tool_name":"Bash","tool_input":{"command":"..."},"transcript_path":"...",...}
#
# Detection is shlex-token based: only commands where shlex tokenizes `git`
# adjacent to `push` are gated. False positives on quoted strings / heredocs
# are avoided.
#
# Audit reads the Claude Code session transcript directly — there is no marker
# file. A bare token write cannot bypass; the hook validates that:
#   1. push-guard:pre-push-review Skill was invoked since HEAD's commit time
#   2. The Read tool was used on a file in this push's diff
#   3. Five dimension cites D1..D5 appear in the assistant text after the
#      Skill invocation, in the format `D{N} {VERDICT} — {file}:{line} (reason)`
#   4. CLEAN/FIXED cite file:line points into the diff hunks
#   5. SKIPPED is only allowed when conservative regex on diff finds no
#      pattern matching that dimension

HOOK_INPUT=$(cat)

# ===== Stage 1: detect git push =====
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

GIT_OPTS_WITH_VALUE = {'-C', '-c', '--git-dir', '--work-tree', '--namespace',
                      '--super-prefix', '--list-cmds'}

def _is_shell_boundary(t: str) -> bool:
    if not t:
        return False
    if t[0] in '|;&><':
        return True
    k = 0
    while k < len(t) and t[k].isdigit():
        k += 1
    return k > 0 and k < len(t) and t[k] in '><'

push_args = None
git_C_path = ''
i = 0
while i < len(toks):
    base = toks[i].rsplit('/', 1)[-1]
    if base == 'git':
        j = i + 1
        local_C = ''
        while j < len(toks):
            t = toks[j]
            if _is_shell_boundary(t):
                break
            if t == 'push':
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

for t in push_args:
    if t in ('--help', '--dry-run', '-n'):
        emit('__DRY_RUN__')

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

LOCAL_REF=$(printf '%s\n' "$RESULT" | sed -n '1p')
GIT_C_PATH=$(printf '%s\n' "$RESULT" | sed -n '2p')

if [ "$LOCAL_REF" = "__NO_PUSH__" ] || [ "$LOCAL_REF" = "__DRY_RUN__" ]; then
    exit 0
fi

if [ "$LOCAL_REF" = "__DELETE__" ]; then
    exit 0
fi

# ===== Stage 2: resolve target SHA (in the right repo) =====
if [ -n "$GIT_C_PATH" ]; then
    GIT_ARGS=(-C "$GIT_C_PATH")
else
    GIT_ARGS=()
fi
TARGET_SHA=$(git "${GIT_ARGS[@]}" rev-parse --verify "$LOCAL_REF" 2>/dev/null)
if [ -z "$TARGET_SHA" ]; then
    TARGET_SHA=$(git "${GIT_ARGS[@]}" rev-parse --verify HEAD 2>/dev/null)
fi

if [ -z "$TARGET_SHA" ]; then
    # No SHA at all (e.g., empty repo with no commits). Allow the push;
    # there's nothing to review.
    exit 0
fi

# ===== Stage 3: transcript audit =====
AUDIT_OUTPUT=$(HOOK_INPUT="$HOOK_INPUT" TARGET_SHA="$TARGET_SHA" GIT_C_PATH="$GIT_C_PATH" python3 <<'PYEOF'
import os, json, re, subprocess, sys
from datetime import datetime

def emit(verdict: str, reason: str = '') -> None:
    print(verdict)
    print(reason)
    raise SystemExit(0)

try:
    hook_input = json.loads(os.environ.get('HOOK_INPUT', ''))
except Exception as e:
    emit('FAIL', f'cannot parse hook input: {e}')

target_sha = os.environ.get('TARGET_SHA', '')
git_c_path = os.environ.get('GIT_C_PATH', '')
transcript_path = hook_input.get('transcript_path', '')

if not transcript_path:
    emit('FAIL', 'hook input has no transcript_path')
if not os.path.exists(transcript_path):
    emit('FAIL', f'transcript not found at {transcript_path}')

def git(*args) -> str:
    cmd = ['git']
    if git_c_path:
        cmd += ['-C', git_c_path]
    cmd += list(args)
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return ''

# HEAD commit time (epoch seconds)
ct = git('show', '-s', '--format=%ct', target_sha).strip()
head_time = int(ct) if ct.isdigit() else 0

# Resolve diff base
def find_base() -> str:
    for ref in ('main', 'master'):
        b = git('merge-base', target_sha, ref).strip()
        if b:
            return b
    # First commit fallback
    roots = git('rev-list', '--max-parents=0', target_sha).strip().split('\n')
    return roots[0] if roots and roots[0] else ''

base = find_base()
if not base:
    # No base means initial commit with nothing to diff against — allow push.
    emit('PASS', 'no diff base; nothing to review')

if base == target_sha:
    # Pushing already-pushed work, no new diff to review.
    emit('PASS', 'no new commits since base')

# Parse diff hunks → {file: set(line_numbers in NEW file)}.
# `-c core.quotePath=false` keeps non-ASCII / spaced filenames as raw UTF-8
# instead of git's default quoted+octal-escaped form, so we don't need to
# unquote when matching against cite paths.
diff_unified0 = git('-c', 'core.quotePath=false', 'diff', '--unified=0', f'{base}..{target_sha}')
diff_full = git('-c', 'core.quotePath=false', 'diff', f'{base}..{target_sha}')

hunks: dict = {}
cur_file = None
for line in diff_unified0.split('\n'):
    if line.startswith('+++ b/'):
        # With core.quotePath=false, git emits a trailing TAB on paths that
        # would normally be quoted (spaces / non-ASCII). Strip it.
        cur_file = line[6:].rstrip('\t')
        hunks.setdefault(cur_file, set())
    elif line.startswith('+++ /dev/null'):
        cur_file = None  # file deleted
    elif line.startswith('@@') and cur_file:
        m = re.search(r'\+(\d+)(?:,(\d+))?', line)
        if m:
            start = int(m.group(1))
            count = int(m.group(2) or 1)
            if count > 0:
                hunks[cur_file].update(range(start, start + count))

diff_files = set(hunks.keys())

if not diff_files:
    # Pure metadata (e.g., email rewrite) — allow.
    emit('PASS', 'no source files changed')

# Added lines only (for SKIP-reason verification grep)
added_lines = '\n'.join(
    line[1:] for line in diff_full.split('\n')
    if line.startswith('+') and not line.startswith('+++')
)

# Read transcript JSONL
events = []
try:
    with open(transcript_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            # Transcript lines must be JSON objects; downstream uses .get()
            # which would crash on lists/strings/numbers.
            if isinstance(obj, dict):
                events.append(obj)
except Exception as e:
    emit('FAIL', f'cannot read transcript: {e}')

def event_time(e: dict) -> int:
    ts = e.get('timestamp', '')
    if not ts:
        return 0
    try:
        # Normalize trailing 'Z' to '+00:00' so fromisoformat (pre-3.11)
        # produces a TZ-aware datetime; otherwise .timestamp() would
        # interpret it as local time, breaking comparison vs git's UTC %ct.
        if ts.endswith('Z'):
            ts = ts[:-1] + '+00:00'
        return int(datetime.fromisoformat(ts).timestamp())
    except Exception:
        return 0

# Find latest Skill invocation of push-guard:pre-push-review since HEAD commit
SKILL_NAME = 'push-guard:pre-push-review'
skill_idx = None
for i, e in enumerate(events):
    if e.get('type') != 'assistant':
        continue
    msg = e.get('message') or {}
    for c in (msg.get('content') or []):
        if not isinstance(c, dict):
            continue
        if c.get('type') == 'tool_use' and c.get('name') == 'Skill':
            inp = c.get('input') or {}
            if inp.get('skill_name') == SKILL_NAME:
                if event_time(e) >= head_time:
                    skill_idx = i

if skill_idx is None:
    emit('FAIL',
         f'Skill {SKILL_NAME} was not invoked since HEAD commit ({target_sha[:7]}). '
         f'Run the skill, do the scan, then push.')

# Collect assistant text + Read tool calls AFTER the skill invocation
texts = []
read_files = set()
for e in events[skill_idx + 1:]:
    if e.get('type') != 'assistant':
        continue
    msg = e.get('message') or {}
    for c in (msg.get('content') or []):
        if not isinstance(c, dict):
            continue
        ctype = c.get('type')
        if ctype == 'text':
            texts.append(c.get('text') or '')
        elif ctype == 'tool_use' and c.get('name') == 'Read':
            fp = (c.get('input') or {}).get('file_path') or ''
            if fp:
                # Normalize to relative-from-repo-root if possible.
                # Diff paths are repo-relative; transcript paths are absolute.
                # Match by suffix.
                read_files.add(fp)

joined_text = '\n'.join(texts)

# Verify Read tool was used on at least one diff file
def matches_diff_file(read_fp: str) -> bool:
    for df in diff_files:
        if read_fp.endswith('/' + df) or read_fp == df:
            return True
    return False

if not any(matches_diff_file(rf) for rf in read_files):
    emit('FAIL',
         f'no Read tool call observed on any modified file after skill invocation. '
         f'Modified files: {sorted(diff_files)}. Read at least one before reporting.')

# Parse 5 cites. Path uses `.+?` (not `\S+?`) so filenames with spaces
# work; the trailing `:(\d+)\s+\(` anchor pins the non-greedy match to the
# last `:digits` before the reason paren.
CITE_RE = re.compile(
    r'D([1-5])\s+(CLEAN|FIXED|SKIPPED)\s+[—\-]\s+(.+?):(\d+)\s+\(([^)]{1,200})\)'
)

cites: dict = {}
for m in CITE_RE.finditer(joined_text):
    dim = int(m.group(1))
    cites[dim] = {
        'verdict': m.group(2),
        'file': m.group(3),
        'line': int(m.group(4)),
        'reason': m.group(5),
    }

missing = [d for d in (1, 2, 3, 4, 5) if d not in cites]
if missing:
    miss_list = ', '.join(f'D{d}' for d in missing)
    emit('FAIL',
         f'missing cites for {miss_list}. Required format: '
         f'`D{{N}} {{CLEAN|FIXED|SKIPPED}} — {{file}}:{{line}} ({{reason}})` '
         f'with all 5 dimensions.')

# Conservative SKIP-reason grep patterns. SKIPPED is rejected if its
# dimension's pattern is found in added lines of the diff.
SKIP_REJECT_PATTERNS = {
    1: re.compile(
        r'\b(subprocess|os\.system|os\.popen|requests\.|urllib\.|http\.client|'
        r'socket\.|sqlite3|psycopg2|pymongo|cursor\.execute|fetch\(|spawn\()',
    ),
    2: re.compile(r'\.encode\s*\(|\.decode\s*\(|\bseek\s*\(|struct\.(pack|unpack)'),
    3: re.compile(r'json\.loads|yaml\.safe_load|pickle\.loads|response\.json\(|xmltodict|argparse'),
    4: re.compile(r'\bclass\s+\w*(State|Machine|Dispatcher|Handler|Registry)\b|\bregistry\s*=\s*\{'),
    5: re.compile(r'sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16}|xox[bp]-[A-Za-z0-9-]{20,}'),
}

# Validate each cite
for dim, c in cites.items():
    verdict = c['verdict']
    fp = c['file']
    ln = c['line']

    if verdict == 'SKIPPED':
        if ln != 0:
            emit('FAIL',
                 f'D{dim} SKIPPED requires line=0, got {ln}. '
                 f'Use `{fp}:0` for SKIPPED cites.')
        pat = SKIP_REJECT_PATTERNS.get(dim)
        if pat and pat.search(added_lines):
            sample = (pat.search(added_lines).group(0))[:60]
            emit('FAIL',
                 f'D{dim} SKIPPED but diff added lines contain pattern matching '
                 f'this dimension (e.g., `{sample}`). Re-evaluate with CLEAN or FIXED.')
        continue

    # CLEAN / FIXED: file must be in diff, line must be in hunks
    if fp not in diff_files:
        emit('FAIL',
             f'D{dim} cite "{fp}" is not a modified file. '
             f'Modified files: {sorted(diff_files)}.')
    if ln not in hunks[fp]:
        sample = sorted(hunks[fp])[:8]
        emit('FAIL',
             f'D{dim} cite line {ln} is outside diff hunks for {fp}. '
             f'Modified lines (sample): {sample}.')

emit('PASS', 'all 5 cites validated against diff hunks')
PYEOF
)

AUDIT_VERDICT=$(printf '%s\n' "$AUDIT_OUTPUT" | sed -n '1p')
AUDIT_REASON=$(printf '%s\n' "$AUDIT_OUTPUT" | sed -n '2,$p')

if [ "$AUDIT_VERDICT" = "PASS" ]; then
    exit 0
fi

# Deny with the audit's specific reason
REASON="$AUDIT_REASON" python3 -c "
import json, os
reason = os.environ.get('REASON', '')
print(json.dumps({
    'systemMessage': '🚫 Push blocked by push-guard transcript audit. ' + reason,
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': reason + ' Run skill push-guard:pre-push-review (or fix the cited issue) and retry.'
    }
}))
"
exit 0
