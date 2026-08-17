#!/usr/bin/env bash
# Installer for macOS. Sets up the bridge, registers the MCP server with Claude
# Code, and schedules the 9am digest. Needs no sudo -- everything lives under
# your home directory.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$REPO_DIR/scripts/lib.sh"

AGENTS_DIR="$HOME/Library/LaunchAgents"
BRIDGE_BIN=$(bridge_binary "$REPO_DIR")

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

bold "1. Checking prerequisites"

CLAUDE=$(find_bin claude) || die "Claude Code not found. Install the desktop app and sign in first: https://claude.com/claude-code"
ok "claude: $CLAUDE"

PYTHON=$(find_bin python3) || die "python3 not found. Install it: brew install python"
ok "python3: $PYTHON ($("$PYTHON" --version 2>&1))"

if ! UV=$(find_bin uv); then
  warn "uv not found - installing"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  UV=$(find_bin uv) || die "uv install failed. Install manually, then re-run."
fi
ok "uv: $UV"

[[ -f "$BRIDGE_BIN" ]] || die "No bridge binary for $(uname -m) at $BRIDGE_BIN
Available: $(ls "$REPO_DIR/bin" 2>/dev/null | tr '\n' ' ')
Or build one: cd whatsapp-bridge && CGO_ENABLED=0 go build -o '$BRIDGE_BIN' ."
ok "bridge binary: $(basename "$BRIDGE_BIN")"

# macOS quarantines anything downloaded from the internet. Unsigned binaries are
# refused outright until the attribute is cleared.
if xattr -p com.apple.quarantine "$BRIDGE_BIN" >/dev/null 2>&1; then
  xattr -d com.apple.quarantine "$BRIDGE_BIN" 2>/dev/null || true
  ok "cleared macOS quarantine flag"
fi
chmod +x "$BRIDGE_BIN" "$REPO_DIR/scripts/"*.sh

mkdir -p "$SUPPORT_DIR" "$AGENTS_DIR"

bold "2. Installing Python dependencies"
(cd "$REPO_DIR/whatsapp-mcp-server" && "$UV" sync --quiet)
ok "installed"

bold "3. Registering the MCP server with Claude Code"
"$CLAUDE" mcp remove whatsapp -s user >/dev/null 2>&1 || true
"$CLAUDE" mcp add whatsapp -s user -- "$UV" --directory "$REPO_DIR/whatsapp-mcp-server" run main.py
ok "registered (restart Claude Code to load the tools)"

bold "4. Telegram configuration"
if [[ -f "$SUPPORT_DIR/telegram.json" ]]; then
  ok "config already exists - leaving it alone"
elif [[ -n "${SKIP_TELEGRAM:-}" ]]; then
  warn "skipped (SKIP_TELEGRAM set) - configure it later, then run scripts/doctor.sh"
else
  # Credentials may arrive three ways: environment (an assistant or script
  # driving this install), an interactive prompt, or not at all. Never block on
  # a prompt when nothing is attached to answer it -- that hangs the install
  # with no visible cause.
  TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  CHAT_ID="${TELEGRAM_CHAT_ID:-}"

  if [[ -z "$TOKEN" || -z "$CHAT_ID" ]]; then
    if [[ ! -t 0 ]]; then
      warn "no Telegram credentials and no terminal to ask on - skipping"
      warn "set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID and re-run, or run scripts/doctor.sh later"
      SKIP_TELEGRAM=1
    else
      cat <<'EOS'
  Create a bot: Telegram -> @BotFather -> /newbot
  Copy the token it gives you. It CONTAINS A COLON, like <digits>:<random text>
  Then message your new bot once (a bot cannot message you first), and open
    https://api.telegram.org/bot<TOKEN>/getUpdates
  to find your chat id (the "id" nested under "chat").

EOS
      [[ -z "$TOKEN" ]] && read -rp "  Bot token: " TOKEN
      [[ -z "$CHAT_ID" ]] && read -rp "  Chat id:   " CHAT_ID
    fi
  fi
