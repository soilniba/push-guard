# 2026-09-16 审查档位成本基准

## 测试环境

- 日期：2026-09-16
- 平台：Windows + Git Bash + Python
- profile：`balanced`
- 测试方式：临时 Git 仓库、临时 bare remote、真实调用 `hooks/check-push-guard.sh`
- 说明：耗时包含 Git Bash 和 Python 进程启动时间，不包含模型 token 和模型响应时间。

## 结果

| 场景 | 处理结果 | 模型审查 | 独立 reviewer | 协议重试 | hook 耗时 |
|---|---|---:|---:|---:|---:|
| 非 push 命令 | 直接放行 | 否 | 否 | 0 | 837.45 ms |
| L0 docs-only push | 直接放行 | 否 | 否 | 0 | 2096.46 ms |
| L1 ordinary code push | 通过固定审查包 | 是，一次 | 否 | 0 | 2145.35 ms |
| L2 hook/security push | 通过固定审查包 | 是，一次 | 否（主审查为 PASS） | 0 | 2104.58 ms |
| 同一 target SHA 第二次 push | 无新 diff，直接放行 | 否 | 否 | 0 | 1941.02 ms |

## 结论

1. 普通大 diff 不再因为行数或文件数量自动启动独立 reviewer。
2. L2 只有主审查返回 `BLOCK` 时才需要一次独立 reviewer；主审查为
   `PASS` 时不会启动第二次审查。
3. 同一目标 SHA 在远端基线已更新后不再重复执行语义审查。
4. Windows 下单次 hook 仍有约 2 秒的进程启动开销；这属于跨平台
   Bash/Python 启动成本，不应通过放宽安全校验来换取更低延迟。真正高成本的
   模型审查次数、独立 reviewer 次数和协议重试次数已经由策略固定上限控制。
