#!/usr/bin/env bash
# install.sh — Install the independent-reviewer plugin into a target project.
#
# Usage:
#   ./install.sh                  Install into the current directory
#   ./install.sh /path/to/project Install into a specific project directory
#
# What it does:
#   1. Copies agents, commands, and hooks into the project's .claude/ directory
#   2. Registers the PostToolUse hook in .claude/settings.json
#   3. Registers the plugin in ~/.claude/marketplace/marketplace.json

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"
CLAUDE_DIR="$TARGET_DIR/.claude"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║         independent-reviewer  v1.0.0             ║"
echo "║         Installing plugin...                     ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Plugin source : $PLUGIN_DIR"
echo "  Target project: $TARGET_DIR"
echo ""

# ── 1. Create necessary directories ──────────────────────────────────────────
mkdir -p "$CLAUDE_DIR/agents"
mkdir -p "$CLAUDE_DIR/commands"
mkdir -p "$CLAUDE_DIR/.independent-reviewer/hooks"
mkdir -p "$CLAUDE_DIR/.independent-reviewer/pending"

# ── 2. Copy agent ─────────────────────────────────────────────────────────────
cp "$PLUGIN_DIR/agents/independent-reviewer.md" "$CLAUDE_DIR/agents/independent-reviewer.md"
echo "  ✅ Agent installed    → .claude/agents/independent-reviewer.md"

# ── 3. Copy slash command ─────────────────────────────────────────────────────
cp "$PLUGIN_DIR/commands/review.md" "$CLAUDE_DIR/commands/review.md"
echo "  ✅ Command installed  → .claude/commands/review.md  (/review)"

# ── 4. Copy hook script ───────────────────────────────────────────────────────
HOOK_DEST="$CLAUDE_DIR/.independent-reviewer/hooks/post-edit-review.sh"
cp "$PLUGIN_DIR/hooks/post-edit-review.sh" "$HOOK_DEST"
chmod +x "$HOOK_DEST"
echo "  ✅ Hook installed     → .claude/.independent-reviewer/hooks/post-edit-review.sh"

# ── 5. Register hook in settings.json ────────────────────────────────────────
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

# Create empty settings.json if missing or empty
if [ ! -f "$SETTINGS_FILE" ] || [ ! -s "$SETTINGS_FILE" ]; then
    echo '{}' > "$SETTINGS_FILE"
fi

python3 - "$SETTINGS_FILE" "$HOOK_DEST" <<'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
hook_command  = sys.argv[2]

with open(settings_path) as f:
    try:
        settings = json.load(f)
    except json.JSONDecodeError:
        settings = {}

settings.setdefault("hooks", {})
settings["hooks"].setdefault("PostToolUse", [])

# Avoid duplicate registration
already = any(
    any(h.get("command", "").endswith("post-edit-review.sh")
        for h in entry.get("hooks", []))
    for entry in settings["hooks"]["PostToolUse"]
)

if not already:
    settings["hooks"]["PostToolUse"].append({
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{"type": "command", "command": hook_command}]
    })

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("  ✅ Hook registered   → .claude/settings.json (PostToolUse)")
PYEOF

# ── 6. Register in the local marketplace ──────────────────────────────────────
MARKETPLACE_DIR="$HOME/.claude/marketplace"
MARKETPLACE_JSON="$MARKETPLACE_DIR/marketplace.json"
mkdir -p "$MARKETPLACE_DIR/plugins"

python3 - "$MARKETPLACE_JSON" "$PLUGIN_DIR" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

marketplace_path = sys.argv[1]
plugin_dir       = sys.argv[2]

# Load plugin metadata
with open(os.path.join(plugin_dir, "plugin.json")) as f:
    meta = json.load(f)

# Load or initialise marketplace catalog
if os.path.exists(marketplace_path) and os.path.getsize(marketplace_path) > 0:
    with open(marketplace_path) as f:
        catalog = json.load(f)
else:
    catalog = {
        "version": "1.0.0",
        "name": "Company Plugin Marketplace",
        "description": "Internal plugin catalog. Share this directory with colleagues to distribute plugins.",
        "plugins": []
    }

# Remove stale entry (idempotent re-install)
catalog["plugins"] = [p for p in catalog["plugins"] if p["name"] != meta["name"]]

catalog["plugins"].append({
    "name":        meta["name"],
    "displayName": meta["displayName"],
    "version":     meta["version"],
    "description": meta["description"],
    "author":      meta["author"],
    "source":      plugin_dir,
    "installed":   True,
    "installedAt": datetime.now(timezone.utc).isoformat()
})

with open(marketplace_path, "w") as f:
    json.dump(catalog, f, indent=2)
    f.write("\n")

print(f"  ✅ Marketplace updated → {marketplace_path}")
PYEOF

echo ""
echo "  ────────────────────────────────────────────────"
echo "  🎉 Plugin installed successfully!"
echo ""
echo "  Available commands:"
echo "    /review             Review all queued changes"
echo "    /review <file>      Review a specific file"
echo ""
echo "  The hook fires automatically after every file edit."
echo "  Run /review at any point to see the findings."
echo "  ────────────────────────────────────────────────"
echo ""
