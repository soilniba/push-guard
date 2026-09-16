: << 'PUSH_GUARD_CMD'
@echo off
set "SCRIPT_DIR=%~dp0"
python "%SCRIPT_DIR%run_push_guard.py"
exit /b %ERRORLEVEL%
PUSH_GUARD_CMD

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$SCRIPT_DIR/run_push_guard.py"
fi
exec python "$SCRIPT_DIR/run_push_guard.py"
