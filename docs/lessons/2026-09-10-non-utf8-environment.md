# 经验记录：非 UTF-8 环境把闸门变成放行

## 现象

1.8.1 在中文 Windows 上表现：

- 本机只有 `python`，没有 `python3` → 阶段 1 起不来 → 按设计 fail-closed，但**所有**
  push 都被拦（包括非 push 场景下的观感）。
- 装了 python3 转发（带 `PYTHONUTF8=1`）后，审计阶段再崩：`subprocess(git, text=True)`
  用系统默认编码（GBK）解码 UTF-8 的 diff 内容 → `UnicodeDecodeError`。

本机（Linux）用 `LC_ALL=C PYTHONCOERCECLOCALE=0 PYTHONUTF8=0` 复现出更严重的一层：
审计崩溃后走 deny 分支，**最终输出那一步也崩了，stdout 为空**——而本 hook 的放行就是
"无输出 + exit 0"。也就是说：环境编码不对时，闸门静默变成放行。

## 根因

- 只找 `python3`，Windows 普遍没有这个名字。
- `subprocess(text=True)` 与 `open()` 不写 `encoding`，就用 locale 默认编码。git 输出与
  会话 jsonl 都是 UTF-8，于是非 UTF-8 locale 下解码即崩。
- deny 分支的输出脚本是 `python -c "…"`，**`-c` 的 argv 按 locale 编码解码**（不是
  Python 源码那套 UTF-8 规则）。脚本里有 `⏸️` 和全角破折号两个字面量 → argv 解码失败
  → 解释器起不来 → 没有输出 → 放行。

## 处理

- 解释器：`PYTHON_BIN=$(command -v python3 || command -v python)`；都找不到时
  阶段 1 无输出，由既有 fail-closed 分支拦下（消息改为 python3/python）。
- 显式编码：`subprocess.check_output(..., encoding='utf-8', errors='replace')`、
  `open(transcript_path, encoding='utf-8', errors='replace')`；三次调用统一加
  `PYTHONIOENCODING=utf-8`。
- 输出脚本改成纯 ASCII：emoji / 破折号写成 `\u` 转义（`json.dumps` 本来也会转义输出）。

## 规则

- **闸门的失败路径必须实测**，不能假设它 fail-closed。本 hook 的"放行"是"stdout 为空"，
  于是任何让输出变空的崩溃（编码、缺依赖、语法）都是放行。新增输出相关代码时，先问：
  它失败时 stdout 是什么？
- 经 `-c` / argv 传给子进程的脚本文本保持 ASCII；非 ASCII 一律写成 `\u` 转义。源码走
  stdin/文件是 UTF-8，`-c` 不是——同一个解释器两套解码规则。
- 读写外部数据（命令输出、会话文件、配置）一律显式指定编码。

## 复现手段

- 非 UTF-8 locale：`LC_ALL=C PYTHONCOERCECLOCALE=0 PYTHONUTF8=0`（断言
  `locale.getpreferredencoding(False)` 不是 utf-8，否则复现不出来）。
- 缺 python3：PATH 里只放 `python`。注意 PATH 清空会连 `cat` 一起缺，那样 hook 连
  stdin 都读不到，测的是另一回事（要用最小 PATH + 显式 `bash` 路径）。
