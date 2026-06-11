#!/usr/bin/env python3
# cp-secretd — narrow privileged channel cp-api → OneCLI vault (M5.5b,
# docs/M5.5b-secret-intake-design.md). Runs as root via systemd socket
# activation (Accept=yes, stdin/stdout = the connection): one JSON request
# line in, one JSON response line out, exit.
#
# Hardwired invariants (NOT parameters — the whole point of this helper over
# handing cp-api the OneCLI admin key):
#   * secret names must match ^vitaliy-mcp-[a-z0-9][a-z0-9._-]{0,48}$
#   * binds go to the vitaliy-bot agent ONLY
#   * secret values are never returned, never logged, never audited
#   * additive bind with verify-after-set + pre-state restore (the
#     git-pat-vault.sh pattern: set-secrets replace-vs-append semantics are
#     unknown, so losing an existing binding rolls back and errors)
#
# Verbs: stage_secret | bind_secret | delete_secret | secret_exists
# Pilot: vitaliy only (M1+ rule).
import json
import os
import re
import socket
import subprocess
import sys

ONECLI = "/usr/local/bin/onecli"
AGENT_IDENT = "vitaliy-bot"
NAME_RE = re.compile(r"^vitaliy-mcp-[a-z0-9][a-z0-9._-]{0,48}$")
HOST_RE = re.compile(r"^(\*\.)?[A-Za-z0-9][A-Za-z0-9.-]{1,200}\.[A-Za-z]{2,}$")
HEADER_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")
MAX_VALUE = 4096
AUDIT_SOCK = os.environ.get("AUDIT_SOCK", "")


def onecli(*args):
    """Run onecli, return parsed JSON (or raw text). Raises on exit!=0."""
    out = subprocess.run(
        [ONECLI, *args], capture_output=True, text=True, timeout=30, check=True,
    ).stdout
    try:
        return json.loads(out)
    except (json.JSONDecodeError, ValueError):
        return out


def rows(data):
    return data.get("data", data) if isinstance(data, dict) else data


def find_secret_id(name):
    for s in rows(onecli("secrets", "list")):
        if isinstance(s, dict) and s.get("name") == name:
            return s["id"]
    return None


def agent_id():
    for a in rows(onecli("agents", "list")):
        if isinstance(a, dict) and a.get("identifier") == AGENT_IDENT:
            return a["id"]
    raise RuntimeError(f"agent {AGENT_IDENT} not found")


def agent_secret_ids(aid):
    out = []
    for s in rows(onecli("agents", "secrets", "--id", aid)):
        out.append(s if isinstance(s, str) else s.get("id", ""))
    return sorted(x for x in out if x)


def set_agent_secrets(aid, ids):
    # set-secrets wants a comma list; empty list clears.
    onecli("agents", "set-secrets", "--id", aid, "--secret-ids", ",".join(ids))


def unbind(aid, sid):
    before = agent_secret_ids(aid)
    if sid not in before:
        return
    set_agent_secrets(aid, [x for x in before if x != sid])


def bind_verified(aid, sid):
    """Additive bind + verify-after-set; restore pre-state on any loss."""
    before = agent_secret_ids(aid)
    if sid in before:
        return
    want = sorted(set(before) | {sid})
    set_agent_secrets(aid, want)
    after = agent_secret_ids(aid)
    missing = sorted(set(want) - set(after))
    if missing:
        set_agent_secrets(aid, before)  # best-effort restore
        raise RuntimeError(f"set-secrets dropped bindings ({len(missing)}) — pre-state restored")


def audit(kind, payload):
    """Best-effort defense-in-depth record (cp-api audits with userId itself)."""
    if not AUDIT_SOCK:
        return
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.5)
        s.connect(AUDIT_SOCK)
        s.sendall((json.dumps(
            {"userId": None, "kind": kind, "actor": "cp-secretd", "payload": payload}
        ) + "\n").encode())
        try:
            s.recv(64)  # collector acks; ignore content
        except OSError:
            pass
        s.close()
    except OSError:
        pass


