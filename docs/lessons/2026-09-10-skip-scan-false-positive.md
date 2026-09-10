# 经验记录：D7 跳过关键词表与 shell 语法冲突

## 现象

本次改动提交后用新版 hook 干跑审计，被拒：

> D7 SKIPPED but diff added lines contain pattern matching this dimension (e.g., `when`).
> Re-evaluate with CLEAN or FIXED.

命中的不是测试代码，而是 hook 注释里的 "when" 和 bash 的 `if ...; then`。

## 根因

`SKIP_REJECT_PATTERNS[7]` 拿 BDD 词（given/when/then）当"这段是测试代码"的信号。
这三个词同时是普通英文和 shell 语法，于是任何新增 `if ...; then` 的 shell diff 都
被判成"含测试代码"。此时改判 CLEAN/FIXED 又会与独立 reviewer 的 SKIPPED 冲突，
两份报告永远无法一致——闸门对这类 diff 是死锁的，不是多问一句的程度。

## 处理

从 D7 关键词表中移除 given/when/then；其余词仍覆盖真实测试代码。另外把 hook 里
新增注释的措辞也避开这些词，防止注释自己触发扫描。

## 规则

启发式扫描用的关键词必须避开通用语言关键字和日常用词。误伤的代价不只是多一次
复核，而是流程走不通（两份报告无法收敛）。新加关键词前先问：这个词在非目标场景
里会不会出现？

## 附带结论

改关键词表这类 diff 必然含有这些词，因此它自己永远无法以 SKIPPED 通过 D7。本次
commit 按 D7 FIXED 记录——这版改动修的正是该维度的探测缺陷，标记与事实一致。
