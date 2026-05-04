---
name: pre-push-review
description: Use before every git push or PR creation to run a systematic 4-dimension code safety scan on modified code
---

# Pre-Push Code Safety Review

**Announce at start:** "I'm using push-guard:pre-push-review to scan modified code before pushing."

## When to Use

**Mandatory** — before any `git push` or PR creation. The hook auto-blocks `git push` via Bash tool until this skill completes.

---

## The Process

### Step 1: Determine What Changed

Get the diff range relative to the base branch (handles single commit, multi-commit branches, and initial commits):

```bash
# Preferred: diff against merge base with main/master
git diff $(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || git rev-parse --root HEAD) HEAD --stat

# Fallback if above fails (e.g. no main branch yet):
git diff HEAD~1 HEAD --stat 2>/dev/null || git diff --cached --stat
```

If there are **no modified source files** (only docs, configs, lockfiles): skip to Step 5 directly.

Then get the actual diff to identify which functions changed and at which line numbers:

```bash
git diff $(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null) HEAD
```

Note which **functions / methods** were added or modified. Only those need scanning — do not rescan unchanged code.

### Step 2: Read Modified Sections

Using the line numbers from the diff output, Read only the changed functions from each file. Do not re-read files already in context unless they changed.

### Step 3: Run 4-Dimension Scan

For each modified function, answer every question. If any answer is "no" or "unknown": fix the code or add a test, then re-check that dimension before proceeding.

---

**Dimension 1 — External Call Exception Safety**

For every external call (`subprocess.run`, file I/O, network request, DB query, shell command):

- [ ] If this call raises an exception, are all variables used afterward still guaranteed to be bound?
- [ ] After any `try/finally` block, are `result` / `fd` / `conn` / similar variables provably bound before use?
- [ ] Are return codes / HTTP status codes / error fields always checked? (No silent assumption of success.)

---

**Dimension 2 — I/O Encoding Boundary Safety** *(skip entirely if no binary↔text conversion in modified code)*

- [ ] After `f.seek(offset)` + `decode()`: is `offset` guaranteed to land on a character boundary, never mid-multibyte sequence?
- [ ] In streaming or chunked reads: can a chunk end in the middle of a logical unit (line, JSON object, frame header)?
- [ ] If either risk exists: does the code read from a provably safe boundary (e.g., byte-level scan for `\n`, or use of a length-prefixed protocol)?

---

**Dimension 3 — External Data Type Validation**

- [ ] Every `json.loads()` / `yaml.safe_load()` / deserialized API response: is the top-level type checked before field access (e.g., `isinstance(x, dict)` before `.get()` or `x["key"]`)?
- [ ] Environment variables / CLI args / user input / HTTP request body: validated for type and range at the system boundary, not assumed?

---

**Dimension 4 — State / Invariant Completeness** *(skip entirely if no state machine, event dispatcher, or handler registry in modified code)*

- [ ] Every transition into a target state: are **all** required fields set — not just the primary status/phase field, but also secondary fields (e.g., IDs that must be None, counters that reset)?
- [ ] Fields that must be cleared on entering a state: explicitly set to `None` / `0` / empty — not left as whatever they were before?
- [ ] New event types / message kinds / routes / commands: registered in every relevant dispatcher, handler map, or routing table?

---

### Step 4: Report Results

State the outcome for each dimension:

- ✅ **CLEAN** — all questions answered yes, no issues found
- ⚠️ **FIXED** — found an issue; describe file:line and what was changed
- ⏭️ **SKIPPED** — not applicable; one-line reason (e.g., "no I/O in modified code")

**Example report:**
```
Dimension 1 — ✅ CLEAN
Dimension 2 — ⏭️ SKIPPED (no binary/text conversion in changed functions)
Dimension 3 — ⚠️ FIXED: api.py:42 — added isinstance(resp, dict) check before resp.get("data")
Dimension 4 — ✅ CLEAN
```

If any dimension is FIXED, run the test suite before proceeding:

```bash
# Adapt to project's test runner:
python -m pytest -x -q 2>&1 | tail -5
# npm test | cargo test | go test ./... | make test
```

All tests must pass before unblocking push.

### Step 5: Unblock Push

After all dimensions are CLEAN or FIXED (and tests pass if anything was fixed):

```bash
touch /tmp/pre-push-review-done
```

Push is unblocked for 30 minutes from this moment. If you don't push within 30 minutes, the hook will ask you to re-run the skill.

---

## Red Flags

**Never:**
- Mark CLEAN without reading the actual modified code
- Skip Dimension 1 because "it looks simple" — exception paths hide in simple code
- Call `touch /tmp/pre-push-review-done` before tests pass after a fix
- Scan only the last commit when the branch has multiple commits (Step 1 uses merge-base)
