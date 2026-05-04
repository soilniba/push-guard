---
name: pre-push-review
description: Use before every git push or PR creation to run a systematic 5-dimension code safety scan on modified code
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

### Step 3: Run 5-Dimension Scan

For each modified function, answer every question. If any answer is "no" or "unknown": fix the code or add a test, then re-check that dimension before proceeding.

---

**Dimension 1 — External Call Exception Safety & Resource Leaks**

For every external call (`subprocess.run`, file I/O, network request, DB query, shell command):

- [ ] If this call raises an exception, are all variables used afterward still guaranteed to be bound?
- [ ] After any `try/finally` block, are `result` / `fd` / `conn` / similar variables provably bound before use?
- [ ] Are return codes / HTTP status codes / error fields always checked? (No silent assumption of success.)
- [ ] Every opened file handle: closed in all code paths — via `with` statement or explicit `finally`?
- [ ] Every acquired connection (DB, network, lock): released in all code paths including the exception path?

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

**Dimension 5 — Hardcoded Secrets** *(skip entirely if modified code introduces no credentials, tokens, keys, or config files)*

- [ ] No API keys, tokens, passwords, or private keys hardcoded as string literals in source?
- [ ] No credentials appearing in log statements, error messages, or exception strings?
- [ ] Any new config / settings files that could contain credentials: listed in `.gitignore`?
- [ ] Credentials loaded exclusively from env vars, secret managers, or gitignored config files — not committed alongside code?

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
Dimension 5 — ⏭️ SKIPPED (no credentials or config files in modified code)
```

If any dimension is FIXED, run the test suite before proceeding:

```bash
# Adapt to project's test runner:
python -m pytest -x -q 2>&1 | tail -5
# npm test | cargo test | go test ./... | make test
```

All tests must pass before unblocking push.

### Step 5: Unblock Push

The token is **single-use** *and* **content-validated**: the marker file must contain the SHA of the commit being pushed (HEAD). The hook reads the marker, compares its content to the SHA of the ref being pushed, and deletes the marker on every check (pass or fail). A bare `touch` will NOT bypass — empty content fails the check.

**Case A — All dimensions CLEAN (no bugs found):**

```bash
git rev-parse HEAD > /tmp/pre-push-review-done
```

**Case B — Some dimensions FIXED (bugs found and fixed, tests pass):**

Confirm all fixes are complete and tests are green, then:

```bash
git rev-parse HEAD > /tmp/pre-push-review-done
```

**Case C — Issues found but user decides not to fix now:**

Stop. Ask the user explicitly:

> "Found [describe issue]. Fix before pushing, or confirm you're OK pushing with this known issue?"

Only create the token after the user explicitly says it's acceptable to push as-is.

#### CRITICAL: Standalone Invocation Required

The marker-writing command **MUST be its own Bash tool call**. Do NOT combine it with `git add`, `git commit`, `git push`, or any other command in the same Bash invocation.

❌ **Forbidden** (defeats the safety boundary — marker is created and consumed in one call, the user has no chance to interrupt):
```bash
git rev-parse HEAD > /tmp/pre-push-review-done && git push origin main
git add . && git commit -m "x" && git rev-parse HEAD > /tmp/pre-push-review-done && git push
```

✅ **Required** — separate Bash calls, in this order:
1. (Earlier) `git add` / `git commit` to produce the commit being reviewed
2. Run the 4-dimension scan against the resulting HEAD
3. **Standalone:** `git rev-parse HEAD > /tmp/pre-push-review-done`
4. **Standalone:** `git push ...`

If the user amends the commit or adds new commits after step 3, the marker SHA no longer matches HEAD and the hook will correctly re-block — re-run the skill.

---

## Red Flags

**Never:**
- Mark CLEAN without reading the actual modified code
- Skip Dimension 1 because "it looks simple" — exception paths hide in simple code
- Skip Dimension 5 — even "obviously safe" commits have accidentally included tokens in test fixtures or config examples
- Write the marker before tests pass after a fix
- Scan only the last commit when the branch has multiple commits (Step 1 uses merge-base)
- Combine the marker-writing command with `git add` / `git commit` / `git push` / any other command in a single Bash call — must be standalone (see Step 5)
- Try to bypass the hook with bare `touch /tmp/pre-push-review-done` — the marker is now content-validated against the HEAD SHA