def validate(req):
    name = req.get("name", "")
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise ValueError("name must match ^vitaliy-mcp-[a-z0-9][a-z0-9._-]{0,48}$")
    if req["verb"] != "stage_secret":
        return
    host = req.get("hostPattern", "")
    if not isinstance(host, str) or not HOST_RE.match(host):
        raise ValueError("hostPattern: a domain like api.example.com or *.example.com")
    header = req.get("headerName", "")
    if not isinstance(header, str) or not HEADER_RE.match(header):
        raise ValueError("headerName: 1–64 chars of [A-Za-z0-9-]")
    fmt = req.get("valueFormat", "")
    if not isinstance(fmt, str) or "{value}" not in fmt or len(fmt) > 64 or not fmt.isprintable():
        raise ValueError("valueFormat: printable, ≤64 chars, must contain {value}")
    value = req.get("value", "")
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_VALUE:
        raise ValueError(f"value: non-empty string up to {MAX_VALUE} chars")
    if any(c in value for c in "\n\r\0"):
        raise ValueError("value: no newlines/control characters")


def handle(req):
    verb = req.get("verb")
    if verb not in ("stage_secret", "bind_secret", "delete_secret", "secret_exists"):
        raise ValueError("verb: stage_secret | bind_secret | delete_secret | secret_exists")
    validate(req)
    name = req["name"]
    aid = agent_id()
    sid = find_secret_id(name)

    if verb == "secret_exists":
        bound = sid is not None and sid in agent_secret_ids(aid)
        return {"ok": True, "exists": sid is not None, "bound": bound}

    if verb == "stage_secret":
        # Rotation path (approved M5.5b Q4): an existing secret of the SAME
        # convention-name is unbound + deleted, then recreated unbound. It is
        # bound again only when the connect approval is allowed.
        if sid:
            unbind(aid, sid)
            onecli("secrets", "delete", "--id", sid)
        # NOTE: --value on argv is briefly visible in /proc of this root-run
        # one-shot (~the onecli call duration) — same accepted window as
        # git-pat-vault.sh / mcp-set-secret.
        onecli(
            "secrets", "create", "--name", name, "--type", "generic",
            "--value", req["value"], "--host-pattern", req["hostPattern"],
            "--header-name", req["headerName"], "--value-format", req["valueFormat"],
        )
        if find_secret_id(name) is None:
            raise RuntimeError("secret created but not found in secrets list")
        audit("mcp.secret.staged", {"name": name, "hostPattern": req["hostPattern"],
                                    "headerName": req["headerName"], "rotated": bool(sid)})
        return {"ok": True, "staged": name, "rotated": bool(sid)}

    if verb == "bind_secret":
        if not sid:
            raise RuntimeError(f"secret {name} not found (stage it first)")
        bind_verified(aid, sid)
        audit("mcp.secret.bound", {"name": name, "agent": AGENT_IDENT})
        return {"ok": True, "bound": name}

    # delete_secret — idempotent: absent secret is success (it's a cleanup verb).
    if not sid:
        return {"ok": True, "deleted": False}
    unbind(aid, sid)
    onecli("secrets", "delete", "--id", sid)
    audit("mcp.secret.deleted", {"name": name})
    return {"ok": True, "deleted": True}


def main():
    line = sys.stdin.readline(64 * 1024)
    try:
        req = json.loads(line)
        if not isinstance(req, dict):
            raise ValueError("request must be a JSON object")
        resp = handle(req)
        # journal trace WITHOUT values
        print(f"cp-secretd: {req.get('verb')} {req.get('name')} -> ok", file=sys.stderr)
    except subprocess.CalledProcessError as e:
        # never let raw CLI stderr leak values; onecli errors don't echo --value
        err = (e.stderr or "onecli failed").strip().splitlines()[-1][:200]
        print(f"cp-secretd: onecli error: {err}", file=sys.stderr)
        resp = {"ok": False, "error": f"onecli: {err}"}
    except Exception as e:  # noqa: BLE001 — single-shot boundary
        print(f"cp-secretd: error: {e}", file=sys.stderr)
        resp = {"ok": False, "error": str(e)[:200]}
    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
