# 需求原文

> push-guard 在本仓库实质失效：hook 用 merge-base HEAD master 当 diff 基准，而本仓库直接在 master
> 上开发 → base == HEAD → 直接 PASS，不做任何校验。这次的审查是我按 skill 手工做的（真实 diff =
> origin/master..HEAD，26 文件）。要让闸门真正生效，得改成以 origin/master 为基准，或走分支开发。

## 本次变更目标

审查基准必须反映待 push、但尚未在远端基线中的提交；不能因 HEAD 位于本地基准分支而跳过审查。
