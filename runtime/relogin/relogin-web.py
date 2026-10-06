#!/usr/bin/env python3
"""relogin-web — the stable address behind the sign-in button.

    GET /relogin/<tenant>.<secret>   →  302 to a FRESH Claude sign-in link

WHY THIS EXISTS. The expiry ladder warns a tenant three, two and one day before their
Claude login lapses, and the warning carries a button. A Telegram inline URL button is
STATIC: the link in it is fixed when the message is sent. Behind a sign-in link sits a
live flow in that tenant's pod which dies in twenty minutes (FLOW_TTL_S). So a button
minted days ahead sent the person to a page that worked, handed them a code, and then
the code came back to "the sign-in is no longer running" — a support ticket every time.

So the button points HERE, at an address that never changes, and the Claude link is
made when the browser arrives.

WHY A HOST SERVICE AND NOT A ROUTE IN cp-api. cp-api runs in a container with /home
bind-mounted but no podman and no host sbin, so it cannot reach into a tenant's pod —
and reaching into the pod is the entire job. This runs on the host as root, beside
`relogin-trigger`, which is the thing that already knows how to do it. nginx proxies
/relogin/ here exactly as it proxies the other two routes to cp-api.

THE TOKEN IS THE TENANT'S OWN, NOT A SIGNATURE. Each pod mints a random value into its
own state dir and builds its button URL from it; this service reads that same file to
recognise the caller. No shared signing secret exists anywhere, and rotating one tenant
is deleting one file.

WHY PUBLIC IS ACCEPTABLE. The token authorises exactly one thing: "start a sign-in for
this tenant". It is not a Claude credential. Someone who steals it can make the pod
offer a sign-in page and complete it with their OWN Claude account — but the resulting
code only takes effect if it reaches the pod, and the only road in is that tenant's own
allowlisted Telegram chat. The realistic abuse is noise, which the rate limit covers.

WHY THE TOKEN DOES NOT EXPIRE. The defect being fixed is a button that goes stale while
the message waits to be read. A lifetime on the token would put the staleness back one
layer down. The token is a long-lived permission to START; the Claude link is minted per
request and never stored here.

Listens on 127.0.0.1 only — nginx terminates TLS and is the sole way in.
"""
from __future__ import annotations

import html
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME_ROOT = os.environ.get("TENANT_HOME_ROOT", "/home")
TRIGGER = os.environ.get("RELOGIN_TRIGGER", "/usr/local/sbin/relogin-trigger")
PORT = int(os.environ.get("RELOGIN_WEB_PORT", "8099"))

# The in-pod helper waits up to 45s for the link to appear; leave room for podman exec.
TRIGGER_TIMEOUT_S = 75
# One start per tenant per window. A second tap inside it is a double-tap or a prefetch.
RATE_WINDOW_S = 30

TENANT_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
SECRET_RE = re.compile(r"^[0-9a-f]{32,128}$")
PATH_RE = re.compile(r"^/relogin/([a-z][a-z0-9_-]{0,31})\.([0-9a-f]{32,128})/?$")
# Only a real Anthropic/Claude authorize URL is ever worth redirecting at: if the
# helper's output shape ever drifts, a stray line must not become an open redirect.
URL_RE = re.compile(r"^https://[a-z0-9.-]*(anthropic|claude)\.(com|ai)/\S*$", re.I)

_last_start: dict[str, float] = {}
_lock = threading.Lock()


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {msg}", flush=True)


def token_path(tenant: str) -> str:
    return os.path.join(HOME_ROOT, tenant, ".claude", "channels",
                        f"telegram-{tenant}", "relogin-token")


def verify(tenant: str, presented: str) -> bool:
    """Constant-time compare against the tenant's own file."""
    if not TENANT_RE.match(tenant) or not SECRET_RE.match(presented):
        return False
    try:
        with open(token_path(tenant), encoding="utf8") as fh:
            stored = fh.read().strip()
    except OSError:
        return False
    if not SECRET_RE.match(stored):
        return False
    # hmac.compare_digest is the constant-time primitive; nothing is being HMACed.
    import hmac
    return hmac.compare_digest(stored, presented)


def mint(tenant: str) -> tuple[str | None, str]:
    """Ask the pod for a fresh link. Returns (url, diagnostic)."""
    try:
        out = subprocess.run([TRIGGER, tenant, "--print-url"],
                             capture_output=True, text=True, timeout=TRIGGER_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return None, "trigger timed out"
    except OSError as exc:
        return None, f"trigger not runnable: {exc}"
    if out.returncode != 0:
        return None, (out.stderr or out.stdout).strip()[-300:]
    url = ""
    for line in out.stdout.splitlines():
        if line.strip().startswith("https://"):
            url = line.strip()
    if not URL_RE.match(url):
        return None, f"unrecognised output: {url[:200]!r}"
    return url, ""


PAGE = (
    "<!doctype html><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>Sign-in</title>"
    "<body style=\"font:16px/1.5 system-ui;margin:0;padding:2rem;max-width:34rem\">"
    "<p>{line}</p>"
    "<p>Send the word <b>relogin</b> to your assistant in Telegram and it will set up "
    "a new sign-in for you.</p>"
)


class Handler(BaseHTTPRequestHandler):
    server_version = "relogin-web"
    sys_version = ""

    def log_message(self, fmt, *args):  # noqa: D102 — our own logging, not stderr noise
        pass

    def _page(self, status: int, line: str) -> None:
        body = PAGE.format(line=html.escape(line)).encode("utf8")
        self.send_response(status)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 — BaseHTTPRequestHandler's interface
        m = PATH_RE.match(self.path.split("?")[0])
        if not m:
            # Deliberately the same answer as a well-formed token for a tenant that
            # does not exist: a probe learns nothing about who is on this host.
            self._page(404, "This sign-in link is not valid.")
            return
        tenant, secret = m.group(1), m.group(2)
        if not verify(tenant, secret):
            log(f"reject {tenant}")
            self._page(404, "This sign-in link is not valid.")
            return

        now = time.time()
        with _lock:
            if now - _last_start.get(tenant, 0.0) < RATE_WINDOW_S:
                self._page(429, "A sign-in was just started for you — check Telegram.")
                return
            _last_start[tenant] = now

        url, why = mint(tenant)
        if url is None:
            with _lock:
                _last_start.pop(tenant, None)  # a failure must not lock them out
            log(f"fail {tenant}: {why}")
            self._page(503, "I could not start a sign-in just now.")
            return

        log(f"ok {tenant}")
        self.send_response(302)
        self.send_header("location", url)
        self.send_header("cache-control", "no-store, no-cache, must-revalidate")
        self.send_header("content-length", "0")
        self.end_headers()


def main() -> int:
    if os.geteuid() != 0:
        print("relogin-web: must run as root — it drives relogin-trigger", file=sys.stderr)
        return 1
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    log(f"listening on 127.0.0.1:{PORT}, trigger={TRIGGER}, homes={HOME_ROOT}")
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
