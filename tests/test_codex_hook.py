import json
import os
import re
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOOK_CONFIG = ROOT / "hooks" / "hooks.json"
HOOK_SCRIPT = ROOT / "hooks" / "check-push-guard.sh"


def _run_hook(payload: dict) -> subprocess.CompletedProcess[str]:
    bash = shutil.which("bash")
    if os.name == "nt":
        windows_git_bash = Path(r"C:\Program Files\Git\usr\bin\bash.exe")
        if windows_git_bash.exists():
            bash = str(windows_git_bash)
    if not bash:
        raise RuntimeError("bash is required to run hook regression tests")
    env = os.environ.copy()
    env["PLUGIN_ROOT"] = str(ROOT)
    return subprocess.run(
        [bash, "hooks/check-push-guard.sh"],
        cwd=ROOT,
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
        env=env,
    )


def test_hook_matches_claude_and_codex_execution_tools():
    config = json.loads(HOOK_CONFIG.read_text(encoding="utf-8"))
    matchers = [
        entry["matcher"]
        for entry in config["hooks"]["PreToolUse"]
        if "matcher" in entry
    ]
    matcher = re.compile("|".join(f"(?:{value})" for value in matchers))

    assert matcher.search("Bash")
    assert matcher.search("exec")
    assert matcher.search("functions.exec_command")


def test_hook_uses_cross_platform_python_launcher():
    config = json.loads(HOOK_CONFIG.read_text(encoding="utf-8"))
    hooks = [
        hook
        for entry in config["hooks"]["PreToolUse"]
        for hook in entry.get("hooks", [])
        if hook.get("type") == "command"
    ]

    assert any(
        hook.get("command") == "python3 ${PLUGIN_ROOT}/hooks/run_push_guard.py"
        and hook.get("commandWindows") == "python ${PLUGIN_ROOT}/hooks/run_push_guard.py"
        for hook in hooks
    )


def test_windows_launcher_blocks_push_without_wsl_bash():
    launcher = ROOT / "hooks" / "run_push_guard.py"
    result = subprocess.run(
        [os.fspath(Path(os.sys.executable)), os.fspath(launcher)],
        cwd=ROOT,
        input=json.dumps(
            {
                "tool_name": "functions.exec_command",
                "tool_input": {"cmd": "git push origin main"},
                "transcript_path": "",
            }
        ),
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )

    assert result.returncode == 0
    assert '"decision": "block"' in result.stdout
    assert '"permissionDecision": "deny"' in result.stdout


def test_codex_cmd_field_does_not_fail_closed_on_prose_containing_git_push():
    result = _run_hook(
        {
            "tool_name": "functions.exec_command",
            "tool_input": {"cmd": "echo git push is mentioned here"},
            "transcript_path": "",
        }
    )

    assert result.returncode == 0
    assert result.stdout == ""


def test_codex_cmd_field_still_blocks_an_actual_push():
    result = _run_hook(
        {
            "tool_name": "functions.exec_command",
            "tool_input": {"cmd": "git push origin main"},
            "transcript_path": "",
        }
    )

    assert result.returncode == 0
    assert '"permissionDecision": "deny"' in result.stdout


def test_bash_command_field_still_blocks_an_actual_push():
    result = _run_hook(
        {
            "tool_name": "Bash",
            "tool_input": {"command": "git push origin main"},
            "transcript_path": "",
        }
    )

    assert result.returncode == 0
    assert '"permissionDecision": "deny"' in result.stdout


def test_codex_custom_tool_call_exec_is_supported_by_transcript_audit_helpers():
    script = HOOK_SCRIPT.read_text(encoding="utf-8")

    assert "custom_tool_call" in script
    assert 'p.get(\'name\') == \'exec\'' in script


def test_multi_agent_v1_reviewer_notifications_are_supported():
    script = HOOK_SCRIPT.read_text(encoding="utf-8")

    assert "multi_agent_v1" in script
    assert "subagent_notification" in script
    assert "agent_id" in script


def test_codex_response_item_user_notifications_are_audited():
    script = HOOK_SCRIPT.read_text(encoding="utf-8")

    assert "p.get('role') == 'user'" in script
    assert "notification_report(text)" in script
