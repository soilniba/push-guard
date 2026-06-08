---
name: pre-push-review
description: Use before every git push or PR creation to run a systematic 6-dimension code safety scan on modified code
---

# Pre-Push Code Safety Review

**Announce at start:** "I'm using push-guard:pre-push-review to scan modified code before pushing."

## When to Use

**Mandatory** — before any `git push` or PR creation. The hook auto-blocks `git push` via Bash tool until this skill runs and emits a valid 6-dimension report with verifiable file:line citations.

## Anti-Bypass Notice

The hook does **not** trust a marker file or self-attestation. It reads the Claude Code session transcript and verifies:

1. This skill was actually invoked since the HEAD commit
2. The 6-dimension report was emitted in the required format (below)
3. Every CLEAN/FIXED cite points to a `file:line` that is **inside this push's diff**
4. SKIPPED dimensions are only allowed when the diff genuinely contains no patterns matching that dimension

You cannot pass by writing a marker, by reciting verdicts without cites, or by citing arbitrary lines outside the diff. Faking a passable report requires actually reading the diff and finding real lines — at which point you've done the review.

---

## The Process

### Step 1: Determine What Changed

```bash
# Diff against merge base with main/master (handles single + multi-commit branches)
git diff $(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null) HEAD --stat

# Or for the actual hunks (you'll need line numbers for cites):
git diff $(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null) HEAD
```

Note which **files + functions + line ranges** are touched. You will need real line numbers from these hunks for the citations.

### Step 2: Read Modified Sections

Use the `Read` tool to open every modified file at the relevant line ranges. The hook also verifies that at least one `Read` call landed on a modified file — pure-text cites without reading anything will be rejected.

### Step 3: Run 5-Dimension Scan

For each modified function, work through every checklist item. If any answer is "no" or "unknown": fix the code (or add a test) before continuing.

---

**Dimension 1 — External Call Exception Safety & Resource Leaks**

For every external call (`subprocess.run`, file I/O, network request, DB query, shell command):

- [ ] If this call raises, are all variables used afterward still guaranteed to be bound?
- [ ] After any `try/finally` block, are `result` / `fd` / `conn` / similar variables provably bound before use?
- [ ] Are return codes / HTTP status / error fields always checked? (No silent assumption of success.)
- [ ] Every opened file handle: closed in all code paths via `with` or `finally`?
- [ ] Every acquired connection (DB, network, lock): released in all paths including the exception path?

---

**Dimension 2 — I/O Encoding Boundary Safety** *(SKIPPED only if diff has no `encode/decode/seek` and no binary↔text conversion)*

- [ ] After `f.seek(offset)` + `decode()`: is `offset` guaranteed to land on a character boundary, never mid-multibyte sequence?
- [ ] In streaming or chunked reads: can a chunk end in the middle of a logical unit (line, JSON object, frame header)?
- [ ] If either risk exists: does the code read from a provably safe boundary (e.g., byte-level scan for `\n`, length-prefixed protocol)?

---

**Dimension 3 — External Data Type Validation** *(SKIPPED only if diff has no `json.loads / yaml.safe_load / pickle.loads / response.json` and no parsing of env/CLI/HTTP input)*

- [ ] Every deserialized payload: top-level type checked before field access (e.g., `isinstance(x, dict)` before `.get()` or `x["key"]`)?
- [ ] Env vars / CLI args / user input / HTTP body: validated for type and range at the system boundary?
- [ ] Every discriminator / enum string from external data (e.g., `verdict`, `kind`, `status`, `type`): does the code branch on **every known value** AND have an explicit **unknown fallback** (warn / skip / raise)?

---

**Dimension 4 — State / Invariant Completeness** *(SKIPPED only if diff has no state-machine / dispatcher / handler-registry patterns)*

- [ ] Every transition into a target state: are **all** required fields set — not just the primary status field, but secondary fields (IDs that must be None, counters that reset)?
- [ ] Fields that must be cleared on entering a state: explicitly set to `None` / `0` / empty?
- [ ] New event types / message kinds / routes / commands: registered in every relevant dispatcher / handler map / routing table?
- [ ] Loop-derived dedup sets built from prior events (e.g., `seen = {e.id for e in events if e.event == "X"}`): when the same loop **emits new entries**, is the set `.add(...)`'d **in-iteration**?

---

**Dimension 5 — Hardcoded Secrets** *(SKIPPED only if diff introduces no credentials, tokens, keys, or config files)*

- [ ] No API keys, tokens, passwords, or private keys hardcoded as string literals?
- [ ] No credentials in log statements, error messages, or exception strings?
- [ ] Any new config / settings files that could contain credentials: listed in `.gitignore`?
- [ ] Credentials loaded exclusively from env vars / secret managers / gitignored config — not committed alongside code?

---

**Dimension 6 — Semantic Logic Correctness** *(SKIPPED only if diff has no business logic / calculation changes)*

- [ ] 变量的实际含义是否匹配其使用场景？（如 score 是排序分数，不是价格）
- [ ] 单位/量纲是否一致？（百分比 vs 小数、万元 vs 元）
- [ ] 计算公式是否合理？（止损价应低于买入价、收益率不会超过 100%）
- [ ] 函数返回值的语义是否与调用方期望匹配？
- [ ] 硬编码数值是否有业务依据？（magic number 检查）

