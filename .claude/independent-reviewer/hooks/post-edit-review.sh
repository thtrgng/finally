#!/usr/bin/env bash
# Post-edit hook for the independent-reviewer plugin.
# Called by Claude Code after every Write / Edit / MultiEdit tool use.
# Input: JSON payload on stdin describing the tool call and its result.

set -euo pipefail

PENDING_DIR=".claude/independent-reviewer/pending"
mkdir -p "$PENDING_DIR"

# Read the hook payload from stdin
PAYLOAD=$(cat)

# Extract useful fields (gracefully — python3 is available on macOS)
TOOL_NAME=$(echo "$PAYLOAD" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_name', 'unknown'))
except:
    print('unknown')
" 2>/dev/null || echo "unknown")

FILE_PATH=$(echo "$PAYLOAD" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    inp = d.get('tool_input', {})
    # Write tool uses 'file_path', Edit uses 'path'
    print(inp.get('file_path', inp.get('path', '')))
except:
    print('')
" 2>/dev/null || echo "")

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EPOCH=$(date +%s)

# Write a pending review record
REVIEW_FILE="$PENDING_DIR/${EPOCH}.json"
python3 -c "
import json
record = {
    'timestamp': '$TIMESTAMP',
    'tool': '$TOOL_NAME',
    'file': '$FILE_PATH'
}
with open('$REVIEW_FILE', 'w') as f:
    json.dump(record, f, indent=2)
" 2>/dev/null || true

# Emit a visible notice (written to stderr so it appears in Claude's output)
if [ -n "$FILE_PATH" ]; then
    echo "📋 [independent-reviewer] Queued review for: $FILE_PATH  →  run /review for feedback" >&2
else
    echo "📋 [independent-reviewer] Change queued for review  →  run /review for feedback" >&2
fi
