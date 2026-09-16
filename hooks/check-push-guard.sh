#!/bin/bash
# Push Guard: block git push via Claude/Codex Bash tool until the selected
# pre-push-review protocol emits a verifiable result for the target diff.
#
# Hook input arrives via stdin as JSON:
#   {"tool_name":"Bash","tool_input":{"command":"..."},"transcript_path":"...",...}
#   {"tool_name":"functions.exec_command","tool_input":{"cmd":"..."},"transcript_path":"...",...}
#
# Detection is shlex-token based: only commands where shlex tokenizes `git`
# adjacent to `push` are gated. False positives on quoted strings / heredocs
# are avoided.
#
# Audit reads the agent session transcript directly — there is no marker file.
# A bare token write cannot bypass; the hook validates that:
#   1. push-guard:pre-push-review Skill was invoked since HEAD's commit time
#   2. The Read tool was used on a file in this push's diff
#   3. The selected profile's normalized PASS/BLOCK result appears after the
#      Skill invocation. Strict mode retains the legacy seven-dimension format.
#   4. CLEAN/FIXED cite file:line points into the diff hunks
#   5. BLOCK findings point into the pushed diff. PASS does not need citations
#      in fast/balanced modes.
#   6. The independent reviewer's report is read from whichever record the
#      harness used to deliver it (tool_result, peer message, queue-operation,
#      queued_command attachment), and every such record must trace back to a
#      subagent spawned with the reviewer signature, never to model text
#
# The review is not started automatically: on an unreviewed push the hook denies
# and instructs the model to let the user choose between running the review (and
# pushing) and abandoning the push.

HOOK_INPUT=$(cat)
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PUSH_GUARD_ROOT=$(cd "$HOOK_DIR/.." && pwd)
export PUSH_GUARD_ROOT

# Interpreter for stages 1 and 3. Windows ships `python`, not `python3`, so
# accept either; if neither exists PYTHON_BIN stays empty and the stages fail
# closed (Stage 1b below).
PYTHON_BIN=$(command -v python3 || command -v python)

# ===== Stage 1: detect git push =====
RESULT=$(HOOK_INPUT="$HOOK_INPUT" PYTHONIOENCODING=utf-8 "$PYTHON_BIN" <<'PYEOF'
import os, json, shlex

try:
    d = json.loads(os.environ.get('HOOK_INPUT', ''))
    tool_input = d.get('tool_input') or {}
    cmd = tool_input.get('command') or tool_input.get('cmd')
    if not isinstance(cmd, str):
        raise TypeError('command/cmd is not a string')
except Exception:
    # Could not read the command at all — bad JSON, or an input shape this hook
    # does not understand. That is NOT the same as "not a push", so it must not
    # be answered with __NO_PUSH__; the Bash side fails closed on it instead.
    print('__UNPARSED__'); raise SystemExit(0)

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

def _is_command_position(index: int) -> bool:
    if index == 0:
        return True
    previous = toks[index - 1]
    if _is_shell_boundary(previous):
        return True
    # Common command wrappers still leave git as the wrapped command, while
    # ordinary prose such as `echo git push` must not be treated as a push.
    return previous in {'command', 'env', 'nice', 'nohup', 'sudo', 'time'}

push_args = None
git_C_path = ''
i = 0
while i < len(toks):
    base = toks[i].rsplit('/', 1)[-1]
    if base in {'git', 'git.exe'} and _is_command_position(i):
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

push_remote = ''

def emit(ref: str, destination: str = '') -> None:
    print(ref)
    print(git_C_path)
    print(push_remote)
    print(destination)
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
for idx, t in enumerate(push_args):
    if skip_next:
        skip_next = False
        continue
    if t in VALUE_OPTS:
        if t == '--repo':
            saw_repo_flag = True
            if idx + 1 < len(push_args):
                push_remote = push_args[idx + 1]
        skip_next = True
        continue
    if t.startswith('--repo='):
        saw_repo_flag = True
        push_remote = t.split('=', 1)[1]
        continue
    if t.startswith('-'):
        continue
    positional.append(t)

refspec_idx = 0 if saw_repo_flag else 1
if not saw_repo_flag and positional:
    push_remote = positional[0]
if len(positional) <= refspec_idx:
    emit('HEAD')
else:
    refspec = positional[refspec_idx]
    if ':' in refspec:
        src, destination = refspec.split(':', 1)
        emit('__DELETE__' if not src else src, destination)
    else:
        emit(refspec, refspec)
PYEOF
)

LOCAL_REF=$(printf '%s\n' "$RESULT" | sed -n '1p')
GIT_C_PATH=$(printf '%s\n' "$RESULT" | sed -n '2p')
PUSH_REMOTE=$(printf '%s\n' "$RESULT" | sed -n '3p')
PUSH_DEST=$(printf '%s\n' "$RESULT" | sed -n '4p')

