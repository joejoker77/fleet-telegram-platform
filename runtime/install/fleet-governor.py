#!/usr/bin/env python3
"""fleet-governor — pick each tenant's auto-compaction window from a ladder
(1M / 800k / 600k / 400k / 200k by default) so nobody runs out of their usage limit,
and move back up as soon as they are safely inside it.

INPUT. ~/.claude/fleet-usage.json, written by fleet-usage-tap.js inside every Claude Code
process of the tenant (Telegram session, Claude App sessions, subagents) from the
anthropic-ratelimit-unified-* headers of responses Claude Code already receives. We make
no request of our own to Anthropic.

OUTPUT. /var/lib/fleet/ctl/<user>/window, mounted read-only into the pod; the tap mirrors it
into CLAUDE_CODE_AUTO_COMPACT_WINDOW, which Claude Code re-reads before every request. So a
change reaches running sessions, App ones included, within seconds.

THE RULE, per window (5 h and 7 days), every poll:
  projected = utilization now + rate x time left until reset
  rate = the faster of (a) the recent rate, a least-squares slope over the last
  rate_window_s of samples, and (b) the average rate since the window began. (a) catches a
  burst like 2026-09-28 (36% -> 77% in 10 min), (b) keeps a steady heavy user honest.
  The step is chosen by `projected` against projected_thresholds; utilization >= hard_used
  forces the smallest step. The stricter of the two windows wins.
DOWN (smaller window) happens at once, as many steps as needed. UP happens one step at a
time and only after the looser target has held for relax_hold_s, computed with
relax_margin of slack, so a tenant on a boundary does not flap.
STALE DATA (no fresh snapshot for max_age_s) never tightens anything. The only change made
without fresh numbers is relaxing once every window that drove the current step has reset.

All numbers live in fleet-policy.json. NOT AN LLM CALL: reads files, does arithmetic.
"""
import argparse
import datetime as dt
import json
import os
import sys
import time

POLICY = os.environ.get("FLEET_POLICY", "/etc/claudeapp/fleet-policy.json")
STATE_DIR = "/var/lib/fleet/governor"
CTL_ROOT = "/var/lib/fleet/ctl"
HOME_ROOT = "/home"
WINDOWS = (("five_hour", 5 * 3600), ("seven_day", 7 * 86400))


def log(msg):
    print(f"[{dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')}] {msg}", flush=True)


