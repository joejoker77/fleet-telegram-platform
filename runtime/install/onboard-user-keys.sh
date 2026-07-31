#!/usr/bin/env bash
# onboard-user-keys.sh — collect, VALIDATE and vault the PER-USER firm service keys for
# tenants that already exist. The companion to onboard-integrations.sh:
#
#   onboard-integrations.sh  -> services with ONE shared firm key (Supabase, Payload, Rota,
#                               Strapi, n8n, Xero, Exa, Composio)
#   onboard-user-keys.sh     -> services where every user has their OWN key
#
# Which services land here is decided by key_type=per_user in role-matrix.json, and who is
# offered each one by that service's roles — the same single source of truth the tenant
# CLAUDE.md and the vault bindings come from. Flipping a service between shared and per-user
# is a matrix edit; this script needs no change.
#
# add-user.sh already asks for these when onboarding a NEW tenant. This script exists for
# tenants who are already set up (e.g. the whole first wave was created before the keys were
# available), so nobody has to be re-provisioned just to add a key.
#
# The Claude process never sees these keys: they go into the OneCLI vault and the egress proxy
# injects the right header on that service's host. A tenant does NOT need to be logged in.
#
#   sudo ./onboard-user-keys.sh                 # every tenant, every per-user service
#   sudo ./onboard-user-keys.sh --user <login>   # just one person
#   sudo ./onboard-user-keys.sh --service pipedrive   # just one service
set -uo pipefail
ONECLI=/usr/local/bin/onecli
export HOME=/root
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MATRIX="${ROLE_MATRIX_JSON:-$HERE/role-matrix.json}"

c_ok(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_no(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_hd(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ONLY_USER=""; ONLY_SVC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user) ONLY_USER="${2:?--user needs a login}"; shift ;;
    --service) ONLY_SVC="${2:?--service needs a service}"; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac; shift
done

[ "$(id -u)" -eq 0 ] || die "run as root (ssh root@host)"
command -v "$ONECLI" >/dev/null || die "onecli not found"
"$ONECLI" auth status >/dev/null 2>&1 || die "onecli not authenticated"
command -v curl >/dev/null || die "curl required for validation"
[ -f "$MATRIX" ] || die "role-matrix.json not found at $MATRIX"

ask_secret(){ local v; read -rsp "  $1: " v; echo >&2; printf '%s' "$v"; }
http_code(){ local m="$1" url="$2"; shift 2; local args=(-sS -o /dev/null -w '%{http_code}' -m 20 -X "$m")
  while [ $# -gt 0 ]; do args+=(-H "$1"); shift; done
  curl "${args[@]}" "$url" 2>/dev/null || echo 000; }
secret_exists(){ "$ONECLI" secrets list 2>/dev/null | grep -q "\"name\"[: ]*\"$1\""; }

# per-user services from the matrix: "service<TAB>space-separated roles"
per_user_services(){
  python3 - "$MATRIX" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for s in m["service_order"]:
    spec = m["services"][s]
    if spec.get("key_type") != "per_user":
        continue
    roles = " ".join(r for r in m["role_order"] if r in spec.get("roles", {}))
    print("\t".join([s, roles]))
PY
}

# stage+bind one key for one tenant, using the generic vault helper
bind_key(){ # $1 user  $2 secret-suffix  $3 host  $4 header  $5 format  $6 value
  KV_USER="$1" KV_VALUE="$6" bash "$HERE/m-key-vault.sh" "$2" "$3" "$4" "$5" >/tmp/kv-$1-$2.log 2>&1 \
    && c_ok "    ✓ vaulted ${1}-$2 and bound to ${1}-bot" \
    || { c_no "    vault/bind FAILED — see /tmp/kv-$1-$2.log"; tail -3 "/tmp/kv-$1-$2.log"; }
}

# ---- per-service definition: how to validate, and how to inject ----------------
# host / header / value-format must match what the service expects at runtime, because the
# proxy replays exactly this on every outbound request.
svc_prompt(){ case "$1" in
  pipedrive)  echo "Pipedrive personal API token (Settings -> Personal preferences -> API)";;
  openrouter) echo "OpenRouter API key (sk-or-v1-...)";;
  *)          echo "API key for $1";; esac; }
svc_host(){ case "$1" in
  pipedrive)  echo "monacosolicitors2.pipedrive.com";;
  openrouter) echo "openrouter.ai";;
  *)          echo "";; esac; }
svc_suffix(){ case "$1" in
  pipedrive)  echo "pipedrive";;
  openrouter) echo "openrouter-api";;
  *)          echo "$1";; esac; }

