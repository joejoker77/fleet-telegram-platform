#!/usr/bin/env python3
"""
A2 Phase-1 — DRY-RUN reconcile core (deploy -> control-plane).

Computes, for one tenant, the skill set + resolved mcpServers that the
control-plane reconcile (Option A, docs/10) WOULD apply, and DIFFS it against the
tenant's live ~/.claude state. Writes NOTHING (no settings.json, no skills rsync,
no state file, no graceful-restart). This is the validation harness: its output
must match what the host deploy-skills/deploy-mcp.v2.4 currently produce, proving
the reconcile logic before Phase-2 (apply path + move into cp-api + GitHub fetch).

Faithfully mirrors the two reference reconcilers:
  - skills allow-list      <- deploy-skills
  - mcp template resolution <- deploy-mcp.v2.4  (USER_CONFIG, SECRET->${ONECLI:},
    OneCLI bound-secret check, managed-set merge). Deploy-time judge gate is
    DEPRECATED (ADR-004) and intentionally omitted.

Run host-side as root (onecli lives on the host), like the real deploy:
  host-sudo python3 a2-reconcile-dryrun.py <user> [--repo <skills-repo-dir>]
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ONECLI = "/usr/local/bin/onecli"
USER_CONFIG_RE = re.compile(r"\$\{USER_CONFIG:([a-z0-9_]+)\}")
SECRET_RE = re.compile(r"\$\{SECRET:([a-z0-9_-]+)\}")
T = 30  # per onecli call timeout

# ---------- users.yaml ----------
def load_yaml(repo: Path):
    try:
        import yaml
    except ImportError:
        print("FATAL: python yaml not available (same dep the host deploy uses)", file=sys.stderr)
        sys.exit(3)
    p = repo / "users.yaml"
    if not p.is_file():
        return {}
    with open(p) as f:
        return yaml.safe_load(f) or {}

def allowed(user, all_slugs, section):
    """An entry not listed -> all users; listed -> only its `users`."""
    out = []
    for slug in all_slugs:
        spec = section.get(slug)
        if not isinstance(spec, dict):
            out.append(slug); continue
        users = spec.get("users")
        if not isinstance(users, list) or user in users:
            out.append(slug)
    return out

# ---------- skills ----------
def reconcile_skills(repo: Path, user: str, home: Path):
    skills_root = repo / "skills"
    all_skills = sorted(d.name for d in skills_root.iterdir() if d.is_dir()) if skills_root.is_dir() else []
    yaml_data = load_yaml(repo)
    allow = allowed(user, all_skills, (yaml_data.get("skills") or {}))
    installed_dir = home / ".claude" / "skills"
    installed = sorted(d.name for d in installed_dir.iterdir() if d.is_dir()) if installed_dir.is_dir() else []
    want = set(allow)
    have = set(installed)
    return {
        "available": all_skills,
        "allowed": allow,
        "installed_now": installed,
        "would_add": sorted(want - have),
        "would_remove": sorted(have - want),   # only matters for repo-managed dirs
        "matches_live": want == have,
    }

# ---------- onecli (bound-secret resolution; same as deploy-mcp.v2.4) ----------
def _onecli(args):
    try:
        r = subprocess.run([ONECLI, *args], capture_output=True, text=True, timeout=T, check=False)
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None

def agent_uuid(user):
    d = _onecli(["agents", "list"])
    rows = d.get("data") if isinstance(d, dict) else d
    if not isinstance(rows, list):
        return None
    return next((a.get("id") for a in rows if isinstance(a, dict) and a.get("identifier") == f"{user}-bot"), None)

def bound_secret_ids(uuid):
    if not uuid:
        return set()
    d = _onecli(["agents", "secrets", "--id", uuid]) or {}
    out = set()
    for it in (d.get("data") or []):
        if isinstance(it, str): out.add(it)
        elif isinstance(it, dict) and it.get("id"): out.add(it["id"])
    return out

def secrets_by_id():
    d = _onecli(["secrets", "list"]) or {}
    return {s["id"]: s["name"] for s in (d.get("data") or []) if isinstance(s, dict) and s.get("id") and s.get("name")}

def bound_bare_names(user, slug, ids, by_id):
    prefix = f"{user}-{slug}-"
    return {by_id[i][len(prefix):] for i in ids if by_id.get(i, "").startswith(prefix)}

def resolve(template, user_config, agent_secrets):
    miss_cfg, miss_sec = [], []
    def walk(n):
        if isinstance(n, dict): return {k: walk(v) for k, v in n.items()}
        if isinstance(n, list): return [walk(x) for x in n]
        if isinstance(n, str):
            def sc(m):
                k = m.group(1)
                if k not in user_config:
                    if k not in miss_cfg: miss_cfg.append(k)
                    return m.group(0)
                return str(user_config[k])
            s = USER_CONFIG_RE.sub(sc, n)
            def ss(m):
                name = m.group(1)
                if name not in agent_secrets and name not in miss_sec: miss_sec.append(name)
                return f"${{ONECLI:{name}}}"   # marker; real value injected at the proxy
            return SECRET_RE.sub(ss, s)
        return n
    return walk(template), miss_cfg, miss_sec

# ---------- mcp ----------
def reconcile_mcp(repo: Path, user: str, home: Path):
    mcp_root = repo / "mcp"
    all_slugs = sorted(d.name for d in mcp_root.iterdir() if d.is_dir() and (d / "template.json").is_file()) if mcp_root.is_dir() else []
    yaml_data = load_yaml(repo)
    section = yaml_data.get("mcp") or {}
    allow = allowed(user, all_slugs, section)
    uuid = agent_uuid(user)
    ids = bound_secret_ids(uuid)
    by_id = secrets_by_id() if ids else {}
    resolved, skipped = {}, {}
    for slug in allow:
        try:
            tpl = json.loads((mcp_root / slug / "template.json").read_text())
        except Exception as e:
            skipped[slug] = {"error": str(e)}; continue
        stanza = tpl.get("mcp_stanza", tpl)
        ucfg = ((section.get(slug) or {}).get("user_config") or {}).get(user) or {}
        secs = bound_bare_names(user, slug, ids, by_id)
        r, mc, ms = resolve(stanza, ucfg, secs)
        if mc or ms:
            skipped[slug] = {"missing_config": mc, "missing_secrets": ms}
        else:
            resolved[slug] = r
    # live settings.json mcpServers (read-only)
    sp = home / ".claude" / "settings.json"
    live = {}
    if sp.is_file():
        try: live = (json.loads(sp.read_text()).get("mcpServers") or {})
        except Exception: live = {}
    return {
        "available": all_slugs,
        "allowed": allow,
        "agent_uuid_found": bool(uuid),
        "bound_secret_count": len(ids),
        "would_manage": sorted(resolved.keys()),
        "skipped": skipped,
        "live_mcpServers": sorted(live.keys()),
    }

def main():
    if len(sys.argv) < 2:
        print("usage: a2-reconcile-dryrun.py <user> [--repo <dir>]", file=sys.stderr); sys.exit(2)
    user = sys.argv[1]
    repo = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == "--repo" else Path(f"/home/{user}/.claude/skills-repo")
    home = Path(f"/home/{user}")
    if not repo.is_dir():
        print(f"FATAL: skills-repo not found: {repo}", file=sys.stderr); sys.exit(1)
    print(f"== A2 DRY-RUN reconcile for '{user}'  (repo={repo}, NO writes) ==")
    sk = reconcile_skills(repo, user, home)
    print("\n[skills]")
    print(f"  available      : {sk['available']}")
    print(f"  allowed        : {sk['allowed']}")
    print(f"  installed now  : {sk['installed_now']}")
    print(f"  would add      : {sk['would_add']}")
    print(f"  would remove   : {sk['would_remove']}")
    print(f"  MATCHES LIVE   : {sk['matches_live']}")
    mc = reconcile_mcp(repo, user, home)
    print("\n[mcp]")
    print(f"  available      : {mc['available']}")
    print(f"  allowed        : {mc['allowed']}")
    print(f"  onecli agent   : found={mc['agent_uuid_found']} bound_secrets={mc['bound_secret_count']}")
    print(f"  would manage   : {mc['would_manage']}")
    print(f"  skipped        : {json.dumps(mc['skipped'])}")
    print(f"  live mcpServers: {mc['live_mcpServers']}")
    print("\n(dry-run only — nothing written)")

if __name__ == "__main__":
    main()
