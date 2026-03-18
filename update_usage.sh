#!/usr/bin/env bash
# ~/.claude/update_usage.sh
# Fetches /usage via a persistent tmux+claude session and caches the result.
# Uses a lock file to prevent concurrent runs.
# Only runs for personal/Max plan account (CLAUDE_CODE_USE_VERTEX != 1).

set -euo pipefail

CACHE_FILE="${HOME}/.claude/usage_cache.json"
LOCK_FILE="${HOME}/.claude/usage_update.lock"

SESSION="claude-usage"
WORKSPACE="${HOME}/.claude/usage-session"
CONFIG_DIR="${HOME}/.claude/usage-config"

# Skip on work/Vertex account
if [ "${CLAUDE_CODE_USE_VERTEX:-0}" = "1" ]; then
  exit 0
fi

# Skip if cache is fresh enough (only when USAGE_STALE_SECONDS is explicitly set)
if [ -n "${USAGE_STALE_SECONDS:-}" ] && [ -f "$CACHE_FILE" ]; then
  cache_ts=$(python3 -c "import json; print(int(json.load(open('$CACHE_FILE')).get('ts',0)))" 2>/dev/null || echo 0)
  cache_age=$(( $(date +%s) - cache_ts ))
  if [ "$cache_age" -lt "$USAGE_STALE_SECONDS" ]; then
    exit 0
  fi
fi

# Acquire lock (skip if another update is running)
if [ -f "$LOCK_FILE" ]; then
  lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
  if kill -0 "$lock_pid" 2>/dev/null; then
    exit 0
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# ── Ensure tmux session is running with claude ──────────────────────────────
ensure_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    # Verify claude is still at a prompt
    if tmux capture-pane -t "$SESSION" -p 2>/dev/null | grep -q '❯'; then
      return 0
    fi
    # Session exists but not at a prompt — kill and restart
    tmux kill-session -t "$SESSION" 2>/dev/null || true
  fi

  # Start a new session in the blank workspace with isolated config
  tmux new-session -d -s "$SESSION" -x 220 -y 50 -c "$WORKSPACE"
  tmux send-keys -t "$SESSION" "CLAUDE_CONFIG_DIR=$CONFIG_DIR claude" Enter

  # Wait up to 30s for the prompt
  for i in $(seq 1 30); do
    sleep 1
    if tmux capture-pane -t "$SESSION" -p 2>/dev/null | grep -q '❯'; then
      return 0
    fi
  done
  return 1
}

if ! ensure_session; then
  exit 0
fi

# ── Fetch /usage output ─────────────────────────────────────────────────────
# Clear pane history so capture only sees fresh output
tmux clear-history -t "$SESSION" 2>/dev/null || true

tmux send-keys -t "$SESSION" "/usage" Enter

# Poll up to 10s for the usage data to render
RAW=""
for i in $(seq 1 20); do
  sleep 0.5
  RAW=$(tmux capture-pane -t "$SESSION" -p -S -200 2>/dev/null || echo "")
  if echo "$RAW" | grep -q '[0-9]\+%.*used'; then
    break
  fi
done

# Dismiss the usage overlay (Escape returns to prompt without quitting)
tmux send-keys -t "$SESSION" Escape
sleep 0.2

if [ -z "$RAW" ] || ! echo "$RAW" | grep -q '[0-9]\+%.*used'; then
  exit 0
fi

# Write RAW to a temp file to avoid env-var size limits
RAW_FILE=$(mktemp /tmp/claude_usage_XXXXX)
printf '%s' "$RAW" > "$RAW_FILE"
trap 'rm -f "$LOCK_FILE" "$RAW_FILE"' EXIT

python3 - "$RAW_FILE" <<'PYEOF'
import re, json, os, sys, time
from datetime import datetime, timezone, timedelta

raw_text = open(sys.argv[1]).read() if len(sys.argv) > 1 else ''

# Use local system timezone
LOCAL_TZ = datetime.now(timezone.utc).astimezone().tzinfo

def strip_ansi(s):
    return re.sub(r'\x1b(?:\[[0-9;?><]*[A-Za-z]|]0;[^\x07]*\x07)', '', s)

