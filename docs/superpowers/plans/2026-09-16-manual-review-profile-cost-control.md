# 手动审查档位与成本控制实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. 本计划由主进程执行，禁止派修改型子 agent。

**Goal:** 将 push-guard 从固定强度、协议驱动的全量审查，改造成由用户手动选择审查档位、按代码风险分级、只阻断明确严重问题的快速审查器，并保持 Codex 与 Claude Code 的功能兼容。

**Architecture:** 插件不判断模型名称或模型能力。用户通过 `review_profile` 手动选择 `fast`、`balanced` 或 `strict`；插件只根据 push 目标 diff 的文件类型和代码风险生成 L0/L1/L2 审查策略。Claude Code 和 Codex 共享审查结果语义与风险规则，工具事件和 Transcript 形态通过适配层归一化。

**Tech Stack:** Bash hook wrapper、Python 3、JSON、Git diff、pytest、Claude Code PreToolUse、Codex `functions.exec_command`/`response_item`/`custom_tool_call`。

**Spec:** `docs/decisions/0004-manual-review-profile-cost-control.md`

## Global Constraints

- 插件不得读取、猜测或评估模型名称和模型能力。
- `review_profile` 只能由用户或部署配置手动指定；默认值为 `balanced`。
- L0/L1/L2 只描述当前 diff 的代码风险，不代表模型能力。
- 只对明确的严重问题返回 `BLOCK`；普通疑问返回 `NOTE`，不得因此无限重试。
- 主 reviewer 最多一次；独立 reviewer 只在 L2 且主 reviewer 为 `BLOCK` 或 `UNCERTAIN` 时最多一次。
- 同一目标 commit 不允许重新执行完整语义审查；协议修复最多一次。
- Codex 和 Claude Code 使用同一套 `PASS/BLOCK/NOTE` 语义和阻断标准。
- 任何 push 目标、远端 ref、diff base 无法确定时继续 fail-closed；不能因为优化成本而放行不明确的 push。
- 所有 Git commit 标题和正文使用中文。
- 主进程直接修改文件；禁止使用修改型子 agent；禁止使用 Sol 模型审核。

---

## Task 1: 建立审查策略与档位配置

**Files:**
- Create: `hooks/review_policy.py`
- Modify: `hooks/hooks.json`（如需要增加配置传递）
- Test: `tests/test_review_policy.py`

**Interfaces:**
- `ReviewProfile = Literal["fast", "balanced", "strict"]`
- `ReviewTier = Literal["L0", "L1", "L2"]`
- `class ReviewPolicy`
- `ReviewPolicy.from_environment(environ: Mapping[str, str]) -> ReviewPolicy`
- `ReviewPolicy.classify(files: Sequence[str], added_lines: str, deleted_lines: str) -> ReviewDecision`
- `ReviewDecision` 至少包含 `profile`、`tier`、`review_required`、`independent_reviewer_required`、`high_priority_files`、`reason`。

- [ ] **Step 1: Write the failing tests**

```python
def test_default_profile_is_balanced():
    decision = ReviewPolicy.from_environment({}).classify(
        ["app/service.py"], "return value", ""
    )
    assert decision.profile == "balanced"


def test_profile_is_manual_and_unknown_value_fails_closed():
    policy = ReviewPolicy.from_environment({"PUSH_GUARD_PROFILE": "strict"})
    assert policy.profile == "strict"

    with pytest.raises(ValueError):
        ReviewPolicy.from_environment({"PUSH_GUARD_PROFILE": "auto-model-score"})


def test_docs_only_diff_is_l0_without_model_review():
    decision = ReviewPolicy.from_environment({}).classify(
        ["docs/README.md"], "+说明", ""
    )
    assert decision.tier == "L0"
    assert decision.review_required is False


def test_hook_and_target_scope_changes_are_l2():
    decision = ReviewPolicy.from_environment({}).classify(
        ["hooks/check_push_guard.py", "app/router.py"],
        "+subprocess.run git push",
        "",
    )
    assert decision.tier == "L2"
    assert decision.independent_reviewer_required is False


def test_large_normal_business_diff_is_not_automatically_independent():
    decision = ReviewPolicy.from_environment({}).classify(
        [f"app/module_{i}.py" for i in range(6)],
        "\n".join("+value = 1" for _ in range(500)),
        "",
    )
    assert decision.tier in {"L1", "L2"}
    assert decision.independent_reviewer_required is False
```

