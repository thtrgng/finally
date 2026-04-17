#!/usr/bin/env bash
# uninstall.sh — Remove the independent-reviewer plugin from a target project.
#
# Usage:
#   ./uninstall.sh                  Remove from current directory
#   ./uninstall.sh /path/to/project Remove from specific project

set -euo pipefail

TARGET_DIR="${1:-$(pwd)}"
CLAUDE_DIR="$TARGET_DIR/.claude"

echo ""
echo "  Uninstalling independent-reviewer from: $TARGET_DIR"
echo ""

# Remove installed files
rm -f "$CLAUDE_DIR/agents/independent-reviewer.md"        && echo "  ✅ Removed agent"
rm -f "$CLAUDE_DIR/commands/review.md"                    && echo "  ✅ Removed /review command"
rm -rf "$CLAUDE_DIR/.independent-reviewer"                && echo "  ✅ Removed hooks and pending queue"

# Remove hook from settings.json
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS_FILE" ] && [ -s "$SETTINGS_FILE" ]; then
    python3 - "$SETTINGS_FILE" <<'PYEOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    try:
        settings = json.load(f)
    except:
        settings = {}

if "hooks" in settings and "PostToolUse" in settings["hooks"]:
    settings["hooks"]["PostToolUse"] = [
        entry for entry in settings["hooks"]["PostToolUse"]
        if not any(
            h.get("command", "").endswith("post-edit-review.sh")
            for h in entry.get("hooks", [])
        )
    ]

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("  ✅ Removed hook from settings.json")
PYEOF
fi

# Mark as uninstalled in marketplace
MARKETPLACE_JSON="$HOME/.claude/marketplace/marketplace.json"
if [ -f "$MARKETPLACE_JSON" ]; then
    python3 - "$MARKETPLACE_JSON" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    catalog = json.load(f)
for p in catalog["plugins"]:
    if p["name"] == "independent-reviewer":
        p["installed"] = False
with open(path, "w") as f:
    json.dump(catalog, f, indent=2)
    f.write("\n")
print("  ✅ Marked uninstalled in marketplace")
PYEOF
fi

echo ""
echo "  🗑️  independent-reviewer uninstalled."
echo ""
