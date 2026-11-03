#!/usr/bin/env bash
# set-tenant-role.sh <login> <role> — move an EXISTING tenant to another role.
#
#   sudo ./set-tenant-role.sh hope-moir starter
#   sudo ./set-tenant-role.sh hope-moir starter --dry-run
#
# WHY THIS EXISTS, AND WHY rebind-shared-secrets.sh IS NOT IT. That script is deliberately
# additive: it only ever ADDS the grants a role is entitled to, so it can be re-run over the
# whole fleet without stripping a binding somebody made on purpose. That is exactly wrong for
# a DOWNGRADE, which is mostly about taking access away. A tenant moved from `basic` to
# `starter` keeps a live Supabase, Payload and Dialpad key until something revokes it.
#
# So this sets the tenant's shared (`ms-*`) grants to EXACTLY what role-matrix.json says, and
# does the same for the two database gateways, whose entitlement is a token file rather than a
# vault binding. Four things change together, and the matrix decides all four:
#
#   1. /etc/claude-role/<login>            — what every other script reads
#   2. the managed block of their CLAUDE.md — the "Your access" table they actually follow
#   3. the vault grants on agent <login>-bot — set, not merged: extras are revoked
#   4. the cp-dbread / cp-grapple tokens    — granted or revoked to match
#
# A tenant's OWN keys (`<login>-mcp-*`, e.g. their personal Pipedrive token) are never touched:
# they are the tenant's property, not a firm binding. If the new role is not entitled to that
# service the key is reported, loudly, for a human to decide about.
#
# The tenant's pod reads CLAUDE.md at session start, so the new access block takes effect on
# their next session. The vault change is immediate: the proxy stops injecting at once.
set -uo pipefail
ONECLI=/usr/local/bin/onecli
export HOME=/root
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RT="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$RT/.." && pwd)"
MATRIX="${ROLE_MATRIX_JSON:-$HERE/role-matrix.json}"
SKEL="${SKEL:-$HERE/tenant-skel}"

