# 设计决策：使用远端跟踪分支作为审查基准

## 问题

本地 `main`/`master` 与 HEAD 相同时，`merge-base` 等于 HEAD，hook 会在审查前直接 PASS。分支约定只能规避问题，不能保证闸门有效。

## 决策

1. 解析本次 push 的远端和目标分支。
2. 优先使用对应的 `refs/remotes/<remote>/<branch>` 作为 diff 基准。
3. 未指定目标分支时使用分支 upstream 或远端默认分支；仍不存在时使用空树，审查全部待推送内容。
4. 不再使用本地 `main`/`master` 作为审查基准，也不因缺少基准直接放行。

## 边界

只读取本地已有的远端跟踪 ref，不在 hook 中自动 fetch；远端 ref 是否最新由 push 前的同步流程负责。