text_clean = strip_ansi(raw_text)
text_clean = re.sub(r'[^\x20-\x7e\n]', ' ', text_clean)
text_clean = re.sub(r'\s+', ' ', text_clean)
text_clean = re.sub(r'[█▏▎▍▌▋▊▉▐▖▗▘▙▚▛▜▝▞▟▁▂▃▄▅▆▇]+', ' ', text_clean)
text_clean = re.sub(r'\s+', ' ', text_clean).strip()

result = {}

# ── Percentages ──────────────────────────────────────────────────────────────
m = re.search(r'Current session.*?(\d+)%\s*used', text_clean)
if m: result['session'] = {'pct_used': int(m.group(1))}

m = re.search(r'Current week.*?(\d+)%\s*used', text_clean)
if m: result['week'] = {'pct_used': int(m.group(1))}

m = re.search(r'Extra usage.*?(\d+)%\s*used', text_clean)
if m: result['extra'] = {'pct_used': int(m.group(1))}

m = re.search(r'\$([0-9.]+)\s*/\s*\$([0-9.]+)\s*spent', text_clean)
if m:
    result.setdefault('extra', {})['spent'] = float(m.group(1))
    result.setdefault('extra', {})['budget'] = float(m.group(2))

# ── Reset timestamps (using local timezone) ──────────────────────────────────
now = datetime.now(LOCAL_TZ)
months = {'Jan':1,'Feb':2,'Mar':3,'Apr':4,'May':5,'Jun':6,
          'Jul':7,'Aug':8,'Sep':9,'Oct':10,'Nov':11,'Dec':12}

# Session reset: "Resets at 6am (Timezone/Name)"
# Raw text may have cursor-forward ANSI codes between chars
sess_raw = re.split(r'Current week', raw_text)[0] if 'Current week' in raw_text else raw_text[:300]
m = re.search(r'(\d+)(?:\x1b\[\d*C)?([ap])?(?:\x1b\[\d*C)?m\s*\([^)]+\)', sess_raw)
if m:
    hour = int(m.group(1))
    meridiem = (m.group(2) or 'a') + 'm'
    if meridiem == 'pm' and hour != 12: hour += 12
    elif meridiem == 'am' and hour == 12: hour = 0
    reset_dt = now.replace(hour=hour, minute=0, second=0, microsecond=0)
    if reset_dt <= now: reset_dt += timedelta(days=1)
    result.setdefault('session', {})['reset_ts'] = int(reset_dt.timestamp())

# Week reset: "Resets Mar 21 at 11am"
m = re.search(r'Resets?\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d+)\s+at\s+(\d+)(am|pm)', text_clean)
if m:
    mon, day, hour = months[m.group(1)], int(m.group(2)), int(m.group(3))
    if m.group(4) == 'pm' and hour != 12: hour += 12
    elif m.group(4) == 'am' and hour == 12: hour = 0
    yr = now.year
    reset_dt = datetime(yr, mon, day, hour, 0, 0, tzinfo=LOCAL_TZ)
    if reset_dt <= now: reset_dt = datetime(yr+1, mon, day, hour, 0, 0, tzinfo=LOCAL_TZ)
    result.setdefault('week', {})['reset_ts'] = int(reset_dt.timestamp())

# Extra reset: "Resets Apr 1"
extra_chunk = re.split(r'Extra usage', text_clean)[-1] if 'Extra usage' in text_clean else text_clean[-300:]
m = re.search(r'[Rr]esets?\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d+)', extra_chunk)
if m:
    mon, day = months[m.group(1)], int(m.group(2))
    yr = now.year
    reset_dt = datetime(yr, mon, day, 0, 0, 0, tzinfo=LOCAL_TZ)
    if reset_dt <= now: reset_dt = datetime(yr+1, mon, day, 0, 0, 0, tzinfo=LOCAL_TZ)
    result.setdefault('extra', {})['reset_ts'] = int(reset_dt.timestamp())

if result:
    result['ts'] = int(time.time())
    cache_path = os.path.expanduser('~/.claude/usage_cache.json')
    with open(cache_path, 'w') as f:
        json.dump(result, f)
else:
    sys.exit(1)
PYEOF
