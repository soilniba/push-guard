"""Target proofs use temporary transcripts and repositories, never real pushes."""

import copy
import json
import shlex
import subprocess

import pytest

from test_codex_hook import ROOT, _make_unpushed_repo
from test_codex_luna import _audit, _review_events


SKILL_PATH = ROOT / "skills" / "pre-push-review" / "SKILL.md"


def _head(repo):
    return subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
    ).strip()


def _skill_read(template, *, nested=False, command=None, wrapper=None):
    event = copy.deepcopy(template)
    command = command or f"sed -n '1,100p' {shlex.quote(str(SKILL_PATH))}"
    if nested:
        event["payload"] = {
            "type": "custom_tool_call", "name": "exec", "status": "completed",
            "input": wrapper or (
                "const r = await tools.exec_command({cmd:"
                + json.dumps(command) + "}); text(r.output);"
            ),
        }
    else:
        event["payload"] = {
            "type": "function_call", "name": "exec_command",
            "namespace": "functions", "arguments": json.dumps({"cmd": command}),
        }
    return event


def _events(repo, *, round_number=1, result="PASS", sha=None, read=True):
    events = _review_events(repo, "gpt-6-luna", "collaboration")
    if read:
        events[0] = _skill_read(events[0], nested=True)
    task = "push_guard_review" + (f"_{round_number}" if round_number > 1 else "")
    call_id = f"review-spawn-{round_number}"
    spawn = events[2]["payload"]
    args = json.loads(spawn["arguments"])
    args["task_name"] = task
    spawn["arguments"] = json.dumps(args)
    spawn["call_id"] = call_id
    ack = events[3]["payload"]
    ack["call_id"] = call_id
    ack["output"] = json.dumps({"task_name": f"agent/{task}"})
    report = events[4]["payload"]
    report["author"] = f"agent/{task}"
    severity = "high" if result == "BLOCK" else "none"
    report["content"][0]["text"] = (
        f"RESULT {result}\nTARGET_SHA {sha or _head(repo)}\n"
        f"SEVERITY {severity}\nSUMMARY target review"
    )
    if result == "BLOCK":
        report["content"][0]["text"] += "\nFINDING app.py:1\nREASON blocking defect"
    return events


def _another_repo(tmp_path, name):
    directory = tmp_path / name
    directory.mkdir()
    repo = _make_unpushed_repo(directory)
    # Distinct content makes target commits unique even within one second.
    (repo / "app.py").write_text(f"print({name!r})\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "app.py"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", name], check=True)
    return repo


def _allowed(result):
    assert result.returncode == 0
    assert result.stdout == "", result.stdout


def _denied(result, reason=None):
    assert result.returncode == 0
    assert '"permissionDecision": "deny"' in result.stdout, result.stdout
    if reason:
        assert reason in result.stdout, result.stdout


def _blocked(result):
    _denied(result, "RESULT BLOCK")
    assert "app.py:1: blocking defect" in result.stdout, result.stdout


@pytest.mark.parametrize("nested", [False, True])
def test_real_skill_read_is_invocation_without_assistant_announcement(tmp_path, nested):
    repo = _make_unpushed_repo(tmp_path)
    events = _events(repo)
    events[0] = _skill_read(
        events[0], nested=nested,
        command=f"cat {shlex.quote(str(SKILL_PATH))}" if nested else None,
    )
    _allowed(_audit(tmp_path, repo, events))


@pytest.mark.parametrize("forgery", ["echo", "js_comment", "js_string"])
def test_skill_path_in_echo_comment_or_string_is_not_invocation(tmp_path, forgery):
    repo = _make_unpushed_repo(tmp_path)
    events = _events(repo)
    if forgery == "echo":
        events[0] = _skill_read(events[0], command=f"echo cat {SKILL_PATH}")
    else:
        fake_read = (
            "await tools.exec_command({cmd:" + json.dumps(f"cat {SKILL_PATH}") + "});"
        )
        fake = f"/* {fake_read} */" if forgery == "js_comment" else (
            "const unused = " + json.dumps(fake_read) + ";"
        )
        events[0] = _skill_read(
            events[0], nested=True,
            wrapper=fake + ' await tools.exec_command({cmd:"echo ok"});',
        )
    result = _audit(tmp_path, repo, events)
    _denied(result)
    assert "was not invoked since HEAD" in result.stdout