c_ok(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_no(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_hd(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

USER_NAME="${1:-}"; NEW_ROLE="${2:-}"; DRY=0
[ -n "$USER_NAME" ] && [ -n "$NEW_ROLE" ] || die "usage: set-tenant-role.sh <login> <role> [--dry-run]"
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac; shift
done
[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f "$MATRIX" ] || die "role-matrix.json not found at $MATRIX"
[ -d "/home/$USER_NAME" ] || die "no such tenant: /home/$USER_NAME"
[ -f "/etc/claude-role/$USER_NAME" ] || die "$USER_NAME has no role file — is it a provisioned tenant?"

# The matrix is the list of roles that exist. A typo must not create a role by accident:
# every script downstream would then treat the tenant as entitled to nothing, silently.
python3 - "$MATRIX" "$NEW_ROLE" <<'PY' || die "unknown role: see role_order in role-matrix.json"
import json, sys
m = json.load(open(sys.argv[1]))
sys.exit(0 if sys.argv[2] in m.get("role_order", []) else 1)
PY

OLD_ROLE="$(tr -d ' \t\r\n' < "/etc/claude-role/$USER_NAME")"
c_hd "$USER_NAME: $OLD_ROLE -> $NEW_ROLE${DRY:+ (dry run)}"
[ "$OLD_ROLE" = "$NEW_ROLE" ] && echo "  already on that role; re-applying anyway (idempotent)"

# ── what each role may reach, for the report ────────────────────────────────
svcs_for(){ python3 - "$MATRIX" "$1" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); role = sys.argv[2]
print(" ".join("%s:%s" % (s, m["services"][s]["roles"][role])
               for s in m["service_order"]
               if role in m["services"].get(s, {}).get("roles", {})))
PY
}
echo "  was: $(svcs_for "$OLD_ROLE")"
echo "  now: $(svcs_for "$NEW_ROLE")"

role_entitled(){ python3 - "$MATRIX" "$1" "$2" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
sys.exit(0 if sys.argv[2] in m.get("services", {}).get(sys.argv[3], {}).get("roles", {}) else 1)
PY
}

# ── 1. the role file ─────────────────────────────────────────────────────────
c_hd "1/4  role file"
if [ "$DRY" = 1 ]; then echo "  would write $NEW_ROLE to /etc/claude-role/$USER_NAME"
else printf '%s\n' "$NEW_ROLE" > "/etc/claude-role/$USER_NAME"; c_ok "  /etc/claude-role/$USER_NAME = $NEW_ROLE"; fi

# ── 2. the managed block of their CLAUDE.md ─────────────────────────────────
# Same construction as provision-tenant.sh, and only the marked block is replaced, so
# anything the tenant wrote outside the markers survives.
c_hd "2/4  tenant guide (the access block they actually follow)"
CMD_OUT="/home/$USER_NAME/.claude/CLAUDE.md"
if [ ! -f "$CMD_OUT" ]; then
  c_no "  $CMD_OUT missing — run provision-tenant.sh for this tenant instead"
elif ! grep -q 'BEGIN MANAGED (provision-tenant)' "$CMD_OUT"; then
  c_no "  $CMD_OUT has no managed markers — not rewriting it by hand; re-provision instead"
else
  MANAGED_TMP="$(mktemp)"
  {
    echo "<!-- BEGIN MANAGED (provision-tenant) — regenerated each run; do NOT edit between these markers. Put your own notes OUTSIDE them. -->"
    sed "s#__TENANT_USER__#$USER_NAME#g; s#__TENANT_HOME__#/home/$USER_NAME#g" "$SKEL/CLAUDE.md.baseline"
    echo; bash "$HERE/render-access-block.sh" "$NEW_ROLE"
    if [ "$NEW_ROLE" = admin ]; then echo; cat "$SKEL/host-admin.md.snippet"; fi
    echo "<!-- END MANAGED (provision-tenant) -->"
  } > "$MANAGED_TMP"
  if [ "$DRY" = 1 ]; then
    echo "  would replace the managed block ($(wc -l < "$MANAGED_TMP") lines)"
  else
    MANAGED_TMP="$MANAGED_TMP" python3 - "$CMD_OUT" <<'PY'
import os, re, sys
target = sys.argv[1]
new = open(os.environ["MANAGED_TMP"]).read().strip()
cur = open(target).read()
pat = re.compile(r"<!-- BEGIN MANAGED \(provision-tenant\).*?<!-- END MANAGED \(provision-tenant\) -->", re.S)
open(target, "w").write(pat.sub(lambda _m: new, cur, count=1))
PY
    chown "$USER_NAME:$USER_NAME" "$CMD_OUT"; chmod 0644 "$CMD_OUT"
    c_ok "  managed block rewritten for role $NEW_ROLE"
  fi
  rm -f "$MANAGED_TMP"
fi

# ── 3. vault grants — SET, not merged ───────────────────────────────────────
c_hd "3/4  vault grants (set to exactly what the matrix allows)"
svc_of(){ case "$1" in
  ms-supabase|ms-supabase-auth)             echo "supabase rw";;
  ms-supabase-stage|ms-supabase-stage-auth) echo "supabase rw";;
  ms-payload)                               echo "payload rw";;
  ms-payload-read)                          echo "payload read";;
  ms-wordpress)                             echo "rota";;
  ms-strapi)                                echo "strapi";;
  ms-n8n-cloud|ms-n8n-selfhosted)           echo "n8n";;
  ms-exa-api)                               echo "exa";;
  ms-composio-api|ms-composio-mcp)          echo "composio";;
  ms-elevenlabs-api)                        echo "elevenlabs";;
  ms-xero-client|ms-xero-api)               echo "xero";;
  ms-dialpad-api)                           echo "dialpad";;
  *)                                        echo "";; esac; }