# ===== Stage 1b: fail closed when stage 1 produced no answer =====
# Stage 1 is python (python3 or python). An empty result means no interpreter is
# available or the stage died without printing; __UNPARSED__ means it could not
# read the command.
# Neither is a "not a push" verdict, and answering them with "allow" would turn
# a broken hook environment into an open gate. Scan the raw hook input instead
# and fail closed. The pattern refuses to cross shell separators or quotes, so
# prose like `git commit -m "fix push"` is not caught; text that literally reads
# like a push can still over-block, which is the intended direction here.
#
# The test uses bash's own ERE engine rather than grep: a missing external tool
# must not be able to turn this fallback into yet another open door.
if [ -z "$LOCAL_REF" ] || [ "$LOCAL_REF" = "__UNPARSED__" ]; then
    PUSH_RE='git[^|;&"]*[[:space:]]push([^[:alnum:]_-]|$)'
    if [[ "$HOOK_INPUT" =~ $PUSH_RE ]]; then
        printf '%s' '{
  "systemMessage": "⛔ push-guard: command could not be parsed (no python3/python on PATH, or unreadable hook input) — push blocked instead of allowed unreviewed.",
  "decision": "block",
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "push-guard could not determine whether this command is a push: stage 1 needs python3 or python on PATH to parse the command, and it produced no verdict. The command text reads like a push, so the push is blocked rather than allowed unreviewed. Fix the hook environment (python3 or python on PATH) and retry."
  }
}'
    fi
    exit 0
