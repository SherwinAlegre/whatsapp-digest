"""Find WhatsApp chats where the last word was theirs, not yours.

There is no unread flag in the bridge's database and none is exposed by WhatsApp
to linked devices. That costs us nothing: every message you have not read is also
one you have not answered, so "unanswered" is the strict superset of "unread" --
and it additionally catches the ones you read on your phone and forgot.

Default output is human-readable. --json emits the candidate list for the
judgment step, which decides which of these actually want a reply (a message
reading "thanks!" is structurally pending but socially finished).
"""

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime

WINDOW_DAYS = 14  # only chats touched in the last two weeks
MIN_AGE_MINUTES = 30  # let a conversation breathe before calling it pending
STALE_HOURS = 24  # bridge silent this long => report is untrustworthy
SNIPPET = 200
CONTEXT_MESSAGES = 6  # trailing messages handed to the judgment step


def store_dir():
    """Where the bridge keeps its databases.

    Must agree with Go's os.UserConfigDir(), which the bridge uses, or the two
    halves will silently look at different files.
    """
    override = os.environ.get("WHATSAPP_STORE_DIR")
    if override:
        return override

    if sys.platform == "win32":
        base = os.environ["APPDATA"]
    elif sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")

    return os.path.join(base, "whatsapp-bridge", "store")


def parse_ts(raw):
    """Bridge stores Go time strings like '2026-08-12 15:12:54 +0800 +08'."""
    return datetime.strptime(raw[:19], "%Y-%m-%d %H:%M:%S")


def build_name_resolver(store):
    """Map a chat JID to something a human recognises.

    The bridge writes chats.name from whatsmeow's contact FullName alone, which is
    set for only 17 of 131 contacts here -- everyone else lands as a bare number.
    The session database holds far more: push_name (the name people set for
    themselves) is populated for 130 of 131, and whatsmeow_lid_map translates the
    opaque @lid identifiers WhatsApp now uses back into phone numbers.
    """
    path = os.path.join(store, "whatsapp.db")
    if not os.path.exists(path):
        return lambda jid, existing: existing

    ses = sqlite3.connect(path, timeout=10)

    contacts = {}
    try:
        for jid, full, first, push, biz in ses.execute(
            "SELECT their_jid, full_name, first_name, push_name, business_name "
            "FROM whatsmeow_contacts"
        ):
            # Address-book name first, then how the business or person styles itself.
            name = full or biz or first or push
            if name:
                contacts[jid.split("@")[0]] = name
    except sqlite3.Error:
        pass

    lidmap = {}
    try:
        for lid, pn in ses.execute("SELECT lid, pn FROM whatsmeow_lid_map"):
            lidmap[lid.split("@")[0]] = pn.split("@")[0]
    except sqlite3.Error:
        pass

    ses.close()

    def resolve(jid, existing):
        user = jid.split("@")[0]
        # A name the bridge already worked out (group titles arrive this way) wins,
        # but only when it is not just the number echoed back.
        if existing and existing != user:
            return existing
        if user in contacts:
            return contacts[user]
        if jid.endswith("@lid") and user in lidmap:
            pn = lidmap[user]
            # Still better than a 15-digit LID: a real number you can recognise.
            return contacts.get(pn, f"+{pn}")
        return f"+{user}" if user.isdigit() else user

    return resolve


def describe(content, media_type):
    if content:
        return " ".join(content.split())[:SNIPPET]
    return f"[{media_type}]" if media_type else "[no text]"


