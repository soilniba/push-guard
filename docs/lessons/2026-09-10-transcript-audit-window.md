# 经验记录：审计扫会话时的三个盲点

## 现象

1. 大 diff 走完审查仍被拒：`independent reviewer subagent is required`。独立审查
   报告确实产出了，但审计看不见。
2. 同样走完审查却报 `no Read tool call observed on any modified file` 或
   `missing cites for D1..D7`，即使读文件和报告都在。
3. 主审查标 D1 CLEAN、独立审查标 D1 FIXED，闸门判"verdict mismatch"，两边都觉得
   自己没错，只能反复重来。

## 根因

审计读的是会话 JSONL，它假设了两件不成立的事：

- **报告的送达方式**。Agent 调用的 tool_result 只有 `Spawned successfully…`；真正的
  报告由后台子代理以"同伴消息"（user 侧、`message.content` 是**字符串**）送达。
  审计只从带 `tool_use_id` 的 tool_result 块收集子代理文本 → 永远收不到报告。
- **skill 的定位**。原实现取"最后一个匹配"，而匹配既认真实的 `Skill` tool_use，也认
  助手文本里出现 skill 名。报告/总结里写一次 skill 名，窗口就右移到最后那条消息，
  之前的 Read 和报告全部落在窗口外。窗口又从 `skill_idx + 1` 起算，把调用所在的那
  条消息（常常就是承载报告的那条）排除。
- **标签语义**。CLEAN 与 FIXED 只有名字，没有定义：修好某维度缺陷的 diff，一个审查
  者认为"该维度现在没问题"=CLEAN，另一个认为"这次改的就是它"=FIXED。闸门要求逐维
  度一致，于是同一件事被两个都说得通的标签卡住。

## 处理

- skill 定位：真实 `Skill` tool_use 优先，助手文本只作 fallback（Codex 无 tool_use
  shape）；窗口改为从 `skill_idx` **起**算。
- 子代理报告：user 侧**字符串**消息，且同时满足 ① 带 harness 的同伴投递包装
  （`teammate-message` / `Another Claude session sent a message:`）② 其 `"from"` 命中
  本次用审查签名 spawn 过的 agent 名 → 收为子代理文本。tool_result 一律是块列表，
  模型 echo 不出这个 shape，所以没有开出自证通道。报告在 JSON 信封里，收到的
  字符串里换行是字面 `\n`，要还原成真换行才能被 cite 解析。
- 标签：SKILL.md 的 reviewer prompt 与报告格式各加一句同义定义——CLEAN = diff 里没有
  该维度需要改的东西；FIXED = diff 内的改动修好了该维度的缺陷；拿不准用 CLEAN。

## 规则

- 审计读的是 harness 的**记录格式**，不是逻辑模型。凡是"某类事件一定长成什么样"的
  假设，都要拿真实会话验证一遍；送达路径有两套（tool_result / 同伴消息）时，两个都
  得接。
- 定位"某个动作发生过"时，优先用结构信号（tool_use 的名字），别用自由文本里的
  关键词；关键词只配当 fallback，且要写明它为什么是 fallback。
- 枚举标签（CLEAN/FIXED/SKIPPED）要在**两侧**给出同一份定义，否则"一致"这个检查
  会退化成措辞之争。

## 附带结论

字符串内容的同伴消息是可信输入的前提是"tool_result 都是块列表"。这个前提在当前
harness 成立（已核对：Bash/Agent 的 tool_result 均为块列表，同伴消息为字符串）。
若将来某个 harness 把 tool_result 记成字符串，这条通道要重新评估。

同伴消息的**送达**还有延迟：子代理早已 idle，报告却要等几分钟才注入本会话，且一次
注入可能带来多轮（重发）记录。等待期间不要重复 spawn 审查代理——先等注入，实在不来
再找代理要一次重发。审计取"最后一个完整 D1..D7 块"，多轮重发不影响结果。

标签分歧的残留：维度是否"适用"仍有两种读法——diff 不解析 json 但对外部数据做类型
检查时，一个审查者按关键词读成 SKIPPED，另一个按维度含义读成 CLEAN（本次 D3 即如此）。
两边定义一致只是把分歧收敛到可讨论，不能消除；分歧时把两种读法摆给对方重新判定，
不要直接把自己的标签改成对方的。

## 追加盲点（同日稍晚）：投递形态又换了一版

同一条"读不到独立审查报告"的故障在收口 description 后再次出现，但记录形态不同：

| 形态 | 记录位置 | 信封 |
|---|---|---|
| 旧（1.8.2 已接） | user 侧字符串 | `teammate-message` / `Another Claude session sent a message:`，`"from"` 为 JSON 字段 |
| 后台任务完成 | `type:"attachment"`(`attachment.type:"queued_command"`) 与 `type:"queue-operation"` | `<task-notification>`，靠 `<tool-use-id>` 指回签名 spawn |
| 具名子代理回信 | 同上 | `<agent-message from="NAME">`，NAME 即 spawn 时给的名字 |

两点差异值得记牢：这些记录**不在** `message.content` 里（`type` 也不是 user），
且信封用的是 `from="X"`（XML 属性）而不是 `"from": "X"`（JSON 字段），换行是**真换行**
（旧的同伴消息是 JSON 信封里的字面 `\n`，要反转义）。锚点仍然是"带签名 spawn 过的
agent"：`agent_ids` 认 `<tool-use-id>`，`agent_names` 认 `<agent-message from=…>`。

**结论**：这条通道的形态由 harness 决定，会随版本变；每次 harness 升级后都该拿真实
会话复验一次"大 diff 能否过闸"，否则故障表现是"审查白做、push 推不出去"。

**自引自锁**：修 hook 本身也要过闸。本机跑的是插件缓存里的副本，仓库改动不会被闸门
采用——需要先把修复版落到缓存里（本次是直接覆盖 `cache/<mp>/<plugin>/<ver>/hooks/`
里那个与已发布版本逐字节一致的副本），才能推出修复本身。

## 追加（同日再晚）：名字锚点用"请求名"，投递信封装的是"解析名"

上面那版修复在实测中又暴露一层，仍在同一条通道上：

- spawn 记录里存的是**请求的名字**（本次 `push_guard_independent`）；
- 名字已被占用时 harness 把它解析成 `push_guard_independent-2`，投递信封
  `<agent-message from="…">` 用的是**解析后的名字**；
- 闸门按请求名精确比对 → 报告读不到 → 大 diff 被判"缺独立审查"。

影响面不止本次：同一会话里第二次大 push 必然重名、必然带后缀，**第二次审查永远读不到**
（表现依旧是"审查白做、push 推不出去"）。且子代理只在**主动 `SendMessage`** 时才会有
投递记录——只把七行写在回复正文里，父会话什么也收不到。

处理：名字比对改成"相等或带 harness 去重后缀"（`same_agent`），同伴消息路径的 `"from"`
字段走同一函数。信任锚点没变——记录必须由 harness 写，名字必须来自带签名的 spawn；
模型写不进 `queue-operation`/`attachment`。

复验方式（不碰真会话）：把会话 JSONL 复制到临时文件，追加一条含七行报告的 assistant
记录当夹具，跑三种情形——修复前的匹配器（拒）、修复后（过）、删掉投递记录（拒）。
删记录要按 JSON 字段删：信封的引号在 JSONL 里是转义的，纯文本 `grep` 匹配不到，
第一版对照就这样空跑过一次。
