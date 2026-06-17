#!/usr/bin/env python3
"""
A2 (c) — backfill control-plane `secret_bindings` from the OneCLI vault.

`secret_bindings` is the product's source-of-truth for "which secret is bound to
which tenant" (metadata only — real values stay in the OneCLI vault). It was
schema-defined but never populated. This one-time, idempotent migration reads
each tenant's CURRENTLY-bound OneCLI secrets (incl. legacy ones bound via the old
host `mcp-set-secret`) and upserts a row per binding, so cp-api's deploy reconcile
can do the MCP bound-secret check from its OWN DB — no `onecli` in cp-api, no
privileged vault creds in cp-api, no host helper.

Stored: placeholder = the full OneCLI secret name (`<user>-<slug>-<name>`, the
canonical id the reconcile reconstructs + checks), host = the secret's host pattern.

Run host-side as root (onecli + cp-postgres live on the host):
  secret-bindings-backfill.py [--apply]   (default: dry-run, prints what it WOULD upsert)
Idempotent: per user it DELETEs existing rows then re-inserts from OneCLI (re-sync).
"""
import json
import subprocess
import sys

ONECLI = "/usr/local/bin/onecli"

def onecli(args):
    try:
        r = subprocess.run([ONECLI, *args], capture_output=True, text=True, timeout=30, check=False)
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None

def rows(d):
    return (d.get("data") if isinstance(d, dict) else d) or []

def psql(sql, capture=True):
    cmd = ["podman", "exec", "-i", "cp-postgres", "psql", "-U", "cplane", "-d", "control_plane",
           "-v", "ON_ERROR_STOP=1"]
    if capture:
        cmd += ["-tAc", sql]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
        if r.returncode != 0:
            raise RuntimeError(f"psql failed: {r.stderr.strip()}")
        return r.stdout.strip()
    # exec a multi-statement script via stdin
    r = subprocess.run(cmd, input=sql, capture_output=True, text=True, timeout=30, check=False)
    if r.returncode != 0:
        raise RuntimeError(f"psql failed: {r.stderr.strip()}")
    return r.stdout.strip()

def sql_str(s):
    return "'" + s.replace("'", "''") + "'"

def agent_uuid(user):
    return next((a.get("id") for a in rows(onecli(["agents", "list"]))
                 if isinstance(a, dict) and a.get("identifier") == f"{user}-bot"), None)

def bound_ids(uuid):
    out = set()
    for it in rows(onecli(["agents", "secrets", "--id", uuid]) or {}):
        if isinstance(it, str): out.add(it)
        elif isinstance(it, dict) and it.get("id"): out.add(it["id"])
    return out

def secrets_index():
    idx = {}
    for s in rows(onecli(["secrets", "list"]) or {}):
        if isinstance(s, dict) and s.get("id") and s.get("name"):
            idx[s["id"]] = {"name": s["name"], "host": s.get("hostPattern") or s.get("host_pattern") or s.get("host") or ""}
    return idx

def main():
    apply = "--apply" in sys.argv
    users = []
    for line in psql("select os_username, id from users where os_username is not null;").splitlines():
        if "|" in line:
            name, uid = line.split("|", 1)
            users.append((name.strip(), uid.strip()))
    if not users:
        print("no users in control-plane DB"); return
    idx = secrets_index()
    print(f"== secret_bindings backfill ({'APPLY' if apply else 'DRY-RUN'}) — {len(users)} users, {len(idx)} vault secrets ==")
    for name, uid in users:
        au = agent_uuid(name)
        bound = bound_ids(au) if au else set()
        binds = [idx[i] for i in bound if i in idx]
        print(f"\n{name} (agent={'ok' if au else 'MISSING'}): {len(binds)} bound -> {[b['name'] for b in binds]}")
        if not apply:
            continue
        stmts = [f"delete from secret_bindings where user_id = {sql_str(uid)};"]
        for b in binds:
            stmts.append(
                "insert into secret_bindings (user_id, placeholder, host) values "
                f"({sql_str(uid)}, {sql_str(b['name'])}, {sql_str(b['host'])});")
        psql("\n".join(stmts), capture=False)
        print(f"  upserted {len(binds)} rows")
    print("\nDONE" + ("" if apply else " (dry-run — re-run with --apply to write)"))

if __name__ == "__main__":
    main()
