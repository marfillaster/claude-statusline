#!/usr/bin/env bash
# claude-statusline uninstaller
# Removes scripts, cleans up tmux session, and reverts ~/.claude/settings.json
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SESSION="claude-usage"

# ── Kill tmux session ───────────────────────────────────────────────────────
if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux kill-session -t "$SESSION"
  echo "✓ Killed tmux session: $SESSION"
else
  echo "✓ tmux session not found (already clean)"
fi

# ── Remove scripts and cache ────────────────────────────────────────────────
removed=()
for file in statusline.sh update_usage.sh usage_cache.json usage_update.lock; do
  if [ -f "$CLAUDE_DIR/$file" ]; then
    rm -f "$CLAUDE_DIR/$file"
    removed+=("$file")
  fi
done

if [ ${#removed[@]} -gt 0 ]; then
  echo "✓ Removed: ${removed[*]}"
else
  echo "✓ Scripts already removed (already clean)"
fi

# ── Remove directories ──────────────────────────────────────────────────────
removed_dirs=()
for dir in usage-session usage-config; do
  if [ -d "$CLAUDE_DIR/$dir" ]; then
    rm -rf "$CLAUDE_DIR/$dir"
    removed_dirs+=("$dir")
  fi
done

if [ ${#removed_dirs[@]} -gt 0 ]; then
  echo "✓ Removed directories: ${removed_dirs[*]}"
else
  echo "✓ Directories already removed (already clean)"
fi

# ── Revert settings.json ────────────────────────────────────────────────────
SETTINGS="$CLAUDE_DIR/settings.json"

if [ ! -f "$SETTINGS" ]; then
  echo "✓ No settings.json found (already clean)"
  exit 0
fi

python3 - "$SETTINGS" <<'PYEOF'
import json, sys, os

path = sys.argv[1]

with open(path) as f:
    cfg = json.load(f)

changed = False

# Remove statusLine if it matches our config
if cfg.get("statusLine", {}).get("command") == "bash ~/.claude/statusline.sh":
    del cfg["statusLine"]
    changed = True

# Remove our hooks
hooks = cfg.get("hooks", {})
our_commands = {
    "USAGE_STALE_SECONDS=300 bash $HOME/.claude/update_usage.sh &",
    "USAGE_STALE_SECONDS=0 bash $HOME/.claude/update_usage.sh &",
    "bash ~/.claude/update_usage.sh &"
}

for hook_type in ["Stop", "SessionStart"]:
    if hook_type in hooks:
        for entry in hooks[hook_type]:
            if entry.get("matcher") == "":
                hook_list = entry.get("hooks", [])
                # Remove any hooks matching our commands
                original_len = len(hook_list)
                hook_list[:] = [h for h in hook_list if h.get("command") not in our_commands]
                if len(hook_list) < original_len:
                    changed = True
                # If the hooks list is now empty, we could remove the entry
                # but we'll leave it to preserve user's hook structure

if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print(f"✓ settings.json reverted ({path})")
else:
    print(f"✓ settings.json already clean (no changes needed)")
PYEOF

echo ""
echo "Done. Restart Claude Code to complete uninstallation."
