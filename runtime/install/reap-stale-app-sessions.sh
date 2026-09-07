#!/usr/bin/env python3
"""reap-stale-app-sessions — end ABANDONED Claude App sessions in tenant pods.

    reap-stale-app-sessions [--idle-hours 48] [--dry-run] [--json]

WHY. Every session the Claude App opens in a pod is a `claude.exe --print` process under
that tenant's remote-control listener, and nothing ever ends it. On 2026-09-07 the firm
host had 85 of them holding ~15 GB on a 32 GB box with no swap: load 547 on 8 cores,
sshd refusing logins, the OOM killer taking tenants' bots at random.

WHAT COUNTS AS ABANDONED. Not age. A lawyer's session can be a day old and still be the
thing they are working in — Vitaliy's objection to the first version of this script, and
he was right. A session is abandoned only if BOTH of these hold:

  * its conversation is not live: either no transcript exists for it at all (nobody ever
    typed in it — this is what a pod restart leaves behind), or the transcript has not
    been written to for --idle-hours (default 48);
  * it is not doing anything right now: no CPU time accrued across a sampling interval,
    and no child processes (a session running a tool has both).

And even then it must look abandoned TWICE, on two consecutive runs, before it is ended.

WHAT IS NEVER TOUCHED. The boot session (`--channels …`) — that IS the Telegram bot — and
the remote-control listener itself, which must stay up for the App to reconnect. Ending
an idle App session loses no conversation: it lives server-side and the App resumes it.

MAPPING A SESSION TO ITS TRANSCRIPT — the part that has to be right, because getting it
wrong means deleting someone's live work:
  * the transcript is NOT named after the session id (files are named by a UUID), so
    matching on the filename finds nothing even for a session in active use;
  * the process does NOT hold the transcript open, so /proc/<pid>/fd is empty of it
    (Claude Code appends and closes) — verified on 35 live sessions;
  * the session id from argv DOES appear inside the transcript body. That is the link
    used here. If the id is found nowhere, the session genuinely has no conversation.

Not an LLM call: it reads /proc and files and signals processes. Safe on a timer.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

STATE = "/var/lib/fleet/reap-app-sessions.json"
READ_CAP = 4 * 1024 * 1024  # per transcript; ids appear early, this is belt and braces


def ps_snapshot():
    out = subprocess.run(["ps", "-eo", "pid=,etimes=,times=,user=,args="],
                         capture_output=True, text=True, timeout=120).stdout
    rows = {}
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        pid, etimes, times, user, args = parts
        if "claude.exe" not in args or "--print" not in args:
            continue
        m = re.search(r"--session-id\s+(\S+)", args)
        rows[pid] = {
            "pid": pid, "user": user, "age_h": int(etimes) / 3600,
            "cpu": int(times), "session": m.group(1) if m else None,
        }
    return rows


def transcript_for(user, session_id):
    """(path, hours_since_write) for the transcript carrying this session id, else None."""
    if not session_id:
        return None
    base = f"/home/{user}/.claude/projects"
    if not os.path.isdir(base):
        return None
    cands = []
    for root, _dirs, files in os.walk(base):
        for f in files:
            if f.endswith(".jsonl"):
                p = os.path.join(root, f)
                try:
                    cands.append((os.path.getmtime(p), p))
                except OSError:
                    pass
    # newest first: a session in use is almost always in a recently written file
    for mtime, p in sorted(cands, reverse=True):
        try:
            with open(p, "r", errors="replace") as fh:
                if session_id in fh.read(READ_CAP):
                    return p, (time.time() - mtime) / 3600
        except OSError:
            continue
    return None


def has_children(pid):
    try:
        r = subprocess.run(["pgrep", "-P", pid], capture_output=True, text=True, timeout=20)
        return bool(r.stdout.strip())
    except Exception:
        return True  # unknown → treat as busy, never as abandoned


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--idle-hours", type=float, default=48.0)
    ap.add_argument("--sample-seconds", type=int, default=90)
    ap.add_argument("--busy-cpu-pct", type=float, default=5.0,
                    help="CPU%% of one core across the sample above which a session counts "
                         "as working. Idle ones measured ~1%%.")
    ap.add_argument("--self-test", metavar="USER:SESSION_ID",
                    help="prove the session-to-transcript matcher can find a known id")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    if os.geteuid() != 0:
        sys.exit("run as root")

    if args.self_test:
        user, sid = args.self_test.split(":", 1)
        hit = transcript_for(user, sid)
        if hit:
            print(f"matcher OK: {sid} found in {os.path.basename(hit[0])}, "
                  f"last written {hit[1]:.1f}h ago")
            return
        sys.exit(f"matcher FAILED: {sid} not found in any of {user}'s transcripts — "
                 "do not trust a 'no conversation ever' verdict until this passes")

    first = ps_snapshot()
    print(f"App sessions: {len(first)}")
    if not first:
        return

    verdicts = {}
    for pid, s in first.items():
        tr = transcript_for(s["user"], s["session"])
        if tr is None:
            s["why"] = "no conversation ever"
            s["conv_idle_h"] = None
            s["conv_stale"] = True
        else:
            path, idle_h = tr
            s["transcript"] = os.path.basename(path)
            s["conv_idle_h"] = idle_h
            s["conv_stale"] = idle_h >= args.idle_hours
            s["why"] = (f"last message {idle_h:.1f}h ago"
                        if s["conv_stale"] else f"active {idle_h:.1f}h ago — SPARED")
        verdicts[pid] = s

    # only the conversation-stale ones are worth the busy checks
    stale = {p: s for p, s in verdicts.items() if s["conv_stale"]}
    print(f"  conversation not live: {len(stale)} | live, spared: {len(verdicts) - len(stale)}")

    if stale:
        time.sleep(args.sample_seconds)
        second = ps_snapshot()
        for pid, s in list(stale.items()):
            if pid not in second:
                del stale[pid]  # exited on its own
                continue
            delta = second[pid]["cpu"] - s["cpu"]
            # An IDLE session still ticks: measured 1s per 90s (~1% of a core) on all 33
            # abandoned sessions in the first dry run. Treating any movement as "busy"
            # therefore spared everything and reclaimed nothing. Real work sits far above
            # this, so the line goes between them rather than at zero.
            if delta >= args.busy_cpu_pct / 100.0 * args.sample_seconds:
                s["why"] += f"; but burned {delta}s CPU in {args.sample_seconds}s — SPARED"
                del stale[pid]
                continue
            s["cpu_delta"] = delta
            if has_children(pid):
                s["why"] += "; but running a tool — SPARED"
                del stale[pid]

    # two strikes: it must have looked abandoned on the previous run too
    prev = {}
    try:
        prev = json.load(open(STATE)).get("candidates", {})
    except Exception:
        pass
    confirmed, firsttime = {}, {}
    for pid, s in stale.items():
        key = s["session"] or pid
        if key in prev:
            confirmed[pid] = s
        else:
            firsttime[pid] = s

    for pid, s in sorted(verdicts.items(), key=lambda kv: kv[1]["user"]):
        mark = "END" if pid in confirmed else ("watch" if pid in firsttime else "keep")
        print("  %-5s %-8s %-20s age=%5.1fh %s" % (mark, pid, s["user"][:20], s["age_h"], s["why"]))

    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "w") as fh:
        json.dump({"at": time.time(),
                   "candidates": {(s["session"] or p): s["user"] for p, s in stale.items()}}, fh)

    print(f"  to end now: {len(confirmed)} | first sighting, will end next run: {len(firsttime)}")
    if args.dry_run:
        print("dry run — nothing ended")
        return
    ended = 0
    for pid in confirmed:
        try:
            os.kill(int(pid), 15)
        except OSError:
            pass
    if confirmed:
        time.sleep(20)
        for pid in confirmed:
            if os.path.isdir(f"/proc/{pid}"):
                try:
                    os.kill(int(pid), 9)
                except OSError:
                    pass
        time.sleep(3)
        ended = sum(0 if os.path.isdir(f"/proc/{p}") else 1 for p in confirmed)
    print(f"ended {ended} of {len(confirmed)}")


if __name__ == "__main__":
    main()
