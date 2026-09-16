# 设计决策：手动审查档位、风险分级与跨 Codex/Claude Code 兼容

**日期：** 2026-09-16  
**状态：** 已实施  
**适用版本：** push-guard 1.9.0 及后续版本

## 1. 背景

push-guard 最初解决的是一个真实问题：当 LLM 能力较弱时，模型经常会忽略异常路径、重复执行、错误目标、权限边界和测试缺口。严格的七维度审查能够捕获这些问题，因此早期使用体验是“审查力度刚好”。

但模型能力会持续提升。当前模型已经能够在普通开发任务中主动完成较完整的异常路径、状态一致性和测试检查，push-guard 如果仍然使用早期的固定强度，就会出现新的失衡：

```text
模型能力提升
    ↓
模型本身已经完成较大范围的安全自检
    ↓
push-guard 仍按旧标准执行全量、逐文件、双 reviewer、严格格式审计
    ↓
审查新增价值下降，协议和格式成本上升
    ↓
审查耗时、token 消耗和无效重试远超功能开发本身
```

因此，本次优化的目标不是简单地“关闭审查”，而是让审查强度可以由用户根据实际使用的模型和项目风险手动调整：

- 旧模型可以手动切换到严格模式；
- 当前能力较强的模型可以手动切换到快速或平衡模式；
- 只有出现明确高风险信号时才升级审查；
- 审查协议错误不能触发无限重复的代码审查；
- Codex 和 Claude Code 必须使用同一套审查语义，但分别适配各自的工具和 Transcript 形态。

## 2. 本次问题的根因

### 2.1 大 diff 阈值过于粗糙

当前规则是“新增超过 30 行或修改超过 2 个文件就必须启动独立 reviewer”。这会把普通的多文件业务修改、测试和文档修改一起升级为最高强度审查。

本次目标安全改造实际是：

```text
18 个文件
4888 行新增
```

因此触发了最重的路径，即主审查、独立审查、逐文件证据、七维度逐项一致性和 Transcript 证明链。

### 2.2 没有风险分级

当前流程没有区分以下改动：

- 文档、注释和版本号；
- 普通业务逻辑；
- 任务恢复和目标解析；
- hook、权限、认证、密钥和部署脚本；
- 测试文件；
- 数据库迁移和批量写操作。

这些改动被统一按最高审查强度处理，导致审查范围与真实风险不匹配。

### 2.3 审查协议复杂度超过了功能审查复杂度

当前 hook 同时负责：

- 解析 push 命令；
- 解析远端和目标 ref；
- 计算远端 diff 基准；
- 解析 Claude Transcript；
- 解析 Codex Transcript；
- 识别不同的子 agent 投递格式；
- 验证 Read 证据；
- 验证七维度报告；
- 验证 `file:line` 是否在 diff hunk；
- 验证 SKIPPED 是否符合正则；
- 验证主 reviewer 与独立 reviewer 的七个标签完全一致。

`hooks/check-push-guard.sh` 已经超过 1000 行，近期提交也主要集中在修复不同 harness 的 Transcript 形态。这说明当前系统的主要成本已经从“找代码 bug”转移成“让审查协议通过”。

### 2.4 对 Codex 的读取证据支持不完整

skill 要求使用 `Read` 工具，但 Codex 环境可能使用：

- `functions.exec_command`；
- PowerShell `Get-Content`；
- `cat`、`sed`、`nl`；
- `git diff` 或 `git show`。

如果 hook 只识别少数 shell 命令，就会把已经完成的代码阅读判定为“没有读取文件”，迫使模型重复审查。

### 2.5 CLEAN、FIXED、SKIPPED 的严格一致性没有带来相应收益

当前独立 reviewer 与主 reviewer 必须对七个维度逐项给出完全相同的标签。两个 reviewer 即使都认为不存在阻断级问题，只要一个写 CLEAN、另一个写 FIXED 或 SKIPPED，push 就会被拒绝。

这类差异通常是审查表达差异，不是代码风险。

### 2.6 审查没有硬性预算和停止条件

当前没有统一限制：

- 主 reviewer 最多运行几次；
- 独立 reviewer 是否必须运行；
- 协议格式最多修复几次；
- Transcript 解析失败后何时停止；
- 非严重问题是否继续扩展；
- 审查耗时达到多少后交给用户判断。

