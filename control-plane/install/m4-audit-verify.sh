#!/usr/bin/env bash
# M4 / WP2 — verify the tamper-resistant audit (docs 09 criterion #4). Run as root.
# Four checks, all NON-DESTRUCTIVE (the tamper test runs against a COPY, never the
# real WORM chain):
#   1. chain integrity — verify.ts over the real /srv/audit → "chain OK".
#   2. usage.turn metering — the M4#2 Stop hook is landing events (WORM + usage_records).
#   3. tamper detection — mutate one record in a COPY → verify.ts → "CHAIN BROKEN".
#   4. WORM attr — /srv/audit is append-only (chattr +a) and tenant-unreadable.
set -uo pipefail

REPO=/home/vitaliy/work/fleet-platform/control-plane
NODE_IMAGE=docker.io/library/node:22-alpine
AUDIT=/srv/audit
log() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -d "$AUDIT" ] || { echo "no $AUDIT" >&2; exit 1; }

verify_dir() {  # <hostdir> — run verify.ts against a dir mounted into a throwaway container
  podman run --rm -v "$REPO:$REPO:ro" -v "$1:/audit:ro" --workdir "$REPO" "$NODE_IMAGE" \
    sh -c 'AUDIT_DIR=/audit exec node_modules/.bin/tsx apps/audit-collector/src/verify.ts'
}

# 1) real chain integrity
log "1. chain integrity (real /srv/audit)"
verify_dir "$AUDIT"; rc1=$?
echo "  verify exit=$rc1 (0 = chain OK)"

# 2) usage.turn metering present?
log "2. usage.turn metering (M4#2 Stop hook landing?)"
ut=$(grep -ho '"kind":"usage.turn"' "$AUDIT"/audit-*.log 2>/dev/null | wc -l)
echo "  usage.turn events in WORM: $ut"
rows=$(podman exec cp-postgres psql -U cplane -d control_plane -tAc \
  "select count(*) from usage_records;" 2>/dev/null | tr -d '[:space:]')
echo "  usage_records rows in PG: ${rows:-?}"
[ "${ut:-0}" -gt 0 ] && echo "  ✓ metering is landing" || echo "  ⚠ no usage.turn yet (turn a few times so the Stop hook fires)"

# 3) tamper detection on a COPY (real chain untouched)
log "3. tamper detection (on a copy)"
TMP=/tmp/audit-tamper.$$
cp -r "$AUDIT" "$TMP"
last=$(ls "$TMP"/audit-*.log 2>/dev/null | sort | tail -1)
if [ -n "$last" ]; then
  python3 - "$last" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()
if lines:
    # flip a character inside the middle record's payload to simulate tampering
    i = len(lines) // 2
    l = lines[i]
    j = max(0, len(l) // 2)
    lines[i] = l[:j] + ("X" if l[j:j+1] != "X" else "Y") + l[j+1:]
    open(p, "w").write("\n".join(lines) + "\n")
    print(f"  tampered record {i} in {p.split('/')[-1]}")
PY
  verify_dir "$TMP"; rc3=$?
  echo "  verify exit=$rc3 (NON-zero = tamper DETECTED ✓)"
else
  echo "  no audit log files to tamper-test"
fi
rm -rf "$TMP"

# 4) WORM attr + tenant cannot read
log "4. WORM (append-only) attribute"
lsattr -d "$AUDIT" 2>/dev/null | sed 's/^/  /' || echo "  (lsattr unavailable)"
echo "  (expect an 'a' flag = append-only; tenants have write-only socket access, never read of $AUDIT)"

echo
echo "== M4/WP2 audit verification done. Expect: (1) chain OK, (2) usage.turn>0, (3) tamper DETECTED, (4) append-only set. =="
