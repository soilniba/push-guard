# 需求原文

## 2026-09-09 审查基准必须基于远端

> push-guard 在本仓库实质失效：hook 用 merge-base HEAD master 当 diff 基准，而本仓库直接在 master
> 上开发 → base == HEAD → 直接 PASS，不做任何校验。这次的审查是我按 skill 手工做的（真实 diff =
> origin/master..HEAD，26 文件）。要让闸门真正生效，得改成以 origin/master 为基准，或走分支开发。

目标：审查基准必须反映待 push、但尚未在远端基线中的提交；不能因 HEAD 位于本地基准分支而跳过审查。

## 2026-09-10 push 前不再自动强制审查

> 把push之前自动强制审查的规则改一下，改成让用户选择是进行审查还是放弃push

澄清后确认：选项只有「进行审查」和「放弃 push」两条，不提供「跳过审查直接推送」的出口。

目标：

1. 未审查的 push 仍然被拦下，闸门不被削弱。
2. 拦截后不再自动开始审查，而是由用户选择：审查（随后推送）或放弃（提交留在本地）。

## 2026-09-10 修正两处缺陷 + 约束独立审查

> 这两个问题也需要修正一下

指上一轮报告中列出的两处既有缺陷：

1. `.claude-plugin/marketplace.json` 的版本停在 1.6.0，与 package.json / plugin.json 的 1.8.0 不一致。
2. python3 缺失时 hook 静默放行：阶段 1 空输出被当成"不是 push"，闸门失效。

> 还有一个，我感觉现在独立审查的时候速度很慢，需要约束一下子agent审查的时候尽量不要发散，只针对问题本身尽快完成审核

目标：

1. 版本号只保留一个权威副本，消灭人工同步的同义字段。
2. 判不出"是不是 push"时一律拦住；降级判断本身不得依赖另一个可能缺失的外部工具。
3. 独立审查子代理的范围与工具预算显式限制在 diff 内：不探索仓库、不跑测试、不做修复。

## 2026-09-10 修正审计的三处判定缺陷

> 修

指上文报告中列出的判定缺陷（审计用真实会话跑通后暴露）：

1. 后台子代理的报告以"同伴消息"（user 侧字符串）送达，而 Agent 的 tool_result 只
   有 spawn 元数据 → 审计永远读不到独立审查报告，大 diff 无法通过。
2. skill 定位：文末提到 skill 名字的普通文本会把窗口右移；窗口又从
   `skill_idx + 1` 起算，把同一条消息里的报告排除掉 → 正常走完的审查被判"没读文件 /
   缺 cite"。
3. CLEAN 与 FIXED 的边界没有定义，主审查与独立审查对同一维度给出不同标签时只能反复
   重来。

目标：

1. 审计能读到独立审查报告，无论它以 Agent tool_result 还是同伴消息送达；且不能因此
   开出自证（模型可控文本不得充当报告）。
2. 定位 skill 以真实调用为准，窗口包含调用所在消息本身。
3. 两个审查者使用同一套 CLEAN/FIXED 定义。

## 2026-09-10 修正 Windows/非 UTF-8 环境下的三处缺陷

> push-guard 刚更新到 1.8.1，hook 直接拒绝了我所有的推送。两个叠加的环境缺陷：
> 本机没有 python3（Windows 只装了 python）；审计阶段按 GBK 解码 git 输出 …
> 这俩都是 1.8.1 自身的缺陷（Windows 上 python3 普遍不存在；读 git 输出本该显式写
> encoding="utf-8", errors="replace"），值得反馈给插件作者。

目标：

1. 没有 `python3`、只有 `python` 的环境也能正常判定与审计。
2. 读 git 输出与会话文件显式用 UTF-8（含解码失败兜底），不依赖 locale 默认编码。
3. 闸门自身的输出路径在非 UTF-8 环境下不得变成"无输出"——本 hook 的无输出等于放行。

## 2026-09-10 审查必须在用户选择之后才开始（收口触发面）

> 我在别的电脑装了这个插件，他怎么还是自动进行push审核了，并没有问我是要push审核还是取消push

定位：决策 0002 把"先问用户"写在 hook 的拦截信息里，但那条信息只在 push 已被拦下
之后才出现。审查会自己开始，是因为另一条更早的路径：skill 的 frontmatter
description 仍是 `Use before every git push or PR creation…`，模型每轮都读得到，
于是在 push 之前主动调用 skill，hook 没有机会拦截。

目标：

1. description 只在闸门拦下、且用户选择"审查并推送"之后才指向本 skill，不再命令
   模型每次 push 前调用。
2. 本次不引入新机制（不加"审计必须读到真实 AskUserQuestion 记录"的强制同意）。

## 2026-09-10 审计要读得到本 harness 的子代理投递

> 我在别的电脑装了这个插件，他怎么还是自动进行push审核了（…）   ← 收口 description 后，
> 本机闸门又暴露出：大 diff 走完审查仍被拦，报告在会话里，审计读不到。

定位：本 harness 把后台/具名子代理的报告记为 `queue-operation` 条目与
`attachment`(type=`queued_command`) 条目，信封是 `<agent-message from="…">` /
`<task-notification>…<tool-use-id>…<result>`；hook 只认 Agent 的 tool_result 与
`teammate-message` / `Another Claude session sent a message:` 两种形态，两种都不是。

目标：

1. 报告无论以哪种 harness 记录形态送达都能被读到；每条记录都必须能追溯到"带审查
   签名 spawn 过的子代理"，不得把模型可写的文本当成报告（自证通道不开）。
2. 记录缺失时仍然拦住——读不到独立审查报告就不许推（决策 0003 的方向）。

## 2026-09-16 降低模型能力提升后的过度审查成本

> 早期模型能力较弱时，固定的七维度、逐文件、独立 reviewer 审查能够
> 发现很多遗漏；当前模型能力提升后，插件仍按旧强度运行，导致审查协议、
> Transcript 适配和无效重试的时间与 token 成本远超功能开发本身。

确认的方向：

1. 插件不读取、猜测或评估模型名称和模型能力。
2. 审查档位由用户或部署配置手动设置，默认 `balanced`，可选 `fast` 和 `strict`。
3. 插件只根据当前 diff 机械分级为 `L0/L1/L2`：
   - 文档-only 变更走 L0，不调用模型；
   - 普通业务代码走 L1，只进行一次有边界的审查；
   - hook、权限、命令、迁移、锁、重试、任务恢复和目标选择等高风险改动走 L2。
4. 默认协议改为 `PASS/BLOCK/NOTE`：只有明确、严重、能够从当前 diff 验证的问题才返回 `BLOCK`。
5. 大小或文件数量不再单独触发独立 reviewer；L2 只有主审查 `BLOCK` 时最多追加一次。
6. 同一目标 commit 不得重新执行完整语义审查；协议修复最多一次，超出后明确交给用户判断。
7. Codex 与 Claude Code 共享风险和阻断语义，分别适配工具事件；
   `Read`、`functions.exec_command`、`cat`、`sed`、`Get-Content`、`git diff`
   和 `git show` 都可作为等价读取证据。

验收重点：

- 不能把理论上的极端环境、代码风格或无法从 diff 验证的事项自动阻断；
- 不能把插件协议失败描述成代码失败；
- 不能因为两个 reviewer 的 `CLEAN/FIXED/SKIPPED` 表述差异而反复重审；
- 不能通过错误的目标 SHA、未注册 reviewer 或缺失 Transcript。
