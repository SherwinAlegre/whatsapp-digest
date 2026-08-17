#!/usr/bin/env bash
# Double-click this file in Finder to link WhatsApp.
#
# macOS opens .command files in Terminal, which is the only place the QR code
# renders correctly -- it is drawn with block characters and needs a monospace
# font at a sensible size.

cd "$(dirname "$0")" || exit 1
source "scripts/lib.sh" 2>/dev/null || { echo "Run this from inside the whatsapp-digest folder."; read -r; exit 1; }

# A roomy window; a cramped one mangles the QR code.
printf '\e[8;45;110t'
clear

cat <<'EOS'
  Linking WhatsApp
  ================

  A QR code will appear below in a few seconds.

  On your phone:
      WhatsApp  ->  Settings  ->  Linked Devices  ->  Link a Device

  Then point your phone at this window.

  The code refreshes every 20 seconds. If you miss one, just wait for
  the next -- do not close this window.

  Once it says "Successfully authenticated", you are done and can close
  this window. Your messages will sync for a few minutes afterwards.

EOS

if pgrep -f "whatsapp-bridge" >/dev/null 2>&1; then
  cat <<'EOS'
  Note: WhatsApp is already linked and running.

  If you are re-linking because it stopped working, quit it first:
EOS
  printf '      launchctl unload ~/Library/LaunchAgents/com.whatsappdigest.bridge.plist\n\n'
  printf '  Showing the live log instead. Press Ctrl-C to close.\n\n'
  sleep 3
  tail -f "$SUPPORT_DIR/bridge.log"
  exit 0
fi

sleep 2
tail -f "$SUPPORT_DIR/bridge.log" 2>/dev/null &
TAIL_PID=$!
trap 'kill $TAIL_PID 2>/dev/null' EXIT

# Wait for authentication, then stop tailing and tell them plainly.
for _ in $(seq 1 300); do
  if grep -q "Successfully authenticated" "$SUPPORT_DIR/bridge.log" 2>/dev/null; then
    sleep 2
    kill $TAIL_PID 2>/dev/null
    printf '\n\n  ✅  Linked. You can close this window.\n\n'
    printf '  Your messages are syncing now. This takes a few minutes.\n\n'
    read -r -p "  Press Return to close." _
    exit 0
  fi
  sleep 2
done

printf '\n  Still not linked after 10 minutes. Close this window and ask for help.\n'
read -r -p "  Press Return to close." _