def humanize(delta):
    mins = int(delta.total_seconds() // 60)
    if mins < 60:
        return f"{mins}m"
    if mins < 2880:
        return f"{mins // 60}h"
    return f"{mins // 1440}d"


def collect(con, now, resolve_name):
    pending = []
    for jid, name in con.execute("SELECT jid, name FROM chats"):
        last = con.execute(
            "SELECT content, is_from_me, timestamp, media_type FROM messages "
            "WHERE chat_jid = ? ORDER BY timestamp DESC LIMIT 1",
            (jid,),
        ).fetchone()
        if not last:
            continue

        content, is_from_me, ts_raw, media_type = last
        if is_from_me:
            continue  # you had the last word

        age = now - parse_ts(ts_raw)
        if age.total_seconds() < MIN_AGE_MINUTES * 60 or age.days >= WINDOW_DAYS:
            continue

        mine = con.execute(
            "SELECT MAX(timestamp) FROM messages WHERE chat_jid = ? AND is_from_me = 1",
            (jid,),
        ).fetchone()[0]
        if mine:
            waiting = con.execute(
                "SELECT COUNT(*) FROM messages WHERE chat_jid = ? AND is_from_me = 0 "
                "AND timestamp > ?",
                (jid, mine),
            ).fetchone()[0]
        else:
            waiting = con.execute(
                "SELECT COUNT(*) FROM messages WHERE chat_jid = ? AND is_from_me = 0",
                (jid,),
            ).fetchone()[0]

        # Trailing exchange, oldest first, so the judge can read the thread.
        tail = [
            {"from": "you" if m[1] else "them", "text": describe(m[0], m[3])}
            for m in reversed(
                con.execute(
                    "SELECT content, is_from_me, timestamp, media_type FROM messages "
                    "WHERE chat_jid = ? ORDER BY timestamp DESC LIMIT ?",
                    (jid, CONTEXT_MESSAGES),
                ).fetchall()
            )
        ]

        pending.append(
            {
                "name": resolve_name(jid, name),
                "is_group": jid.endswith("@g.us"),
                "age": humanize(age),
                "age_minutes": int(age.total_seconds() // 60),
                "waiting": waiting,
                "never_replied": mine is None,
                "last_message": describe(content, media_type),
                "context": tail,
            }
        )

    pending.sort(key=lambda r: r["age_minutes"])
    return pending


def main():
    # WhatsApp messages are full of emoji. Schedulers (Task Scheduler, launchd)
    # give Python a non-UTF-8 stdout, where printing one raises UnicodeEncodeError
    # and kills the run -- so force UTF-8 before writing anything.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, OSError):
            pass

    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    store = store_dir()
    db = os.path.join(store, "messages.db")
    if not os.path.exists(db):
        payload = {"error": f"database not found at {db}", "stale": True, "pending": []}
        print(json.dumps(payload) if args.json else payload["error"])
        return 2

    con = sqlite3.connect(db, timeout=10)
    now = datetime.now()

    newest = con.execute("SELECT MAX(timestamp) FROM messages").fetchone()[0]
    lag = now - parse_ts(newest) if newest else None
    stale = lag is None or lag.total_seconds() > STALE_HOURS * 3600

    pending = collect(con, now, build_name_resolver(store)) if newest else []

    if args.json:
        print(
            json.dumps(
                {
                    "generated": now.isoformat(timespec="seconds"),
                    "stale": stale,
                    "last_sync": humanize(lag) if lag else None,
                    "window_days": WINDOW_DAYS,
                    "pending": pending,
                },
                ensure_ascii=False,
                indent=1,
            )
        )
        return 0

    print(f"WhatsApp — awaiting your reply     {now:%a %d %b %Y, %H:%M}")
    if stale:
        print(f"!! STALE: no messages for {humanize(lag) if lag else 'ever'} — bridge is likely down.")
    print("=" * 60)
    for r in pending:
        tag = " [never replied]" if r["never_replied"] else ""
        pile = f" ({r['waiting']} waiting)" if r["waiting"] > 1 else ""
        kind = "group" if r["is_group"] else "direct"
        print(f"\n  {r['name']} [{kind}] — {r['age']} ago{pile}{tag}")
        print(f'    "{r["last_message"]}"')
    print(f"\n{len(pending)} chats pending in the last {WINDOW_DAYS} days.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
