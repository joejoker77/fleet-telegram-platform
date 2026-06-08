#!/usr/bin/env bash
# Read-only diagnostic for the M2.4 proxy-auth 000 failure. Isolates whether it's
# the token, the network path, or onecli. Safe to run anytime.
set -uo pipefail
C=claude-cptest
GW="$(podman network inspect cl-net --format json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["subnets"][0]["gateway"])' 2>/dev/null)"
TOK="$(cat /etc/cl-egress/cptest.token 2>/dev/null)"
echo "GW=$GW  token_len=${#TOK}"
U=https://api.anthropic.com/v1/messages

probe() { # label, where(host|cont), proxyurl
  local label="$1" where="$2" px="$3" code
  if [ "$where" = host ]; then
    code=$(curl -m8 -s -o /dev/null -w '%{http_code}' -x "$px" "$U" 2>/dev/null || true)
  else
    code=$(podman exec "$C" curl -m8 -s -o /dev/null -w '%{http_code}' -x "$px" "$U" 2>/dev/null || true)
  fi
  printf '  %-34s -> %s\n' "$label" "$code"
}

echo "--- baseline (no token) ---"
probe "host  -> fwd (no token)"      host "http://$GW:10255"
probe "cont  -> fwd (no token)"      cont "http://$GW:10255"
echo "--- with cptest token ---"
probe "host  -> fwd (token)"         host "http://x:$TOK@$GW:10255"
probe "cont  -> fwd (token)"         cont "http://x:$TOK@$GW:10255"

echo "--- container verbose (token) — see where it breaks ---"
podman exec "$C" curl -v -m8 -o /dev/null -x "http://x:$TOK@$GW:10255" "$U" 2>&1 | grep -iE 'Trying|Connected|CONNECT|Proxy|407|401|refused|timed out|closing|HTTP/' | head -15

echo "--- forwarder + listeners ---"
systemctl is-active cl-egress-forwarder 2>&1
ss -ltnp 2>/dev/null | grep ':10255' || echo "(nothing on 10255)"
echo "--- container networks ---"
podman inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}' "$C" 2>/dev/null
