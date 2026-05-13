#!/usr/bin/env bash
# ~/.claude/update_usage.sh
# Fetches Claude Code rate-limit utilization via the Anthropic API and caches
# the result. Inspired by https://github.com/HermannBjorgvin/Clawdmeter.
#
# Method: make a minimal /v1/messages call (1 Haiku token) using the OAuth
# token from Claude Code's credentials store, then parse rate-limit response
# headers:
#   anthropic-ratelimit-unified-5h-utilization  -> session pct (0.0-1.0)
#   anthropic-ratelimit-unified-5h-reset        -> session reset (unix ts)
#   anthropic-ratelimit-unified-7d-utilization  -> week pct (0.0-1.0)
#   anthropic-ratelimit-unified-7d-reset        -> week reset (unix ts)
#
# Only runs for personal/Max plan account (CLAUDE_CODE_USE_VERTEX != 1).

set -euo pipefail

# Namespace resources by auth type
AUTH_SUFFIX="personal"
[ "${CLAUDE_CODE_USE_VERTEX:-0}" = "1" ] && AUTH_SUFFIX="vertex"

CACHE_FILE="${HOME}/.claude/usage_cache.${AUTH_SUFFIX}.json"
LOCK_FILE="${HOME}/.claude/usage_update.${AUTH_SUFFIX}.lock"

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

# ── Read OAuth access token ─────────────────────────────────────────────────
# macOS: Keychain. Linux: ~/.claude/.credentials.json.
read_token() {
  local creds=""
  if [ "$(uname)" = "Darwin" ]; then
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
  fi
  if [ -z "$creds" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
    creds=$(cat "$HOME/.claude/.credentials.json")
  fi
  [ -z "$creds" ] && return 1
  printf '%s' "$creds" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    tok = d.get("claudeAiOauth", {}).get("accessToken") or d.get("accessToken")
    if tok: print(tok)
except Exception:
    pass
'
}

TOKEN=$(read_token)
[ -z "$TOKEN" ] && exit 0

# ── Fetch rate-limit headers ────────────────────────────────────────────────
HDR_FILE=$(mktemp /tmp/claude_usage_hdr_XXXXX)
trap 'rm -f "$LOCK_FILE" "$HDR_FILE"' EXIT

curl -sS -D "$HDR_FILE" -o /dev/null \
  "https://api.anthropic.com/v1/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Content-Type: application/json" \
  -H "User-Agent: claude-code/2.1.140" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
  >/dev/null 2>&1 || exit 0

# ── Parse headers and write cache ───────────────────────────────────────────
CACHE_FILE="$CACHE_FILE" python3 - "$HDR_FILE" <<'PYEOF'
import json, os, re, sys, time

hdrs = {}
with open(sys.argv[1]) as f:
    for line in f:
        if ':' in line:
            k, _, v = line.partition(':')
            hdrs[k.strip().lower()] = v.strip()

def fnum(name):
    v = hdrs.get(name)
    if v is None: return None
    try: return float(v)
    except ValueError: return None

def inum(name):
    v = fnum(name)
    return int(v) if v is not None else None

result = {}

u5 = fnum('anthropic-ratelimit-unified-5h-utilization')
r5 = inum('anthropic-ratelimit-unified-5h-reset')
if u5 is not None:
    result['session'] = {'pct_used': round(u5 * 100)}
    if r5 is not None:
        result['session']['reset_ts'] = r5

u7 = fnum('anthropic-ratelimit-unified-7d-utilization')
r7 = inum('anthropic-ratelimit-unified-7d-reset')
if u7 is not None:
    result['week'] = {'pct_used': round(u7 * 100)}
    if r7 is not None:
        result['week']['reset_ts'] = r7

if not result:
    sys.exit(1)

result['ts'] = int(time.time())
cache_path = os.path.expanduser(os.environ.get('CACHE_FILE', '~/.claude/usage_cache.personal.json'))
with open(cache_path, 'w') as f:
    json.dump(result, f)
PYEOF
