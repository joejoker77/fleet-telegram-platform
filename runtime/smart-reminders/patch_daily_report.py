#!/usr/bin/python3
"""Add a 'Smart reminders' section to the daily Claude activity report (run as root).
Idempotent. Patches /usr/local/bin/claude_daily_report.py and, if present, the repo copy."""
import sys

TARGETS = ["/usr/local/bin/claude_daily_report.py",
           "/opt/ftp-src/fleet-telegram-platform/runtime/install/claude-daily-report.py"]

HELPER = '''

def smart_reminders_section():
    """Who is using smart reminders (creations in the last 7 days / all time, active,
    fired). Read from the service's own stats command; no model involved."""
    import subprocess
    try:
        out = subprocess.run(["/usr/bin/python3", "/opt/smart-reminders/smart_reminders.py", "--stats"],
                             capture_output=True, text=True, timeout=60)
        st = json.loads(out.stdout)
    except Exception as exc:
        return "<b>Smart reminders: stats unavailable (%s).</b>" % str(exc)[:80]
    per = st.get("per_tenant", {})
    tot = st.get("totals", {})
    lines = ["<b>Smart reminders</b>  —  created: %d in 7 days, %d all time; %d active; fired %d"
             % (tot.get("created_7d", 0), tot.get("created_all", 0), tot.get("active", 0), tot.get("fired_all", 0))]
    if not per:
        lines.append("Nobody has created one yet.")
        return "\\n".join(lines)
    lines.append("<pre>%-19s %6s %7s %6s" % ("bot", "7 days", "all", "active"))
    for name, v in sorted(per.items(), key=lambda kv: (-kv[1]["created_7d"], -kv[1]["created_all"], kv[0])):
        lines.append("%-19s %6d %7d %6d" % (name[:19], v["created_7d"], v["created_all"], v["active"]))
    lines.append("</pre>")
    return "\\n".join(lines)
'''

ANCHOR = '    text = "\\n\\n".join(parts)\n'
INSERT = '    parts.append(smart_reminders_section())\n'


def patch(path):
    try:
        s = open(path).read()
    except OSError:
        return "missing"
    if "smart_reminders_section" in s:
        return "already"
    if ANCHOR not in s or "\ndef main():" not in s:
        return "anchor-not-found"
    s = s.replace("\ndef main():", HELPER + "\n\ndef main():", 1)
    s = s.replace(ANCHOR, INSERT + ANCHOR, 1)
    open(path, "w").write(s)
    return "patched"


for t in TARGETS:
    print(t, patch(t))