def load_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def write_atomic(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def rollout(policy, section):
    r = (policy.get(section) or {}).get("rollout", [])
    if r == "all":
        try:
            return sorted(os.listdir("/etc/claude-role"))
        except FileNotFoundError:
            return []
    return list(r)


# ---------------------------------------------------------------- the arithmetic

def slope(samples):
    """Least-squares utilization per second over (ts, u) samples, or None."""
    n = len(samples)
    if n < 2:
        return None
    mt = sum(t for t, _ in samples) / n
    mu = sum(u for _, u in samples) / n
    var = sum((t - mt) ** 2 for t, _ in samples)
    if var <= 0:
        return None
    return sum((t - mt) * (u - mu) for t, u in samples) / var


def project(history, key, length, now, cfg):
    """(projected, utilization, reset, why) for one window, from fresh history only."""
    pts = [(s["ts"], s[key]["utilization"], s[key]["resets_at"]) for s in history if s.get(key)]
    if not pts:
        return None
    ts, u, reset = pts[-1]
    if reset <= now:
        return None                               # window has reset; its old numbers mean nothing
    same = [(t, uu) for t, uu, r in pts if r == reset and t >= now - cfg["rate_window_s"]]
    recent = None
    if same and same[-1][0] - same[0][0] >= cfg["min_rate_span_s"]:
        recent = slope(same)
    start = reset - length
    avg = u / max(now - start, 60)                # average pace since the window opened
    rate = max(x for x in (recent, avg) if x is not None)
    rate = max(rate, 0.0)
    left = reset - now
    p = u + rate * left
    why = (f"{key}: {u*100:.0f}% used, {left/3600:.1f}h to reset, "
           f"pace {'%.2f' % (recent*6000) if recent is not None else '-'}/{avg*6000:.2f} %/min "
           f"-> projected {p*100:.0f}%")
    return p, u, reset, why


def step_for(projected, used, cfg, margin=0.0):
    """Index into the ladder (0 = largest window) for one window's numbers."""
    if used >= cfg["hard_used"] - margin:
        return len(cfg["ladder"]) - 1
    i = 0
    for th in cfg["projected_thresholds"]:
        if projected >= th - margin:
            i += 1
    return min(i, len(cfg["ladder"]) - 1)


def decide(history, now, cfg, fresh):
    """(target_step, relax_step, drivers_reset_max, why). target = where the numbers say we
    must be now; relax = where we may go when relaxing (with margin)."""
    if not fresh:
        return None, None, None, "no fresh usage data"
    target = relax = 0
    resets, whys = [], []
    for key, length in WINDOWS:
        r = project(history, key, length, now, cfg)
        if r is None:
            whys.append(f"{key}: no current data")
            continue
        p, u, reset, why = r
        t = step_for(p, u, cfg)
        target = max(target, t)
        relax = max(relax, step_for(p, u, cfg, margin=cfg["relax_margin"]))
        if t > 0:
            resets.append(reset)
        whys.append(why + (f" => step {t}" if t else ""))
    return target, max(relax, target), (max(resets) if resets else None), "; ".join(whys)


# ---------------------------------------------------------------- per tenant

def run_one(user, cfg, now, dry):
    ladder = cfg["ladder"]
    st_path = os.path.join(STATE_DIR, f"{user}.json")
    st = load_json(st_path, {}) or {}
    step = int(st.get("step", 0))
    hist = [h for h in st.get("history", []) if h.get("ts", 0) >= now - max(cfg["rate_window_s"], 3600)]

    snap = load_json(f"{HOME_ROOT}/{user}/.claude/fleet-usage.json")
    if isinstance(snap, dict) and isinstance(snap.get("ts"), (int, float)):
        if not hist or snap["ts"] > hist[-1]["ts"]:
            hist.append({k: snap.get(k) for k in ("ts", "five_hour", "seven_day")})
    age = now - hist[-1]["ts"] if hist else None
    fresh = age is not None and -120 <= age <= cfg["max_age_s"]

    target, relax, drivers_reset, why = decide(hist, now, cfg, fresh)
    new = step
    if target is None:
        # Stale: never tighten. Relax one step once every window that drove us down has reset.
        if step > 0 and now >= st.get("drivers_reset", 0) and now - st.get("since", 0) >= cfg["relax_hold_s"]:
            new, why = step - 1, f"{why}; the windows that drove step {step} have reset"
    elif target > step:
        new = target                                           # down: at once, all the way
    elif relax < step:
        held = st.get("relax_since")
        if held is None:
            st["relax_since"] = now
        elif now - held >= cfg["relax_hold_s"]:
            new = step - 1                                     # up: one step, after the hold
    if target is not None and relax >= step:
        st.pop("relax_since", None)

    st.update(history=hist, updated=now, why=why, age=age)
    if target is not None and target > 0 and drivers_reset:
        st["drivers_reset"] = drivers_reset
    ctl = os.path.join(CTL_ROOT, user, "window")
    want = "auto" if new == 0 else str(ladder[new])
    if new != step:
        verb = "WOULD move" if dry else "moved"
        log(f"{user}: {verb} {ladder[step]//1000}k -> {ladder[new]//1000}k ({why})")
        if not dry:
            st.update(step=new, since=now)
            st.pop("relax_since", None)
    else:
        log(f"{user}: stays {ladder[step]//1000}k ({why})")
    if not dry:
        cur = (open(ctl).read().strip() if os.path.exists(ctl) else None)
        target_text = "auto" if st.get("step", step) == 0 else str(ladder[st.get("step", step)])
        if cur != target_text:
            write_atomic(ctl, target_text + "\n")
        write_atomic(st_path, json.dumps(st), 0o600)
    return want


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--once", action="store_true", help="one pass, then exit (default: loop)")
    ap.add_argument("--dry-run", action="store_true", help="decide and log, write nothing")
    ap.add_argument("--tenant", action="append", help="limit to these tenants")
    ap.add_argument("--reset", metavar="USER", help="put USER back to auto (1M) and forget history")
    a = ap.parse_args()
    if a.reset:
        write_atomic(os.path.join(CTL_ROOT, a.reset, "window"), "auto\n")
        try:
            os.unlink(os.path.join(STATE_DIR, f"{a.reset}.json"))
        except FileNotFoundError:
            pass
        log(f"{a.reset}: reset to auto")
        return
    while True:
        policy = load_json(POLICY, {}) or {}
        cfg = policy.get("context_window") or {}
        tenants = a.tenant or rollout(policy, "context_window")
        if not cfg.get("ladder") or not tenants:
            log("no ladder or no tenants in policy — nothing to do")
        else:
            now = int(time.time())
            for u in tenants:
                try:
                    run_one(u, cfg, now, a.dry_run)
                except Exception as e:  # one tenant must never stop the others
                    log(f"{u}: error {type(e).__name__}: {e}")
        if a.once or a.dry_run:
            return
        time.sleep(int(cfg.get("poll_s", 30)))


if __name__ == "__main__":
    main()
