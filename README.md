# claude-statusline

A two-line status bar for [Claude Code](https://claude.ai/code) showing context window usage, model, and quota.

```
myproject │ 72% · 57k/200k │ sonnet-4-6
sess 91% ↻3h · wk 13% ↻4d2h
```

**Line 1** — always visible: working directory, context remaining, model
**Line 2** — personal/Max plan only: 5-hour session and 7-day weekly quota remaining with reset countdowns

Colors go green → yellow → red as the resource depletes.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `jq` — JSON parsing
- `python3` — quota display and token math
- `curl` — fetching rate-limit headers from the Anthropic API

```bash
brew install jq   # macOS (curl + python3 are preinstalled)
```

## Install

```bash
git clone https://github.com/marfillaster/claude-statusline
cd claude-statusline
bash install.sh
```

Restart Claude Code. That's it.

The installer copies `statusline.sh` and `update_usage.sh` to `~/.claude/` and patches `~/.claude/settings.json` without overwriting your existing settings. Safe to run multiple times (idempotent).

**Multi-instance support:** If you run multiple Claude instances with different auth types (e.g., `claude` for work and `claude-ken` for personal), the scripts automatically namespace cache files and lock files by auth type. Each instance maintains its own isolated state.

## How it works

**Line 1** is rendered by `statusline.sh` on every response. Claude Code passes a JSON payload via stdin with context window stats and model info.

**Line 2** reads from `~/.claude/usage_cache.{personal|vertex}.json`, which is populated by `update_usage.sh`. That script runs in the background:
- **On session start** (via SessionStart hook) — immediate update when Claude launches
- **After each response** (via Stop hook) — throttled to once every 5 minutes by default

`update_usage.sh` reads your Claude Code OAuth token (macOS Keychain or `~/.claude/.credentials.json` on Linux), makes a minimal `POST /v1/messages` call (1 Haiku token — effectively free), and parses the response's `anthropic-ratelimit-unified-{5h,7d}-{utilization,reset}` headers. This approach is borrowed from [Clawdmeter](https://github.com/HermannBjorgvin/Clawdmeter).

**Multi-instance isolation:** When `CLAUDE_CODE_USE_VERTEX=1` (work account), resources use the `vertex` suffix. When `CLAUDE_CODE_USE_VERTEX=0` or unset (personal account), resources use the `personal` suffix. This prevents interference when running multiple instances simultaneously.

Line 2 is suppressed automatically when `CLAUDE_CODE_USE_VERTEX=1` is set (work/enterprise accounts don't have the same quota model).

## Context display

| State | Display |
|-------|---------|
| Not yet measured | `~/200k` |
| In use | `72% · 57k/200k` |
| No data | `—` |

The percentage shown is **remaining**, not used — consistent with the quota line.

## Quota display

Quota is read from Anthropic API rate-limit response headers and cached locally. The cache refreshes every 5 minutes by default. A `(stale Nh)` indicator appears if the cache is older than 2 hours.

To force a refresh:
```bash
bash ~/.claude/update_usage.sh
```

`USAGE_STALE_SECONDS` controls the throttle. If unset, quota is fetched on every response. The default install sets it to 300 (5 min) in the Stop hook. To change it, edit the hook command in `~/.claude/settings.json`:
```json
"command": "USAGE_STALE_SECONDS=900 bash $HOME/.claude/update_usage.sh &"
```

## Uninstall

```bash
cd claude-statusline
bash uninstall.sh
```

The uninstaller removes all scripts and reverts `~/.claude/settings.json`. Safe to run multiple times.
