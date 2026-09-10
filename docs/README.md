# 文档索引

- [需求原文](requirements.md)
- [设计决策：使用远端跟踪分支作为审查基准](decisions/0001-remote-tracking-diff-base.md)
- [设计决策：审查前由用户选择，放弃是允许的结局](decisions/0002-user-consent-before-review.md)
- [设计决策：判定不出"是不是 push"时一律拦住](decisions/0003-fail-closed-degraded-mode.md)

## 开发记录

- [2026-09-09：本地基准导致直接放行](lessons/2026-09-09-local-base-bypass.md)
- [2026-09-10：marketplace 版本号手工副本漂移](lessons/2026-09-10-marketplace-version-drift.md)
- [2026-09-10：D7 跳过关键词表与 shell 语法冲突](lessons/2026-09-10-skip-scan-false-positive.md)
- [2026-09-10：审计扫会话时的三个盲点](lessons/2026-09-10-transcript-audit-window.md)
- [2026-09-10：非 UTF-8 环境把闸门变成放行](lessons/2026-09-10-non-utf8-environment.md)
- [2026-09-10：触发面在 description，不在拦截信息](lessons/2026-09-10-skill-description-auto-trigger.md)
