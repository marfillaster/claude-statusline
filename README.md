# claude-statusline

A two-line status bar for [Claude Code](https://claude.ai/code) showing context window usage, model, and quota.

```
myproject │ 72% · 57k/200k │ sonnet-4-6
sess 91% ↻3h · wk 13% ↻4d2h · +$14.46 ↻12d
```

**Line 1** — always visible: working directory, context remaining, model
**Line 2** — personal/Max plan only: session, weekly, and extra quota remaining with reset countdowns

Colors go green → yellow → red as the resource depletes.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `jq` — JSON parsing
- `python3` — quota display and token math
- `tmux` — persistent background session for quota fetching (personal plan only)

```bash
brew install jq tmux   # macOS
```

## Install

```bash
git clone https://github.com/marfillaster/claude-statusline
cd claude-statusline
bash install.sh
```

Restart Claude Code. That's it.

The installer copies `statusline.sh` and `update_usage.sh` to `~/.claude/` and patches `~/.claude/settings.json` without overwriting your existing settings.

## How it works

**Line 1** is rendered by `statusline.sh` on every response. Claude Code passes a JSON payload via stdin with context window stats and model info.

**Line 2** reads from `~/.claude/usage_cache.json`, which is populated by `update_usage.sh`. That script runs in the background after each response (via a Stop hook), at most once every 30 minutes. It connects to a persistent `tmux` session named `claude-usage`, sends `/usage`, captures the TUI output, and writes the cache.

The `claude-usage` session starts on first use and stays warm — no per-prompt startup cost. It runs in a blank workspace (`~/.claude/usage-session/`) with an isolated config (`~/.claude/usage-config/settings.json`) that disables the statusline and hooks, preventing recursive invocation.

Line 2 is suppressed automatically when `CLAUDE_CODE_USE_VERTEX=1` is set (work/enterprise accounts don't have the same quota model).

## Context display

| State | Display |
|-------|---------|
| Not yet measured | `~/200k` |
| In use | `72% · 57k/200k` |
| No data | `—` |

The percentage shown is **remaining**, not used — consistent with the quota line.

## Quota display

Quota is fetched from the interactive `/usage` command and cached locally. The cache refreshes every 30 minutes in the background. A `(stale Nh)` indicator appears if the cache is older than 2 hours.

To force a refresh:
```bash
bash ~/.claude/update_usage.sh
```

To change the refresh interval, set `USAGE_STALE_SECONDS` in the Stop hook inside `~/.claude/settings.json`:
```json
"command": "USAGE_STALE_SECONDS=900 bash $HOME/.claude/update_usage.sh &"
```

## Uninstall

Remove the scripts and revert settings:

```bash
tmux kill-session -t claude-usage 2>/dev/null || true
rm -rf ~/.claude/statusline.sh ~/.claude/update_usage.sh \
       ~/.claude/usage_cache.json \
       ~/.claude/usage-session ~/.claude/usage-config

# In ~/.claude/settings.json, remove:
#   "statusLine": { ... }
#   "hooks" > "Stop" entry for update_usage.sh
```
