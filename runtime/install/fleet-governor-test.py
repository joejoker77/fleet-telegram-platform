"""Offline tests for fleet-governor. Run: python3 fleet-governor-test.py"""
import contextlib, importlib.util, io, json, os, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("g", os.path.join(HERE, "fleet-governor.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
CFG = json.load(open(os.path.join(HERE, "fleet-policy.json")))["context_window"]
L = CFG["ladder"]
bad = 0


def check(name, got, exp):
    global bad
    ok = got == exp
    bad += not ok
    print("OK " if ok else "BAD", name, "->", got, "" if ok else f"(expected {exp})")


tmp = tempfile.mkdtemp()
g.STATE_DIR, g.CTL_ROOT, g.HOME_ROOT = tmp + "/state", tmp + "/ctl", tmp + "/home"
os.makedirs(tmp + "/home/u/.claude")


def snap(ts, u5, r5, u7=0.10, r7=None):
    d = {"ts": ts, "five_hour": {"utilization": u5, "resets_at": r5},
         "seven_day": {"utilization": u7, "resets_at": r7 or ts + 5 * 86400}}
    json.dump(d, open(tmp + "/home/u/.claude/fleet-usage.json", "w"))


def run(now):
    with contextlib.redirect_stdout(io.StringIO()) as o:
        g.run_one("u", CFG, now, False)
    return o.getvalue().strip()


def window():
    return open(tmp + "/ctl/u/window").read().strip()


def reset():
    for p in (tmp + "/state/u.json", tmp + "/ctl/u/window"):
        if os.path.exists(p):
            os.unlink(p)

# ---- 1. calm day: 10% used, 3h to reset, slow -> stays 1M
T0 = 1_800_000_000
R5 = T0 + 3 * 3600
for i in range(10):
    snap(T0 + 60 * i, 0.10 + 0.0005 * i, R5); run(T0 + 60 * i + 5)
check("calm: stays 1M", window(), "auto")

# ---- 2. Daria 2026-09-28: 36% at 15:05, +4%/min, reset 16:50
reset()
T = T0; R = T + 105 * 60
moved_at = None; trail = []
for i in range(12):
    u = min(0.36 + 0.04 * i, 1.0)
    snap(T + 60 * i, u, R); run(T + 60 * i + 5)
    trail.append((i, round(u * 100), window()))
    if moved_at is None and window() == str(L[-1]):
        moved_at = (i, round(u * 100))
print("   daria trail:", trail[:6])
check("burst: reaches 200k within 3 min of the burst starting", moved_at is not None and moved_at[0] <= 3, True)

# ---- 3. going back up: one step at a time, only after the hold
reset()
T = T0; R = T + 4 * 3600
snap(T, 0.60, R); run(T)                                    # 60% at 20% elapsed -> tight
tight = window()
check("heavy pace -> smaller than 1M", tight != "auto", True)
# now usage stops growing and the reset passes -> new window, 2%
T2 = R + 60; R2 = T2 + 5 * 3600
seen = []
for k in range(60):
    t = T2 + 60 * k
    snap(t, 0.02, R2); run(t + 5)
    if not seen or seen[-1] != window():
        seen.append(window())
check("relaxes step by step back to 1M", seen[-1], "auto")
check("never skips a step on the way up", all(
    (L.index(int(a)) if a != "auto" else 0) - (L.index(int(b)) if b != "auto" else 0) == 1
    for a, b in zip(seen, seen[1:])), True)

# ---- 4. stale data never tightens
reset()
snap(T0, 0.95, T0 + 3600); run(T0 + 5)                      # fresh, very hot -> 200k
check("hot fresh -> 200k", window(), str(L[-1]))
reset()
snap(T0 - 3 * 3600, 0.95, T0 + 3600); out = run(T0)         # same numbers, 3h old
check("same numbers but stale -> untouched (1M)", window(), "auto")

# ---- 5. stale while tight: holds until the driving window resets, then relaxes
reset()
snap(T0, 0.95, T0 + 3600); run(T0 + 5)
run(T0 + 1800)                                              # stale-ish: 30 min, no new data
check("stale before reset -> holds 200k", window(), str(L[-1]))
run(T0 + 3600 + 700)                                        # after reset + hold
check("stale after reset -> one step up", window(), str(L[-2]))

# ---- 6. weekly window drives it too
reset()
T = T0; R7 = T + 6 * 86400
snap(T, 0.05, T + 4 * 3600, u7=0.70, r7=R7); run(T + 5)
check("weekly 70% with 6 days left -> tight", window() != "auto", True)
reset()
snap(T, 0.05, T + 4 * 3600, u7=0.30, r7=T + 2 * 86400); run(T + 5)
check("weekly 30% with 2 days left -> 1M", window(), "auto")

# ---- 7. Vitaliy's 5h examples
reset(); snap(T0, 0.10, T0 + 2 * 3600); run(T0 + 5)
check("5h 10% used, 2h left -> 1M", window(), "auto")
reset(); snap(T0, 0.60, T0 + 3 * 3600); run(T0 + 5)
check("5h 60% used, 3h left -> tight", window() != "auto", True)

print("FAILURES:", bad)
