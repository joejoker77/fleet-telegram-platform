#!/usr/bin/env python3
"""
icloud-browser-auth.py — obtain an iCloud Drive rclone remote via a REAL browser login.

WHY (2026-06-18): rclone's native iclouddrive SRP+2FA flow is dead-ended — Apple
fingerprints the non-browser request and returns HTTP 412 on verify/trusteddevice/
securitycode even for a VALID 2FA code (rclone forum 52019 #31, icloud-photos-downloader
#1026). The community-proven workaround is to log in through a genuine browser (which Apple
trusts), harvest the X-APPLE-WEBAUTH-* session cookies + the HSA-TRUST token, and write them
straight into rclone.conf as `cookies =` + `trust_token =`. rclone then runs on those cookies;
no SRP. trust_token lasts ~30 days, after which `rclone reconnect` re-runs this.

This drives headless Chromium (Playwright) on the HOST as root:
  www.icloud.com  → Apple ID sign-in widget (iframe) → 2FA (code relayed via --twofa-file)
  → harvest cookies → patch /home/<user>/rclone.conf with the <user>_icloud remote.

The 2FA code is read from a polled relay file (same contract as icloud-auth-core.py), so the
caller (auth-helper / test harness) drops the 6-digit code the user reads off the trusted device.
The password comes from ICLOUD_PASSWORD env (never on this script's argv).

Usage:
  ICLOUD_PASSWORD=... icloud-browser-auth.py <os_user> <apple_id> --twofa-file <path> \
      [--timeout 300] [--rclone /path/rclone] [--headed] [--debug-dir /run/icloud-auth]
Exit 0 = remote configured (trust_token harvested + `rclone lsd` works). Run as root.
"""
import os, sys, time, json, argparse, subprocess

AP = argparse.ArgumentParser()
AP.add_argument("user"); AP.add_argument("apple_id")
AP.add_argument("--twofa-file", required=True, help="path polled for the 2FA code (one line)")
AP.add_argument("--timeout", type=int, default=300, help="overall seconds")
AP.add_argument("--rclone", default="/usr/bin/rclone")
AP.add_argument("--headed", action="store_true", help="run a headed browser (needs Xvfb); default headless")
AP.add_argument("--debug-dir", default="/run/icloud-auth", help="where to drop screenshots/cookie dumps on trouble")
A = AP.parse_args()

if os.geteuid() != 0:
    sys.exit("run as root")
PW = os.environ.get("ICLOUD_PASSWORD", "")
if not PW:
    sys.exit("ICLOUD_PASSWORD env is required (the regular Apple ID password)")

CONF   = f"/home/{A.user}/rclone.conf"
REMOTE = f"{A.user}_icloud"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.4.1 Safari/605.1.15")

def log(m): print(f"[icloud-browser-auth] {m}", flush=True)

def read_2fa(path, deadline):
    log(f"waiting for the 2FA code in {path} ...")
    while time.time() < deadline:
        try:
            code = open(path).read().strip()
            if code:
                try: os.unlink(path)
                except OSError: pass
                return code
        except FileNotFoundError:
            pass
        time.sleep(1)
    return ""

def find_in_frames(page, selectors, timeout_ms=15000):
    """Return (frame, selector) for the first selector that appears in ANY frame."""
    end = time.time() + timeout_ms / 1000.0
    while time.time() < end:
        for fr in page.frames:
            for sel in selectors:
                try:
                    el = fr.query_selector(sel)
                    if el and el.is_visible():
                        return fr, sel
                except Exception:
                    pass
        time.sleep(0.4)
    return None, None

def dump(page, tag):
    try:
        os.makedirs(A.debug_dir, exist_ok=True)
        p = f"{A.debug_dir}/{A.user}-{tag}.png"
        page.screenshot(path=p, full_page=True)
        log(f"  (debug screenshot {p})")
    except Exception as e:
        log(f"  (screenshot failed: {e})")

