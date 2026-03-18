#!/usr/bin/env bash
# claude-statusline installer
# Installs statusline.sh + update_usage.sh and patches ~/.claude/settings.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"

# ── Copy scripts ────────────────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR"
cp "$SCRIPT_DIR/statusline.sh"    "$CLAUDE_DIR/statusline.sh"
cp "$SCRIPT_DIR/update_usage.sh"  "$CLAUDE_DIR/update_usage.sh"
chmod +x "$CLAUDE_DIR/statusline.sh" "$CLAUDE_DIR/update_usage.sh"
echo "✓ Scripts installed to $CLAUDE_DIR"

# ── Create tmux session workspace and isolated config ───────────────────────
WORKSPACE="${CLAUDE_DIR}/usage-session"
CONFIG_DIR="${CLAUDE_DIR}/usage-config"

mkdir -p "$WORKSPACE" "$CONFIG_DIR"

# Minimal settings for the claude-usage tmux session:
# - No statusLine (avoids recursive statusline rendering)
# - No hooks (avoids triggering another update_usage.sh)
# CLAUDE_CONFIG_DIR replaces ~/.claude entirely, so these are the only settings
# that apply inside the tmux session.
cat > "${CONFIG_DIR}/settings.json" <<'EOF'
{
  "statusLine": {
    "type": "disabled"
  }
}
EOF

echo "✓ tmux session config written to $CONFIG_DIR/settings.json"
echo "✓ tmux session workspace created at $WORKSPACE"

# ── Patch settings.json ─────────────────────────────────────────────────────
SETTINGS="$CLAUDE_DIR/settings.json"

python3 - "$SETTINGS" <<'PYEOF'
import json, sys, os

path = sys.argv[1]

# Load existing settings or start fresh
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
else:
    cfg = {}

# statusLine
cfg["statusLine"] = {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
}

# hooks.Stop — add our hook, preserve any existing Stop hooks
hooks = cfg.setdefault("hooks", {})
stop_hooks = hooks.setdefault("Stop", [])

our_cmd = "USAGE_STALE_SECONDS=1800 bash $HOME/.claude/update_usage.sh &"
our_hook = {"type": "command", "command": our_cmd}

# Find or create the catch-all matcher entry
for entry in stop_hooks:
    if entry.get("matcher") == "":
        existing = entry.setdefault("hooks", [])
        if not any(h.get("command") == our_cmd for h in existing):
            existing.append(our_hook)
        break
else:
    stop_hooks.append({"matcher": "", "hooks": [our_hook]})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print(f"✓ settings.json patched ({path})")
PYEOF

echo ""
echo "Done. Restart Claude Code to activate the statusline."
echo ""
echo "Notes:"
echo "  • Line 2 (quota) only appears for personal/Max plan (not Vertex/work accounts)"
echo "  • Quota cache updates every 30 min in the background via a persistent tmux session"
echo "  • The tmux session (claude-usage) starts on first prompt and stays warm"
echo "  • Requires: jq, python3, tmux"