- [ ] **Step 2: Run the policy tests and verify they fail**

Run:

```powershell
python -m pytest tests/test_review_policy.py -q
```

Expected: FAIL because `hooks/review_policy.py` and its public types do not exist.

- [ ] **Step 3: Implement the smallest policy module**

Implement:

```python
PROFILE_ENV = "PUSH_GUARD_PROFILE"
PROFILES = frozenset({"fast", "balanced", "strict"})
HIGH_RISK_PATH_PREFIXES = (
    "hooks/",
    ".github/",
    ".gitlab/",
)
HIGH_RISK_TOKENS = (
    "auth",
    "permission",
    "secret",
    "token",
    "migration",
    "subprocess",
    "shell",
    "exec",
    "lock",
    "retry",
    "task",
    "target",
    "router",
)
```

Rules:

- `PUSH_GUARD_PROFILE` is the only profile input;
- missing profile means `balanced`;
- unknown profile raises a configuration error;
- docs-only changes are L0;
- hook/security/permission/command/lock/retry/target changes are L2;
- ordinary code changes are L1;
- large line count alone never requires an independent reviewer;
- independent reviewer is initially false; escalation is decided later by the main report.

- [ ] **Step 4: Run the policy tests**

Run:

```powershell
python -m pytest tests/test_review_policy.py -q
```

Expected: all policy tests pass.

- [ ] **Step 5: Commit**

```powershell
git add hooks/review_policy.py tests/test_review_policy.py
git commit -m "新增手动审查档位和风险分级策略"
```

## Task 2: 生成固定审查包，减少重复读取和工具差异

**Files:**
- Create: `hooks/review_packet.py`
- Test: `tests/test_review_packet.py`

**Interfaces:**
- `ReviewPacket.from_git(repo: Path, target_sha: str, base_ref: str, decision: ReviewDecision) -> ReviewPacket`
- `ReviewPacket.to_prompt() -> str`
- `ReviewPacket.digest() -> str`
- `ReviewPacket.files_to_read() -> tuple[str, ...]`

- [ ] **Step 1: Write the failing tests**

```python
def test_packet_contains_target_and_base():
    packet = ReviewPacket(
        target_sha="abc123",
        base_ref="origin/master",
        tier="L1",
        profile="balanced",
        high_priority_files=("app/router.py",),
        changed_files=("app/router.py", "docs/README.md"),
        diff="diff --git a/app/router.py b/app/router.py",
    )
    prompt = packet.to_prompt()
    assert "target_sha=abc123" in prompt
    assert "base_ref=origin/master" in prompt
    assert "app/router.py" in prompt


def test_docs_and_tests_are_not_high_priority_by_default():
    packet = ReviewPacket(
        target_sha="abc123",
        base_ref="origin/master",
        tier="L1",
        profile="balanced",
        high_priority_files=("app/router.py",),
        changed_files=(
            "app/router.py",
            "docs/README.md",
            "tests/test_router.py",
        ),
        diff="diff --git a/app/router.py b/app/router.py",
    )
    assert "docs/README.md" not in packet.files_to_read()
    assert "tests/test_router.py" not in packet.files_to_read()


def packet_for(target_sha):
    return ReviewPacket(
        target_sha=target_sha,
        base_ref="origin/master",
        tier="L1",
        profile="balanced",
        high_priority_files=("app/router.py",),
        changed_files=("app/router.py",),
        diff=f"diff for {target_sha}",
    )


def test_packet_digest_changes_when_target_changes():
    first = packet_for("abc123")
    second = packet_for("def456")
    assert first.digest() != second.digest()
```

- [ ] **Step 2: Run packet tests and verify they fail**

Run:

```powershell
python -m pytest tests/test_review_packet.py -q
```

Expected: FAIL because the packet module is not implemented.

- [ ] **Step 3: Implement packet generation**

The packet must include only:

