import pytest

from hooks.review_packet import ReviewPacket
from hooks.review_report import (
    LEGACY_REPORT,
    parse_review_result,
    validate_review_result,
)


def test_pass_does_not_require_seven_dimension_citations():
    result = parse_review_result(
        "RESULT PASS\nSEVERITY none\nSUMMARY 未发现阻断级问题",
        profile="balanced",
    )
    assert result.status == "PASS"
    assert result.findings == ()


def test_block_requires_changed_file_and_line():
    result = parse_review_result(
        "RESULT BLOCK\nSEVERITY high\n"
        "FINDING app/router.py:813\n"
        "REASON 缺少目标时会扩大执行范围",
        profile="balanced",
    )
    assert result.status == "BLOCK"
    assert result.findings[0].file == "app/router.py"


def test_note_never_blocks():
    result = parse_review_result(
        "RESULT PASS\nSEVERITY note\n"
        "NOTE 某极端环境未在 diff 中验证",
        profile="balanced",
    )
    assert result.status == "PASS"


def test_strict_profile_accepts_legacy_seven_dimension_report():
    result = parse_review_result(LEGACY_REPORT, profile="strict")
    assert result.status == "PASS"


def test_block_must_reference_a_file_in_the_packet():
    packet = ReviewPacket(
        target_sha="abc123",
        base_ref="origin/master",
        tier="L1",
        profile="balanced",
        high_priority_files=("app/router.py",),
        changed_files=("app/router.py",),
        diff=(
            "diff --git a/app/router.py b/app/router.py\n"
            "@@ -1 +1 @@\n"
            "+return 1\n"
        ),
    )
    result = parse_review_result(
        "RESULT BLOCK\nFINDING app/service.py:1\nREASON 错误范围",
        profile="balanced",
    )
    validation = validate_review_result(result, packet)
    assert not validation.valid
    assert "changed" in validation.reason


def test_unknown_result_status_is_rejected():
    with pytest.raises(ValueError):
        parse_review_result("RESULT MAYBE\nSUMMARY 不确定", profile="balanced")


def test_target_sha_mismatch_is_rejected_by_packet_validation():
    packet = ReviewPacket(
        target_sha="abc123",
        base_ref="origin/master",
        tier="L1",
        profile="balanced",
        high_priority_files=("app/router.py",),
        changed_files=("app/router.py",),
        diff="",
    )
    result = parse_review_result(
        "RESULT PASS\nTARGET_SHA deadbeef\nSUMMARY 已完成",
        profile="balanced",
    )
    validation = validate_review_result(result, packet)
    assert not validation.valid
    assert "target" in validation.reason
