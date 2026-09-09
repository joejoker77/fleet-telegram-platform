#!/usr/bin/env bash
# mint-registry-token.sh <tenant> — give ONE tenant the key that lets them use the skills
# marketplace from chat (share-skill list/publish/get).
#
# WHY THIS IS SEPARATE. m8.2-chat-registry.sh minted these for every tenant that existed
# when the marketplace was installed, and add-user.sh knew nothing about it — so
# ben-holtom, onboarded 2026-09-09, came up with everything else in place and
# `share-skill` refusing to run: "No sharing key found for this account". Found by
# comparing him against an existing manager, not by any script's own output.
#
# Idempotent: a tenant who already has a key keeps it (the pod may already have been told
# about it). Only the sha256 goes in the map, so the map is not itself a credential; the
# tenant's own copy is 0600 and owned by them.
set -euo pipefail

U="${1:?usage: mint-registry-token.sh <tenant>}"
TOKENS_DIR=/etc/claudeapp/registry
TOKENS_FILE="$TOKENS_DIR/tokens.json"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
id "$U" >/dev/null 2>&1 || { echo "no such user: $U" >&2; exit 1; }
[ -d "/home/$U/.claude" ] || { echo "$U has no ~/.claude yet" >&2; exit 1; }

install -d -m 0700 "$TOKENS_DIR"
[ -f "$TOKENS_FILE" ] || printf '{}\n' > "$TOKENS_FILE"
chmod 0600 "$TOKENS_FILE"

python3 - "$TOKENS_FILE" "$U" <<'PY'
import hashlib, json, os, pwd, secrets, sys
tokens_file, u = sys.argv[1], sys.argv[2]
try:
    m = json.load(open(tokens_file))
except Exception:
    m = {}
tok_path = os.path.join("/home", u, ".claude", "registry.token")
if u in m.values() and os.path.exists(tok_path):
    print(f"  {u}: already has a sharing key")
    raise SystemExit(0)
pw = pwd.getpwnam(u)
tok = "reg_" + secrets.token_urlsafe(32)
for d, who in list(m.items()):
    if who == u:
        del m[d]
m[hashlib.sha256(tok.encode()).hexdigest()] = u
old = os.umask(0o077)
try:
    with open(tok_path, "w") as f:
        f.write(tok + "\n")
finally:
    os.umask(old)
os.chmod(tok_path, 0o600)
os.chown(tok_path, pw.pw_uid, pw.pw_gid)
json.dump(m, open(tokens_file, "w"), indent=2, sort_keys=True)
os.chmod(tokens_file, 0o600)
print(f"  {u}: sharing key minted ({len(m)} tenants in the map)")
PY
