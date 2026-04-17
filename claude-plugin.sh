#!/usr/bin/env bash
# claude-plugin.sh — Local plugin marketplace manager for Claude Code.
#
# Usage:
#   ./claude-plugin.sh list                    List all plugins in the catalog
#   ./claude-plugin.sh install <plugin-name>   Install a plugin into this project
#   ./claude-plugin.sh uninstall <plugin-name> Remove a plugin from this project
#   ./claude-plugin.sh info <plugin-name>      Show details about a plugin
#   ./claude-plugin.sh status                  Show what's installed in this project
#
# The marketplace catalog lives at: ~/.claude/marketplace/marketplace.json
# Add more plugins by placing their plugin.json in ~/.claude/marketplace/plugins/<name>/

set -euo pipefail

MARKETPLACE_DIR="$HOME/.claude/marketplace"
MARKETPLACE_JSON="$MARKETPLACE_DIR/marketplace.json"
PROJECT_DIR="$(pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────

bold() { printf '\033[1m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }
red() { printf '\033[31m%s\033[0m' "$1"; }
cyan() { printf '\033[36m%s\033[0m' "$1"; }
dim() { printf '\033[2m%s\033[0m' "$1"; }

require_marketplace() {
    if [ ! -f "$MARKETPLACE_JSON" ] || [ ! -s "$MARKETPLACE_JSON" ]; then
        echo ""
        echo "  $(red '✗') No marketplace catalog found."
        echo "  Expected: $MARKETPLACE_JSON"
        echo ""
        echo "  To create one, install a plugin first:"
        echo "    bash .claude/independent-reviewer/install.sh"
        echo ""
        exit 1
    fi
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_list() {
    require_marketplace
    echo ""
    echo "  $(bold 'Company Plugin Marketplace')"
    echo "  $(dim "$MARKETPLACE_JSON")"
    echo ""
    python3 - "$MARKETPLACE_JSON" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    catalog = json.load(f)

plugins = catalog.get("plugins", [])
if not plugins:
    print("  No plugins in catalog yet.")
else:
    for p in plugins:
        status = "✓ installed" if p.get("installed") else "○ available"
        color  = "\033[32m" if p.get("installed") else "\033[2m"
        reset  = "\033[0m"
        print(f"  {color}{status}{reset}  \033[1m{p['name']}\033[0m  v{p['version']}")
        print(f"             {p['description']}")
        print()
PYEOF
}

cmd_info() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "  Usage: $0 info <plugin-name>"
        exit 1
    fi
    require_marketplace
    python3 - "$MARKETPLACE_JSON" "$name" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    catalog = json.load(f)

name = sys.argv[2]
plugin = next((p for p in catalog.get("plugins", []) if p["name"] == name), None)

if not plugin:
    print(f"\n  ✗ Plugin '{name}' not found in catalog.\n")
    sys.exit(1)

def field(label, val):
    print(f"  \033[2m{label:<14}\033[0m {val}")

print()
print(f"  \033[1m{plugin['displayName']}\033[0m  v{plugin['version']}")
print()
field("Name:",        plugin['name'])
field("Author:",      plugin['author'])
field("Description:", plugin['description'])
field("Source:",      plugin.get('source', 'unknown'))
status = "\033[32mInstalled\033[0m" if plugin.get("installed") else "\033[2mNot installed\033[0m"
field("Status:",      status)
if plugin.get("installedAt"):
    field("Installed at:", plugin["installedAt"])
print()
PYEOF
}

cmd_install() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "  Usage: $0 install <plugin-name>"
        exit 1
    fi
    require_marketplace

    # Find the plugin source directory
    SOURCE=$(python3 - "$MARKETPLACE_JSON" "$name" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    catalog = json.load(f)
name = sys.argv[2]
plugin = next((p for p in catalog.get("plugins", []) if p["name"] == name), None)
if not plugin:
    print("")
else:
    print(plugin.get("source", ""))
PYEOF
)

    if [ -z "$SOURCE" ]; then
        echo ""
        echo "  $(red '✗') Plugin '$name' not found in marketplace."
        echo "  Run: $0 list   to see available plugins."
        echo ""
        exit 1
    fi

    INSTALL_SCRIPT="$SOURCE/install.sh"
    if [ ! -f "$INSTALL_SCRIPT" ]; then
        echo ""
        echo "  $(red '✗') No install.sh found at: $INSTALL_SCRIPT"
        echo ""
        exit 1
    fi

    bash "$INSTALL_SCRIPT" "$PROJECT_DIR"
}

cmd_uninstall() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "  Usage: $0 uninstall <plugin-name>"
        exit 1
    fi
    require_marketplace

    SOURCE=$(python3 - "$MARKETPLACE_JSON" "$name" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    catalog = json.load(f)
name = sys.argv[2]
plugin = next((p for p in catalog.get("plugins", []) if p["name"] == name), None)
if not plugin:
    print("")
else:
    print(plugin.get("source", ""))
PYEOF
)

    if [ -z "$SOURCE" ]; then
        echo ""
        echo "  $(red '✗') Plugin '$name' not found in marketplace."
        echo ""
        exit 1
    fi

    UNINSTALL_SCRIPT="$SOURCE/uninstall.sh"
    if [ ! -f "$UNINSTALL_SCRIPT" ]; then
        echo ""
        echo "  $(red '✗') No uninstall.sh found at: $UNINSTALL_SCRIPT"
        echo ""
        exit 1
    fi

    bash "$UNINSTALL_SCRIPT" "$PROJECT_DIR"
}

cmd_status() {
    echo ""
    echo "  $(bold 'Installed plugins in this project')"
    echo "  $(dim "$PROJECT_DIR")"
    echo ""

    AGENTS=$(ls "$PROJECT_DIR/.claude/agents/" 2>/dev/null | grep -v "^$" || echo "none")
    COMMANDS=$(ls "$PROJECT_DIR/.claude/commands/" 2>/dev/null | grep -v "^$" || echo "none")

    echo "  $(bold 'Agents:')   $AGENTS"
    echo "  $(bold 'Commands:') $COMMANDS"

    SETTINGS="$PROJECT_DIR/.claude/settings.json"
    if [ -f "$SETTINGS" ] && [ -s "$SETTINGS" ]; then
        HOOK_COUNT=$(python3 -c "
import json
with open('$SETTINGS') as f:
    s = json.load(f)
hooks = s.get('hooks', {}).get('PostToolUse', [])
print(len(hooks))
" 2>/dev/null || echo "0")
        echo "  $(bold 'Hooks:')    $HOOK_COUNT PostToolUse hook(s) registered"
    fi
    echo ""
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    list)      cmd_list       ;;
    info)      cmd_info "$@"  ;;
    install)   cmd_install "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    status)    cmd_status     ;;
    *)
        echo ""
        echo "  $(bold 'claude-plugin') — Company marketplace manager"
        echo ""
        echo "  Commands:"
        echo "    list                    List all plugins in the catalog"
        echo "    install   <name>        Install a plugin into this project"
        echo "    uninstall <name>        Remove a plugin from this project"
        echo "    info      <name>        Show plugin details"
        echo "    status                  Show what is installed in this project"
        echo ""
        ;;
esac
