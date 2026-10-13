"""Synthetic transcripts stay in tmp_path; no live review or push is performed."""

import json
from datetime import datetime, timezone

import pytest

from test_codex_hook import (
    FIXTURE_DIR,
    _make_unpushed_repo,
    _push_command,
    _run_hook_in_repo,
)


def _review_events(repo, model, namespace):
    fixture = (FIXTURE_DIR / "codex_transcript.jsonl").read_text(encoding="utf-8")
    fixture = fixture.replace("__TIMESTAMP__", datetime.now(timezone.utc).isoformat())
    fixture = fixture.replace("__READ_FILE__", (repo / "app.py").as_posix())
    events = [json.loads(line) for line in fixture.splitlines()]
    spawn = events[2]["payload"]
    spawn["namespace"] = namespace
    args = json.loads(spawn["arguments"])
    args["model"] = model
    if namespace == "multi_agent_v1":
        args.pop("fork_turns")
        args["fork_context"] = False
        events[3]["payload"]["output"] = json.dumps({"agent_id": "review-agent"})
        events[4]["payload"] = {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": (
                "<subagent_notification>"
                + json.dumps({"agent_path": "review-agent", "status": {
                    "completed": "RESULT PASS\nSEVERITY none\nSUMMARY clean"
                }})
                + "</subagent_notification>"
            )}],
        }
    spawn["arguments"] = json.dumps(args)
    return events


def _audit(tmp_path, repo, events):
    transcript = tmp_path / "review.jsonl"
    transcript.write_text(
        "".join(json.dumps(event) + "\n" for event in events), encoding="utf-8"
    )
    return _run_hook_in_repo(repo, {
        "tool_name": "functions.exec_command",
        "tool_input": {"cmd": _push_command(repo)},
        "transcript_path": str(transcript),
    })


@pytest.mark.parametrize("namespace", ["collaboration", "multi_agent_v1"])
@pytest.mark.parametrize("model", ["gpt-6-luna", "gpt-6.1-luna", "gpt-5.6-luna"])
def test_independent_review_accepts_versioned_luna_family(tmp_path, model, namespace):
    repo = _make_unpushed_repo(tmp_path)
    result = _audit(tmp_path, repo, _review_events(repo, model, namespace))

    assert result.returncode == 0
    assert result.stdout == ""


@pytest.mark.parametrize("namespace", ["collaboration", "multi_agent_v1"])
@pytest.mark.parametrize("model", [
    "gpt-5.6-sol", "gpt-6-sol", "gpt-next-luna", "gpt-6-luna-extra", "gpt-6.1.2-luna"
])
def test_independent_review_rejects_non_luna_or_malformed_model(
    tmp_path, model, namespace
):
    repo = _make_unpushed_repo(tmp_path)
    result = _audit(tmp_path, repo, _review_events(repo, model, namespace))

    assert result.returncode == 0
    assert '"permissionDecision": "deny"' in result.stdout
    assert model in result.stdout


@pytest.mark.parametrize("namespace", ["collaboration", "multi_agent_v1"])
@pytest.mark.parametrize("violation", ["inherited_history", "missing_ack", "wrong_author"])
def test_luna_model_still_requires_independence_and_authenticated_report(
    tmp_path, namespace, violation
):
    repo = _make_unpushed_repo(tmp_path)
    events = _review_events(repo, "gpt-6-luna", namespace)
    if violation == "inherited_history":
        args = json.loads(events[2]["payload"]["arguments"])
        args["fork_turns" if namespace == "collaboration" else "fork_context"] = (
            "all" if namespace == "collaboration" else True
        )
        events[2]["payload"]["arguments"] = json.dumps(args)
    elif violation == "missing_ack":
        events.pop(3)
    elif namespace == "collaboration":
        events[4]["payload"]["author"] = "agent/unregistered-reviewer"
    else:
        events[4]["payload"]["content"][0]["text"] = (
            events[4]["payload"]["content"][0]["text"].replace(
                "review-agent", "unregistered-reviewer"
            )
        )
    result = _audit(tmp_path, repo, events)

    assert result.returncode == 0
    assert '"permissionDecision": "deny"' in result.stdout
    assert "registered review subagent" in result.stdout
