"""Normalized review results for the fast/balanced protocol.

The parser is intentionally small.  It validates the result shape, while the
packet-aware validator checks that a BLOCK finding points into the pushed diff.
"""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Literal

from .review_packet import ReviewPacket


ReviewStatus = Literal["PASS", "BLOCK"]

LEGACY_REPORT = """\
D1 CLEAN — app/router.py:1 (no external call)
D2 SKIPPED — app/router.py:0 (no encoding boundary)
D3 SKIPPED — app/router.py:0 (no external input)
D4 SKIPPED — app/router.py:0 (no state machine)
D5 SKIPPED — app/router.py:0 (no credentials)
D6 CLEAN — app/router.py:1 (ordinary logic)
D7 SKIPPED — app/router.py:0 (no test change)
"""

_RESULT_RE = re.compile(r"(?im)^\s*RESULT\s+([A-Z]+)\s*$")
_SEVERITY_RE = re.compile(r"(?im)^\s*SEVERITY\s+(.+?)\s*$")
_SUMMARY_RE = re.compile(r"(?im)^\s*SUMMARY\s+(.+?)\s*$")
_FINDING_RE = re.compile(r"^\s*FINDING\s+(.+?):(\d+)\s*(.*?)\s*$", re.I)
_REASON_RE = re.compile(r"^\s*REASON\s+(.+?)\s*$", re.I)
_NOTE_RE = re.compile(r"^\s*NOTE\s+(.+?)\s*$", re.I)
_LEGACY_CITE_RE = re.compile(
    r"D([1-7])\s+(CLEAN|FIXED|SKIPPED)\s+[—-]\s+(.+?):(\d+)\s+\(([^)]{1,200})\)",
    re.I,
)


@dataclass(frozen=True)
class Finding:
    file: str
    line: int
    reason: str = ""


@dataclass(frozen=True)
class ReviewResult:
    status: ReviewStatus
    severity: str = "none"
    summary: str = ""
    findings: tuple[Finding, ...] = ()
    notes: tuple[str, ...] = ()
    legacy_dimensions: tuple[int, ...] = ()


@dataclass(frozen=True)
class Validation:
    valid: bool
    reason: str = ""

    @property
    def ok(self) -> bool:
        return self.valid


def _parse_legacy(text: str) -> ReviewResult:
    matches = list(_LEGACY_CITE_RE.finditer(text))
    dimensions = tuple(sorted({int(match.group(1)) for match in matches}))
    if dimensions != tuple(range(1, 8)):
        missing = sorted(set(range(1, 8)) - set(dimensions))
        raise ValueError(
            "strict review is missing legacy dimensions: "
            + ", ".join(f"D{item}" for item in missing)
        )
    result_match = _RESULT_RE.search(text)
    status = result_match.group(1).upper() if result_match else "PASS"
    if status not in {"PASS", "BLOCK"}:
        raise ValueError(f"unknown review result: {status}")
    return ReviewResult(
        status=status,  # type: ignore[arg-type]
        severity="none" if status == "PASS" else "high",
        legacy_dimensions=dimensions,
    )


def parse_review_result(text: str, profile: str) -> ReviewResult:
    """Parse a fast/balanced result or the legacy strict report."""

    if not isinstance(text, str) or not text.strip():
        raise ValueError("review result is empty")

    if profile == "strict":
        return _parse_legacy(text)

    result_match = _RESULT_RE.search(text)
    if not result_match:
        raise ValueError("review result must contain RESULT PASS or RESULT BLOCK")
    status = result_match.group(1).upper()
    if status not in {"PASS", "BLOCK"}:
        raise ValueError(f"unknown review result: {status}")

    severity_match = _SEVERITY_RE.search(text)
    summary_match = _SUMMARY_RE.search(text)
    severity = severity_match.group(1).strip().lower() if severity_match else "none"
    summary = summary_match.group(1).strip() if summary_match else ""

    findings: list[Finding] = []
    notes: list[str] = []
    for line in text.splitlines():
        finding_match = _FINDING_RE.match(line)
        if finding_match:
            findings.append(
                Finding(
                    file=finding_match.group(1).strip().replace("\\", "/"),
                    line=int(finding_match.group(2)),
                    reason=finding_match.group(3).strip(),
                )
            )
            continue
        reason_match = _REASON_RE.match(line)
        if reason_match and findings:
            previous = findings[-1]
            findings[-1] = Finding(
                file=previous.file,
                line=previous.line,
                reason=reason_match.group(1).strip(),
            )
            continue
        note_match = _NOTE_RE.match(line)
        if note_match:
            notes.append(note_match.group(1).strip())

    if status == "BLOCK":
        if not findings:
            raise ValueError("BLOCK requires at least one FINDING file:line")
        if any(finding.line <= 0 for finding in findings):
            raise ValueError("BLOCK findings must use a positive line number")

    if len(findings) > 3:
        notes.append(f"{len(findings) - 3} extra findings were treated as notes")
        findings = findings[:3]

    return ReviewResult(
        status=status,  # type: ignore[arg-type]
        severity=severity,
        summary=summary,
        findings=tuple(findings),
        notes=tuple(notes),
    )


def _hunk_ranges(packet: ReviewPacket) -> dict[str, list[tuple[int, int]]]:
    ranges: dict[str, list[tuple[int, int]]] = {}
    current_file: str | None = None
    for line in packet.diff.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:].rstrip("\t").replace("\\", "/")
            ranges.setdefault(current_file, [])
            continue
        if not current_file or not line.startswith("@@"):
            continue
        match = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if not match:
            continue
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        if count:
            ranges[current_file].append((start, start + count - 1))
    return ranges


def validate_review_result(
    result: ReviewResult,
    packet: ReviewPacket,
) -> Validation:
    """Validate packet provenance for a result that would block a push."""

    if result.status == "PASS":
        return Validation(True, "PASS is non-blocking")

    changed_files = {
        path.replace("\\", "/")
        for path in (packet.changed_files or packet.high_priority_files)
    }
    ranges = _hunk_ranges(packet)
    for finding in result.findings:
        path = finding.file.replace("\\", "/")
        if path not in changed_files:
            return Validation(
                False,
                f"BLOCK finding must reference a changed file: {path}",
            )
        if finding.line <= 0:
            return Validation(False, "BLOCK finding must reference a positive line")
        if path in ranges and ranges[path]:
            if not any(
                start <= finding.line <= end
                for start, end in ranges[path]
            ):
                return Validation(
                    False,
                    f"BLOCK finding line is outside the diff hunk: {path}:{finding.line}",
                )

    return Validation(True, "BLOCK findings reference the pushed diff")
