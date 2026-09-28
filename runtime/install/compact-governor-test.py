"""Offline tests for compact-governor + usage-statusline. Run: python3 compact-governor-test.py"""
import importlib.util, json, os, subprocess, sys, tempfile, time
R = os.path.dirname(os.path.abspath(__file__)) + "/"
s = importlib.util.spec_from_file_location("g", R + "compact-governor.py")
g = importlib.util.module_from_spec(s); s.loader.exec_module(g)
H, D = 3600, 86400
now = int(time.time())
bad = 0


def check(name, got, exp):
    global bad
    ok = got == exp
    bad += not ok
    print("OK " if ok else "BAD", name, "->", got, "" if ok else f"(expected {exp})")


def snap(ts=None, **w):
    d = {"ts": now if ts is None else ts}
    for k, (u, left) in w.items():
        d[k] = {"used_percentage": u, "resets_at": now + left}
    return d

MA = 20 * 60
# --- Vitaliy's four examples + edges (fresh data)
check("5h 10% used, 2h left", g.decide(snap(five_hour=(10, 2 * H)), now, 50, MA)[0], "normal")
check("5h 60% used, 3h left", g.decide(snap(five_hour=(60, 3 * H)), now, 50, MA)[0], "saver")
check("7d 30% used, 2d left", g.decide(snap(seven_day=(30, 2 * D)), now, 50, MA)[0], "normal")
check("7d 70% used, 6d left", g.decide(snap(seven_day=(70, 6 * D)), now, 50, MA)[0], "saver")
check("5h 49% (under floor), 4.5h left", g.decide(snap(five_hour=(49, 4.5 * H)), now, 50, MA)[0], "normal")
check("5h 100% used, 1h left", g.decide(snap(five_hour=(100, 1 * H)), now, 50, MA)[0], "saver")
check("5h 55%, 30min left (pace ok)", g.decide(snap(five_hour=(55, 1800)), now, 50, MA)[0], "normal")
check("5h 90% but reset passed", g.decide(snap(five_hour=(90, -10)), now, 50, MA)[0], "normal")
check("both windows, weekly hot", g.decide(snap(five_hour=(5, 4 * H), seven_day=(80, 5 * D)), now, 50, MA)[0], "saver")
check("implausible 150%", g.decide(snap(five_hour=(150, 2 * H)), now, 50, MA)[0], "normal")
check("reset 2 days away on a 5h window", g.decide(snap(five_hour=(90, 2 * D)), now, 50, MA)[0], "normal")
# --- hysteresis
check("in saver: 47%, just behind time -> stays", g.decide(snap(five_hour=(47, 2.4 * H)), now, 50, MA, True)[0], "saver")
check("in saver: 44% -> off", g.decide(snap(five_hour=(44, 3 * H)), now, 50, MA, True)[0], "normal")
check("in saver: 60% but 75% elapsed -> off", g.decide(snap(five_hour=(60, 1.25 * H)), now, 50, MA, True)[0], "normal")
# --- stale
check("stale 30 min old", g.decide(snap(ts=now - 30 * 60, five_hour=(90, 2 * H)), now, 50, MA)[0], "stale")
check("from the future", g.decide(snap(ts=now + 3600, five_hour=(90, 2 * H)), now, 50, MA)[0], "stale")
check("no snapshot", g.decide(None, now, 50, MA)[0], "stale")
check("no ts", g.decide({"five_hour": {"used_percentage": 90, "resets_at": now + H}}, now, 50, MA)[0], "stale")
check("19 min old still fresh", g.decide(snap(ts=now - 19 * 60, five_hour=(60, 3 * H)), now, 50, MA)[0], "saver")
v, r, hold = g.decide(snap(five_hour=(60, 3 * H), seven_day=(70, 6 * D)), now, 50, MA)
check("hold_until = latest hot reset", hold, now + 6 * D)

