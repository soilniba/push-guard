"""Small, deterministic review packets shared by Claude Code and Codex."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import subprocess
from typing import Any, Mapping

from .review_policy import ReviewDecision, ReviewProfile, ReviewTier


@dataclass
class ReviewState:
    """Bounded per-target state for semantic and protocol work."""

    target_sha: str
    semantic_review_done: bool
    protocol_repairs: int = 0
    independent_reviews: int = 0

    def can_retry_protocol(self) -> bool:
        return self.semantic_review_done and self.protocol_repairs < 1

    def can_start_independent(self) -> bool:
        return self.semantic_review_done and self.independent_reviews < 1

    def protocol_failure_message(self) -> str:
        status = "已完成" if self.semantic_review_done else "未完成"
        remaining = "允许一次协议修复" if self.can_retry_protocol() else "协议修复次数已用尽"
        return (
            f"代码审查状态：{status}；目标：{self.target_sha}\n"
            "当前失败类型：插件协议问题，不是代码问题\n"
            f"剩余动作：{remaining}；超过后交给用户判断"
        )


_READ_COMMAND_RE = re.compile(
    r"(?<![A-Za-z0-9_-])(?:"
    r"Read"
    r"|cat"
    r"|sed"
    r"|nl"
    r"|less"
    r"|head"
    r"|tail"
    r"|Get-Content"
    r"|git\s+(?:diff|show)"
    r")(?![A-Za-z0-9_-])",
    re.IGNORECASE,
)


def _normalize_path(path: str) -> str:
    normalized = str(path).replace("\\", "/").strip()
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def _git(repo: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(detail or f"git command failed: {' '.join(args)}")
    return completed.stdout.decode("utf-8", errors="replace")


def _changed_files(repo: Path, base_ref: str, target_sha: str) -> tuple[str, ...]:
    output = _git(repo, "diff", "--name-only", f"{base_ref}..{target_sha}")
    return tuple(
        dict.fromkeys(
            path
            for path in (_normalize_path(line) for line in output.splitlines())
            if path
        )
    )


def _texts(value: Any) -> tuple[str, ...]:
    if isinstance(value, str):
        return (value,)
    if isinstance(value, Mapping):
        parts: list[str] = []
        for key, item in value.items():
            if key in {
                "file_path",
                "path",
                "cmd",
                "command",
                "input",
                "arguments",
                "tool_input",
                "payload",
                "content",
            }:
                parts.extend(_texts(item))
        return tuple(parts)
    if isinstance(value, (list, tuple)):
        parts = []
        for item in value:
            parts.extend(_texts(item))
        return tuple(parts)
    return ()


@dataclass(frozen=True)
class ReviewPacket:
    target_sha: str
    base_ref: str
    tier: ReviewTier
    profile: ReviewProfile
    high_priority_files: tuple[str, ...]
    changed_files: tuple[str, ...]
    diff: str
    repo: Path | None = None

    @classmethod
    def from_git(
        cls,
        repo: Path,
        target_sha: str,
        base_ref: str,
        decision: ReviewDecision,
    ) -> "ReviewPacket":
        repo = Path(repo).resolve()
        changed = _changed_files(repo, base_ref, target_sha)
        if not changed:
            changed = tuple(decision.changed_files)

        changed_set = set(changed)
        high_priority = tuple(
            dict.fromkeys(
                _normalize_path(path)
                for path in decision.high_priority_files
                if _normalize_path(path) in changed_set
            )
        )
        if not high_priority and decision.tier != "L0":
            high_priority = tuple(changed)

        diff = ""
        if high_priority:
            diff = _git(
                repo,
                "diff",
                "--no-ext-diff",
                "--unified=3",
                f"{base_ref}..{target_sha}",
                "--",
                *high_priority,
            )

        return cls(
            target_sha=target_sha,
            base_ref=base_ref,
            tier=decision.tier,
            profile=decision.profile,
            high_priority_files=high_priority,
            changed_files=changed,
            diff=diff,
            repo=repo,
        )

    def files_to_read(self) -> tuple[str, ...]:
        return self.high_priority_files

    def to_prompt(self) -> str:
        high_priority = "\n".join(
            f"- {path}" for path in self.high_priority_files
        ) or "- none"
        excluded = "\n".join(
            f"- {path}"
            for path in self.changed_files
            if path not in self.high_priority_files
        ) or "- none"
        repository = str(self.repo) if self.repo is not None else "<unknown>"
        return (
            "PUSH_GUARD_REVIEW_PACKET\n"
            f"repository={repository}\n"
            f"target_sha={self.target_sha}\n"
            f"base_ref={self.base_ref}\n"
            f"review_profile={self.profile}\n"
            f"tier={self.tier}\n"
            "HIGH_PRIORITY_FILES\n"
            f"{high_priority}\n"
            "EXCLUDED_FILES\n"
            f"{excluded}\n"
            "DIFF_BEGIN\n"
            f"{self.diff}"
            "\nDIFF_END\n"
        )

    def digest(self) -> str:
        payload = {
            "target_sha": self.target_sha,
            "base_ref": self.base_ref,
            "profile": self.profile,
            "tier": self.tier,
            "high_priority_files": self.high_priority_files,
            "diff": self.diff,
        }
        encoded = json.dumps(
            payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def accepts_read_evidence(self, value: Any) -> bool:
        return is_read_evidence(value, self)


def is_read_evidence(value: Any, packet: ReviewPacket) -> bool:
    """Return whether a real tool-shaped read references a packet file.

    The hook should validate the semantic action, not the vendor-specific name
    of the tool.  This accepts Claude's ``Read``, Codex exec wrappers, common
    shell readers and Git diff/show commands, but not arbitrary prose.
    """

    high_priority = tuple(_normalize_path(path) for path in packet.files_to_read())
    if not high_priority:
        return False

    if isinstance(value, Mapping):
        tool_name = str(
            value.get("tool_name") or value.get("name") or value.get("type") or ""
        )
        inputs = _texts(value)
        if tool_name.lower() == "read":
            return any(
                any(path == _normalize_path(text) or text.replace("\\", "/").endswith("/" + path)
                    for path in high_priority)
                for text in inputs
            )
        value_text = "\n".join(inputs)
    else:
        value_text = "\n".join(_texts(value))

    normalized = value_text.replace("\\", "/")
    references_file = any(
        path in normalized or normalized.endswith(path)
        for path in high_priority
    )
    return references_file and bool(_READ_COMMAND_RE.search(normalized))


def read_evidence_matches(value: Any, packet: ReviewPacket) -> bool:
    """Descriptive alias for callers in the transcript adapter."""

    return is_read_evidence(value, packet)


def command_mentions_packet_read(command: str, packet: ReviewPacket) -> bool:
    """Compatibility helper for shell/Codex transcript adapters."""

    return is_read_evidence(command, packet)
