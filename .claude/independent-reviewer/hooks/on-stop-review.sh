#!/usr/bin/env bash
# on-stop-review.sh — Triggered by the Stop hook when Claude finishes a session.
# Runs `git diff HEAD`, passes it to Claude non-interactively, and writes the
# review to planning/REVIEW.md.

set -euo pipefail

PROJECT_DIR="$(pwd)"
REVIEW_FILE="$PROJECT_DIR/planning/REVIEW.md"

# Get the diff — if nothing changed, exit silently
DIFF=$(git diff HEAD 2>/dev/null || true)
STAGED=$(git diff --cached 2>/dev/null || true)
COMBINED="${DIFF}${STAGED}"

if [ -z "$COMBINED" ]; then
    echo "[independent-reviewer] No uncommitted changes — skipping review." >&2
    exit 0
fi

echo "[independent-reviewer] Changes detected — running post-session review..." >&2

# Build a summary of changed files for the prompt
CHANGED_FILES=$(git diff HEAD --name-only 2>/dev/null | head -20 | tr '\n' ', ' | sed 's/,$//')

# Run Claude non-interactively to produce the review
# --print runs Claude and exits immediately — no interactive session, no loop risk
REVIEW=$(claude --print "You are an independent code reviewer.

Review the following git diff and write a concise, structured code review.

Changed files: $CHANGED_FILES

\`\`\`diff
$COMBINED
\`\`\`

Write your review in this exact format:

## 🔍 Independent Review — $(date '+%Y-%m-%d %H:%M')

**Files changed:** [list]
**Verdict:** ✅ LGTM | ⚠️ Minor issues found | 🚨 Issues found — action required

### Findings

[For each issue: severity emoji (🔴 Critical / 🟡 Important / 🟢 Style), filename:line, title, explanation, suggestion]

If there are no issues, say so clearly.

### Summary
One short paragraph.

Be direct and concise. Do not reproduce large blocks of the diff." 2>/dev/null)

# Write to planning/REVIEW.md
mkdir -p "$PROJECT_DIR/planning"
echo "$REVIEW" > "$REVIEW_FILE"

echo "[independent-reviewer] ✅ Review written to planning/REVIEW.md" >&2