def test_three_authenticated_target_reports_each_apply_to_exact_head(tmp_path):
    repos = [_another_repo(tmp_path, name) for name in ["first", "second", "third"]]
    events = _events(repos[0], read=False)
    for number, repo in enumerate(repos[1:], 2):
        events.extend(_events(repo, round_number=number)[1:])
    for repo in repos:
        _allowed(_audit(tmp_path, repo, events))


def test_repeated_actual_skill_reads_do_not_discard_completed_review(tmp_path):
    repo = _make_unpushed_repo(tmp_path)
    events = _events(repo)
    events.append(_skill_read(events[0], nested=False))
    _allowed(_audit(tmp_path, repo, events))


def test_foreign_block_does_not_block_authenticated_current_target_pass(tmp_path):
    repo = _make_unpushed_repo(tmp_path)
    events = _events(repo, result="BLOCK", sha="a" * 40, read=False)
    events.extend(_events(repo, round_number=2)[2:])
    _allowed(_audit(tmp_path, repo, events))


def test_foreign_pass_does_not_override_current_target_block(tmp_path):
    repo = _make_unpushed_repo(tmp_path)
    events = _events(repo, result="BLOCK", read=False)
    events.extend(_events(repo, round_number=2, sha="a" * 40)[2:])
    _blocked(_audit(tmp_path, repo, events))


def test_valid_single_reviewer_block_is_denied(tmp_path):
    repo = _make_unpushed_repo(tmp_path)
    _blocked(_audit(tmp_path, repo, _events(repo, result="BLOCK", read=False)))


def test_missing_current_target_report_is_denied(tmp_path):
    repo = _make_unpushed_repo(tmp_path)
    events = _events(repo, sha="a" * 40, read=False)
    events.extend(_events(repo, round_number=2, sha="b" * 40)[2:])
    _denied(_audit(tmp_path, repo, events), "registered review subagent is required")


def test_two_authenticated_reviewers_for_same_target_are_denied(tmp_path):
    repo = _make_unpushed_repo(tmp_path)
    events = _events(repo, read=False)
    events.extend(_events(repo, round_number=2)[2:])
    _denied(_audit(tmp_path, repo, events), "expected one registered review subagent, found 2")


def test_multi_reviewer_report_without_target_sha_is_denied(tmp_path):
    repo = _make_unpushed_repo(tmp_path)
    events = _events(repo, sha="a" * 40, read=False)
    second = _events(repo, round_number=2)
    second[-1]["payload"]["content"][0]["text"] = "RESULT PASS\nSEVERITY none\nSUMMARY clean"
    events.extend(second[2:])
    _denied(_audit(tmp_path, repo, events), "multi-target reports require TARGET_SHA")


@pytest.mark.parametrize("violation", [
    "missing_ack", "wrong_author", "wrong_recipient", "inherited_context"
])
def test_target_sha_does_not_replace_authenticated_isolated_identity(tmp_path, violation):
    repo = _make_unpushed_repo(tmp_path)
    events = _events(repo, sha="a" * 40, read=False)
    local = _events(repo, round_number=2)[2:]
    if violation == "missing_ack":
        local.pop(1)
    elif violation == "wrong_author":
        local[-1]["payload"]["author"] = "agent/unregistered"
    elif violation == "wrong_recipient":
        local[-1]["payload"]["recipient"] = "agent/another-parent"
    else:
        args = json.loads(local[0]["payload"]["arguments"])
        args["fork_turns"] = "all"
        local[0]["payload"]["arguments"] = json.dumps(args)
    events.extend(local)
    reasons = {
        "missing_ack": "registered review subagent ACK missing",
        "wrong_author": "registered review subagent report missing or malformed",
        "wrong_recipient": "registered review subagent report missing or malformed",
        "inherited_context": "target does not match the pushed target",
    }
    _denied(_audit(tmp_path, repo, events), reasons[violation])


def test_single_reviewer_explicit_old_head_is_denied(tmp_path):
    repo = _make_unpushed_repo(tmp_path)
    # Legacy skill announcement isolates SHA rejection from read recognition.
    _denied(
        _audit(tmp_path, repo, _events(repo, sha="a" * 40, read=False)),
        "target does not match the pushed target",
    )