---

### Step 3.5: Independent Reviewer Subagent (REQUIRED for large diffs)

The hook treats a diff as **large** when it adds more than 30 lines OR touches more than 2 files. For a large diff, you must spawn an independent reviewer subagent and the hook will compare its 6-dimension verdicts against yours per dimension. Mismatch on any dimension blocks the push.

**Why:** the same agent that wrote the code also reviews it. A fresh-context subagent reading the diff cold catches blind spots that confirmation bias missed. Verdict agreement across two independent passes is much stronger evidence than a single self-review.

**Small diffs** (≤30 added lines AND ≤2 files): subagent is optional, but if you spawn one its verdict still must agree.

**How to spawn (verbatim template — the signature is what the hook looks for):**

Invoke the `Agent` tool with `subagent_type: "general-purpose"` and the prompt below (copy literally; the bracketed signature on the first line is mandatory):

```
[PUSH-GUARD-INDEPENDENT-REVIEW v1]

You are an independent code reviewer. You have NO context from the parent
conversation, NO access to project memory, and you MUST NOT invoke any Skill,
MUST NOT read ~/.claude/CLAUDE.md, MUST NOT read project memory files under
.claude/projects/*/memory/, and MUST NOT read .claude/settings.json.

Your job: scan the diff at HEAD against its merge-base with main/master, then
emit exactly six lines in this format:

  D{N} {VERDICT} — {file}:{line} ({reason ≤80 chars})

Where N is 1..6, VERDICT is CLEAN | FIXED | SKIPPED, file:line is inside the
diff hunks for CLEAN/FIXED (use file:0 for SKIPPED), reason is ≤80 chars.

The six dimensions:
  D1 — External call exception safety & resource leaks
  D2 — I/O encoding boundary safety (SKIPPED if no encode/decode/seek)
  D3 — External data type validation (SKIPPED if no json.loads/yaml/etc.)
  D4 — State / invariant completeness (SKIPPED if no state machine / registry)
  D5 — Hardcoded secrets (SKIPPED if no credentials introduced)
  D6 — Semantic logic correctness (SKIPPED if no business logic changes)

Process:
  1. Run: git diff $(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null) HEAD
  2. Read each modified file at the touched line ranges using the Read tool.
  3. For each dimension, decide CLEAN / FIXED / SKIPPED on the merits — do NOT
     defer to or read any prior review.
  4. Output the six lines. No preamble, no summary, no extra text.
```

After the subagent returns, the hook will parse its 6-line report from the Agent tool_result and require D1–D6 verdicts to match yours. If they disagree, neither push goes through; reconcile the disagreement (fix the code, or re-examine your verdict, or the subagent's) and re-emit both reports.

### Step 4: Emit the Report (REQUIRED FORMAT)

Output **exactly six** lines, one per dimension, in this format:

```
D{N} {VERDICT} — {file}:{line} ({reason ≤80 chars})
```

Where:
- `{N}` is `1` … `6`
- `{VERDICT}` is `CLEAN`, `FIXED`, or `SKIPPED`
- `{file}` is the path relative to repo root (must be in this push's diff for CLEAN/FIXED)
- `{line}` is a real line number inside the diff hunks for CLEAN/FIXED; use `0` for SKIPPED
- `{reason}` is a free-text justification (≤80 chars). For SKIPPED, the reason should briefly state why the dimension doesn't apply.

The em-dash `—` between verdict and file:line is required (a regular hyphen `-` is also accepted).

**Example report (passes audit):**
```
D1 CLEAN — hooks/check-push-guard.sh:54 (_is_shell_boundary 是纯函数无 I/O)
D2 SKIPPED — hooks/check-push-guard.sh:0 (无 encode/decode/seek 调用)
D3 CLEAN — hooks/check-push-guard.sh:43 (shlex 输出已是 str，类型契约成立)
D4 SKIPPED — hooks/check-push-guard.sh:0 (无状态机/dispatcher)
D5 SKIPPED — hooks/check-push-guard.sh:0 (无密钥/凭据)
D6 SKIPPED — hooks/check-push-guard.sh:0 (无业务逻辑/计算变更)
```

**FIXED format** is the same — cite the file:line you fixed:
```
D3 FIXED — api.py:42 (added isinstance(resp, dict) before resp.get("data"))
```

If any dimension was FIXED, run the test suite before emitting the report:
```bash
python -m pytest -x -q 2>&1 | tail -5
# or: npm test | cargo test | go test ./...
```

### Step 5: Push

After emitting the report, run `git push` directly. The hook reads the transcript, finds your skill invocation + report, validates every cite against the diff hunks, and decides pass/deny. **No marker file to write.** No "unblock" step.

If the hook denies, the rejection reason will name the specific cite or check that failed (e.g., "D2 cite line 0 with reason 'no encoding' but diff contains `.decode\\(`"). Fix the report (or the underlying issue) and re-emit, then retry push.

---

## Red Flags

**Never:**
- Mark CLEAN without a real `file:line` cite that's inside the diff hunk
- Mark SKIPPED for a dimension whose patterns appear in the diff (the hook will catch this)
- Emit the 5 lines without actually `Read`-ing any modified file (the hook checks for Read tool calls)
- Recite the format from memory without re-running the actual scan against the current diff
- Ask the user to manually approve a known-broken cite to bypass the audit
