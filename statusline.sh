#!/usr/bin/env bash
# ~/.claude/statusline.sh
# Line 1: dir | ctx% remaining · tokens | model-code
# Line 2: quota remaining with countdowns (personal/Max plan only)

input=$(cat)

jq_get() {
  command -v jq >/dev/null 2>&1 && printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null || true
}

# ── Extract fields ─────────────────────────────────────────────────────────
cwd=$(jq_get '.workspace.current_dir // .cwd')
model_id=$(jq_get '.model.id // .model')
used_pct=$(jq_get '.context_window.used_percentage')
# Total tokens in context = cache_read + cache_creation + input (current turn)
input_tokens=$(jq_get '(.context_window.current_usage.cache_read_input_tokens // 0) + (.context_window.current_usage.cache_creation_input_tokens // 0) + (.context_window.current_usage.input_tokens // 0)')
ctx_size=$(jq_get '.context_window.context_window_size // 0')
ctx_window_present=$(jq_get '.context_window | if . != null then "1" else "" end')

# ── Colors ─────────────────────────────────────────────────────────────────
R='\033[0m'       # reset
BOLD='\033[1m'
DIM='\033[2m'
WHITE='\033[97m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'

color_remaining() {
  local pct=$1 val=$2   # pct = percent USED; high remaining = good
  local rem=$(( 100 - pct ))
  if   [ "$rem" -ge 50 ] 2>/dev/null; then printf '%b%s%b' "$GREEN"  "$val" "$R"
  elif [ "$rem" -ge 20 ] 2>/dev/null; then printf '%b%s%b' "$YELLOW" "$val" "$R"
  else                                      printf '%b%s%b' "$RED"    "$val" "$R"
  fi
}

# ── Line 1 ─────────────────────────────────────────────────────────────────
dir_name=$([ -n "$cwd" ] && basename "$cwd" || basename "$PWD")

# Derive percentage from tokens if used_percentage absent
if [ -z "$used_pct" ] || [ "$used_pct" = "null" ]; then
  if [ -n "$input_tokens" ] && [ -n "$ctx_size" ] && [ "$ctx_size" != "0" ]; then
    used_pct=$(python3 -c "print(round($input_tokens/$ctx_size*100,1))" 2>/dev/null || echo "")
  fi
fi

ctx_part=""
if [ -n "$used_pct" ] && [ "$used_pct" != "null" ]; then
  pct_int=$(printf '%.0f' "$used_pct" 2>/dev/null || echo "$used_pct")
  rem_int=$(( 100 - pct_int ))
  tok_k=$(( ${input_tokens:-0} / 1000 ))
  ctx_k=$(( ${ctx_size:-0} / 1000 ))
  if [ "$pct_int" -eq 0 ] 2>/dev/null; then
    # 0% used = not yet measured
    if [ "$ctx_k" -gt 0 ] 2>/dev/null; then
      ctx_part=$(color_remaining "0" "~/${ctx_k}k")
    else
      ctx_part=$(color_remaining "0" "~")
    fi
  elif [ "$tok_k" -gt 0 ] 2>/dev/null && [ "$ctx_k" -gt 0 ] 2>/dev/null; then
    ctx_part=$(color_remaining "$pct_int" "${rem_int}% · ${tok_k}k/${ctx_k}k")
  elif [ "$ctx_k" -gt 0 ] 2>/dev/null; then
    ctx_part=$(color_remaining "$pct_int" "${rem_int}%/${ctx_k}k")
  else
    ctx_part=$(color_remaining "$pct_int" "${rem_int}%")
  fi
elif [ -n "$ctx_window_present" ]; then
  # context_window exists but percentage missing — not yet measured
  ctx_k=$(( ${ctx_size:-0} / 1000 ))
  if [ "$ctx_k" -gt 0 ] 2>/dev/null; then
    ctx_part=$(color_remaining "0" "~/${ctx_k}k")
  else
    ctx_part=$(color_remaining "0" "~")
  fi
else
  ctx_part="${DIM}—${R}"
fi

# Model: strip "claude-" prefix
model_short="${model_id#claude-}"
[ -z "$model_short" ] && model_short="${model_id:-?}"

sep="${DIM} │ ${R}"

line1="${BOLD}${WHITE}${dir_name}${R}${sep}${ctx_part}${sep}${CYAN}${model_short}${R}"

# ── Line 2 (personal/Max plan only) ────────────────────────────────────────
line2=""
if [ "${CLAUDE_CODE_USE_VERTEX:-0}" != "1" ]; then
  CACHE="${HOME}/.claude/usage_cache.json"
  if [ -f "$CACHE" ] && command -v python3 >/dev/null 2>&1; then
    line2=$(python3 << 'PYEOF'
import json, os, time

CACHE = os.path.expanduser("~/.claude/usage_cache.json")
R     = "\033[0m"
DIM   = "\033[2m"
GREEN = "\033[32m"
YELLOW= "\033[33m"
RED   = "\033[31m"
WHITE = "\033[97m"

def color_rem(pct_used, val):
    rem = 100 - pct_used
    if rem >= 50: return f"{GREEN}{val}{R}"
    if rem >= 20: return f"{YELLOW}{val}{R}"
    return f"{RED}{val}{R}"

try:
    d = json.load(open(CACHE))
    parts = []
    sep = f"{DIM} · {R}"
    now_ts = time.time()

    def countdown(reset_ts):
        secs = max(0, int(reset_ts) - int(now_ts))
        h = secs // 3600
        d2 = h // 24
        h2 = h % 24
        if d2 > 0:
            return f"{d2}d{h2}h"
        return f"{h}h"

    sess = d.get("session", {})
    week = d.get("week", {})
    extra = d.get("extra", {})

    if sess.get("pct_used") is not None:
        rem = 100 - sess["pct_used"]
        s = color_rem(sess["pct_used"], f"sess {rem}%")
        if sess.get("reset_ts"):
            s += f" {DIM}↻{countdown(sess['reset_ts'])}{R}"
        parts.append(s)

    if week.get("pct_used") is not None:
        rem = 100 - week["pct_used"]
        s = color_rem(week["pct_used"], f"wk {rem}%")
        if week.get("reset_ts"):
            s += f" {DIM}↻{countdown(week['reset_ts'])}{R}"
        parts.append(s)

    if extra.get("spent") is not None and extra.get("budget") is not None:
        left = extra["budget"] - extra["spent"]
        s = f"{WHITE}+${left:.2f}{R}"
        if extra.get("reset_ts"):
            s += f" {DIM}↻{countdown(extra['reset_ts'])}{R}"
        parts.append(s)

    age = int(time.time()) - int(d.get("ts", 0))
    if age > 7200:
        stale_h = age // 3600
        parts.append(f"{DIM}(stale {stale_h}h){R}")

    if parts:
        print(sep.join(parts))
except Exception:
    pass
PYEOF
)
  fi
fi

# ── Output ─────────────────────────────────────────────────────────────────
printf "%b\n" "$line1"
[ -n "$line2" ] && printf "%b\n" "$line2"
true
