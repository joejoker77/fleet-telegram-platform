#!/usr/bin/env bash
# Rollback for M3.0-smoke — fully remove the throwaway m3smoke tenant (pod, unit,
# OneCLI agent + token, DB rows, AND the OS account + home, which includes the
# copied plugin cache + Claude OAuth). Run as root. Idempotent. The rebuilt
# runtime image is left in place (the real cutover uses it too).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
RT="$ROOT/runtime"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
echo "== deprovisioning m3smoke (purge user + home incl. copied creds) =="
bash "$RT/install/deprovision-tenant.sh" m3smoke --purge-user
echo "m3-smoke rollback done (runtime image kept; live pilot untouched)"
