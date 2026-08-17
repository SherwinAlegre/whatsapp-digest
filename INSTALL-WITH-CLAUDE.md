# Install with Claude Code

**If you are a person:** don't read this. Open Claude Code and paste the prompt in
[the README](README.md#install-macos) — Claude will follow these instructions for you.

**If you are Claude:** you are installing this on a macOS machine for someone who is
not technical and should never need to open a terminal. Everything below is for you.

---

## Ground rules

- **Do the work yourself.** Run the commands. Do not paste command lists at the user
  and ask them to run them — that is the exact experience this file exists to avoid.
- **Two things you cannot do for them**, because they require a phone and a human:
  creating the Telegram bot, and scanning the QR code. Everything else is yours.
- **Explain in plain language.** No jargon. They do not know what a daemon, a PATH,
  or a launch agent is, and do not need to.
- **Stop and explain if something fails.** Do not improvise around a failure
  silently — say what broke, in their terms, and what you need from them.

---

## Step 1 — Check they have what they need

```bash
command -v claude && claude --version
sw_vers -productVersion
python3 --version
```

If `python3` is missing, install it: `brew install python`. If Homebrew is missing
too, get it from https://brew.sh — tell the user this takes a few minutes and needs
their password (it is a normal macOS install prompt, not something you did).

They must be signed in to Claude Code already — they are, since they are talking to
you.

## Step 2 — Download

Put it somewhere they can find it in Finder, not a hidden folder:

```bash
cd ~/Applications 2>/dev/null || cd ~
git clone https://github.com/SherwinAlegre/whatsapp-digest.git
cd whatsapp-digest
```

If `~/Applications` does not exist, use `~` and tell them where it went.

## Step 3 — Run the installer, skipping Telegram

`SKIP_TELEGRAM=1` matters: the installer would otherwise wait for a token that does
not exist yet, and hang.

```bash
SKIP_TELEGRAM=1 bash scripts/install-macos.sh
```

This installs dependencies, registers the WhatsApp tools with their Claude Code,
and sets up the background connection plus the 9am schedule.

## Step 4 — Walk them through Telegram

This is a conversation, not a command. Ask them to do this on their phone, one step
at a time, and wait for each:

1. Open Telegram, search for **@BotFather**, tap **Start**.
2. Send `/newbot`.
3. It asks for a name — anything, e.g. "My WhatsApp Digest".
4. It asks for a username — must end in `bot`, e.g. `sherwin_digest_bot`. If taken,
   try another.
5. It replies with a token. **Ask them to paste it to you.** Tell them it looks like
   a long line with a colon in the middle.
6. Ask them to **send any message to their new bot** — say "hi". This is required;
   a bot cannot start a conversation.

Then find their chat id yourself:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates"
```

Read the `"id"` inside `"chat"`. If the result is empty, they have not messaged the
bot yet — ask again, then retry.

Write the config:

```bash
mkdir -p "$HOME/Library/Application Support/whatsapp-bridge"
cat > "$HOME/Library/Application Support/whatsapp-bridge/telegram.json" <<EOF
{ "bot_token": "<TOKEN>", "chat_id": "<CHAT_ID>" }
EOF
chmod 600 "$HOME/Library/Application Support/whatsapp-bridge/telegram.json"
```

Verify before moving on:

```bash
curl -s -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  --data-urlencode "chat_id=<CHAT_ID>" --data-urlencode "text=Setup working"
```

Tell them to check Telegram. If the message is not there, fix it now — do not
continue and hope.

> If they paste something with no colon, it is the chat id, not the token. Ask for
> the token again, from @BotFather → `/mytoken`.

## Step 5 — Have them link WhatsApp

You cannot do this: the QR code must be looked at with a phone camera.

Open the window for them:

```bash
open "Link WhatsApp.command"
```

Then tell them, in these words or close to them:

> A black window just opened with a QR code in it. On your phone, open WhatsApp →
> Settings → Linked Devices → Link a Device, and point your camera at that window.
> The code changes every 20 seconds — if you miss it, just wait for the next one.

The window tells them when it has worked and when to close it. Wait for them to
confirm before continuing.

## Step 6 — Check everything, then prove it works

```bash
bash scripts/doctor.sh
```

Fix anything it flags — it prints the remedy for each failure.

Message history takes a few minutes to arrive. Once `doctor.sh` reports a recent
sync, test the real scheduled path:

```bash
launchctl kickstart -k gui/$(id -u)/com.whatsappdigest.daily
```

Not `bash scripts/run_digest.sh` — that tests your environment, not the scheduler's,
and the difference is the most common cause of a digest that works today and
silently stops tomorrow.

Confirm with them that a Telegram message arrived.

## Step 7 — Tell them what happens now

Cover these, plainly:

- A message arrives every morning at **9am**, listing who is waiting on a reply.
- **Every few weeks WhatsApp will disconnect it.** They will get a red Telegram
  message saying so. To fix it they double-click **Link WhatsApp.command** in the
  `whatsapp-digest` folder and scan again. Show them the folder in Finder now, so
  they can find it later: `open .`
- If the report is ever empty, that is genuine — a broken connection sends a warning
  instead, never silence.
- The first few reports are thin. It improves as message history builds up.

---

## If something goes wrong

`bash scripts/doctor.sh` first, then `bash scripts/doctor.sh --launchd` if the
digest works when run by hand but not on schedule. Both name the fix.
