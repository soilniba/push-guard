# 设计：Luna 家族与当前 Codex 审查工具兼容

日期：2026-10-13。状态：修复通过验证，已安装；当前会话需重开加载新版。

## 需求原文

> 修正Push-Guard插件

> 应该是使用luna模型，但不限制5.6版本，使用luna最新版本即可，同时检查下插件有没有更新，我记得已经解决过这个问题了

## 更新检查与根因

- 本地 `main` 已执行 `git pull --ff-only`，与远端一致。
  GitHub API 确认 main 最新提交仍为 `e387849`，日期 2026-09-22，内容为固定 5.6 Luna。
  releases 和 tags 未发现新发布。
- 安装版本为 `1.9.1+codex.20260917052707`；缓存与源码内容一致。
- 2026-10-08 的嵌套 exec 读取修复已在源码及缓存中存在，仍未提交；本轮保留原有修改。
- 当前 hook 主格式已经支持 `collaboration.spawn_agent`、`fork_turns: none`、
  canonical `task_name` ACK 和同源 `agent_message`；无需重写 transcript 适配。
- 阻断来自 hook 与技能仍固定 `gpt-5.6-luna`，以及技能要求旧的 `multi_agent_v1`。
  当前工具提供 `gpt-6-luna`，没有 5.6 Luna。

## 最小修复

1. hook 校验显式选择的模型属于 `gpt-<数字版本>-luna` 家族，不锁定版本；
   技能从实际可用模型中选版本最新的 Luna，不按模型推断或更改审查档位。
2. 技能优先使用当前 `collaboration.spawn_agent(fork_turns="none")`，
   有旧 `multi_agent_v1` 的环境继续兼容；任务名、ACK、来源和同一提交审查证明保持约束。
3. 修正回归测试的 Windows Bash 硬编码和对真实仓库 HEAD 的依赖，
   用临时仓库验证实际 hook；更新版本后安装并验证缓存，保持用户选择门禁。

本轮不提交此前用户未提交的 nested exec、需求和文档修改。
不允许未审查 push，不接受主代理自证、继承上下文或错误来源报告。

## 验证标准

- 当前及后续 Luna 版本、正确工具与 ACK 可以提供合法审查证明。
- 非 Luna、继承上下文、缺 ACK、错误报告作者/接收者、错误目标提交均被拒绝。
- 没有审查的代码 push 仍拦截；纯文档 L0 仍按已有规则处理。
- Windows 与 Linux 测试选用真实可用 Bash，不依赖项目当前有没有待推送提交。
- 用户原有修改完整保留；源码、本轮提交和已安装缓存的差异明确。

## 验证与安装记录

- 工作区全量测试：71 passed，1 skipped；Windows 专属 launcher 项在 Linux 跳过。
- 单独导出暂存区测试：70 passed，1 skipped；原有 nested exec 参数化测试未混入提交。
  首次从 `/tmp` 启动导致 Python 无法导入项目模块，改为导出目录运行后通过。
- 新增 22 项 Luna 与隔离身份回归，旧 hook 红灯、修复后绿灯；
  合成审查记录只在临时仓库单测使用，不充当真实推送证明。
- 独立 `gpt-6-luna` 只读审查无阻断；技能校验、Bash 语法及 diff 检查通过。
- `codex plugin add push-guard@push-guard --json` 安装
  `1.9.2+codex.20261013033512`；已确认 enabled，hook/技能/manifest 与源码一致。
- 插件缓存按版本保存；当前会话仍持有旧版路径，重开会话加载新版。
  不改写旧缓存，也不禁用门禁；真实推送仍需用户选择审查。