因此，任何一个协议细节都可能触发长时间重试。

## 3. 设计目标

### 3.1 首要目标

push-guard 的首要目标改为：

> 在有限时间和有限 token 预算内，尽快发现明确、严重、可验证的 bug；不要试图消除所有理论上的意外。

### 3.2 必须保留的安全能力

以下问题仍然必须能够阻断 push：

- 明确的错误目标或批量范围扩大；
- 明确的重复执行、重复下发或任务 ID 错乱；
- 明确的数据丢失或破坏性操作；
- 明确的权限绕过或认证缺陷；
- 明确的密钥、token 或私钥泄露；
- 正常路径上的未捕获异常；
- 明确的资源泄漏；
- 明确的发布、部署或 hook 失效。

### 3.3 明确的非目标

以下内容不能自动阻断 push：

- 仅凭理论推测的极端环境问题；
- 无法从当前 diff 验证的未来扩展风险；
- 代码风格、命名或非关键文档问题；
- 不影响当前行为的架构偏好；
- 低概率且没有可复现路径的并发假设；
- “可能存在但没有证据”的问题；
- 模型无法判断但也没有具体失败迹象的未知项。

这些问题可以作为 `NOTE` 返回，但不能触发无限修复和重新审查。

## 4. 手动审查档位与风险分级

### 4.1 插件不判断模型能力

插件不读取、猜测或评估当前使用的模型能力，原因有三：

- Codex 和 Claude Code 不一定稳定提供模型名称；
- 模型名称不能完整代表实际能力；
- 模型能力变化并不频繁，没必要让插件每次运行都重新判断。

审查档位由用户或部署配置手动维护：

```text
review_profile=balanced   默认，当前推荐的平衡模式
review_profile=fast       用户确认模型能力较强时手动选择
review_profile=strict     用户使用旧模型或需要完整审查时手动选择
```

默认只提供一个固定档位，不存在插件内部的“模型能力评分器”。

### 4.2 模型档位由用户手动调整

当用户更换模型、发现模型审查质量发生明显变化，或项目从普通开发进入发布阶段时，手动调整 `review_profile` 即可：

```text
旧模型或审查质量不稳定       → strict
当前日常开发                 → balanced
用户确认模型能力较强且低风险  → fast
```

这属于运维和使用策略，不属于插件的自动推理能力。

代码风险仍然可以由插件机械分级，但这与模型能力判断无关：

- L0/L1/L2 只描述当前 diff 的代码风险；
- 高风险代码可以从 L1 升级到 L2；
- 代码风险升级不代表插件判断了模型强弱；
- 同一个 commit 的审查结果可以复用，不能因为换一次 push 命令就重新完整审查。

### 4.3 风险等级

#### L0：机械检查，不调用模型

满足以下条件时直接通过：

- 只有文档、注释、版本号或格式化修改；
- 没有修改可执行代码、hook、配置、测试行为或部署文件；
- 没有新增脚本、命令、权限和外部调用。

以下路径即使只改一行也不能归入 L0：

```text
hooks/**
.github/**
.gitlab-ci.yml
Dockerfile
部署脚本
权限与认证配置
数据库迁移
```

#### L1：一次快速审查

适用于普通业务代码：

- 代码变更规模中小；
- 不涉及权限、认证、密钥、部署、迁移和破坏性批量操作；
- 没有明显的高风险外部调用；
- 主 reviewer 只运行一次；
- 不强制启动独立 reviewer。

#### L2：高风险审查

适用于：

- hook、CI、部署、认证、权限和密钥；
- shell、命令执行、远程执行和批量写操作；
- 数据库迁移和数据格式迁移；
- 任务恢复、幂等、锁和重复执行；
- 目标解析、路由和资源范围控制；
- 主 reviewer 输出 `BLOCK` 或 `UNCERTAIN`。

L2 先执行一次主 reviewer。只有主 reviewer 明确发现高风险问题，或结论确实无法判断时，才启动一次独立 reviewer。

## 5. 审查报告协议

### 5.1 从七维标签改为风险结果

七个维度可以继续作为 reviewer 的内部检查清单，但不再要求对外输出七行、每维固定 citation，也不再要求两个 reviewer 的标签逐项一致。