def main():
    from playwright.sync_api import sync_playwright
    deadline = time.time() + A.timeout
    os.makedirs(A.debug_dir, exist_ok=True)

    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=not A.headed, args=[
            "--no-sandbox", "--disable-blink-features=AutomationControlled",
            "--disable-dev-shm-usage",
        ])
        ctx = browser.new_context(user_agent=UA, locale="en-US",
                                  viewport={"width": 1280, "height": 900})
        # light stealth: hide webdriver flag
        ctx.add_init_script("Object.defineProperty(navigator,'webdriver',{get:()=>undefined});")
        page = ctx.new_page()
        page.set_default_timeout(30000)

        log("opening www.icloud.com ...")
        page.goto("https://www.icloud.com/", wait_until="domcontentloaded")
        # The page usually has a "Sign In" button that reveals the Apple ID widget.
        for sel in ["text=Sign In", "button:has-text('Sign In')", "a:has-text('Sign In')"]:
            try:
                b = page.query_selector(sel)
                if b and b.is_visible():
                    b.click(); log("clicked top-level Sign In"); break
            except Exception:
                pass

        # 1) Apple ID
        fr, sel = find_in_frames(page, ["#account_name_text_field",
                                        "input[name='accountName']",
                                        "input[type='email']"], 25000)
        if not fr:
            dump(page, "no-appleid-field"); log("FAILED: never found the Apple ID field"); return 1
        log("entering Apple ID ...")
        fr.fill(sel, A.apple_id)
        for nxt in ["#sign-in", "button#sign-in", "button[type='submit']", "#continue-password"]:
            try:
                el = fr.query_selector(nxt)
                if el and el.is_visible(): el.click(); break
            except Exception: pass
        try: fr.press(sel, "Enter")
        except Exception: pass

        # 2) Password
        fr2, psel = find_in_frames(page, ["#password_text_field",
                                          "input[name='password']",
                                          "input[type='password']"], 25000)
        if not fr2:
            dump(page, "no-pw-field"); log("FAILED: never found the password field"); return 1
        log("entering password ...")
        fr2.fill(psel, PW)
        for nxt in ["#sign-in", "button#sign-in", "button[type='submit']"]:
            try:
                el = fr2.query_selector(nxt)
                if el and el.is_visible(): el.click(); break
            except Exception: pass
        try: fr2.press(psel, "Enter")
        except Exception: pass

        # 3) 2FA — Apple pushes a code to the trusted device; relay it in.
        log("submitted credentials — Apple should push a 2FA code to the trusted device.")
        fr3, csel = find_in_frames(page, ["input[id^='char']",
                                          ".form-security-code-input",
                                          "input[name='char0']",
                                          "input[autocomplete='one-time-code']"], 40000)
        if not fr3:
            # maybe already trusted / no 2FA needed
            log("no 2FA field appeared within 40s — checking if already signed in ...")
        else:
            code = read_2fa(A.twofa_file, deadline)
            if not code:
                dump(page, "no-2fa-code"); log("FAILED: no 2FA code within timeout"); return 1
            log(f"typing 2FA code ({len(code)} digits) ...")
            # individual digit boxes (type each) OR one field
            boxes = fr3.query_selector_all("input[id^='char'], .form-security-code-input, input[autocomplete='one-time-code']")
            if len(boxes) >= len(code):
                for i, d in enumerate(code):
                    boxes[i].fill(d)
            else:
                fr3.fill(csel, code)
            time.sleep(3)
            dump(page, "after-code")  # capture the post-code screen (usually "Trust this browser?")

        # 3b) Trust prompt — clicking "Trust" is what mints the long-lived trust_token.
        #     The screen appears a beat after the code auto-submits and may be in any frame.
        log("handling the 'Trust this browser?' prompt ...")
        for _ in range(10):
            if time.time() > deadline: break
            clicked = False
            # EXACT match only — the screen also has a "Don't Trust" button, and a substring
            # match on 'Trust' would (and did) click the WRONG one, so no trust_token is minted.
            for fr in page.frames:
                for nxt in ["button:text-is('Trust')", "button:text-is('Trust This Browser')",
                            "#trust-browser"]:
                    try:
                        el = fr.query_selector(nxt)
                        if el and el.is_visible():
                            el.click(); clicked = True; log(f"  clicked: {nxt}"); break
                    except Exception: pass
                if clicked: break
            if clicked: break
            # benign "Continue"/"Not Now" upsell interstitials (never click Don't Trust)
            for fr in page.frames:
                for nxt in ["button:has-text('Continue')", "button:has-text('Not Now')"]:
                    try:
                        el = fr.query_selector(nxt)
                        if el and el.is_visible(): el.click(); break
                    except Exception: pass
            time.sleep(1.5)

        # 4) wait for the authed web session cookies — WITHOUT navigating back to the
        #    marketing root (that logs us out before cookies commit). Force-load the Drive
        #    app ONCE to provision the drive-scoped X-APPLE-WEBAUTH-* cookies.
        log("waiting for the web session cookies to be issued ...")
        settled = False
        for i in range(40):
            if time.time() > deadline: break
            names = {c["name"] for c in ctx.cookies()}
            if "X-APPLE-WEBAUTH-HSA-TRUST" in names:
                settled = True; break                       # best: durable trust token present
            if "X-APPLE-WEBAUTH-TOKEN" in names and i >= 8:
                settled = True; break                       # session is up; proceed even sans trust cookie
            if i == 4:
                try: page.goto("https://www.icloud.com/iclouddrive/", wait_until="domcontentloaded")
                except Exception: pass
            time.sleep(3)

        cookies = ctx.cookies()
        names = sorted({c["name"] for c in cookies})
        log(f"cookies present: {names}")
        # harvest
        wanted_prefixes = ("X-APPLE-WEBAUTH", "X-APPLE-UNIQUE", "X_APPLE_WEB", "X-APPLE-DS")
        pairs, trust_token = [], ""
        for c in cookies:
            n = c["name"]
            if n == "X-APPLE-WEBAUTH-HSA-TRUST":
                trust_token = c["value"]
            if n.startswith(wanted_prefixes):
                pairs.append(f"{n}={c['value']}")
        cookie_str = ";".join(pairs)

        # dump raw harvest for debugging/inspection
        try:
            with open(f"{A.debug_dir}/{A.user}-cookies.json", "w") as f:
                json.dump(cookies, f, indent=2)
        except Exception: pass

        if not cookie_str:
            dump(page, "no-cookies");
            log(f"FAILED: did not harvest any session cookies (settled={settled}).")
            browser.close(); return 1
        if not trust_token:
            log("WARN: no X-APPLE-WEBAUTH-HSA-TRUST cookie — writing the remote with session "
                "cookies only (trust_token empty). Works now; may need re-auth sooner than 30d.")
        log(f"harvested {len(pairs)} session cookies; trust_token={'yes' if trust_token else 'NO'}.")
        browser.close()

    # 5) write the rclone.conf section DIRECTLY. `config create` re-runs the SRP+2FA state
    #    machine (it would prompt for 2FA again) — we already have the session, so we just
    #    persist the harvested cookies + trust_token as a plain config section. rclone then
    #    authenticates with the trust_token (SRP sign-in, 2FA skipped) on first use.
    obs = subprocess.run([A.rclone, "obscure", PW], capture_output=True, text=True)
    obs_pw = obs.stdout.strip() if obs.returncode == 0 else PW
    # config delete is auth-free; drops any stale section cleanly
    subprocess.run([A.rclone, "--config", CONF, "config", "delete", REMOTE],
                   capture_output=True, text=True)
    section = (f"\n[{REMOTE}]\n"
               f"type = iclouddrive\n"
               f"apple_id = {A.apple_id}\n"
               f"password = {obs_pw}\n"
               f"service = drive\n"
               f"cookies = {cookie_str}\n")
    if trust_token:
        section += f"trust_token = {trust_token}\n"
    try:
        os.makedirs(os.path.dirname(CONF), exist_ok=True)
        with open(CONF, "a") as f:
            f.write(section)
        os.chmod(CONF, 0o600)
        log(f"wrote remote section [{REMOTE}] into {CONF}")
    except Exception as e:
        log(f"FAILED to write {CONF}: {e}"); return 1

    # 6) verify the remote actually lists
    err = ""
    try:
        lsd = subprocess.run([A.rclone, "--config", CONF, "--user-agent", UA, "lsd", f"{REMOTE}:"],
                             capture_output=True, text=True, timeout=90)
        sys.stdout.write(lsd.stdout); sys.stderr.write(lsd.stderr)
        if lsd.returncode == 0:
            log(f"SUCCESS — remote {REMOTE} configured + verified (lsd worked) in {CONF}")
            return 0
        err = (lsd.stderr or lsd.stdout)
    except Exception as e:
        err = str(e); log(f"lsd verify error: {e}")

    if "503" in err or "Temporarily Unavailable" in err or "429" in err:
        # config is GOOD; Apple's SRP endpoint is throttling us right now. Retry lsd later
        # (no browser / no 2FA needed — the trust_token is persisted).
        log(f"CONFIG WRITTEN OK — but Apple is throttling auth (503/429). The remote is in "
            f"{CONF}; re-run `rclone --config {CONF} lsd {REMOTE}:` after the throttle clears.")
        return 2
    log(f"FAILED — {REMOTE} written but verification (lsd) failed. See output above.")
    return 1

sys.exit(main())
