# push-guard

Pre-push code safety review plugin for Claude Code.

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
2. If the command contains `git push`, checks for `/tmp/pre-push-review-done`
3. If marker absent → **blocks push**, prompts to run skill
4. Run `push-guard:pre-push-review` → skill guides 4-dimension scan
5. Skill creates marker on completion → hook consumes (deletes) it on next push
6. **Every push requires its own review** — the token is single-use

## Install

```bash
claude plugin add soilniba/push-guard
```

## Manual Skill Invocation

You can also invoke the skill directly without waiting for a blocked push:

```
push-guard:pre-push-review
```

## Uninstall

```bash
claude plugin remove push-guard
```