统一报告格式建议为：

```text
RESULT PASS
SEVERITY none
FILES app/router.py, app/message_jobs.py
SUMMARY 未发现阻断级问题
```

发现明确严重问题时：

```text
RESULT BLOCK
SEVERITY high
FINDING app/router.py:813
REASON 缺少目标时仍可能扩大为全员执行
```

非阻断问题：

```text
RESULT PASS
SEVERITY note
NOTE 某极端环境未在当前 diff 中验证，但没有发现正常路径故障
```

规则：

- `BLOCK` 必须提供真实文件和行号；
- `PASS` 不要求每个维度都提供引用；
- `NOTE` 不阻断 push；
- 主 reviewer 与独立 reviewer 只需在 `BLOCK / PASS` 结论上保持一致；
- 不再因为 CLEAN、FIXED、SKIPPED 的表述差异阻断 push。

### 5.2 严格模式兼容

`review_profile=strict` 可以保留旧的七维度报告协议，供以下情况使用：

- 旧模型；
- 用户明确要求完整审查；
- 安全关键项目；
- 发布前专项审查。

这样不会丢失旧能力，但默认路径不再为所有项目承担严格模式成本。

## 6. 审查范围

hook 先机械生成审查包，按文件类型和风险筛选：

### 6.1 高优先级文件

```text
hooks/**
认证、权限、密钥相关代码
命令执行、远程执行和批量操作
任务恢复、锁、幂等和状态机
目标解析、资源选择和路由
数据迁移
```

### 6.2 普通代码文件

只提供修改函数、修改行和直接调用点，不要求 reviewer 重新阅读整个仓库。

### 6.3 低优先级文件

以下文件只做机械检查或在测试行为明显变化时才进入重点审查：

```text
docs/**
README*
CHANGELOG*
tests/**
```

测试文件在以下情况下仍需进入重点审查：

- 删除或放宽关键断言；
- 大量增加 mock，绕过核心逻辑；
- 删除回归测试；
- 修改安全边界和错误路径测试。

## 7. 预算和停止条件

同一个目标 commit 的一次 push 流程最多允许：

```text
主 reviewer：1 次
独立 reviewer：最多 1 次，仅 L2 且主 reviewer BLOCK/UNCERTAIN 时启动
协议格式修复：最多 1 次
完整审查重跑：0 次
```

以下情况必须停止继续重试，并把具体原因交给用户：

- Transcript 形态不兼容；
- 无法获得独立 reviewer 的可验证投递；
- citation 只存在格式问题而非代码风险；
- reviewer 超出时间预算；
- 同一个 commit 已完成语义审查，但 hook 仍无法完成机械校验。

停止时必须明确区分：

```text
代码审查是否完成
是否发现阻断级问题
失败是代码问题还是插件协议问题
建议用户做什么判断
```

## 8. Codex 与 Claude Code 兼容要求

### 8.1 共同语义层

两种环境必须共享以下语义：

- 相同的风险等级；
- 相同的 `PASS / BLOCK / NOTE` 结果；
- 相同的阻断标准；
- 相同的预算和重试限制；
- 相同的目标 commit 和 diff base 计算规则。

不得让 Codex 和 Claude Code 依赖不同的业务判断逻辑。

### 8.2 环境适配层

适配层分别支持：

#### Claude Code

- `Bash` push 命令；
- `Read` 文件读取；
- `Agent` 独立 reviewer；
- `tool_result` 和同伴消息投递。

#### Codex

- `functions.exec_command`；
- `custom_tool_call`；
- `response_item`；
- `agent_message`；
- `multi_agent_v1`；
- `queue-operation` 和 `attachment` 形式的 harness 投递。

### 8.3 不绑定某个工具名称

不能把“是否读过修改文件”绑定到某一个名为 `Read` 的工具。

推荐改成审查包机制：

```text
push-guard review-packet <target-sha>
```

由插件自己生成并校验：

- 目标 commit；
- 远端 diff base；
- 风险等级；
- 高优先级文件；
- 修改行范围；
- 审查排除项。

模型可以使用 `Read`、`cat`、`sed`、`Get-Content`、`git diff` 或其他等价方式读取内容，hook 不再因工具名称不同而判定审查未发生。

### 8.4 Transcript 只负责证明，不负责业务决策

