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
