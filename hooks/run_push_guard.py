#!/usr/bin/env python3
"""Run the Push Guard shell hook with a real Bash on Windows.

Windows commonly has ``C:\\Windows\\System32\\bash.exe`` before Git Bash on
PATH.  That executable is the WSL launcher, not a POSIX shell that can run a
Windows plugin path, so invoking a hook with bare ``bash`` makes Codex report a
failed hook and then continue with the push.  Resolve Git Bash explicitly on
Windows and forward the hook protocol unchanged.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys


HOOK_SCRIPT = Path(__file__).with_name("check-push-guard.sh")
GIT_OPTS_WITH_VALUE = {
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--super-prefix",
    "--list-cmds",
}


def _is_shell_boundary(token: str) -> bool:
    if not token:
        return False
    if token[0] in "|;&><":
        return True
    index = 0
    while index < len(token) and token[index].isdigit():
        index += 1
    return index > 0 and index < len(token) and token[index] in "><"


def _is_env_assignment(token: str) -> bool:
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*\+?=", token))


def _is_command_position(tokens: list[str], index: int) -> bool:
    if index == 0:
        return True
    previous_index = index - 1
    while previous_index >= 0 and _is_env_assignment(tokens[previous_index]):
        previous_index -= 1
    if previous_index < 0:
        return True
    previous = tokens[previous_index]
    if _is_shell_boundary(previous):
        return True
    return previous in {"command", "env", "nice", "nohup", "sudo", "time"}


def _git_subcommand_is_push(tokens: list[str], git_index: int) -> bool | None:
    index = git_index + 1
    while index < len(tokens):
        token = tokens[index]
        if _is_shell_boundary(token):
            return False
        if token == "push":
            return True
        if token in GIT_OPTS_WITH_VALUE:
            if index + 1 >= len(tokens):
                return None
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        return False
    return False


def _is_push_candidate(payload: bytes) -> bool:
    """Return whether the full shell hook should inspect this payload.

    A false result is only returned when the command can be confidently
    classified as not containing an executable ``git push``. Any malformed
    or ambiguous input is forwarded to the shell hook, which fails closed.
    """

    try:
        data = json.loads(payload.decode("utf-8"))
        tool_input = data.get("tool_input") or {}
        command = tool_input.get("command") or tool_input.get("cmd")
        if not isinstance(command, str):
            return True
        tokens = shlex.split(command)
    except Exception:
        return True

    for index, token in enumerate(tokens):
        base = token.rsplit("/", 1)[-1].lower()
        if base not in {"git", "git.exe"}:
            continue
        if not _is_command_position(tokens, index):
            continue
        result = _git_subcommand_is_push(tokens, index)
        if result is None:
            return True
        if result:
            return True
    return False


def _deny(reason: str) -> int:
    print(
        json.dumps(
            {
                "systemMessage": (
                    "⛔ push-guard hook could not start; the push is blocked "
                    "instead of being allowed unreviewed."
                ),
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                },
            },
            ensure_ascii=True,
        )
    )
    return 0


def _windows_bash_candidates() -> list[Path]:
    candidates: list[Path] = []

    configured = os.environ.get("PUSH_GUARD_BASH")
    if configured:
        candidates.append(Path(configured))

    for git_command in (shutil.which("git.exe"), shutil.which("git")):
        if not git_command:
            continue
        git_root = Path(git_command).resolve().parent.parent
        candidates.append(git_root / "usr" / "bin" / "bash.exe")

    for variable in ("ProgramFiles", "ProgramFiles(x86)"):
        program_files = os.environ.get(variable)
        if program_files:
            candidates.append(Path(program_files) / "Git" / "usr" / "bin" / "bash.exe")

    # Keep this only as a last resort.  In particular, do not select the WSL
    # launcher from C:\\Windows\\System32.
    path_bash = shutil.which("bash.exe") or shutil.which("bash")
    if path_bash:
        candidates.append(Path(path_bash))
    return candidates


def _find_bash() -> Path | None:
    if os.name != "nt":
        path_bash = shutil.which("bash")
        return Path(path_bash) if path_bash else None

    seen: set[str] = set()
    for candidate in _windows_bash_candidates():
        key = os.path.normcase(os.fspath(candidate))
        if key in seen:
            continue
        seen.add(key)
        try:
            resolved = candidate.resolve()
        except OSError:
            resolved = candidate
        if not resolved.is_file():
            continue
        if resolved.name.lower() != "bash.exe":
            continue
        if str(resolved).lower().startswith(
            os.path.normcase(r"c:\windows\system32")
        ):
            continue
        return resolved
    return None


def main() -> int:
    payload = sys.stdin.buffer.read()
    if not _is_push_candidate(payload):
        return 0

    if not HOOK_SCRIPT.is_file():
        return _deny(f"Push Guard hook script not found: {HOOK_SCRIPT}")

    bash = _find_bash()
    if bash is None:
        return _deny(
            "Git Bash was not found. Install Git for Windows or set "
            "PUSH_GUARD_BASH to the path of bash.exe, then retry."
        )

    try:
        completed = subprocess.run(
            [os.fspath(bash), os.fspath(HOOK_SCRIPT)],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as exc:
        return _deny(f"Could not start Git Bash: {exc}")

    sys.stdout.buffer.write(completed.stdout)
    sys.stderr.buffer.write(completed.stderr)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
