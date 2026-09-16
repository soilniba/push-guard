import subprocess
from pathlib import Path

from hooks.review_packet import ReviewPacket, is_read_evidence
from hooks.review_policy import ReviewPolicy


def test_packet_contains_target_and_base():
    packet = ReviewPacket(
        target_sha="abc123",
        base_ref="origin/master",
        tier="L1",
        profile="balanced",
        high_priority_files=("app/router.py",),
        changed_files=("app/router.py", "docs/README.md"),
        diff="diff --git a/app/router.py b/app/router.py",
    )
    prompt = packet.to_prompt()
    assert "target_sha=abc123" in prompt
    assert "base_ref=origin/master" in prompt
    assert "app/router.py" in prompt


def test_docs_and_tests_are_not_high_priority_by_default():
    packet = ReviewPacket(
        target_sha="abc123",
        base_ref="origin/master",
        tier="L1",
        profile="balanced",
        high_priority_files=("app/router.py",),
        changed_files=(
            "app/router.py",
            "docs/README.md",
            "tests/test_router.py",
        ),
        diff="diff --git a/app/router.py b/app/router.py",
    )
    assert "docs/README.md" not in packet.files_to_read()
    assert "tests/test_router.py" not in packet.files_to_read()


def packet_for(target_sha):
    return ReviewPacket(
        target_sha=target_sha,
        base_ref="origin/master",
        tier="L1",
        profile="balanced",
        high_priority_files=("app/router.py",),
        changed_files=("app/router.py",),
        diff=f"diff for {target_sha}",
    )


def test_packet_digest_changes_when_target_changes():
    first = packet_for("abc123")
    second = packet_for("def456")
    assert first.digest() != second.digest()


def test_read_evidence_accepts_claude_codex_and_shell_equivalents():
    packet = packet_for("abc123")
    commands = (
        "Read app/router.py",
        "functions.exec_command cat app/router.py",
        "custom_tool_call sed -n '1,80p' app/router.py",
        "cat app/router.py",
        "sed -n '1,80p' app/router.py",
        "nl -ba app/router.py",
        "head -80 app/router.py",
        "tail -80 app/router.py",
        "Get-Content app/router.py",
        "git diff origin/master HEAD -- app/router.py",
        "git show HEAD:app/router.py",
    )
    assert all(is_read_evidence(command, packet) for command in commands)
    assert is_read_evidence(
        {
            "tool_name": "functions.exec_command",
            "tool_input": {"cmd": "cat app/router.py"},
        },
        packet,
    )
    assert is_read_evidence(
        {
            "name": "Read",
            "input": {"file_path": r"E:\repo\app\router.py"},
        },
        packet,
    )


def test_read_evidence_rejects_unrelated_file_and_non_read_command():
    packet = packet_for("abc123")
    assert not is_read_evidence("cat app/service.py", packet)
    assert not is_read_evidence("python deploy.py app/router.py", packet)


def test_from_git_limits_diff_to_high_priority_files(tmp_path: Path):
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.email", "tests@example.invalid"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.name", "Push Guard Tests"],
        check=True,
    )
    (repo / "app").mkdir()
    (repo / "docs").mkdir()
    (repo / "app" / "router.py").write_text("return 1\n", encoding="utf-8")
    (repo / "docs" / "README.md").write_text("old\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
    subprocess.run(
        ["git", "-C", str(repo), "commit", "-qm", "初始测试提交"],
        check=True,
    )
    base = subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        text=True,
    ).strip()
    (repo / "app" / "router.py").write_text("return 2\n", encoding="utf-8")
    (repo / "docs" / "README.md").write_text("new docs\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
    subprocess.run(
        ["git", "-C", str(repo), "commit", "-qm", "修改测试内容"],
        check=True,
    )
    target = subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        text=True,
    ).strip()

    decision = ReviewPolicy.from_environment({}).classify(
        ["app/router.py", "docs/README.md"],
        "+return 2",
        "",
    )
    packet = ReviewPacket.from_git(repo, target, base, decision)

    assert packet.target_sha == target
    assert packet.base_ref == base
    assert packet.files_to_read() == ("app/router.py",)
    assert "router.py" in packet.diff
    assert "README.md" not in packet.diff
