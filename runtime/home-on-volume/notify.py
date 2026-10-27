#!/usr/bin/env python3
"""Send one message, read from stdin, to the admin on Telegram.

Used by migrate.sh, which stops every pod including the one whose session asked for
the migration -- so the only way the result reaches a person is for the host itself
to send it. Goes through smart-reminders' admin channel, the same path disk-alert
uses. No model call: it is a plain Bot API post.
"""
import sys

sys.path.insert(0, "/opt/smart-reminders")
import smart_reminders as sr  # noqa: E402

msg = sys.stdin.read().strip()
if not msg:
    sys.exit(0)
sys.exit(0 if sr.tg_admin(msg, sr.conf()) else 1)
