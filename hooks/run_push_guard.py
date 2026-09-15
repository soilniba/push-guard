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
import shutil
import subprocess
import sys


HOOK_SCRIPT = Path(__file__).with_name("check-push-guard.sh")


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
    if not HOOK_SCRIPT.is_file():
        return _deny(f"Push Guard hook script not found: {HOOK_SCRIPT}")

    bash = _find_bash()
    if bash is None:
        return _deny(
            "Git Bash was not found. Install Git for Windows or set "
            "PUSH_GUARD_BASH to the path of bash.exe, then retry."
        )

    payload = sys.stdin.buffer.read()
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
