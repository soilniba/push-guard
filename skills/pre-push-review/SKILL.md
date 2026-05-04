---
name: pre-push-review
description: Use before every git push or PR creation to run a systematic 4-dimension code safety scan on modified code
---

# Pre-Push Code Safety Review

**Announce at start:** "I'm using push-guard:pre-push-review to scan modified code before pushing."

## When to Use

**Mandatory** — before any `git push` or PR creation.

The hook auto-blocks `git push` via Bash tool until this skill completes.

## The Process

### Step 1: Identify Scope

```bash
git diff --name-only HEAD~1..HEAD 2>/dev/null || git diff --cached --name-only
```

List which files were modified. Only scan **new or modified functions** in those files — don't rescan unchanged code.

### Step 2: Read Modified Sections

Use Read tool to load only the changed functions/methods. Do not re-read files you already have in context unless they changed.

### Step 3: Run 4-Dimension Scan

For each modified function, answer every question below. If any answer is "no" or "unknown", fix the code or add a test before proceeding.

---

**Dimension 1 — External Call Exception Safety**

For every external call in modified code (`subprocess.run`, file I/O, network, DB, shell):

- [ ] If this call raises an exception, is every variable used afterward still guaranteed to be bound?
- [ ] After any `try/finally` block, are `result` / `fd` / `conn` / similar variables provably bound?
- [ ] Are return codes / HTTP status / error fields always checked (no silent assumption of success)?

---

**Dimension 2 — I/O Encoding Boundary Safety** *(skip if no binary/text conversion)*

- [ ] After `f.seek(offset)`, is `offset` guaranteed to land on a character boundary (never mid-UTF-8 multibyte sequence)?
- [ ] In streaming or chunked reads, can any chunk be missing the end of a logical unit (line, record, JSON object)?
- [ ] If either risk exists: is the code using byte-level reverse scan or a known-safe boundary (e.g., `\n` byte)?

---

**Dimension 3 — External Data Type Validation**

- [ ] Every `json.loads()` / `yaml.safe_load()` / API response result: is the type checked (`isinstance(x, dict)`) before calling `.get()` or `[]`?
- [ ] Environment variables / CLI args / user input / HTTP body: validated at the system boundary for type and range?

---

**Dimension 4 — State / Invariant Completeness** *(skip if no state machine, workflow, or registry)*

- [ ] Every transition into a target state: are **all** required fields set, not just the primary "phase" field?
- [ ] Fields that must be `None` in the target state: explicitly cleared in `model_copy` / assignment?
- [ ] New event types / message kinds / routes / commands: registered in the dispatcher / handler map?

---

### Step 4: Report Results

For each dimension, state one of:
- ✅ **CLEAN** — all questions answered yes
- ⚠️ **FIXED** — found an issue, fixed it (describe what changed)
- ⏭️ **SKIPPED** — dimension not applicable (state why)

If any fix was made, run the test suite:

```bash
# Adapt to project's test runner
python -m pytest -x -q 2>&1 | tail -5
# or: npm test / cargo test / go test ./... / etc.
```

### Step 5: Unblock Push

After all dimensions are CLEAN or FIXED (and tests pass if fixes were made):

```bash
touch /tmp/pre-push-review-done
```

Push is now unblocked for the next 30 minutes.

---

## Red Flags

**Never:**
- Mark a dimension CLEAN without actually checking every question
- Skip Dimension 1 because "it's simple code"
- Unblock push if tests are failing after a fix

**If you find a real bug:** fix it, run tests, then continue the scan — don't stop early.
