#!/usr/bin/env bash
# Diagnose a WhatsApp Digest install. Run this first when anything misbehaves.
#
#   bash scripts/doctor.sh              normal check
#   bash scripts/doctor.sh --launchd    re-run under launchd's minimal PATH,
#                                       which is how the 9am job actually sees
#                                       the world. Use this when the digest
#                                       works by hand but not on schedule.
#   bash scripts/doctor.sh --send-test  also send a Telegram test message

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LAUNCHD_MODE=0
SEND_TEST=0
for arg in "$@"; do
  case "$arg" in
    --launchd) LAUNCHD_MODE=1 ;;
    --send-test) SEND_TEST=1 ;;
  esac
done

if [[ $LAUNCHD_MODE -eq 1 ]]; then
  # Reproduce the environment launchd hands a job.
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  echo "### Running with launchd's minimal PATH: $PATH"
  echo
fi

# shellcheck source=lib.sh
source "$REPO_DIR/scripts/lib.sh"

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      → %s\n' "$2"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      → %s\n' "$2"; WARN=$((WARN+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

head_ "System"
echo "  os=$OSTYPE  arch=$(uname -m)  date=$(date '+%Y-%m-%d %H:%M %Z')"
echo "  support dir: $SUPPORT_DIR"

head_ "Executables"
for tool in python3 curl claude uv; do
  if p=$(find_bin "$tool"); then
    ok "$tool → $p"
  else
    case "$tool" in
      python3|curl) bad "$tool not found" "Install it: brew install python" ;;
      claude) warn "claude not found" "The digest will still send, but unfiltered (no summarising). Install Claude Code and sign in." ;;
      uv) warn "uv not found" "Only needed to (re)install the MCP server: curl -LsSf https://astral.sh/uv/install.sh | sh" ;;
    esac
  fi
done

head_ "Bridge binary"
BIN=$(bridge_binary "$REPO_DIR")
if [[ -f "$BIN" ]]; then
  if [[ -x "$BIN" ]]; then ok "$(basename "$BIN") present and executable"
  else bad "$(basename "$BIN") is not executable" "chmod +x '$BIN'"; fi
  if xattr -p com.apple.quarantine "$BIN" >/dev/null 2>&1; then
    bad "quarantined by macOS Gatekeeper" "xattr -d com.apple.quarantine '$BIN'"
  else
    ok "not quarantined"
  fi
else
  bad "no binary for this architecture at $BIN" "Available: $(ls "$REPO_DIR/bin" 2>/dev/null | tr '\n' ' ')"
fi

head_ "Bridge process"
if pgrep -f "whatsapp-bridge" >/dev/null 2>&1; then
  ok "running (pid $(pgrep -f whatsapp-bridge | head -1))"
else
  bad "not running" "launchctl load ~/Library/LaunchAgents/com.whatsappdigest.bridge.plist"
fi

head_ "Message database"
DB="$SUPPORT_DIR/store/messages.db"
if [[ -f "$DB" ]]; then
  SIZE=$(wc -c < "$DB" | tr -d ' ')
  if (( SIZE > 100000 )); then ok "messages.db present ($((SIZE/1024)) KB)"
  else warn "messages.db is only $((SIZE/1024)) KB" "History sync may still be running, or the bridge is not linked yet."; fi

  if PY=$(find_bin python3); then
    SUMMARY=$("$PY" "$REPO_DIR/pending_replies.py" --json 2>/dev/null | "$PY" -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print("%s|%s|%s" % (d["stale"], d["last_sync"] or "never", len(d["pending"])))
except Exception:
    print("ERR||")
' 2>/dev/null)
    IFS='|' read -r STALE LAST NPEND <<< "$SUMMARY"
    if [[ "$STALE" == "False" ]]; then ok "last message $LAST ago; $NPEND chats awaiting reply"
    elif [[ "$STALE" == "True" ]]; then bad "no messages for $LAST — bridge is disconnected" "Re-link: WhatsApp → Settings → Linked Devices"
    else bad "could not read the database" "Run: python3 pending_replies.py"; fi
  fi
else
  bad "no messages.db at $DB" "The bridge has never synced. Start it and scan the QR code."
fi

head_ "Telegram"
CFG="$SUPPORT_DIR/telegram.json"
if [[ -f "$CFG" ]]; then
  ok "config present"
  if PY=$(find_bin python3); then
    TOKEN=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("bot_token",""))' "$CFG" 2>/dev/null)
    CHAT=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("chat_id",""))' "$CFG" 2>/dev/null)
    if [[ "$TOKEN" != *:* ]]; then
      bad "bot_token has no colon — this is not a bot token" "A token looks like 8123456789:AAH... Get it from @BotFather → /mytoken. The chat id is a different value."
    elif C=$(find_bin curl); then
      if "$C" -sS --max-time 20 "https://api.telegram.org/bot${TOKEN}/getMe" 2>/dev/null | grep -q '"ok":true'; then
        ok "token valid"
        if [[ $SEND_TEST -eq 1 ]]; then
          if "$C" -sS --max-time 20 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
               --data-urlencode "chat_id=${CHAT}" --data-urlencode "text=Digest doctor: test message" 2>/dev/null | grep -q '"ok":true'; then
            ok "test message delivered"
          else
            bad "could not send to chat_id $CHAT" "Message your bot once from Telegram, then re-check the id via /getUpdates"
          fi
        fi
      else
        bad "token rejected by Telegram" "Verify with: curl https://api.telegram.org/bot<TOKEN>/getMe"
      fi
    fi
  fi
else
  bad "no telegram.json at $CFG" "Re-run scripts/install-macos.sh"
fi

head_ "Claude Code MCP registration"
if CL=$(find_bin claude); then
  if "$CL" mcp list 2>/dev/null | grep -q "whatsapp"; then ok "whatsapp MCP server registered"
  else warn "whatsapp not in 'claude mcp list'" "Only needed for asking Claude about your chats interactively; the daily digest does not require it."; fi
else
  warn "skipped (claude not found)"
fi

head_ "Scheduling"
if [[ "$OSTYPE" == "darwin"* ]]; then
  for label in bridge daily; do
    PLIST="$HOME/Library/LaunchAgents/com.whatsappdigest.$label.plist"
    if [[ -f "$PLIST" ]]; then
      if launchctl list 2>/dev/null | grep -q "com.whatsappdigest.$label"; then ok "com.whatsappdigest.$label loaded"
      else bad "com.whatsappdigest.$label not loaded" "launchctl load '$PLIST'"; fi
    else
      bad "missing $PLIST" "Re-run scripts/install-macos.sh"
    fi
  done
fi

head_ "Recent digest runs"
if [[ -f "$SUPPORT_DIR/digest.log" ]]; then
  tail -5 "$SUPPORT_DIR/digest.log" | sed 's/^/  /'
else
  warn "no digest.log yet" "The digest has never run. Test it: bash scripts/run_digest.sh"
fi

printf '\n\033[1mResult:\033[0m %d passed, %d warnings, %d failures\n' "$PASS" "$WARN" "$FAIL"

if [[ $FAIL -gt 0 && $LAUNCHD_MODE -eq 0 ]]; then
  printf '\nIf the digest works when you run it by hand but not at 9am, run:\n'
  printf '  bash scripts/doctor.sh --launchd\n'
  printf 'That reproduces the restricted PATH the scheduler uses.\n'
fi

exit $(( FAIL > 0 ? 1 : 0 ))
