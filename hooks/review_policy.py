"""Manual review profiles and mechanical diff-risk classification.

This module deliberately knows nothing about the model or the harness that is
running the hook.  The profile is an operator setting; the tier is derived
only from the files and diff content for the push target.
"""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Literal, Mapping, Sequence, cast


PROFILE_ENV = "PUSH_GUARD_PROFILE"
PROFILES = frozenset({"fast", "balanced", "strict"})

ReviewProfile = Literal["fast", "balanced", "strict"]
ReviewTier = Literal["L0", "L1", "L2"]

HIGH_RISK_PATH_PREFIXES = (
    "hooks/",
    ".github/",
    ".gitlab/",
    ".husky/",
    "deploy/",
    "deployment/",
    "infra/",
    "ops/",
)

HIGH_RISK_FILENAMES = frozenset(
    {
        "dockerfile",
        "docker-compose.yml",
        "docker-compose.yaml",
        ".env",
        ".env.example",
    }
)

HIGH_RISK_TOKENS = (
    "auth",
    "permission",
    "secret",
    "token",
    "migration",
    "subprocess",
    "shell",
    "exec",
    "lock",
    "retry",
    "task",
    "target",
    "router",
)

_HIGH_RISK_TOKEN_RE = re.compile(
    r"(?<![a-z0-9])(?:"
    + "|".join(re.escape(token) for token in HIGH_RISK_TOKENS)
    + r")(?![a-z0-9])",
    re.IGNORECASE,
)

_LOW_PRIORITY_SUFFIXES = (
    ".md",
    ".markdown",
    ".rst",
    ".adoc",
    ".txt",
)


def _normalize_path(path: str) -> str:
    normalized = str(path).replace("\\", "/").strip()
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def _is_documentation(path: str) -> bool:
    normalized = path.lower()
    name = normalized.rsplit("/", 1)[-1]
    return (
        normalized.startswith("docs/")
        or name.startswith("readme")
        or name.startswith("changelog")
        or name in {"license", "notice"}
        or name.endswith(_LOW_PRIORITY_SUFFIXES)
    )


def _is_test(path: str) -> bool:
    normalized = path.lower()
    name = normalized.rsplit("/", 1)[-1]
    return (
        normalized.startswith(("test/", "tests/", "__tests__/"))
        or name.startswith("test_")
        or name.endswith(("_test.py", ".test.js", ".test.ts", ".spec.js", ".spec.ts"))
    )


def _is_high_risk_path(path: str) -> bool:
    normalized = path.lower()
    name = normalized.rsplit("/", 1)[-1]
    if normalized.startswith(HIGH_RISK_PATH_PREFIXES):
        return True
    if name in HIGH_RISK_FILENAMES:
        return True
    return bool(_HIGH_RISK_TOKEN_RE.search(normalized))


def _contains_high_risk_content(*parts: str) -> bool:
    content = "\n".join(part for part in parts if part)
    return bool(_HIGH_RISK_TOKEN_RE.search(content))


@dataclass(frozen=True)
class ReviewDecision:
    """The deterministic strategy selected for one target diff."""

    profile: ReviewProfile
    tier: ReviewTier
    review_required: bool
    independent_reviewer_required: bool
    high_priority_files: tuple[str, ...]
    reason: str
    changed_files: tuple[str, ...] = ()


@dataclass(frozen=True)
class ReviewPolicy:
    """Operator-selected profile plus mechanical risk classification."""

    profile: ReviewProfile = "balanced"

    @classmethod
    def from_environment(cls, environ: Mapping[str, str]) -> "ReviewPolicy":
        value = environ.get(PROFILE_ENV, "balanced")
        profile = str(value).strip().lower() or "balanced"
        if profile not in PROFILES:
            allowed = ", ".join(sorted(PROFILES))
            raise ValueError(
                f"{PROFILE_ENV} must be one of {allowed}; got {value!r}"
            )
        return cls(profile=cast(ReviewProfile, profile))

    def classify(
        self,
        files: Sequence[str],
        added_lines: str,
        deleted_lines: str,
    ) -> ReviewDecision:
        changed_files = tuple(
            dict.fromkeys(
                normalized
                for normalized in (_normalize_path(path) for path in files)
                if normalized
            )
        )

        if not changed_files or all(_is_documentation(path) for path in changed_files):
            return ReviewDecision(
                profile=self.profile,
                tier="L0",
                review_required=False,
                independent_reviewer_required=False,
                high_priority_files=(),
                reason="documentation-only diff uses mechanical checks",
                changed_files=changed_files,
            )

        high_risk_files = tuple(
            path
            for path in changed_files
            if _is_high_risk_path(path)
        )
        high_risk_content = _contains_high_risk_content(added_lines, deleted_lines)
        tier: ReviewTier = "L2" if high_risk_files or high_risk_content else "L1"

        high_priority_files = tuple(
            path
            for path in changed_files
            if not _is_documentation(path)
            and (not _is_test(path) or _is_high_risk_path(path))
        )
        if not high_priority_files:
            high_priority_files = changed_files

        if tier == "L2":
            reason = "diff contains a high-risk path or risk token"
        else:
            reason = "ordinary executable diff uses one bounded review"

        return ReviewDecision(
            profile=self.profile,
            tier=tier,
            review_required=True,
            independent_reviewer_required=False,
            high_priority_files=high_priority_files,
            reason=reason,
            changed_files=changed_files,
        )