fi

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
AUDIT_OUTPUT=$(HOOK_INPUT="$HOOK_INPUT" TARGET_SHA="$TARGET_SHA" GIT_C_PATH="$GIT_C_PATH" \
    LOCAL_REF="$LOCAL_REF" PUSH_REMOTE="$PUSH_REMOTE" PUSH_DEST="$PUSH_DEST" \
    PYTHONIOENCODING=utf-8 "$PYTHON_BIN" <<'PYEOF'
import os, json, re, glob, subprocess, sys
from datetime import datetime
from pathlib import Path

def emit(verdict: str, reason: str = '') -> None:
    print(verdict)
    print(reason)
    raise SystemExit(0)

push_guard_root = os.environ.get('PUSH_GUARD_ROOT', '')
if push_guard_root:
    sys.path.insert(0, push_guard_root)

try:
    from hooks.review_packet import ReviewPacket, ReviewState
    from hooks.review_policy import ReviewPolicy
    from hooks.review_report import parse_review_result, validate_review_result
except Exception as exc:
    emit('FAIL', f'push-guard protocol modules unavailable: {exc}')

try:
    hook_input = json.loads(os.environ.get('HOOK_INPUT', ''))
except Exception as e:
    emit('FAIL', f'cannot parse hook input: {e}')

target_sha = os.environ.get('TARGET_SHA', '')
git_c_path = os.environ.get('GIT_C_PATH', '')
local_ref = os.environ.get('LOCAL_REF', '')
push_remote = os.environ.get('PUSH_REMOTE', '')
push_dest = os.environ.get('PUSH_DEST', '')
transcript_path = hook_input.get('transcript_path', '')

def git(*args) -> str:
    cmd = ['git']
    if git_c_path:
        cmd += ['-C', git_c_path]
    cmd += list(args)
    try:
        # Explicit UTF-8: git output is UTF-8 (commit messages, paths), while the
        # locale default is GBK on Chinese Windows — decoding with it raises
        # UnicodeDecodeError and takes the whole audit down.
        return subprocess.check_output(cmd, text=True, encoding='utf-8',
                                       errors='replace', stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return ''

# HEAD commit time (epoch seconds)
ct = git('show', '-s', '--format=%ct', target_sha).strip()
head_time = int(ct) if ct.isdigit() else 0

# Resolve the diff base from the remote state, not the local main/master branch.
# A local base branch can point at target_sha itself, which would make the hook
# report "no new commits" without auditing the target. The push parser supplies
# the remote and destination when available; upstream/default remote refs cover
# `git push` and first pushes of a new branch.
def valid_remote_ref(ref: str) -> str:
    if not ref or not ref.startswith('refs/remotes/'):
        return ''
    resolved = git('rev-parse', '--verify', ref).strip()
    return resolved if resolved else ''

def remote_branch_ref(remote: str, branch: str) -> str:
    if branch.startswith('refs/heads/'):
        branch = branch[len('refs/heads/'):]
    if not remote or not branch or branch in ('HEAD', 'refs/heads/HEAD'):
        return ''
    return valid_remote_ref(f'refs/remotes/{remote}/{branch}')

def remote_default_ref(remote: str) -> str:
    if not remote:
        return ''
    symbolic = git('symbolic-ref', '--quiet', '--short',
                   f'refs/remotes/{remote}/HEAD').strip()
    if not symbolic.startswith(f'{remote}/'):
        return ''
    return valid_remote_ref(f'refs/remotes/{symbolic}')

def upstream_ref(branch: str) -> str:
    if not branch or branch == 'HEAD':
        return ''
    symbolic = git('rev-parse', '--abbrev-ref', '--symbolic-full-name',
                   f'{branch}@{{upstream}}').strip()
    if symbolic.startswith('refs/remotes/'):
        return valid_remote_ref(symbolic)
    if '/' in symbolic and not symbolic.startswith('refs/'):
        remote, remote_branch = symbolic.split('/', 1)
        return remote_branch_ref(remote, remote_branch)
    return ''

def find_base() -> str:
    current_branch = git('symbolic-ref', '--quiet', '--short', 'HEAD').strip()
    candidates = []

    if push_remote and push_dest:
        candidates.append(remote_branch_ref(push_remote, push_dest))
    if push_remote:
        candidates.append(remote_default_ref(push_remote))
    candidates.append(upstream_ref(local_ref if local_ref != 'HEAD' else current_branch))

    for remote in git('remote').splitlines():
        candidates.append(remote_default_ref(remote.strip()))

    for candidate in candidates:
        if candidate:
            return candidate
    return ''

base = find_base()
if not base:
    # Review a first push against the empty tree instead of treating the
    # absence of a remote-tracking ref as permission to bypass the gate.
    base = git('hash-object', '-t', 'tree', '/dev/null').strip()
    if not base:
        emit('FAIL', 'cannot resolve a diff base or the empty tree')

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
deleted_lines = '\n'.join(
    line[1:] for line in diff_full.split('\n')
    if line.startswith('-') and not line.startswith('---')
)

try:
    review_policy = ReviewPolicy.from_environment(os.environ)
    review_decision = review_policy.classify(
        sorted(diff_files),
        added_lines,
        deleted_lines,
    )
except Exception as exc:
    emit('FAIL', f'push-guard protocol/configuration problem: {exc}')

if review_decision.tier == 'L0':
    emit('PASS', 'L0 documentation-only diff; no model review required')

if not transcript_path:
    emit('FAIL', 'hook input has no transcript_path')

# Worktree fallback: in some setups (e.g. Claude session started in a parent
# repo, then cwd switched into a worktree under .claude/worktrees/), Claude
# Code encodes transcript_path against cwd but writes the jsonl under the
# parent repo's project dir. The literal path then doesn't exist. Fall back
# to a basename search under ~/.claude/projects/*/.
#
# Strict UUID regex on the basename: rejects non-UUID names so an attacker (or
# a buggy wrapper) can't make the hook resolve `transcript_path = passwd.jsonl`
# and load whatever same-named file happens to exist under ~/.claude/projects/.
# UUID v4 basenames are globally unique in real Claude Code, so on collision we
# can take candidates[0] — picking by mtime would just add a getmtime race for
# no observable benefit.
if not os.path.exists(transcript_path):
    bn = os.path.basename(transcript_path)
    if re.match(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$', bn):
        candidates = glob.glob(os.path.expanduser(f'~/.claude/projects/*/{bn}'))
        if candidates:
            transcript_path = candidates[0]
if not os.path.exists(transcript_path):
    emit('FAIL', f'transcript not found at {transcript_path}')

def select_packet_diff(source: str, selected_files: tuple[str, ...]) -> str:
    selected = set(selected_files)
    blocks = []
    current = []
    current_file = None

    def flush() -> None:
        if current and current_file in selected:
            blocks.extend(current)

    for line in source.splitlines():
        if line.startswith('diff --git '):
            flush()
            current = [line]
            current_file = None
            continue
        if not current:
            continue
        current.append(line)
        if line.startswith('+++ b/'):
            current_file = line[6:].rstrip('\t').replace('\\', '/')
    flush()
    return '\n'.join(blocks) + ('\n' if blocks else '')

repo_path = Path(git_c_path or os.getcwd()).resolve()
review_packet = ReviewPacket(
    target_sha=target_sha,
    base_ref=base,
    tier=review_decision.tier,
    profile=review_decision.profile,
    high_priority_files=review_decision.high_priority_files,
    changed_files=tuple(sorted(diff_files)),
    diff=select_packet_diff(
        diff_full,
        review_decision.high_priority_files,
    ),
    repo=repo_path,
)

# Read transcript JSONL
events = []
try:
    with open(transcript_path, encoding='utf-8', errors='replace') as f:
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

# Find latest push-guard:pre-push-review invocation since HEAD commit.
# Claude records this as a Skill tool call; Codex records plugin skill use as
# model-visible text, so support both transcript shapes.
SKILL_NAME = 'push-guard:pre-push-review'
skill_idx = None
skill_tool_idx = None  # a real Skill tool call — the authoritative invocation
skill_text_idx = None  # a prose mention — fallback only, see below
skill_tool_count = 0
skill_text_count = 0

def text_parts(content) -> list[str]:
    out = []
    if isinstance(content, str):
        out.append(content)
    elif isinstance(content, list):
        for c in content:
            if isinstance(c, str):
                out.append(c)
            elif isinstance(c, dict):
                text = c.get('text') or c.get('content')
                if isinstance(text, str):
                    out.append(text)
    return out

def parse_arguments(value):
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {}
        except Exception:
            return {}
    return {}

def codex_payload(e: dict) -> dict:
    p = e.get('payload')
    return p if isinstance(p, dict) else {}

for i, e in enumerate(events):
    if event_time(e) < head_time:
        continue
    if e.get('type') == 'assistant':
        msg = e.get('message') or {}
        for c in (msg.get('content') or []):
            if not isinstance(c, dict):
                continue
            if c.get('type') == 'tool_use' and c.get('name') == 'Skill':
                inp = c.get('input') or {}
                if inp.get('skill') == SKILL_NAME:
                    skill_tool_idx = i
                    skill_tool_count += 1
            elif c.get('type') == 'text' and SKILL_NAME in (c.get('text') or ''):
                skill_text_idx = i
                skill_text_count += 1
    elif e.get('type') == 'response_item':
        p = codex_payload(e)
        if p.get('type') == 'message' and p.get('role') == 'assistant':
            if any(SKILL_NAME in t for t in text_parts(p.get('content'))):
                skill_text_idx = i
                skill_text_count += 1

# Prefer the real invocation. A mere mention of the skill name is not an
# invocation: the announcement, a report or a summary naming the skill must not
# move the window forward, or a Read (and the report) that came before the
# mention fall outside it and a correct review gets rejected.
skill_idx = skill_tool_idx if skill_tool_idx is not None else skill_text_idx

if skill_idx is None:
    emit('FAIL',
         f'Skill {SKILL_NAME} was not invoked since HEAD commit ({target_sha[:7]}). '
         f'Run the skill, do the scan, then push.')

# Collect main-agent assistant text + Read tool calls + independent reviewer
# subagent invocations AFTER the skill invocation. Claude uses Read/Agent
# events; Codex may record terminal calls as custom_tool_call and agent results
# as agent_message, so both transcript shapes must be handled.
SUBAGENT_SIGNATURE = '[PUSH-GUARD-INDEPENDENT-REVIEW v1]'
# Codex encrypts the spawn message in its transcript, so unlike Claude we
# cannot inspect it for SUBAGENT_SIGNATURE.  A reserved, isolated task name
# (optionally with a numeric round suffix) is its transcript-level review
# identity; an ACK for the same call must then establish the canonical agent
# path before a report is accepted.
CODEX_INDEPENDENT_TASK_RE = re.compile(r'^push_guard_independent(?:_[1-9][0-9]*)?$')
MULTI_AGENT_NAMESPACE = 'multi_agent_v1'
# How the harness wraps a peer/subagent message delivered to this session.
PEER_DELIVERY_RE = re.compile(r'teammate-message|Another Claude session sent a message:')
# Some harness builds deliver a subagent's report neither as a tool_result (the
# Agent call returns spawn metadata only) nor as a user-side string, but as a
# `queue-operation` entry or an `attachment` of type `queued_command`. Both are
# harness-written records: the model cannot author them, so reading them opens
# no self-attestation path. Both carry one of two envelopes:
#   <agent-message from="NAME">report</agent-message>
#       NAME must be an agent spawned with the reviewer signature.
#   <task-notification>...<tool-use-id>ID</tool-use-id>...<result>report</result>
#       ID must be an Agent call whose prompt carried the reviewer signature.
# Unlike the JSON-enveloped peer delivery, these payloads hold real newlines.
AGENT_MESSAGE_RE = re.compile(r'<agent-message from="([^"]+)">(.*?)</agent-message>', re.S)
NOTIFICATION_ID_RE = re.compile(r'<tool-use-id>([^<]+)</tool-use-id>')
NOTIFICATION_RESULT_RE = re.compile(r'<result>(.*?)</result>', re.S)


def same_agent(name: str, spawn_names: set) -> bool:
    """True when `name` names a spawn, allowing the harness's -N dedup suffix.

    A spawn record holds the name that was requested; the delivery envelope
    carries the name the harness resolved it to, which is `<name>-<n>` once
    that name is already taken in the session. Anchoring on the requested name
    alone drops the report of every reviewer spawned after the first one.
    """
    return any(name == n or name.startswith(n + '-') for n in spawn_names)


def delivered_report(payload, agent_ids: set, agent_names: set) -> str:
    """Report text carried by a harness delivery record, or '' when none."""
    if not isinstance(payload, str):
        return ''
    m = AGENT_MESSAGE_RE.search(payload)
    if m and same_agent(m.group(1), agent_names):
        return m.group(2)
    if '<task-notification>' in payload:
        tid = NOTIFICATION_ID_RE.search(payload)
        if tid and tid.group(1) in agent_ids:
            res = NOTIFICATION_RESULT_RE.search(payload)
            if res:
                return res.group(1)
    return ''
main_texts = []
sub_texts = []
read_files = set()
agent_ids: set = set()
agent_names: set = set()
codex_pending_agents: dict = {}
codex_independent_agents: dict = {}

def command_mentions_diff_read(cmd: str) -> set[str]:
    if not cmd:
        return set()
    found = set()
    norm_cmd = cmd.replace('\\', '/')
    if review_packet.accepts_read_evidence(cmd):
        for df in review_packet.files_to_read():
            if df in norm_cmd:
                found.add(df)
        if found:
            return found
    if not re.search(
        r'\b(cat|sed|nl|less|head|tail|rg|grep|Get-Content|'
        r'git\s+(?:diff|show))\b',
        cmd,
        re.IGNORECASE,
    ):
        return set()
    for df in diff_files:
        if df in norm_cmd:
            found.add(df)
    return found

def is_codex_independent_task(task_name) -> bool:
    return isinstance(task_name, str) and bool(CODEX_INDEPENDENT_TASK_RE.fullmatch(task_name))

def has_reviewer_signature(args: dict) -> bool:
    """Check visible multi-agent arguments for the reviewer signature."""
    message = args.get('message')
    if isinstance(message, str) and SUBAGENT_SIGNATURE in message:
        return True
    items = args.get('items')
    if isinstance(items, list):
        return any(
            isinstance(item, dict)
            and isinstance(item.get('text'), str)
            and SUBAGENT_SIGNATURE in item.get('text')
            for item in items
        )
    return False

def notification_report(raw: str) -> str:
    """Read a harness-written multi-agent notification tied to a real spawn."""
    if not isinstance(raw, str) or '<subagent_notification>' not in raw:
        return ''
    match = re.search(
        r'<subagent_notification>\s*(\{.*?\})\s*</subagent_notification>',
        raw,
        re.S,
    )
    if not match:
        return ''
    try:
        payload = json.loads(match.group(1))
    except json.JSONDecodeError:
        return ''
    agent_path = payload.get('agent_path')
    if not isinstance(agent_path, str) or agent_path not in codex_independent_agents:
        return ''
    status = payload.get('status')
    if isinstance(status, str):
        return status
    if isinstance(status, dict):
        for key in ('completed', 'result', 'message'):
            report = status.get(key)
            if isinstance(report, str):
                return report
    return ''

def code_marker_positions(source: str, marker: str):
    """Yield marker positions outside simple JavaScript strings/comments."""
    index = 0
    quote = None
    while index < len(source):
        char = source[index]
        if quote:
            if char == '\\':
                index += 2
                continue
            if char == quote:
                quote = None
            index += 1
            continue
        if source.startswith('//', index):
            newline = source.find('\n', index + 2)
            index = len(source) if newline < 0 else newline + 1
            continue
        if source.startswith('/*', index):
            end = source.find('*/', index + 2)
            index = len(source) if end < 0 else end + 2
            continue
        if char in ("'", '"', '`'):
            quote = char
            index += 1
            continue
        if source.startswith(marker, index):
            before = source[index - 1] if index else ''
            after = index + len(marker)
            next_char = source[after] if after < len(source) else ''
            if (
                (not before or not (before.isalnum() or before in '_$.'))
                and (not next_char or next_char.isspace() or next_char == '(')
            ):
                yield index
            index = after
            continue
        index += 1

def custom_tool_commands(payload: dict) -> list[str]:
    """Extract literal cmd values from Codex's nested exec wrapper source."""
    if payload.get('name') != 'exec' or payload.get('status') != 'completed':
        return []
    source = payload.get('input')
    if not isinstance(source, str):
        return []

    commands = []
    marker = 'tools.exec_command'
    decoder = json.JSONDecoder()
    for call_start in code_marker_positions(source, marker):
        open_paren = call_start + len(marker)
        while open_paren < len(source) and source[open_paren].isspace():
            open_paren += 1
        if open_paren >= len(source) or source[open_paren] != '(':
            continue
        argument_start = open_paren + 1
        while argument_start < len(source) and source[argument_start].isspace():
            argument_start += 1
        try:
            args, argument_end = decoder.raw_decode(source, argument_start)
        except json.JSONDecodeError:
            continue
        if not isinstance(args, dict) or not source[argument_end:].lstrip().startswith(')'):
            continue
        command = args.get('cmd') or args.get('command') or ''
        if isinstance(command, str):
            commands.append(command)
    return commands

# The window starts AT the invocation, inclusive: the assistant message that
# carries the Skill call is the same message that often carries the report, and
# an exclusive window would drop it as "missing cites".
for i, e in enumerate(events[skill_idx:], skill_idx):
    etype = e.get('type')
    msg = e.get('message') or {}
    if etype == 'assistant':
        for c in (msg.get('content') or []):
            if not isinstance(c, dict):
                continue
            ctype = c.get('type')
            if ctype == 'text':
                main_texts.append(c.get('text') or '')
            elif ctype == 'tool_use':
                tool_name = c.get('name') or ''
                tool_input = c.get('input') or {}
                if tool_name == 'Agent':
                    # Only count Agent calls that carry our independent-reviewer
                    # signature in the prompt. Other agent spawns are unrelated.
                    inp = tool_input
                    if SUBAGENT_SIGNATURE in (inp.get('prompt') or ''):
                        aid = c.get('id')
                        # Reject id=None: a malformed tool_use without an id
                        # would otherwise let any tool_result lacking
                        # `tool_use_id` (also None) match and pollute sub_texts.
                        if aid:
                            agent_ids.add(aid)
                        aname = (inp.get('name') or '').strip()
                        if aname:
                            agent_names.add(aname)
                elif tool_name == 'Read':
                    fp = tool_input.get('file_path') or ''
                    if fp:
                        # Normalize: diff paths use `/`; on Windows, Read passes
                        # backslash absolute paths, so normalize to `/` for suffix match.
                        read_files.add(fp.replace('\\', '/'))
                elif review_packet.accepts_read_evidence(
                    {'name': tool_name, 'input': tool_input}
                ):
                    rendered = json.dumps(
                        {'name': tool_name, 'input': tool_input},
                        ensure_ascii=False,
                    ).replace('\\', '/')
                    read_files.update(
                        df for df in review_packet.files_to_read()
                        if df in rendered
                    )
    elif etype == 'user':
        raw = msg.get('content')
        if isinstance(raw, str):
            report = notification_report(raw)
            if report:
                sub_texts.append(report)
                continue
            # A backgrounded subagent reports through a peer delivery — a
            # user-side STRING message — while its Agent tool_result carries
            # only spawn metadata (just "Spawned successfully..."). Without
            # reading the delivery, a large diff can never satisfy the
            # independent-reviewer gate. Accept a string only when it is
            # wrapped as a harness peer delivery AND comes from an agent that
            # was spawned with the reviewer signature: tool results are lists
            # of tool_result blocks, so nothing the model can echo qualifies.
            # `\n` is unescaped because the report travels inside a JSON envelope.
            if PEER_DELIVERY_RE.search(raw):
                fm = re.search(r'"from"\s*:\s*"([^"]+)"', raw)
                if fm and same_agent(fm.group(1), agent_names):
                    sub_texts.append(raw.replace('\\n', '\n'))
            continue
        # Agent tool_result events live on the user side. Pair with
        # tool_use_id collected above.
        for c in (raw or []):
            if not isinstance(c, dict):
                continue
            if c.get('type') == 'tool_result' and c.get('tool_use_id') in agent_ids:
                content = c.get('content')
                if isinstance(content, str):
                    sub_texts.append(content)
                elif isinstance(content, list):
                    for sub in content:
                        if isinstance(sub, dict) and sub.get('type') == 'text':
                            sub_texts.append(sub.get('text') or '')
    elif etype in ('attachment', 'queue-operation'):
        # Harness delivery record (see delivered_report above).
        if etype == 'attachment':
            att = e.get('attachment')
            payload = att.get('prompt') if isinstance(att, dict) else None
        else:
            payload = e.get('content')
        rep = delivered_report(payload, agent_ids, agent_names)
        if rep:
            sub_texts.append(rep)
    elif etype == 'response_item':
        p = codex_payload(e)
        ptype = p.get('type')
        if ptype == 'message' and p.get('role') == 'assistant':
            main_texts.extend(text_parts(p.get('content')))
        elif ptype == 'message' and p.get('role') == 'user':
            # Codex records harness-delivered subagent notifications as
            # response_item/message user records, not legacy type=user
            # transcript events. Only accept a completed report when the
            # notification names an independent reviewer registered above.
            for text in text_parts(p.get('content')):
                report = notification_report(text)
                if report:
                    sub_texts.append(report)
        elif ptype == 'function_call':
            name = p.get('name') or ''
            args = parse_arguments(p.get('arguments'))
            cmd = args.get('cmd') or args.get('command') or ''
            for df in command_mentions_diff_read(cmd):
                read_files.add(df)
            legacy_independent = (
                name == 'spawn_agent'
                and p.get('namespace') == 'collaboration'
                and is_codex_independent_task(args.get('task_name'))
                and args.get('fork_turns') == 'none'
            )
            harness_independent = (
                name == 'spawn_agent'
                and p.get('namespace') == MULTI_AGENT_NAMESPACE
                and args.get('fork_context') is False
                and has_reviewer_signature(args)
            )
            if legacy_independent or harness_independent:
                aid = p.get('call_id') or p.get('id')
                if aid:
                    codex_pending_agents[aid] = (i, harness_independent)
        elif ptype == 'function_call_output':
            cid = p.get('call_id') or p.get('id')
            if cid in agent_ids:
                out = p.get('output')
                if isinstance(out, str):
                    sub_texts.append(out)
            if cid in codex_pending_agents:
                ack = parse_arguments(p.get('output'))
                pending_at, harness_independent = codex_pending_agents[cid]
                if i > pending_at and harness_independent:
                    agent_id = ack.get('agent_id')
                    if isinstance(agent_id, str) and agent_id:
                        codex_independent_agents[agent_id] = i
                        agent_ids.add(agent_id)
                elif i > pending_at:
                    task_name = ack.get('task_name')
                    if (
                        isinstance(task_name, str)
                        and '/' in task_name
                        and is_codex_independent_task(task_name.rsplit('/', 1)[-1])
                    ):
                        codex_independent_agents[task_name] = i
        elif ptype == 'custom_tool_call' and p.get('name') == 'exec':
            for cmd in custom_tool_commands(p):
                for df in command_mentions_diff_read(cmd):
                    read_files.add(df)
        elif ptype == 'agent_message':
            author = p.get('author') or ''
            recipient = p.get('recipient') or ''
            registered_at = codex_independent_agents.get(author)
            if (
                registered_at is not None
                and i > registered_at
                and recipient == author.rsplit('/', 1)[0]
            ):
                for content in p.get('content') or []:
                    if (
                        isinstance(content, dict)
                        and content.get('type') == 'input_text'
                        and isinstance(content.get('text'), str)
                    ):
                        sub_texts.append(content['text'])

joined_text = '\n'.join(main_texts)
sub_joined_text = '\n'.join(sub_texts)

if review_decision.profile != 'strict':
    skill_invocations = (
        skill_tool_count
        if skill_tool_count
        else skill_text_count
    )
    if skill_invocations > 1:
        review_state = ReviewState(
            target_sha,
            semantic_review_done=True,
            protocol_repairs=1,
            independent_reviews=0,
        )
        emit(
            'FAIL',
            review_state.protocol_failure_message()
            + '\n禁止对同一目标 commit 重跑完整语义审查',
        )

    try:
        normalized_result = parse_review_result(
            joined_text,
            profile=review_decision.profile,
        )
    except Exception as exc:
        emit(
            'FAIL',
            'code review status: incomplete\n'
            'blocking issue: unknown\n'
            'failure type: push-guard protocol problem\n'
            'remaining action: repair the result format once; then stop\n'
            f'detail: {exc}',
        )

    normalized_validation = validate_review_result(
        normalized_result,
        review_packet,
    )
    if not normalized_validation.valid:
        emit(
            'FAIL',
            'code review status: complete\n'
            f'blocking issue: {normalized_result.status == "BLOCK"}\n'
            'failure type: push-guard protocol problem\n'
            'remaining action: repair the finding format once; then stop\n'
            f'detail: {normalized_validation.reason}',
        )

    packet_files = review_packet.files_to_read()
    read_ok = any(
        any(
            read_file == packet_file
            or read_file.endswith('/' + packet_file)
            for packet_file in packet_files
        )
        for read_file in read_files
    )
    if not read_ok:
        emit(
            'FAIL',
            'code review status: complete\n'
            f'blocking issue: {normalized_result.status == "BLOCK"}\n'
            'failure type: push-guard protocol problem\n'
            'remaining action: read one high-priority packet file once; then stop\n'
            f'detail: no equivalent read evidence for {list(packet_files)}',
        )

    if (
        review_decision.tier == 'L2'
        and normalized_result.status == 'BLOCK'
    ):
        independent_count = max(
            len(agent_names),
            len(codex_pending_agents),
        )
        if independent_count > 1:
            review_state = ReviewState(
                target_sha,
                semantic_review_done=True,
                protocol_repairs=0,
                independent_reviews=1,
            )
            emit(
                'FAIL',
                review_state.protocol_failure_message()
                + '\n独立 reviewer 最多允许一次',
            )
        if not sub_joined_text.strip():
            emit(
                'FAIL',
                'code review status: complete\n'
                'blocking issue: yes\n'
                'failure type: push-guard protocol problem\n'
                'remaining action: run one registered independent reviewer; then stop\n'
                'detail: L2 BLOCK requires one independent BLOCK/PASS check',
            )
        try:
            independent_result = parse_review_result(
                sub_joined_text,
                profile=review_decision.profile,
            )
        except Exception as exc:
            emit(
                'FAIL',
                'code review status: complete\n'
                'blocking issue: yes\n'
                'failure type: push-guard protocol problem\n'
                'remaining action: repair the independent result once; then stop\n'
                f'detail: {exc}',
            )
        independent_validation = validate_review_result(
            independent_result,
            review_packet,
        )
        if not independent_validation.valid:
            emit(
                'FAIL',
                'code review status: complete\n'
                'blocking issue: yes\n'
                'failure type: push-guard protocol problem\n'
                'remaining action: repair the independent finding once; then stop\n'
                f'detail: {independent_validation.reason}',
            )
        if independent_result.status != normalized_result.status:
            emit(
                'FAIL',
                'code review status: complete\n'
                'blocking issue: unknown\n'
                'failure type: code risk disagreement\n'
                'remaining action: user decides whether to fix or re-examine once\n'
                f'detail: main={normalized_result.status}, '
                f'independent={independent_result.status}',
            )

    emit(
        'PASS',
        f'normalized review passed: {normalized_result.status}; '
        f'tier={review_decision.tier}; '
        f'independent={review_decision.tier == "L2" and normalized_result.status == "BLOCK"}',
    )

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

# Parse 6 cites. Path uses `.+?` (not `\S+?`) so filenames with spaces
# work; the trailing `:(\d+)\s+\(` anchor pins the non-greedy match to the
# last `:digits` before the reason paren.
CITE_RE = re.compile(
    r'D([1-7])\s+(CLEAN|FIXED|SKIPPED)\s+[—\-]\s+(.+?):(\d+)\s+\(([^)]{1,200})\)'
)

cites: dict = {}
for m in CITE_RE.finditer(joined_text):
    dim = int(m.group(1))
    cites[dim] = {
        'verdict': m.group(2),
        # diff_files always use `/`; normalize cite path so a Windows-typed
        # cite with backslashes still matches.
        'file': m.group(3).replace('\\', '/'),
        'line': int(m.group(4)),
        'reason': m.group(5),
    }

missing = [d for d in (1, 2, 3, 4, 5, 6, 7) if d not in cites]
if missing:
    miss_list = ', '.join(f'D{d}' for d in missing)
    emit('FAIL',
         f'missing cites for {miss_list}. Required format: '
         f'`D{{N}} {{CLEAN|FIXED|SKIPPED}} — {{file}}:{{line}} ({{reason}})` '
         f'with all 7 dimensions.')

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
    6: re.compile(
        r'\b(price|amount|cost|pnl|return|rate|ratio|percent|quantity)\b'
        r'|\b(round|abs|int|float)\s*\(',
        re.IGNORECASE,
    ),
    7: re.compile(
        # given|when|then are deliberately absent: they are BDD words, but they
        # are also plain English and shell syntax (`if ...; then`), so they
        # rejected honest SKIPPED verdicts on shell diffs — and since the
        # independent reviewer also reports SKIPPED for a no-test diff, the two
        # reports could never agree. Everything else in the list is unchanged.
        r'\b(test_|assert|mock|patch|unittest|pytest|expect|should|'
        r'fixture|setUp|tearDown)\b'
        r'|\bdef test_',
        re.IGNORECASE,
    ),
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

# ===== Dual-reviewer gate =====
# Large diffs require an independent reviewer subagent. Small diffs may use one
# but don't have to. When a subagent IS present, its 7-dimension verdict must
# agree with the main agent's per-dimension — disagreement means a real risk
# was spotted by one and missed by the other.
diff_added_lines = sum(
    1 for line in diff_full.split('\n')
    if line.startswith('+') and not line.startswith('+++')
)
diff_is_large = diff_added_lines > 30 or len(diff_files) > 2

# Anchor sub-cite extraction to the LAST contiguous D1→D2→D3→D4→D5→D6 sequence.
    # A subagent is told to emit exactly seven lines, but real outputs often contain
# stray CITE_RE-shaped strings: CoT preamble (`先看 D1 ...`) before the block,
# or FINDINGS bullets after the block that quote `D{N} VERDICT — file:line` as
# discussion examples. A naive last-wins parse lets such strays override real
# verdicts. Requiring strict 1,2,3,4,5,6 dim-order means stray cites that don't
# form a complete in-order block are ignored. Multiple complete blocks → the
# last one wins (re-emission is supported).
sub_cites: dict = {}
_seq: list = []  # in-progress 1..7 block being built
for m in CITE_RE.finditer(sub_joined_text):
    dim = int(m.group(1))
    expected = len(_seq) + 1
    if dim == expected:
        _seq.append(m)
        if len(_seq) == 7:
            sub_cites = {
                int(sm.group(1)): {
                    'verdict': sm.group(2),
                    'file': sm.group(3).replace('\\', '/'),
                    'line': int(sm.group(4)),
                    'reason': sm.group(5),
                }
                for sm in _seq
            }
            _seq = []
    elif dim == 1:
        # Stray match broke the sequence, but this match is itself a fresh D1
        # so start a new attempt from here.
        _seq = [m]
    else:
        _seq = []

if diff_is_large and not sub_cites:
    emit('FAIL',
         f'diff is large ({diff_added_lines} added lines across '
         f'{len(diff_files)} files); independent reviewer subagent is '
         f'required. Spawn the Agent tool with prompt starting '
         f'"{SUBAGENT_SIGNATURE}" — see SKILL.md Step 3.5.')

if sub_cites:
    sub_missing = [d for d in (1, 2, 3, 4, 5, 6, 7) if d not in sub_cites]
    if sub_missing:
        miss_list = ', '.join(f'D{d}' for d in sub_missing)
        emit('FAIL',
             f'independent reviewer subagent report is missing cites for '
             f'{miss_list}. Subagent must emit all 7 dimensions in the same '
             f'format as the main report.')
    for dim in (1, 2, 3, 4, 5, 6, 7):
        m_v = cites[dim]['verdict']
        s_v = sub_cites[dim]['verdict']
        if m_v != s_v:
            emit('FAIL',
                 f'D{dim} verdict mismatch: main={m_v}, independent={s_v}. '
                 f'Reconcile (fix code or re-examine) and re-emit both reports.')

emit('PASS', 'all 7 cites validated against diff hunks')
PYEOF
)

AUDIT_VERDICT=$(printf '%s\n' "$AUDIT_OUTPUT" | sed -n '1p')
AUDIT_REASON=$(printf '%s\n' "$AUDIT_OUTPUT" | sed -n '2,$p')

# A verdict always carries a reason on every emit() path; an empty one means the
# audit stage crashed. Say so instead of denying with a blank explanation.
if [ -z "$AUDIT_REASON" ]; then
    AUDIT_REASON="the audit stage produced no verdict (hook internal failure); retry, or inspect the hook."
fi

if [ "$AUDIT_VERDICT" = "PASS" ]; then
    exit 0
fi

# Deny, but hand the decision to the user: running the review is no longer
# automatic. The push stays blocked until the review passes, so declining the
# review can only end in an abandon, never in an unreviewed push.
#
# This script is passed through `-c`, and `-c` is decoded with the locale
# encoding — NOT with Python's usual UTF-8 source rule. One literal non-ASCII
# character here therefore kills the emitter outright on a GBK/ASCII locale,
# and a dead hook is a silent allow. Keep the script ASCII-only: write the
# emoji and the em dash as \u escapes (json.dumps emits them escaped anyway).
REASON="$AUDIT_REASON" PYTHONIOENCODING=utf-8 "$PYTHON_BIN" -c "
import json, os
reason = os.environ.get('REASON', '')
ask = (
    'This push is unreviewed. The rule is: the user decides the next step. '
    'Ask the user to choose between '
    '(a) run the pre-push review and push, or (b) abandon this push. '
    '(Claude Code: use AskUserQuestion. Codex: ask in your reply.) '
    'On (a): run skill push-guard:pre-push-review, clear this audit, retry the push. '
    'On (b): stop and leave the commits local. '
    'If you already asked for this push and the user chose the review, do not ask '
    'again: fix the audit detail below and retry. '
    'Audit detail: '
)
print(json.dumps({
    'systemMessage': '\u23f8\ufe0f push-guard: unreviewed push paused \u2014 waiting for your choice (review / abandon). ' + reason,
    'decision': 'block',
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': ask + reason
    }
}))
"
exit 0
