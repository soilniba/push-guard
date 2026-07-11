# push-guard

Pre-push code safety review plugin for Claude Code. Works with any language.

Automatically blocks `git push` (executed via Claude's Bash tool) until a systematic 4-dimension code review is completed.

## What It Checks

| Dimension | What |
|---|---|
| 1. Exception path safety | Every external call's error paths — no unbound variables after exceptions |
| 2. I/O encoding boundary | No `seek + decode` landing mid-UTF-8 char; no truncated chunked reads |
| 3. External data type validation | `json.loads` / API responses / env vars validated before field access |
| 4. State / invariant completeness | All fields set on state transition; dispatchers fully registered |

## How It Works

1. `PreToolUse` hook intercepts every Bash tool call
2. If the command contains `git push`, the hook parses the refspec to identify the local ref being pushed and resolves it to a commit SHA
3. The hook reads `/tmp/pre-push-review-done`. If absent **or** if its content does not equal the target ref's SHA → **blocks push**, prompts to run skill
4. Run `push-guard:pre-push-review` → skill guides the dimension-by-dimension scan, then writes the HEAD SHA into the marker via `git rev-parse HEAD > /tmp/pre-push-review-done`
5. Hook consumes (deletes) the marker on every check
6. **Every push requires its own review** — the token is single-use, and amending or adding new commits invalidates the marker (SHA changes), forcing a fresh review

### Why content-validated?

Earlier versions used file-existence as the gate, which a bare `touch /tmp/pre-push-review-done` could bypass — including accidental cases where the marker-creation command was chained (`touch ... && git push`) in a single Bash call, producing no real review window. Tying the marker to the HEAD SHA closes that loop: the marker can only be produced from inside the working tree, after the commit being pushed exists, and is invalidated the moment HEAD moves.

### Pushing from a different repo: use `git -C`, not `cd &&`

The hook is a token-level parser — it reads `git -C <path>` from the command and resolves the ref in that repo, but it can't follow shell builtins like `cd` (no reliable way to track cwd mutations across `cd ... && git ...`). When the Bash tool's cwd is repo A but you want to push repo B:

✅ `git -C /path/to/repoB push origin main`
❌ `cd /path/to/repoB && git push origin main` — hook resolves the ref in repo A's cwd, mismatches the marker SHA, blocks the push

## Install

### Claude Code

```bash
claude plugin add soilniba/push-guard
```

### Codex

Install from a local Codex marketplace that points at this repository, then trust
the hook in `/hooks`:

```bash
codex plugin marketplace add /home/wangr/projects/push-guard
codex plugin add push-guard@push-guard
```

Codex loads plugin hooks from `hooks/hooks.json`. The hook reads both standard and
`custom_tool_call` Codex transcript events, then blocks `git push` until
`push-guard:pre-push-review` has emitted the required 7-dimension report.

## Manual Skill Invocation

You can also invoke the skill directly without waiting for a blocked push:

```
push-guard:pre-push-review
```

## Uninstall

```bash
claude plugin remove push-guard
```
