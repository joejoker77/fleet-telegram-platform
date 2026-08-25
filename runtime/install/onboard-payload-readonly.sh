#!/usr/bin/env bash
# onboard-payload-readonly.sh — Tom enters the READ-ONLY Payload API key; this stores
# it and gives it to the non-admin tenants. The admins' existing full-access key is
# not touched.
#
# The key never reaches anyone's chat: it is typed here (hidden), validated against
# the live CMS, and put in the OneCLI vault. The egress proxy injects it afterwards,
# so no Claude process ever sees the value.
#
# WHY THIS SCRIPT REFUSES SOME KEYS. The existing admin key can create, update and
# delete in all 23 collections, including client chat sessions. If that key were
# entered here by mistake, every non-admin bot on the platform would get full control
# of the chatbot database. So the script asks the CMS what the key is allowed to do
# and stops if it can write anywhere. It is not a formality — it is the whole point.
#
# WHEN PAYLOAD CANNOT EXPRESS READ-ONLY (added 2026-08-24, at Tom's request after the
# CMS developer reported he cannot make certain internal collections read-only).
# --tolerate-writes takes an explicit, named list of collections whose write permissions
# are accepted knowingly. Everything outside that list is still refused, and writes on the
# client-data collections are refused even if named — those are not Tom's to trade away in
# a shell prompt. There is deliberately no flag that accepts "whatever this key can do":
# the value of this script is that somebody has to read the list and say yes to it.
#
#   sudo ./onboard-payload-readonly.sh              # store and distribute
#   sudo ./onboard-payload-readonly.sh --check-only # just test a key, store nothing
#   sudo ./onboard-payload-readonly.sh --tolerate-writes internal-a,internal-b
#
set -uo pipefail
ONECLI=/usr/local/bin/onecli
export HOME=/root
HOST=chatbot.monacosolicitors.co.uk
NAME=ms-payload-read
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MATRIX="${ROLE_MATRIX_JSON:-$HERE/role-matrix.json}"
CHECK_ONLY=0
TOLERATE=""
# Collections holding client personal data. Used twice: a warning if the key can READ them,
# and a hard refusal — not overridable — if it can WRITE them.
CLIENT_DATA="sessions session-messages session-messages-ocr-archive users users-media claims emails subscriptions users-subscriptions atj-deals"
while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --tolerate-writes) shift; TOLERATE="${1:-}"; [ -n "$TOLERATE" ] || { echo "--tolerate-writes needs a comma-separated list" >&2; exit 2; } ;;
    --tolerate-writes=*) TOLERATE="${1#*=}" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
TOLERATE="$(printf '%s' "$TOLERATE" | tr ',' ' ' | tr -s ' ')"

c_ok(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_no(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_hd(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v "$ONECLI" >/dev/null || die "onecli not found"
"$ONECLI" auth status >/dev/null 2>&1 || die "onecli not authenticated"
[ -f "$MATRIX" ] || die "role-matrix.json not found at $MATRIX"

c_hd "Payload CMS — read-only key for non-admin tenants"
cat <<'TXT'
Create the key in Payload as a user whose role is read-only, with "enable API key"
switched on, then paste it below. Nothing is stored until it passes the checks.
TXT

read -rsp "  Payload READ-ONLY API key: " K; echo
K="$(printf '%s' "$K" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$K" ] || die "nothing entered"
printf '    received %d chars, %s…%s\n' "${#K}" "${K:0:3}" "${K: -4}"

c_hd "1. does the key work at all?"
CODE="$(curl -sS -o /tmp/.pl.$$ -w '%{http_code}' -m 25 \
        -H "Authorization: users API-Key $K" "https://$HOST/api/access" 2>/dev/null || echo 000)"
[ "$CODE" = 200 ] || { c_no "  /api/access returned $CODE — not a working Payload API key"; rm -f /tmp/.pl.$$; exit 1; }
c_ok "  /api/access -> 200"

c_hd "2. is it really read-only?"
python3 - /tmp/.pl.$$ <<'PY' > /tmp/.plsum.$$ || { c_no "  could not read the permission map"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
cols = d.get("collections", {}) or {}
def allowed(v):
    return bool(v.get("permission")) if isinstance(v, dict) else bool(v)
writes, reads = [], []
for name, p in sorted(cols.items()):
    p = p or {}
    w = [o for o in ("create", "update", "delete") if allowed(p.get(o))]
    if w: writes.append(f"{name}:{','.join(w)}")
    if allowed(p.get("read")): reads.append(name)
print("WRITES=" + ";".join(writes))
print("READS=" + ";".join(reads))
PY
WRITES="$(sed -n 's/^WRITES=//p' /tmp/.plsum.$$)"
READS="$(sed -n 's/^READS=//p' /tmp/.plsum.$$)"
rm -f /tmp/.pl.$$ /tmp/.plsum.$$

if [ -n "$WRITES" ]; then
  # Sort what the key can write into three buckets: client data (never allowed), named on
  # --tolerate-writes (allowed after a typed confirmation), and everything else (refused).
  PROTECTED=""; TOLERATED=""; UNEXPECTED=""
  for e in $(printf '%s' "$WRITES" | tr ';' '\n'); do
    n="${e%%:*}"
    case " $CLIENT_DATA " in *" $n "*) PROTECTED="$PROTECTED $e"; continue ;; esac
    case " $TOLERATE " in *" $n "*) TOLERATED="$TOLERATED $e" ;; *) UNEXPECTED="$UNEXPECTED $e" ;; esac
  done

  if [ -n "$PROTECTED" ]; then
    c_no "  REFUSED — this key can WRITE to collections holding client personal data."
    printf '    %s\n' $PROTECTED
    echo
    echo "  This is refused outright and --tolerate-writes does not override it. A key that"
    echo "  can modify client chat sessions or claims would be handed to every non-admin bot,"
    echo "  and from there to whoever is driving that bot. If the CMS genuinely cannot make"
    echo "  these read-only, that is a decision for the firm and its DPO, not for this prompt."
    exit 1
  fi

  if [ -n "$UNEXPECTED" ]; then
    c_no "  REFUSED — this key can WRITE where it was not expected to. Nothing was stored."
    echo "  It can create/update/delete in:"
    printf '    %s\n' $UNEXPECTED
    echo
    echo "  This looks like the administrators' key, or a role that is not read-only."
    echo "  Storing it here would give every non-admin bot control of those collections."
    echo "  Either narrow the role in Payload, or — if these specific collections genuinely"
    echo "  cannot be made read-only — re-run naming them explicitly:"
    echo
    echo "    sudo $0 --tolerate-writes $(printf '%s' "$UNEXPECTED" | tr ' ' '\n' | sed 's/:.*//' | grep . | paste -sd, -)"
    exit 1
  fi

  c_no "  this key is NOT read-only. It can write to the collections you named:"
  printf '    %s\n' $TOLERATED
  echo
  echo "  Every non-admin bot will be able to create/update/delete there, and so will the"
  echo "  person driving it. Nothing outside this list is writable, and no client-data"
  echo "  collection is. Storing it is a deliberate exception, not a read-only key."
  read -rp "  Type ACCEPT-WRITES to store it anyway, anything else to abort: " aw
  [ "$aw" = ACCEPT-WRITES ] || { echo "  aborted, nothing stored"; exit 1; }
