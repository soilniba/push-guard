#!/bin/bash
# Push Guard: block git push via Claude Bash tool until pre-push-review skill completes.
#
# Hook input arrives via stdin as JSON: {"tool_name":"Bash","tool_input":{"command":"..."}}
# Exits 2 (block) if git push detected and review marker is absent.

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

    echo ""
    echo "🚫 Push blocked: pre-push review not completed."
    echo ""
    echo "Run the review skill first:"
    echo "  push-guard:pre-push-review"
    echo ""
    echo "The skill will scan modified code across 4 safety dimensions."
    echo "Push unblocks automatically after skill completes (single-use token)."
    echo ""
    exit 2
fi

exit 0
