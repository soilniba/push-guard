#!/bin/bash
# Push Guard: block git push via Claude Bash tool until pre-push-review skill completes.
#
# Hook input arrives via stdin as JSON: {"tool_name":"Bash","tool_input":{"command":"..."}}
# Outputs JSON to deny the push if review marker is absent.

MARKER="/tmp/pre-push-review-done"

# Extract command from stdin JSON
COMMAND=$(python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" 2>/dev/null)

# Check if this is a real git push (ignore --help / --dry-run / -n)
if echo "$COMMAND" | grep -qE 'git\s+push' && \
   ! echo "$COMMAND" | grep -qE '(--help|-n\b|--dry-run)'; then

    if [ -f "$MARKER" ]; then
        rm -f "$MARKER"  # 单次消耗：token 用完即删，下次 push 必须重新 review
        exit 0
    fi

    python3 -c "
import json
print(json.dumps({
    'systemMessage': '🚫 Push blocked: run push-guard:pre-push-review first (4-dimension safety scan)',
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': 'Pre-push review not completed. Run: push-guard:pre-push-review'
    }
}))
"
    exit 0
fi

exit 0
