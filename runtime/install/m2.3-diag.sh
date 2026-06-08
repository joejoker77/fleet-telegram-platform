#!/usr/bin/env bash
# Read-only diagnostics for the M2.3 proxy-path failure. Safe to run anytime.
set -uo pipefail
GW="$( . /etc/cl-egress.env 2>/dev/null; echo "${GW:-?}" )"
C=claude-cptest
echo "=== GW = $GW ==="

echo; echo "--- 1) who listens on :10255 (forwarder + onecli) ---"
ss -ltnp 2>/dev/null | grep -E ':10255' || echo "(nothing listening on 10255)"

echo; echo "--- 2) forwarder service state ---"
systemctl is-active cl-egress-forwarder 2>&1
systemctl status cl-egress-forwarder --no-pager -l 2>&1 | sed -n '1,10p'

echo; echo "--- 3) HOST -> forwarder (isolates forwarder->onecli; expect 4xx) ---"
curl -sS -m6 -o /dev/null -w 'host->fwd http=%{http_code}\n' -x "http://$GW:10255" https://api.anthropic.com/v1/messages 2>&1 || echo "host->fwd FAILED"

echo; echo "--- 4) CONTAINER -> forwarder (verbose; refused vs timeout is the key signal) ---"
podman exec "$C" curl -v -m8 -x "http://$GW:10255" https://api.anthropic.com/v1/messages 2>&1 | tail -15 || true

echo; echo "--- 5) CONTAINER -> gateway:10255 raw reachability ---"
podman exec "$C" sh -c "timeout 5 sh -c 'echo > /dev/tcp/$GW/10255' && echo OPEN || echo CLOSED" 2>&1 || echo "(probe n/a)"

echo; echo "--- 6) cl_egress table (rules; counters if present) ---"
nft list table inet cl_egress 2>&1

echo; echo "--- 7) host input/forward chains + policies (names/policies only, not full perimeter) ---"
nft list ruleset 2>/dev/null | grep -E 'table |chain |type filter hook (input|forward)|policy (drop|accept)' | head -50