- repository path;
- target commit SHA;
- remote diff base;
- manually selected profile;
- computed L0/L1/L2 tier;
- changed file names;
- high-priority file names;
- unified diff for high-priority code sections;
- explicit exclusions for docs and ordinary tests.

The packet must not include the full repository or unrelated history. Its digest must be computed from target SHA, base ref, profile, tier and selected diff.

- [ ] **Step 4: Add read-equivalence rules**

The packet validator must treat the following as equivalent evidence:

```text
Claude Read tool
Codex functions.exec_command
Codex custom_tool_call
cat / sed / nl / head / tail
PowerShell Get-Content
git diff / git show
```

The validator should verify that the command or tool input references a packet file or high-priority diff file. It must not require a tool literally named `Read`.

- [ ] **Step 5: Run packet tests**

Run:

```powershell
python -m pytest tests/test_review_packet.py -q
```

Expected: all packet tests pass.

- [ ] **Step 6: Commit**

```powershell
git add hooks/review_packet.py tests/test_review_packet.py
git commit -m "生成固定审查包并统一读取证据"
```

## Task 3: 简化审查结果协议并保留 strict 兼容模式

**Files:**
- Modify: `skills/pre-push-review/SKILL.md`
- Modify: `hooks/check-push-guard.sh`
- Test: `tests/test_review_report.py`
- Modify: `tests/test_codex_hook.py`

**Interfaces:**
- `ReviewResult`: `PASS`, `BLOCK`, `NOTE`
- `parse_review_result(text: str, profile: str) -> ReviewResult`
- `validate_review_result(result: ReviewResult, packet: ReviewPacket) -> Validation`

- [ ] **Step 1: Write failing report tests**

```python
def test_pass_does_not_require_seven_dimension_citations():
    result = parse_review_result(
        "RESULT PASS\nSEVERITY none\nSUMMARY 未发现阻断级问题",
        profile="balanced",
    )
    assert result.status == "PASS"
    assert result.findings == ()


def test_block_requires_changed_file_and_line():
    result = parse_review_result(
        "RESULT BLOCK\nSEVERITY high\n"
        "FINDING app/router.py:813\n"
        "REASON 缺少目标时会扩大执行范围",
        profile="balanced",
    )
    assert result.status == "BLOCK"
    assert result.findings[0].file == "app/router.py"


def test_note_never_blocks():
    result = parse_review_result(
        "RESULT PASS\nSEVERITY note\n"
        "NOTE 某极端环境未在 diff 中验证",
        profile="balanced",
    )
    assert result.status == "PASS"


def test_strict_profile_accepts_legacy_seven_dimension_report():
    result = parse_review_result(LEGACY_REPORT, profile="strict")
    assert result.status == "PASS"
```

- [ ] **Step 2: Run report tests and verify they fail**

Run:

```powershell
python -m pytest tests/test_review_report.py -q
```

Expected: FAIL because the simplified result parser does not exist.

- [ ] **Step 3: Implement normalized report parsing**

Balanced/fast mode:

- require `RESULT PASS` or `RESULT BLOCK`;
- allow optional `SEVERITY`, `SUMMARY` and `NOTE`;
- require a valid changed-file citation only for `BLOCK`;
- treat `NOTE` as non-blocking;
- reject unknown result statuses;
- cap findings at three; extra findings become non-blocking notes.

Strict mode:

- preserve the legacy seven-dimension parser;
- preserve the existing citation and SKIPPED checks;
- do not change strict mode semantics during this task.

- [ ] **Step 4: Change the skill prompt**

The default prompt must say:

```text
目标是快速发现明确的阻断级问题，不是穷尽所有理论边界。
不要因为未知、极端环境、风格或无法从 diff 验证的事项阻断。
默认只输出 PASS 或 BLOCK；普通疑问写成 NOTE。
不要自动修复代码，不要运行测试，不要扩大到未关联文件。
```

The prompt must mention that `review_profile` is manually selected and that the plugin never judges model capability.

- [ ] **Step 5: Make independent review compare only blocking status**

For `fast`/`balanced`:

- no independent reviewer for L0/L1;
- L2 starts independent review only when the main result is `BLOCK` or `UNCERTAIN`;
- compare only `BLOCK` versus non-`BLOCK`;
- do not compare CLEAN/FIXED/SKIPPED labels.