else
  c_ok "  read-only confirmed: no create/update/delete anywhere"
fi

READ_N="$(printf '%s' "$READS" | tr ';' '\n' | grep -c . || true)"
echo "  it can read $READ_N collection(s):"
printf '%s' "$READS" | tr ';' '\n' | sed 's/^/    /'

c_hd "3. does it reach client personal data?"
SENSITIVE=""
for c in $CLIENT_DATA; do
  case ";$READS;" in *";$c;"*) SENSITIVE="$SENSITIVE $c";; esac
done
if [ -n "$SENSITIVE" ]; then
  c_no "  this key can read collections holding CLIENT PERSONAL DATA:"
  printf '   %s\n' $SENSITIVE
  echo
  echo "  Every non-admin bot — and so the person driving it — would be able to read"
  echo "  those. If that is not intended, narrow the read-only role in Payload to the"
  echo "  content collections (pages, pages-categories, quick-responses, assistants)"
  echo "  and run this again."
  read -rp "  Type ACCEPT to store it anyway, anything else to abort: " a
  [ "$a" = ACCEPT ] || { echo "  aborted, nothing stored"; exit 1; }
else
  c_ok "  no client-data collections readable — content only"
fi

[ "$CHECK_ONLY" = 1 ] && { c_hd "--check-only: nothing stored"; exit 0; }

c_hd "4. store in the vault"
SID="$("$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s['name']=='$NAME': print(s['id'])" 2>/dev/null || true)"
if [ -n "$SID" ]; then
  read -rp "  $NAME already exists — replace it? [y/N]: " r
  [ "$r" = y ] || [ "$r" = Y ] || { echo "  kept the existing one, nothing changed"; exit 0; }
  "$ONECLI" secrets delete --id "$SID" >/dev/null 2>&1 || true
fi
"$ONECLI" secrets create --name "$NAME" --type generic --value "$K" \
  --host-pattern "$HOST" --header-name Authorization --value-format 'users API-Key {value}' >/dev/null \
  || die "vault create failed"
unset K
SID="$("$ONECLI" secrets list 2>/dev/null | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s['name']=='$NAME': print(s['id'])")"
[ -n "$SID" ] || die "secret not found after create"
c_ok "  stored as $NAME"

c_hd "5. give it to the read-scoped tenants"
ALLOWED="$(python3 - "$MATRIX" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(" ".join(r for r, s in m["services"]["payload"]["roles"].items() if s == "read"))
PY
)"
echo "  roles with scope read: [${ALLOWED:-none}]"
bound=0
for f in /etc/claude-role/*; do
  [ -f "$f" ] || continue
  u="$(basename "$f")"; role="$(tr -d ' \t\r\n' <"$f")"
  case " $ALLOWED " in *" $role "*) ;; *) continue;; esac
  aid="$("$ONECLI" agents list 2>/dev/null | python3 -c "
import json,sys
for a in json.load(sys.stdin):
    if a.get('identifier')=='${u}-bot': print(a['id'])")"
  [ -n "$aid" ] || { echo "   - $u: no agent, skipped"; continue; }
  if "$ONECLI" agents grant-secret --id "$aid" --secret-id "$SID" >/dev/null 2>&1 \
     || "$ONECLI" agents grant --id "$aid" --secret-id "$SID" >/dev/null 2>&1; then
    echo "   - $u ($role) ok"; bound=$((bound+1))
  else
    c_no "   - $u ($role) bind FAILED"
  fi
done
c_ok "  bound to $bound tenant(s)"

c_hd "Done"
echo "Admins keep their existing full-access key; nothing about it changed."
echo "Verify from any non-admin pod:"
echo "  podman exec claude-<tenant> curl -s -o /dev/null -w '%{http_code}\\n' https://$HOST/api/pages?limit=1"
