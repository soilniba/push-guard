# 经验记录：改了"谁来触发"，触发面却在 description

## 现象

另一台电脑上装了 push-guard，push 时仍自动开始审查，从未问过"审查 / 放弃"。

## 根因

决定"审查会不会自己开始"的，不是 hook 的拦截信息，而是 skill 的 frontmatter
description——它是模型每轮都读得到的技能列表项，官方文档明确它是模型自主决定
是否调用 skill 的依据。

`SKILL.md` 的 description 当时是：

```
Use before every git push or PR creation to run a systematic 7-dimension code safety scan
```

于是模型在准备 push 时先调用 skill、跑完审查、再 push——全程没有触发拦截，
决策 0002 里那次询问也就没有机会出现。4c6a9b5 改了正文的 "When to Use"
（用户先选），没改 description：正文与触发面说的不是同一件事。

## 规则

改一个流程"由谁触发"时，要把**所有触发面**一起改：

| 触发面 | 性质 |
|---|---|
| hook 拦截文本 | 机制，拦下之后才生效 |
| skill description | 软触发，模型每轮都读，可能先于机制生效 |
| 用户全局指令（`~/.claude/CLAUDE.md`） | 常驻指令，同样先于机制生效 |

三者不一致时，软触发和常驻指令会先把流程跑完，机制根本没被调用。这与
`2026-09-10-marketplace-version-drift.md` 是同一条：同一事实存在多个副本，
改动只落在一处，其余副本继续按旧语义工作。

## 附带发现：改完代码，那台机器未必拿得到

第三方 marketplace **默认不开自动更新**（只有官方 marketplace 默认开），且
`plugin.json` 的 `version` 不变时，连手动 `claude plugin update` 都会被跳过
（官方文档：resolved version 与本地相同即 skip）。所以"我改了代码"和"那台机器
跑的是新代码"是两件事，需要：

```bash
claude plugin marketplace update push-guard
claude plugin update push-guard@push-guard   # 需重启或 /reload-plugins 生效
```

或在 `/plugin` → Marketplaces 面板里给该 marketplace 打开 auto-update。