For `strict`, retain the legacy independent reviewer behavior until a later migration.

- [ ] **Step 6: Run report and hook tests**

Run:

```powershell
python -m pytest tests/test_review_report.py tests/test_codex_hook.py -q
```

Expected: all report and hook tests pass.

- [ ] **Step 7: Commit**

```powershell
git add skills/pre-push-review/SKILL.md hooks/check-push-guard.sh \
        tests/test_review_report.py tests/test_codex_hook.py
git commit -m "简化快速审查结果并保留严格模式兼容"
```

## Task 4: 增加有限重试和协议错误停止状态

**Files:**
- Modify: `hooks/check-push-guard.sh`
- Modify: `hooks/review_packet.py`
- Test: `tests/test_review_budget.py`

**Interfaces:**
- `ReviewState(target_sha: str, semantic_review_done: bool, protocol_repairs: int, independent_reviews: int)`
- `ReviewState.can_retry_protocol() -> bool`
- `ReviewState.can_start_independent() -> bool`
- `ReviewState.protocol_failure_message() -> str`

- [ ] **Step 1: Write failing budget tests**

```python
def test_protocol_repair_is_allowed_once():
    state = ReviewState("abc", semantic_review_done=True,
                        protocol_repairs=0, independent_reviews=0)
    assert state.can_retry_protocol()
    state.protocol_repairs += 1
    assert not state.can_retry_protocol()


def test_independent_review_is_one_shot():
    state = ReviewState("abc", semantic_review_done=True,
                        protocol_repairs=0, independent_reviews=1)
    assert not state.can_start_independent()


def test_protocol_failure_does_not_claim_code_failure():
    message = ReviewState(
        "abc", semantic_review_done=True,
        protocol_repairs=1, independent_reviews=0,
    ).protocol_failure_message()
    assert "协议问题" in message
    assert "代码问题" in message
```

- [ ] **Step 2: Run budget tests and verify they fail**

Run:

```powershell
python -m pytest tests/test_review_budget.py -q
```

Expected: FAIL because the state object does not exist.

- [ ] **Step 3: Implement bounded state**

State is keyed by target SHA and must distinguish:

- semantic review not started;
- semantic review completed;
- protocol repair used;
- independent reviewer used.

When the semantic review is complete but citation, Transcript or tool-shape validation fails, return a protocol error that asks for one format repair. Do not launch a new semantic review.

- [ ] **Step 4: Add explicit stop output**

The hook must report:

```text
代码审查状态：已完成 / 未完成
阻断级问题：有 / 无 / 未知
当前失败类型：代码风险 / 插件协议问题 / 环境问题
剩余动作：最多一次协议修复；超过后交给用户判断
```

- [ ] **Step 5: Run budget tests**

Run:

```powershell
python -m pytest tests/test_review_budget.py -q
```

Expected: all budget tests pass.

- [ ] **Step 6: Commit**

```powershell
git add hooks/check-push-guard.sh hooks/review_packet.py tests/test_review_budget.py
git commit -m "限制审查重试并区分协议失败"
```

## Task 5: 统一 Claude Code 与 Codex 适配测试

**Files:**
- Modify: `hooks/check-push-guard.sh`
- Modify: `hooks/run_push_guard.py`
- Modify: `hooks/hooks.json`
- Modify: `tests/test_codex_hook.py`
- Create: `tests/fixtures/claude_transcript.jsonl`
- Create: `tests/fixtures/codex_transcript.jsonl`

- [ ] **Step 1: Add Claude fixture tests**

Test a push transcript containing:

```text
PreToolUse Bash git push
Skill invocation
Read of a high-priority file
PASS report
```

Expected: the hook recognizes the review without requiring Codex event shapes.

- [ ] **Step 2: Add Codex fixture tests**

Test a push transcript containing:

```text
functions.exec_command
response_item/custom_tool_call
agent_message when L2 escalation is used
PASS report
```

Expected: the same normalized semantic result passes.

- [ ] **Step 3: Add read-equivalence tests**

Cover:

```text
cat app/router.py
sed -n '1,80p' app/router.py
Get-Content app/router.py
git diff origin/master HEAD -- app/router.py
```

