# 经验记录：本地基准导致直接放行

## 现象

在本地 `main`/`master` 上直接开发时，`merge-base(HEAD, 本地基准)` 等于 HEAD，hook 在 transcript 审计前返回 PASS。

## 根因

本地分支表示当前工作树，不表示远端已经接收的状态。把它当作 push 审查基准会把待推送提交误判为“无新增提交”。

## 处理

改用 push 目标对应的远端跟踪 ref；没有远端 ref 时以空树比较，确保首次 push 也进入审查流程。skill 文档与 reviewer 指令同步采用同一基准规则。