fi

if [[ ! -f "$SUPPORT_DIR/telegram.json" && -z "${SKIP_TELEGRAM:-}" ]]; then
  if [[ "$TOKEN" != *:* ]]; then
    die "That is not a bot token - it has no colon. You have probably pasted the chat id. Get the token from @BotFather (/mytoken) and re-run."
  fi

  "$PYTHON" - "$SUPPORT_DIR/telegram.json" "$TOKEN" "$CHAT_ID" <<'PY'
import json, sys
path, token, chat = sys.argv[1:4]
json.dump({"bot_token": token, "chat_id": chat}, open(path, "w"), indent=1)
PY
  chmod 600 "$SUPPORT_DIR/telegram.json"

  # Verify now rather than discovering it is wrong at 9am tomorrow.
  if curl -sS --max-time 20 "https://api.telegram.org/bot${TOKEN}/getMe" | grep -q '"ok":true'; then
    ok "token verified"
  else
    warn "token rejected by Telegram - fix it in $SUPPORT_DIR/telegram.json, then run: bash scripts/doctor.sh"
  fi
fi

bold "5. Scheduling"

# Stop anything already running, or the new agent fights it for port 8080 and
# the database.
if pgrep -f "whatsapp-bridge" >/dev/null 2>&1; then
  launchctl unload "$AGENTS_DIR/com.whatsappdigest.bridge.plist" 2>/dev/null || true
  pkill -f "whatsapp-bridge" 2>/dev/null || true
  sleep 2
  ok "stopped an existing bridge process"
fi

# launchd hands jobs a minimal PATH. The scripts resolve binaries themselves
# (scripts/lib.sh), but setting PATH here too means anything they shell out to
# also works. Both belts, because the failure is silent and daily.
LAUNCH_PATH="$(dirname "$CLAUDE"):$(dirname "$PYTHON"):$(dirname "$UV"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cat > "$AGENTS_DIR/com.whatsappdigest.bridge.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.whatsappdigest.bridge</string>
  <key>ProgramArguments</key><array><string>$BRIDGE_BIN</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$LAUNCH_PATH</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$SUPPORT_DIR/bridge.log</string>
  <key>StandardErrorPath</key><string>$SUPPORT_DIR/bridge.err</string>
</dict>
</plist>
PLIST
ok "bridge agent (starts at login, restarts if it dies)"

cat > "$AGENTS_DIR/com.whatsappdigest.daily.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.whatsappdigest.daily</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$REPO_DIR/scripts/run_digest.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$LAUNCH_PATH</string></dict>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$SUPPORT_DIR/digest.out</string>
  <key>StandardErrorPath</key><string>$SUPPORT_DIR/digest.err</string>
</dict>
</plist>
PLIST
ok "daily agent (09:00; launchd runs it on wake if you were asleep)"

for label in bridge daily; do
  launchctl unload "$AGENTS_DIR/com.whatsappdigest.$label.plist" 2>/dev/null || true
  launchctl load "$AGENTS_DIR/com.whatsappdigest.$label.plist"
done
ok "agents loaded"

bold "6. Checking the install"
bash "$REPO_DIR/scripts/doctor.sh" || true

bold "One step left: link your phone"
cat <<EOF

  The bridge is running and waiting for you to scan its QR code:

      tail -f "$SUPPORT_DIR/bridge.log"

  On your phone: WhatsApp -> Settings -> Linked Devices -> Link a Device
  Use a full-size terminal window; a narrow one mangles the QR code.

  History sync takes a few minutes. Once it finishes, test the REAL scheduled
  path -- not just running the script by hand, which uses a different PATH:

      launchctl kickstart -k gui/\$(id -u)/com.whatsappdigest.daily

  A Telegram message should arrive within a minute. If it does, you are done.
  If it does not:

      bash "$REPO_DIR/scripts/doctor.sh" --launchd

EOF
