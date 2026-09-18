# push-guard

Pre-push code safety review plugin for Claude Code and Codex. Works with any
language and keeps the same risk and blocking semantics in both environments.

Blocks `git push` until the user chooses whether to run the review or abandon
the push. The default review is bounded and looks for clear, severe,
diff-verifiable bugs; the historical 7-dimension protocol remains available in
the manually selected `strict` profile.

## 文档

设计、需求原文和开发记录见 [docs/README.md](docs/README.md)。

## 手动审查档位

The plugin never reads, guesses, or scores model capability. Select the review
profile manually when the model or project risk changes:

```bash
PUSH_GUARD_PROFILE=fast
PUSH_GUARD_PROFILE=balanced
PUSH_GUARD_PROFILE=strict
```

`balanced` is the default. `fast` and `balanced` use one normalized
`PASS/BLOCK/NOTE` review. `strict` retains the legacy seven-dimension report
and its compatibility checks.

## What It Checks

The mechanical policy classifies the target diff:

| Tier | Behavior |
|---|---|
| L0 | Documentation-only changes pass without a model review |
| L1 | Ordinary executable changes receive one bounded review |
| L2 | Hook, permission, command, migration, lock, retry, task/target, and other high-risk changes receive focused review |

Large line counts or file counts alone do not start a second reviewer.
Every L1/L2 review runs once in a fresh-context subagent; the current session
only coordinates the review and cannot self-approve from its conversation
history.

| Dimension | What |
|---|---|
| 1. Exception path safety | Every external call's error paths — no unbound variables after exceptions |
| 2. I/O encoding boundary | No `seek + decode` landing mid-UTF-8 char; no truncated chunked reads |
| 3. External data type validation | `json.loads` / API responses / env vars validated before field access |
| 4. State / invariant completeness | All fields set on state transition; dispatchers fully registered |
| 5. Hardcoded secrets | No credentials, tokens, or private keys in committed code |
| 6. Semantic logic correctness | Variables, units, formulas, and return values match their meaning |
| 7. Test quality | Tests exercise real behavior, boundaries, and failure paths |

The table above describes the legacy checklist retained for `strict`. In the
default profiles, these checks are internal guidance rather than seven
mandatory citations.

## How It Works

1. `PreToolUse` hook intercepts every Bash tool call
2. If the command contains `git push`, the hook resolves the target commit and the remote-tracking diff base
3. The hook classifies the diff as L0/L1/L2 and creates a target-scoped review packet
4. The hook reads the session transcript and verifies that a registered review subagent produced the selected profile's result and that equivalent file-read evidence exists
5. Missing or invalid evidence blocks the push and asks you to choose: run the review, or abandon the push
6. Every new target commit is checked against the remote-tracking base; if no base exists, the target is checked against the empty tree

Protocol failures are reported as plugin protocol or environment problems,
not silently labeled as code defects. A target commit cannot trigger an
unbounded semantic-review loop; at most one protocol repair and one isolated
review subagent are allowed.

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

### Updating a local plugin checkout

The client hook is loaded from the installed plugin cache, not directly from the
working tree. After changing hooks or launcher code, update the plugin version
in the manifests, reinstall it from the local marketplace, and start a new
Codex/Claude Code thread so the new `PreToolUse` hook is loaded. Do not use a
Git `pre-push` hook as a substitute: the push gate belongs to the client hook
layer.

## Manual Skill Invocation

You can also invoke the skill directly without waiting for a blocked push:

```
push-guard:pre-push-review
```

## Uninstall

```bash
claude plugin remove push-guard
```