# --- run_one state machine with a fake pane
tmp = tempfile.mkdtemp(); g.STATE_DIR = tmp + "/state"; g.HOME_ROOT = tmp
os.makedirs(tmp + "/u/.claude")
typed = []
g.switch = lambda u, arg: (typed.append(arg) or (True, "ok", False))
g.static_override = lambda u: None
conf = {"threshold": 50, "saver": 200000, "dwell": 1800, "max_age": MA}
def put(sn): json.dump(sn, open(tmp + "/u/.claude/usage-snapshot.json", "w"))
def state(): return json.load(open(g.STATE_DIR + "/u.json")) if os.path.exists(g.STATE_DIR + "/u.json") else {}
import io, contextlib
def run(t):
    with contextlib.redirect_stdout(io.StringIO()) as o:
        g.run_one("u", conf, t, False)
    return o.getvalue().strip()

put(snap(five_hour=(60, 3 * H))); run(now)
check("sm: fresh hot -> saver", (state().get("mode"), typed[-1:]), ("saver", ["200000"]))
put(snap(five_hour=(10, 4 * H))); out = run(now + 600)
check("sm: cool again within dwell -> waits", (state().get("mode"), len(typed)), ("saver", 1))
put(snap(ts=now + 2400, five_hour=(10, 4 * H))); run(now + 2400)
check("sm: cool after dwell -> normal", (state().get("mode"), typed[-1]), ("normal", "auto"))
put(snap(ts=now, five_hour=(95, 1 * H))); out = run(now + 6000)
check("sm: stale hot data -> no switch", (state().get("mode"), len(typed)), ("normal", 2))
put(snap(ts=now + 6000, five_hour=(80, 6000 + 2 * H))); run(now + 6000)
check("sm: fresh hot -> saver again", state().get("mode"), "saver")
hold = state()["hold_until"]
put(snap(ts=now + 6000, five_hour=(80, 6000 + 2 * H))); out = run(now + 9000)
check("sm: stale, before reset -> holds saver", (state().get("mode"), len(typed)), ("saver", 3))
out = run(hold + 60)
check("sm: stale, after reset -> normal", (state().get("mode"), typed[-1]), ("normal", "auto"))

# --- pane detection
ghost = "✻ Cogitated for 27s · done 2:29 PM\n──\n\x1b[39m❯\xa0\x1b[2mWhat did Sasha say\x1b[0m\n──\n  ⏵⏵ auto mode on\n"
typedp = "done\n──\n\x1b[39m❯\xa0hello there\n──\n footer\n"
empty = "done\n──\n\x1b[39m❯\xa0\n──\n footer\n"
busy = "\x1b[38;5;174m✻\x1b[39m Herding… (3s · esc to interrupt)\n──\n\x1b[39m❯\xa0\n──\n footer\n"
dialog = "Allow?\n\x1b[39m❯\xa01. Yes\n  2. No\n\n a\n b\n c\n Esc to cancel\n"
for n, p, exp in (("ghost", ghost, True), ("typed", typedp, False), ("empty", empty, True),
                  ("busy", busy, False), ("blank", "", False), ("dialog", dialog, False)):
    check("pane " + n, g.pane_ready(p)[0], exp)

# --- status line script
home = tempfile.mkdtemp(); os.makedirs(home + "/.claude")
env = dict(os.environ, HOME=home)
inp = json.dumps({"rate_limits": {"five_hour": {"used_percentage": 3, "resets_at": 1790586600},
                                  "seven_day": {"used_percentage": 5, "resets_at": 1790665200}},
                  "context_window": {"total_input_tokens": 220888}})
p = subprocess.run([sys.executable, R + "tenant-skel/usage-statusline.py"], input=inp, text=True, capture_output=True, env=env)
sn = json.load(open(home + "/.claude/usage-snapshot.json"))
check("statusline writes snapshot, prints nothing", (p.returncode, p.stdout, sn["five_hour"]["used_percentage"]), (0, "", 3.0))
p = subprocess.run([sys.executable, R + "tenant-skel/usage-statusline.py"], input='{"model":{}}', text=True, capture_output=True, env=env)
check("statusline w/o rate_limits keeps old snapshot", json.load(open(home + "/.claude/usage-snapshot.json"))["ts"], sn["ts"])
p = subprocess.run([sys.executable, R + "tenant-skel/usage-statusline.py"], input="garbage", text=True, capture_output=True, env=env)
check("statusline garbage silent", (p.returncode, p.stderr), (0, ""))
print("FAILURES:", bad)
