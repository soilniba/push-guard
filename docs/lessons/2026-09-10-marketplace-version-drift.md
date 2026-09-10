# 经验记录：marketplace 版本号手工副本漂移

## 现象

`.claude-plugin/marketplace.json` 里的 `plugins[0].version` 停在 `1.6.0`，而
`package.json` 与 `.claude-plugin/plugin.json` 已经到 `1.8.0`。同一次发版后三个文件
说的版本不一致，装到本地的插件快照仍是更旧的构建。

## 根因

同一个事实（当前版本）被三处人工维护。发版时改了能记住的两处，第三处没人看，
于是漂移。版本不是数据，是重复副本。

## 处理

删掉 `marketplace.json` 里的 `version` 字段，只保留 `plugin.json` 作为唯一权威来源
（该字段在 marketplace 条目里可选，缺失时以下游 `plugin.json` 为准）。

## 规则

同一事实只留一个权威副本；其余位置要么引用，要么删除。手工同步的副本数量 = 漂移概率。
