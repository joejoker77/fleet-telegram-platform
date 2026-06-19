#!/usr/bin/env bash
# DEPRECATED 2026-06-10 (ADR-004): deploy-time gating removed. The scan-mcp-config
# logic is retained for the M5 publish boundary; this standalone gate is reference.
# fleet MCP install gate — scans every mcpServers stanza in a settings.json
# through the L4 scanner + cp-judge. Exit 0 = all pass (safe to apply), non-zero
# = at least one blocked / judge error (do NOT apply).
#
# WIRING (the one-liner the operator adds to deploy-mcp, scoped per tenant):
#   after deploy-mcp renders the CANDIDATE settings.json (before it replaces the
#   live one), for a given user <user>:
#       <repo>/control-plane/install/m4.2-mcp-gate.sh <candidate.json> <user> \
#         || { echo "MCP gate blocked the change"; exit 1; }
#   so a malicious/ambiguous MCP never reaches the live settings.json.
#
# Runs the scan inside the cp runtime container (has node + the workspace +
# cp-audit-run volume + host net to reach cp-judge:8090). Run as root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
REPO="$ROOT/control-plane"
NODE_IMAGE=docker.io/library/node:22-alpine

SETTINGS="${1:-}"
ACTOR="${2:-mcp-gate}"
[ -n "$SETTINGS" ] || { echo "usage: m4.2-mcp-gate.sh <settings.json> [actor]" >&2; exit 64; }
[ -f "$SETTINGS" ] || { echo "no such settings file: $SETTINGS" >&2; exit 64; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
curl -sf http://127.0.0.1:8090/healthz >/dev/null 2>&1 || { echo "cp-judge not up on :8090" >&2; exit 3; }

# Mount the settings file read-only into the container at a fixed path.
podman run --rm --network host \
  --workdir "$REPO" -v "$REPO:$REPO:ro" -v cp-audit-run:/run/audit \
  -v "$SETTINGS:/tmp/candidate-settings.json:ro" \
  "$NODE_IMAGE" \
  sh -c 'set -e; export JUDGE_URL=http://127.0.0.1:8090 AUDIT_SOCKET=/run/audit/collector.sock;
    exec node_modules/.bin/tsx packages/scanners/src/scan-mcp-config.ts /tmp/candidate-settings.json '"$ACTOR"
