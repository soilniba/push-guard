# push-guard

Pre-push code safety review plugin for Claude Code. Works with any language.

Blocks `git push` (executed via Claude's Bash tool) until a systematic 7-dimension code review is completed. The hook does not start that review on its own: it asks you to choose between running the review (and pushing) and abandoning the push.

## 文档

设计、需求原文和开发记录见 [docs/README.md](docs/README.md)。

## What It Checks

| Dimension | What |
|---|---|
| 1. Exception path safety | Every external call's error paths — no unbound variables after exceptions |
| 2. I/O encoding boundary | No `seek + decode` landing mid-UTF-8 char; no truncated chunked reads |
| 3. External data type validation | `json.loads` / API responses / env vars validated before field access |
| 4. State / invariant completeness | All fields set on state transition; dispatchers fully registered |
| 5. Hardcoded secrets | No credentials, tokens, or private keys in committed code |
| 6. Semantic logic correctness | Variables, units, formulas, and return values match their meaning |
| 7. Test quality | Tests exercise real behavior, boundaries, and failure paths |

## How It Works

1. `PreToolUse` hook intercepts every Bash tool call
2. If the command contains `git push`, the hook resolves the target commit and the remote-tracking diff base
3. The hook reads the session transcript and verifies the skill invocation, modified-file read, and 7-dimension report
4. Missing or invalid evidence blocks the push and asks you to choose: run the review, or abandon the push
5. Every new target commit is checked against the remote-tracking base; if no base exists, the target is checked against the empty tree

### Why remote-tracking based?

Using the local `main`/`master` branch as the merge-base makes a push from that branch compare HEAD with itself and skip the review. The hook instead uses the remote-tracking branch for the push target, such as `origin/main` or `origin/master`.

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
