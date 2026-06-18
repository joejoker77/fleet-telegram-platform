#!/usr/bin/env python3
"""
icloud-auth-core.py — drive rclone's INTERACTIVE iclouddrive auth in ONE process
(a pty), so the SRP session stays alive across the 2FA step. This deliberately
avoids rclone's non-interactive `config create --continue` path, which is BROKEN
for iclouddrive 2FA (rclone issue #9324: SRP session lost between create+continue;
Apple's 2FA codes are session-scoped). Single-process pty keeps the session.

It runs (as root, on the host where rclone + Apple network + the mount live):
  rclone --config /home/<user>/rclone.conf config create <user>_icloud iclouddrive \
         apple_id=<id> password=<plaintext> service=drive --obscure --all
The only input that has no default is the 2FA code; everything else we Enter
through. apple_id/password are passed as params (not prompted). The password comes
from the env (ICLOUD_PASSWORD) so it never lands on the argv of THIS script; rclone
obscures it (--obscure) into the config. The 2FA code is read from a relay file
(--twofa-file), polled, so the caller (auth-helper / test harness) can drop the
code the user reads off their trusted device.

Usage:
  ICLOUD_PASSWORD=... icloud-auth-core.py <os_user> <apple_id> --twofa-file <path> [--timeout N]
Exit 0 = remote configured (trust_token present). Run as root.
"""
import os, sys, pty, select, time, re, subprocess, argparse, fcntl

AP = argparse.ArgumentParser()
AP.add_argument("user"); AP.add_argument("apple_id")
AP.add_argument("--twofa-file", required=True, help="path polled for the 2FA code (one line)")
AP.add_argument("--timeout", type=int, default=240, help="overall seconds (2FA codes expire fast)")
AP.add_argument("--rclone", default="/usr/bin/rclone")
A = AP.parse_args()

if os.geteuid() != 0:
    sys.exit("run as root")
PW = os.environ.get("ICLOUD_PASSWORD", "")
if not PW:
    sys.exit("ICLOUD_PASSWORD env is required (the regular Apple ID password; app-specific NOT accepted)")

CONF = f"/home/{A.user}/rclone.conf"
REMOTE = f"{A.user}_icloud"

# 2FA prompt + the few confirmations rclone may show. Everything else → Enter (default).
RE_2FA   = re.compile(r"(config_2fa|two-factor|2fa code|verification code|enter your 2fa)", re.I)
RE_YESOK = re.compile(r"(y\)\s*Yes this is OK|y/e/d>|Yes this is OK \(default\))", re.I)
RE_PROMPT_TAIL = re.compile(r">\s*$")

def log(m): print(f"[icloud-auth-core] {m}", flush=True)

def read_2fa(path, deadline):
    log("rclone reached the 2FA step — Apple pushed a code to the trusted device.")
    log(f"waiting for the 2FA code in {path} ...")
    while time.time() < deadline:
        try:
            with open(path) as f:
                code = f.read().strip()
            if code:
                try: os.unlink(path)
                except OSError: pass
                return code
        except FileNotFoundError:
            pass
        time.sleep(1)
    return ""

def main():
    cmd = [A.rclone, "--config", CONF, "config", "create", REMOTE, "iclouddrive",
           f"apple_id={A.apple_id}", f"password={PW}", "service=drive", "--obscure", "--all"]
    pid, fd = pty.fork()
    if pid == 0:  # child
        os.execvp(cmd[0], cmd)
        os._exit(127)
    # parent drives the pty
    fl = fcntl.fcntl(fd, fcntl.F_GETFL); fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    deadline = time.time() + A.timeout
    buf = ""; sent_2fa = False
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 1.0)
        if fd in r:
            try: chunk = os.read(fd, 4096).decode("utf-8", "replace")
            except OSError: break  # EOF (child exited)
            if not chunk: break
            sys.stdout.write(chunk); sys.stdout.flush(); buf += chunk
            continue
        # output stalled → rclone is likely waiting for input; act on the tail
        tail = buf[-400:]
        if RE_2FA.search(tail) and not sent_2fa:
            code = read_2fa(A.twofa_file, deadline)
            if not code: log("no 2FA code within timeout — aborting"); break
            os.write(fd, (code + "\n").encode()); sent_2fa = True; buf = ""
        elif RE_YESOK.search(tail):
            os.write(fd, b"y\n"); buf = ""
        elif RE_PROMPT_TAIL.search(tail):
            os.write(fd, b"\n"); buf = ""  # accept default for any other question
    try: _, status = os.waitpid(pid, 0)
    except OSError: status = 0
    # verify: remote exists with a trust_token
    ok = False
    try:
        out = subprocess.run([A.rclone, "--config", CONF, "config", "dump"],
                             capture_output=True, text=True, timeout=15).stdout
        ok = (f'"{REMOTE}"' in out and "trust_token" in out)
    except Exception:
        pass
    if ok:
        log(f"SUCCESS — remote {REMOTE} configured with a trust_token in {CONF}")
        return 0
    log(f"FAILED — {REMOTE} not fully configured (no trust_token). See output above.")
    return 1

sys.exit(main())
