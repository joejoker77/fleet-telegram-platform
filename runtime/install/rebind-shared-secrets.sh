#!/usr/bin/env bash
# rebind-shared-secrets.sh — (re)bind the shared firm secrets ALREADY in the vault to the
# agents that role-matrix.json entitles, without asking anyone to re-enter a credential.
#
# Two situations need this:
#   1. A tenant was added AFTER the shared keys were onboarded. onboard-integrations.sh binds
#      only to the tenants that exist when it runs, so a later tenant would otherwise have no
#      shared keys until every credential was typed in again.
#   2. A binding failed for an infrastructural reason and has to be replayed — e.g. the vault
#      retired PUT /agents/:id/secrets (HTTP 410) and every bind failed until the shim was
#      taught the new per-secret grant API.
#
# Idempotent and additive: it only ADDS grants a role is entitled to. It never revokes, so it
# cannot strip a binding someone made deliberately.
#
#   sudo ./rebind-shared-secrets.sh            # all tenants
#   sudo ./rebind-shared-secrets.sh --user <login>
#   sudo ./rebind-shared-secrets.sh --dry-run
set -uo pipefail
ONECLI=/usr/local/bin/onecli
export HOME=/root
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MATRIX="${ROLE_MATRIX_JSON:-$HERE/role-matrix.json}"

c_ok(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_no(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_hd(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ONLY_USER=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) ONLY_USER="${2:?--user needs a login}"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac; shift
done
[ "$(id -u)" -eq 0 ] || die "run as root"
"$ONECLI" auth status >/dev/null 2>&1 || die "onecli not authenticated"
[ -f "$MATRIX" ] || die "role-matrix.json not found at $MATRIX"

# secret name -> "service scope". Mirrors the vault_and_distribute calls in
# onboard-integrations.sh; scope is empty unless the service distributes per scope (Supabase,
# where rw roles get the service_role key and read roles go through the DB gateway instead).
svc_of(){ case "$1" in
  ms-supabase|ms-supabase-auth)        echo "supabase rw";;
  ms-payload)                          echo "payload";;
  ms-wordpress)                        echo "rota";;
  ms-strapi)                           echo "strapi";;
  ms-n8n-cloud|ms-n8n-selfhosted)      echo "n8n";;
  ms-exa-api)                          echo "exa";;
  ms-composio-api|ms-composio-mcp)     echo "composio";;
  ms-elevenlabs-api)                   echo "elevenlabs";;
  ms-xero-client)                      echo "xero";;
  *)                                   echo "";; esac; }

roles_for(){ # $1 service  $2 scope(optional) -> space-separated roles
  python3 - "$MATRIX" "$1" "${2:-}" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
svc, scope = sys.argv[2], sys.argv[3]
roles = m.get("services", {}).get(svc, {}).get("roles", {})
order = m.get("role_order", [])
print(" ".join(r for r in order if r in roles and (not scope or roles[r] == scope)))
PY
}

agent_id(){ "$ONECLI" agents list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in r if a.get('identifier')=='$1'),''))"; }
granted_ids(){ "$ONECLI" agents secrets --id "$1" 2>/dev/null | python3 -c '
import json,sys
try: print(" ".join(json.load(sys.stdin)))
except Exception: pass'; }

c_hd "Re-binding shared secrets per role-matrix.json"
# Every ms-* secret currently in the vault, as "id<TAB>name"
SECRETS="$("$ONECLI" secrets list 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin); r=d.get("data",d) if isinstance(d,dict) else d
for s in r:
    n = str(s.get("name",""))
    if n.startswith("ms-"): print("%s\t%s" % (s.get("id"), n))')"
[ -n "$SECRETS" ] || { echo "no ms-* secrets in the vault yet — nothing to bind"; exit 0; }
echo "shared secrets found:"; printf '%s\n' "$SECRETS" | while IFS="$(printf '\t')" read -r i n; do echo "  $n"; done

added=0; skipped=0; failed=0
for f in /etc/claude-role/*; do
  [ -f "$f" ] || continue
  u="$(basename "$f")"; role="$(tr -d ' \t\r\n' <"$f")"
  [ -z "$ONLY_USER" ] || [ "$ONLY_USER" = "$u" ] || continue
  aid="$(agent_id "${u}-bot")"
  if [ -z "$aid" ]; then c_no "  $u: no agent ${u}-bot — skipped"; continue; fi
  have="$(granted_ids "$aid")"
  want=""
  while IFS="$(printf '\t')" read -r sid sname <&3; do
    [ -n "${sid:-}" ] || continue
    spec="$(svc_of "$sname")"
    [ -n "$spec" ] || continue                       # unknown ms-* secret: leave it alone
    set -- $spec; svc="$1"; scope="${2:-}"
    allowed="$(roles_for "$svc" "$scope")"
    case " $allowed " in *" $role "*) want="$want $sid";; *) continue;; esac
  done 3<<EOF
$SECRETS
EOF
  # union of what it already has and what the matrix entitles: additive, never revoking
  union="$(printf '%s %s\n' "$have" "$want" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')"
  newcount=0
  for s in $want; do printf '%s\n' "$have" | tr ' ' '\n' | grep -qx -- "$s" || newcount=$((newcount+1)); done
  if [ "$newcount" = 0 ]; then echo "  $u ($role): nothing new"; skipped=$((skipped+1)); continue; fi
  if [ "$DRY" = 1 ]; then echo "  $u ($role): would add $newcount grant(s)"; continue; fi
  if "$ONECLI" agents set-secrets --id "$aid" --secret-ids "$union" >/dev/null 2>&1; then
    c_ok "  $u ($role): +$newcount grant(s)"; added=$((added+newcount))
  else
    c_no "  $u ($role): bind FAILED"; failed=$((failed+1))
  fi
done

c_hd "summary"
echo "  grants added: $added   tenants already complete: $skipped   failures: $failed"
[ "$failed" = 0 ] || exit 1