Transcript 解析只证明：

- push 目标是否明确；
- 审查包对应的 commit 是否一致；
- 是否存在合法的审查结果；
- 独立 reviewer 如果启用，是否确实由已登记的 reviewer 产生。

Transcript 解析失败属于插件协议错误，不应重新触发完整代码审查。

## 9. 实施阶段

### 阶段一：降低无效成本

修改：

```text
skills/pre-push-review/SKILL.md
hooks/check-push-guard.sh
tests/test_codex_hook.py
```

内容：

- 增加 L0/L1/L2 风险策略；
- 默认采用用户配置的 `review_profile`，初始值为 `balanced`；
- 取消“超过 30 行必派独立 reviewer”；
- 报告改为 `PASS / BLOCK / NOTE`；
- 独立 reviewer 只比较阻断结论；
- citation 只对 `BLOCK` 强制；
- 增加主审查、独立审查和协议修复上限；
- 明确审查超时和协议失败的停止输出。

### 阶段二：生成审查包

新增：

```text
hooks/review_policy.py
hooks/review_packet.py
```

职责：

- 文件和 diff 风险分类；
- 生成高优先级修改范围；
- 生成并校验审查包；
- 统一 Claude Code 与 Codex 的输入。

### 阶段三：收敛运行时实现

新增或迁移：

```text
hooks/check_push_guard.py
```

让 shell 只负责启动 Python。Python 统一处理：

- push 命令解析；
- diff 基准；
- 审查包；
- Transcript 适配；
- 报告校验；
- Codex/Claude Code 事件归一化。

此阶段不改变阻断策略，只降低跨平台和 harness 兼容维护成本。

### 阶段四：人工策略校准

当用户确认模型能力或使用场景发生变化时，只手动调整 profile 和风险阈值，不重新设计整个协议：

```text
旧模型或质量不稳定：strict
日常开发：balanced
用户确认模型能力较强且改动低风险：fast
高风险改动：自动升级到 L2
```

手动调整后仍必须通过固定回归样例验证，不能在插件内部凭模型名称自动放宽或收紧。

## 10. 测试与验收标准

### 10.1 触发测试

- 文档-only diff 不调用模型；
- 普通小型业务 diff 只调用一次 reviewer；
- 普通大 diff 不再因为行数单独触发独立 reviewer；
- hook、权限、认证、密钥和部署改动进入 L2；
- 主 reviewer 输出 `BLOCK` 时最多追加一次独立 reviewer。

### 10.2 协议测试

- Claude Code 的 `Bash/Read/Agent` 事件可验证；
- Codex 的 `functions.exec_command/custom_tool_call/response_item` 可验证；
- PowerShell `Get-Content` 和 `cat/sed/git diff` 不会被误判为未读取；
- 同一 commit 的 citation 修复不会要求重新做完整审查；
- Transcript 缺失时明确报“插件协议问题”，不会无限重试。

### 10.3 安全测试

- 错误目标、错误远端、错误 ref 不能被误放行；
- 高风险文件不能走 L0；
- `BLOCK` 没有有效文件和行号时必须拒绝；
- `PASS` 不因缺少逐维度 citation 被拒绝；
- 独立 reviewer 的普通文本不能伪装成合法结果；
- reviewer 数量和重试次数不能超过预算。

### 10.4 本次问题的回归标准

对于类似本次的 18 文件、数千行正常业务改动，目标行为是：

```text
不因文件数量自动启动独立 reviewer；
只审查高风险代码文件；
主 reviewer 最多一次；
只有明确 BLOCK/UNCERTAIN 才追加一次独立 reviewer；
citation 或 Transcript 适配问题最多修复一次；
不得进入无限重试；
```

## 11. 结论

push-guard 不应永久保持早期模型时代的最高审查强度。模型能力提升后，用户可以手动降低审查档位；插件本身只负责按选定档位快速验证是否存在明确的严重风险。

因此采用以下长期方向：

```text
手动审查档位
    + 风险分级
    + PASS/BLOCK/NOTE 简化协议
    + 高风险才启用独立 reviewer
    + 有限时间和重试预算
    + Codex/Claude Code 共同语义、分别适配
```

严格审查能力保留为显式 `strict` 模式，由用户在需要时手动启用，不再作为所有 push 的默认成本。