roles_for(){ python3 - "$MATRIX" "$1" "${2:-}" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
svc, scope = sys.argv[2], sys.argv[3]
roles = m.get("services", {}).get(svc, {}).get("roles", {})
print(" ".join(r for r in m.get("role_order", []) if r in roles and (not scope or roles[r] == scope)))
PY
}
agent_id(){ "$ONECLI" agents list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('data',d) if isinstance(d,dict) else d
print(next((a['id'] for a in r if a.get('identifier')=='$1'),''))"; }

if ! "$ONECLI" auth status >/dev/null 2>&1; then
  c_no "  onecli not authenticated — grants NOT changed. Re-run this script once it is."
else
  AID="$(agent_id "${USER_NAME}-bot")"
  if [ -z "$AID" ]; then
    c_no "  no agent ${USER_NAME}-bot in the vault — grants not changed"
  else
    SECRETS="$("$ONECLI" secrets list 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin); r=d.get("data",d) if isinstance(d,dict) else d
for s in r:
    n = str(s.get("name",""))
    if n.startswith("ms-"): print("%s\t%s" % (s.get("id"), n))')"
    have="$("$ONECLI" agents secrets --id "$AID" 2>/dev/null | python3 -c '
import json,sys
try: print(" ".join(json.load(sys.stdin)))
except Exception: pass')"
    want=""; keep_names=""; drop_names=""
    while IFS="$(printf '\t')" read -r sid sname <&3; do
      [ -n "${sid:-}" ] || continue
      spec="$(svc_of "$sname")"
      if [ -z "$spec" ]; then
        # An ms-* secret this script does not know about. Keep whatever the tenant already has
        # rather than revoking something a newer onboarding step bound deliberately.
        case " $have " in *" $sid "*) want="$want $sid"; keep_names="$keep_names $sname(unmapped)";; esac
        continue
      fi
      set -- $spec; svc="$1"; scope="${2:-}"
      allowed="$(roles_for "$svc" "$scope")"
      if case " $allowed " in *" $NEW_ROLE "*) true;; *) false;; esac; then
        want="$want $sid"; keep_names="$keep_names $sname"
      else
        case " $have " in *" $sid "*) drop_names="$drop_names $sname";; esac
      fi
    done 3<<EOF
$SECRETS
EOF
    echo "  keep:  ${keep_names:-(none)}"
    echo "  REVOKE:${drop_names:-  (none)}"
    csv="$(printf '%s\n' $want | sort -u | tr '\n' ',' | sed 's/,$//')"
    if [ "$DRY" = 1 ]; then
      echo "  would set the grant list to $(printf '%s\n' $want | sort -u | wc -l) secret(s)"
    elif "$ONECLI" agents set-secrets --id "$AID" --secret-ids "$csv" >/dev/null 2>&1; then
      c_ok "  grants set for ${USER_NAME}-bot"
    else
      c_no "  set-secrets FAILED — the tenant still holds the old grants"
    fi
  fi
  # The tenant's own keys are reported, never revoked: they belong to the tenant.
  own="$("$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('data',d) if isinstance(d,dict) else d
print(' '.join(str(s.get('name','')) for s in r if str(s.get('name','')).startswith('$USER_NAME-')))")"
  [ -n "${own// /}" ] && echo "  their own keys (untouched, decide by hand if the new role should not have them):$own"
fi

# ── 4. the two database gateways, whose entitlement is a token file ─────────
c_hd "4/4  database gateways"
gw_sync(){ # $1 service  $2 installer  $3 container  $4 token file
  local svc="$1" inst="$2" cont="$3" tok="$4"
  if [ ! -f "$inst" ]; then echo "  $svc: installer missing — skipped"; return; fi
  if role_entitled "$NEW_ROLE" "$svc"; then
    if [ -f "/home/$USER_NAME/.claude/$tok" ]; then echo "  $svc: already granted"; return; fi
    if [ "$DRY" = 1 ]; then echo "  $svc: would grant"; return; fi
    if ! podman container exists "$cont" 2>/dev/null; then c_no "  $svc: $cont not installed — cannot grant"; return; fi
    bash "$inst" --grant "$USER_NAME" >/dev/null 2>&1 \
      && c_ok "  $svc: granted ($tok)" || c_no "  $svc: grant FAILED — run: $inst --grant $USER_NAME"
  else
    if [ ! -f "/home/$USER_NAME/.claude/$tok" ]; then echo "  $svc: not entitled, nothing held"; return; fi
    if [ "$DRY" = 1 ]; then echo "  $svc: would REVOKE"; return; fi
    bash "$inst" --revoke "$USER_NAME" >/dev/null 2>&1 \
      && c_ok "  $svc: revoked" || c_no "  $svc: revoke FAILED — run: $inst --revoke $USER_NAME"
  fi
}
gw_sync supabase        "$REPO/control-plane/install/m9.1-dbread-gateway.sh"         cp-dbread dbread.token
gw_sync grapple_replica "$REPO/control-plane/install/m9.2-grapple-replica-gateway.sh" cp-grapple grapple.token

c_hd "done"
echo "  $USER_NAME is now role '$NEW_ROLE'."
echo "  Vault changes are live immediately. The new access block is read when their session"
echo "  next starts, so restart the pod if they should see it now:"
echo "    systemctl restart claude-pod@$USER_NAME"