# svc_resolve <service> <key> — validate against the LIVE service and echo
# "header|format|observed-codes" (header/format empty when the key is refused). The header
# must be the one the API actually accepted, since the proxy replays exactly that on every
# request. Mirrors onboard-integrations.sh: Pipedrive personal API tokens authenticate via
# x-api-token on the v2 API, OAuth access tokens via Authorization: Bearer — so try
# x-api-token first and fall back rather than assuming one of them (assuming v1 +
# x-api-token is what made this script reject perfectly good tokens).
# NB: the codes travel in the echoed string, not a variable — this runs inside a command
# substitution, so a global assignment here would be lost with the subshell.
svc_resolve(){
  local svc="$1" key="$2" H c1 c2 c3
  case "$svc" in
    pipedrive)
      H="$(svc_host pipedrive)"
      c1="$(http_code GET "https://$H/api/v2/users/me"      "x-api-token: $key")"
      c2="$(http_code GET "https://$H/api/v2/deals?limit=1" "x-api-token: $key")"
      if [ "$c1" = 200 ] || [ "$c2" = 200 ]; then echo "x-api-token|{value}|users/me=$c1 deals=$c2"; return 0; fi
      c3="$(http_code GET "https://$H/api/v2/users/me" "Authorization: Bearer $key")"
      if [ "$c3" = 200 ]; then echo "Authorization|Bearer {value}|bearer=$c3"; return 0; fi
      echo "||users/me=$c1 deals=$c2 bearer=$c3"; return 1 ;;
    openrouter)
      c1="$(http_code GET "https://openrouter.ai/api/v1/key" "Authorization: Bearer $key")"
      if [ "$c1" = 200 ]; then echo "Authorization|Bearer {value}|key=$c1"; return 0; fi
      echo "||key=$c1"; return 1 ;;
    *) echo "||no validator for $svc"; return 1 ;;
  esac
}

# ---- main ---------------------------------------------------------------------
c_hd "Per-user firm service keys (availability by role-matrix.json)"
echo "Each user has their OWN key for these services. Keys are validated against the live"
echo "service before being stored, and go straight into the vault — never a file, and the"
echo "assistant never sees them. Press Enter at any prompt to skip that one."
echo
echo "Tenants on this host:"
for f in /etc/claude-role/*; do
  [ -f "$f" ] || continue
  echo "  $(basename "$f") = $(tr -d ' \t\r\n' <"$f")"
done

processed=0
while IFS="$(printf '\t')" read -r svc roles <&3; do
  [ -n "${svc:-}" ] || continue
  [ -z "$ONLY_SVC" ] || [ "$ONLY_SVC" = "$svc" ] || continue
  host="$(svc_host "$svc")"
  if [ -z "$host" ]; then c_no "no host mapping for '$svc' — add one to this script; skipped"; continue; fi

  c_hd "$svc  (roles: $roles)"
  for f in /etc/claude-role/*; do
    [ -f "$f" ] || continue
    u="$(basename "$f")"; r="$(tr -d ' \t\r\n' <"$f")"
    [ -z "$ONLY_USER" ] || [ "$ONLY_USER" = "$u" ] || continue
    case " $roles " in *" $r "*) ;; *) continue;; esac   # role not entitled -> never asked

    name="${u}-$(svc_suffix "$svc")"
    if secret_exists "$name"; then echo "  $u ($r): already has $name — skipping"; continue; fi

    echo "  $u ($r):"
    K="$(ask_secret "$(svc_prompt "$svc") for $u")"
    if [ -z "$K" ]; then echo "    skipped"; continue; fi
    hf="$(svc_resolve "$svc" "$K")" || true
    hdr="$(printf '%s' "$hf" | cut -d'|' -f1)"
    fmt="$(printf '%s' "$hf" | cut -d'|' -f2)"
    why="$(printf '%s' "$hf" | cut -d'|' -f3)"
    if [ -n "$hdr" ]; then
      c_ok "    key valid (via $hdr)"
      bind_key "$u" "$(svc_suffix "$svc")" "$host" "$hdr" "$fmt" "$K"
      processed=$((processed+1))
    else
      c_no "    REFUSED by $svc — nothing stored for $u  [$why]"
      case "$svc" in
        pipedrive)  echo "      use a personal API token from Settings -> Personal preferences -> API of the $host account";;
        openrouter) echo "      the key must start sk-or-v1- and belong to an active OpenRouter account";;
      esac
    fi
    unset K
  done
done 3< <(per_user_services)

c_hd "done"
echo "keys stored this run: $processed"
echo "Nothing else is needed for these to work — the proxy injects them on the next request."
echo "A tenant does not have to be logged in for the binding to exist."
