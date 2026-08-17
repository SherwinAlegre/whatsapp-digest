#!/usr/bin/env bash
# Installer for macOS. Sets up the bridge, registers the MCP server with Claude
# Code, and schedules the 9am digest. Needs no sudo -- everything lives under
# your home directory.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/whatsapp-bridge"
AGENTS_DIR="$HOME/Library/LaunchAgents"
BRIDGE_BIN="$REPO_DIR/bin/whatsapp-bridge-$(uname -m | sed 's/x86_64/amd64/')"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

bold "1. Checking prerequisites"

command -v claude >/dev/null 2>&1 || die "Claude Code not found. Install the desktop app and sign in first: https://claude.com/claude-code"
ok "claude found: $(command -v claude)"

command -v python3 >/dev/null 2>&1 || die "python3 not found. Install it: brew install python"
ok "python3 found: $(python3 --version)"

if ! command -v uv >/dev/null 2>&1; then
  warn "uv not found - installing"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
ok "uv found: $(command -v uv)"

[[ -x "$BRIDGE_BIN" ]] || die "No bridge binary for your architecture at $BRIDGE_BIN
Build one with:  cd whatsapp-bridge && CGO_ENABLED=0 go build -o ../bin/whatsapp-bridge-\$(uname -m) ."
ok "bridge binary: $(basename "$BRIDGE_BIN")"

# macOS quarantines binaries downloaded from the internet. Unsigned ones are
# refused outright until the attribute is cleared.
if xattr -p com.apple.quarantine "$BRIDGE_BIN" >/dev/null 2>&1; then
  xattr -d com.apple.quarantine "$BRIDGE_BIN" 2>/dev/null || true
  ok "cleared macOS quarantine flag"
fi
chmod +x "$BRIDGE_BIN"

mkdir -p "$SUPPORT_DIR" "$AGENTS_DIR"

bold "2. Installing the Python MCP server dependencies"
(cd "$REPO_DIR/whatsapp-mcp-server" && uv sync --quiet)
ok "dependencies installed"

bold "3. Registering the MCP server with Claude Code"
claude mcp remove whatsapp -s user >/dev/null 2>&1 || true
claude mcp add whatsapp -s user -- "$(command -v uv)" --directory "$REPO_DIR/whatsapp-mcp-server" run main.py
ok "registered (restart Claude Code to load the tools)"

bold "4. Telegram configuration"
if [[ -f "$SUPPORT_DIR/telegram.json" ]]; then
  ok "config already exists - leaving it alone"
else
  echo "  Create a bot: Telegram -> @BotFather -> /newbot"
  echo "  Then message your new bot once, and open:"
  echo "    https://api.telegram.org/bot<TOKEN>/getUpdates"
  echo "  to find your chat id (the \"id\" under \"chat\")."
  echo
  read -rp "  Bot token (looks like 8123456789:AAH...): " TOKEN
  read -rp "  Chat id (a number): " CHAT_ID
  python3 - "$SUPPORT_DIR/telegram.json" "$TOKEN" "$CHAT_ID" <<'PY'
import json, sys
path, token, chat = sys.argv[1:4]
json.dump({"bot_token": token, "chat_id": chat}, open(path, "w"), indent=1)
PY
  chmod 600 "$SUPPORT_DIR/telegram.json"
  # Verify now rather than discovering it is wrong at 9am tomorrow.
  if curl -sS "https://api.telegram.org/bot${TOKEN}/getMe" | grep -q '"ok":true'; then
    ok "token verified"
  else
    warn "token did not verify - check it and re-run, or edit $SUPPORT_DIR/telegram.json"
  fi
fi

bold "5. Scheduling"

cat > "$AGENTS_DIR/com.whatsappdigest.bridge.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.whatsappdigest.bridge</string>
  <key>ProgramArguments</key><array><string>$BRIDGE_BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$SUPPORT_DIR/bridge.log</string>
  <key>StandardErrorPath</key><string>$SUPPORT_DIR/bridge.err</string>
</dict>
</plist>
PLIST
ok "bridge agent written (starts at login, restarts if it dies)"

cat > "$AGENTS_DIR/com.whatsappdigest.daily.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.whatsappdigest.daily</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$REPO_DIR/scripts/run_digest.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$SUPPORT_DIR/digest.out</string>
  <key>StandardErrorPath</key><string>$SUPPORT_DIR/digest.err</string>
</dict>
</plist>
PLIST
ok "daily agent written (09:00; launchd runs it on wake if you were asleep)"

chmod +x "$REPO_DIR/scripts/run_digest.sh"

for label in bridge daily; do
  launchctl unload "$AGENTS_DIR/com.whatsappdigest.$label.plist" 2>/dev/null || true
  launchctl load "$AGENTS_DIR/com.whatsappdigest.$label.plist"
done
ok "agents loaded"

bold "Done. One step left:"
cat <<EOF

  The bridge is now running and waiting for you to link it.
  Watch the log and scan the QR code with your phone:

      tail -f "$SUPPORT_DIR/bridge.log"

  On your phone: WhatsApp -> Settings -> Linked Devices -> Link a Device

  History sync takes a few minutes. Then test the whole pipeline:

      bash "$REPO_DIR/scripts/run_digest.sh"

  You should get a Telegram message within a few seconds.

EOF