Expected: all are accepted as file-reading evidence when the path is in the review packet.

- [ ] **Step 4: Add negative provenance tests**

Verify that:

- arbitrary assistant text cannot become an independent reviewer result;
- an unregistered agent message cannot satisfy L2;
- a result for another target SHA cannot satisfy the current push;
- missing Transcript still fails closed for an actual push.

- [ ] **Step 5: Run cross-runtime tests**

Run:

```powershell
python -m pytest tests/test_codex_hook.py -q
```

Expected: all Claude/Codex compatibility tests pass.

- [ ] **Step 6: Commit**

```powershell
git add hooks/check-push-guard.sh hooks/run_push_guard.py hooks/hooks.json \
        tests/test_codex_hook.py tests/fixtures
git commit -m "补齐 Codex 与 Claude Code 审查兼容测试"
```

## Task 6: 更新文档、版本和回归基准

**Files:**
- Modify: `README.md`
- Modify: `docs/README.md`
- Modify: `docs/requirements.md`
- Modify: `docs/decisions/0004-manual-review-profile-cost-control.md`
- Modify: `package.json`
- Modify: `.claude-plugin/plugin.json`
- Modify: `.codex-plugin/plugin.json`
- Modify: `.agents/plugins/marketplace.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Document manual profile configuration**

Document:

```text
PUSH_GUARD_PROFILE=fast
PUSH_GUARD_PROFILE=balanced
PUSH_GUARD_PROFILE=strict
```

明确说明插件不会判断模型能力，模型档位由用户手动调整。

- [ ] **Step 2: Document L0/L1/L2 behavior**

明确说明：

- docs-only 变更可直接通过；
- 普通业务代码默认一次快速审查；
- 高风险代码才升级；
- `NOTE` 不阻断；
- 协议错误最多一次修复后停止。

- [ ] **Step 3: Verify all plugin manifests use one version**

Run:

```powershell
$files = @(
  "package.json",
  ".claude-plugin/plugin.json",
  ".codex-plugin/plugin.json"
)
$files | ForEach-Object { Get-Content -Raw $_ | ConvertFrom-Json | Select-Object -ExpandProperty version }
```

Expected: every manifest prints the same version.

- [ ] **Step 4: Run documentation and manifest checks**

Run:

```powershell
git diff --check
python -m pytest tests/test_codex_hook.py tests/test_review_policy.py `
    tests/test_review_packet.py tests/test_review_report.py `
    tests/test_review_budget.py -q
```

Expected: no whitespace errors and all focused tests pass.

- [ ] **Step 5: Commit**

```powershell
git add README.md docs package.json .claude-plugin .codex-plugin .agents
git commit -m "完善手动审查档位和跨运行时使用文档"
```

## Task 7: 全量验证与成本基准

**Files:**
- Test: `tests/`
- No production code changes expected.

- [ ] **Step 1: Run the complete test suite**

Run:

```powershell
python -m pytest -q
```

Expected: zero failures.

- [ ] **Step 2: Run hook latency samples**

Measure at least:

```text
非 push 命令；
L0 docs-only push；
L1 ordinary code push；
L2 hook/security push；
同一 target SHA 的第二次 push。
```

Record:

- hook process time;
- whether a model reviewer is required;
- whether an independent reviewer is required;
- number of protocol retries.

- [ ] **Step 3: Verify the target cost behavior**

For a representative large but ordinary business diff:

```text
不因文件数量单独启动独立 reviewer；
默认主 reviewer 不超过一次；
没有明确 BLOCK/UNCERTAIN 时不启动第二 reviewer；
citation 或 Transcript 适配问题最多一次修复；
```

- [ ] **Step 4: Verify both plugin environments**

Run the same fixture suite through:

```text
Claude Code hook matcher / Bash event path
Codex functions.exec_command / response_item path
```

Expected: the same target SHA and normalized `PASS/BLOCK/NOTE` result.

- [ ] **Step 5: Final verification**

Run:

```powershell
git diff --check
git status --short
python -m pytest -q
```

Expected:

- no diff whitespace errors;
- only intentional files changed;
- full test suite passes;
- no unbounded retry path remains in the tested state machine.
