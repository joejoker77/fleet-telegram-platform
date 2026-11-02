#!/usr/bin/env bash
# Can every tenant actually publish a skill to the firm catalogue?
#
# WHY THIS EXISTS. Publishing pushes to the marketplace repo from inside the tenant's pod, with
# the PAT the egress proxy injects on api.github.com. The proxy injects by host AND path, and
# m-key-vault.sh says plainly that a path pattern is REQUIRED whenever two secrets can share a
# hostname. `vault-put` — the self-service path every tenant's assistant is told to use — cannot
# set one. So a tenant who stores a personal GitHub token gets a host-wide rule that also matches
# the marketplace repo, and from then on their publishes carry a token chosen by the vault rather
# than by us.
#
# On 2026-11-02 that cost a day: of 36 tenants, 2 had no credential for the repo at all, 1 had a
# personal token and no marketplace one, and 4 had both. Five of those seven failed with
# "GitHub 404: Not Found" — which is what a private repo says to a request it does not recognise,
# and reads like a missing file.
#
# This asks the vault the same question the proxy will ask at publish time, for every tenant, and
# names who cannot publish BEFORE they try.
#
#   check-registry-github.sh            one line per tenant that is not ok
#   check-registry-github.sh --all      one line per tenant
#
# Exit: 0 everyone can publish, 1 somebody cannot, 2 the vault could not be read.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

ONECLI_API="${ONECLI_API:-http://127.0.0.1:10254}"
REPO_PATH="${REPO_PATH:-/repos/monacodigital/ClaudeCodeTeam}"
ROLE_DIR=/etc/claude-role
ALL=0
[ "${1:-}" = "--all" ] && ALL=1

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
curl -s -m 20 -o "$tmp" "$ONECLI_API/api/secrets" || { echo "could not read the vault at $ONECLI_API" >&2; exit 2; }
[ -s "$tmp" ] || { echo "the vault returned nothing" >&2; exit 2; }

ls "$ROLE_DIR" 2>/dev/null | ALL=$ALL REPO_PATH=$REPO_PATH python3 -c '
import json, os, sys

secrets = json.load(open(sys.argv[1]))
repo_path = os.environ["REPO_PATH"]
show_all = os.environ["ALL"] == "1"

def matches(s):
    """Would the proxy inject this secret into the publish request?"""
    if (s.get("hostPattern") or "") != "api.github.com":
        return False
    p = s.get("pathPattern")
    if not p:
        return True                      # host-wide: matches every path, including ours
    return repo_path.startswith(p.rstrip("*"))

candidates = [s for s in secrets if matches(s)]
bad = 0
for tenant in (l.strip() for l in sys.stdin if l.strip()):
    mine = [s["name"] for s in candidates if s["name"].startswith(tenant + "-")]
    want = f"{tenant}-registry-github"
    if mine == [want]:
        state, note = "ok", "the catalogue token, and nothing else"
    elif not mine:
        state, note = "NO", "nothing in the vault matches the catalogue repo — publishing answers 404"
    elif want not in mine:
        state, note = "NO", f"publishes with {mine[0]}, which is not the catalogue token"
    else:
        others = [m for m in mine if m != want]
        state, note = "NO", ("the catalogue token AND " + ", ".join(others) +
                             " both match; which one is sent is not ours to choose")
    if state != "ok":
        bad += 1
    if show_all or state != "ok":
        print("  %-4s %-22s %s" % (state, tenant, note))

print()
print("cannot publish: %d" % bad if bad else "every tenant can publish to the catalogue")
sys.exit(1 if bad else 0)
' "$tmp"
