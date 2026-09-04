#!/usr/bin/env bash
# m8.2-github-read-token.sh — give cp-api READ access to the private marketplace repo.
#
#   sudo bash m8.2-github-read-token.sh          # prompts, hidden input
#   printf %s "$TOK" | sudo bash m8.2-github-read-token.sh --stdin
#   sudo bash m8.2-github-read-token.sh --remove
#
# WHY A SECOND TOKEN. Import fetches the artefact's files from GitHub, and that code was
# written for a PUBLIC marketplace repo — it sent no credential at all, so against the
# firm's private repo every import 404s. The write-capable PAT deliberately lives only in
# the tenant pods, where the OneCLI egress proxy injects it; handing that same token to a
# host-side service would give cp-api the ability to push to the repo, which it has never
# needed. So this takes a SEPARATE, read-only PAT.
#
# Ask Tom for: fine-grained token, repository access limited to the marketplace repo,
# permissions Contents=Read and Metadata=Read. Nothing else — no Pull requests, no write.
#
# The value never reaches argv, a file, or this script's output: it is read on stdin and
# handed straight to `podman secret create`, then mounted into cp-api at
# /run/secrets/cp_github_read_token and read by config.ts via GITHUB_READ_TOKEN_FILE.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
REPO="$REPO_ROOT/control-plane"
SECRET=cp_github_read_token
TOKENS_DIR=/etc/claudeapp/registry
API_PORT=8080
NODE_IMAGE=docker.io/library/node:22-alpine
MODE="${1:-}"

log() { printf '\n== %s ==\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

recreate_cp_api() {  # $1 = "with" | "without"
  local with_secret="$1" extra_secret=() extra_env=""
  if [ "$with_secret" = "with" ]; then
    extra_secret=(--secret "$SECRET")
    extra_env="export GITHUB_READ_TOKEN_FILE=/run/secrets/$SECRET;"
  fi
  local pin_mount=()
  [ -d "$TOKENS_DIR" ] && pin_mount=(-v "$TOKENS_DIR:$TOKENS_DIR:ro")
  podman rm -f cp-api >/dev/null 2>&1 || true
  podman run -d --name cp-api --network host \
    --workdir "$REPO" \
    -v "$REPO:$REPO:ro" \
    -v cp-audit-run:/run/audit \
    -v /run/cp-secretd:/run/cp-secretd \
    -v /home:/home \
    "${pin_mount[@]}" \
    --secret cp_pg_password --secret cp_bot_token --secret cp_jwt_secret \
    --secret cp_github_webhook_secret "${extra_secret[@]}" \
    --restart=always \
    "$NODE_IMAGE" \
    sh -c 'set -e;
      command -v git >/dev/null 2>&1 || apk add --no-cache git >/dev/null 2>&1 || true;
      export HOST=127.0.0.1 PORT='"$API_PORT"' REDIS_URL=redis://127.0.0.1:6380 AUDIT_SOCKET=/run/audit/collector.sock TENANT_HOME_ROOT=/home;
      export TELEGRAM_BOT_TOKEN_FILE=/run/secrets/cp_bot_token JWT_SECRET_FILE=/run/secrets/cp_jwt_secret;
      export GITHUB_WEBHOOK_SECRET_FILE=/run/secrets/cp_github_webhook_secret;
      export TELEGRAM_BOT_USERNAME=;
      export REGISTRY_TOKENS_FILE='"$TOKENS_DIR"'/tokens.json;
      '"$extra_env"'
      export DATABASE_URL="postgres://cplane:$(cat /run/secrets/cp_pg_password)@127.0.0.1:5433/control_plane";
      exec node_modules/.bin/tsx apps/api/src/index.ts' >/dev/null
  local ok=""
  for _ in $(seq 1 40); do
    curl -sf "http://127.0.0.1:$API_PORT/healthz" >/dev/null 2>&1 && { ok=1; break; }
    [ "$(podman inspect -f '{{.State.Status}}' cp-api 2>/dev/null)" = "running" ] \
      || { podman logs --tail 40 cp-api 2>&1; die "cp-api not running"; }
    sleep 1
  done
  [ -n "$ok" ] || { podman logs --tail 40 cp-api 2>&1; die "cp-api did not answer /healthz"; }
  echo "  cp-api healthy"
}

if [ "$MODE" = "--remove" ]; then
  log "removing the read token"
  podman secret rm "$SECRET" >/dev/null 2>&1 || true
  recreate_cp_api without
  echo "  done — import will fail on a private repo again, by design"
  exit 0
fi

log "reading the token"
if [ "$MODE" = "--stdin" ]; then
  IFS= read -r TOKEN || true
else
  read -rsp "  paste the READ-ONLY PAT (input hidden): " TOKEN; echo
fi
[ -n "${TOKEN:-}" ] || die "empty token"
case "$TOKEN" in
  github_pat_*|ghp_*) : ;;
  *) die "that does not look like a GitHub PAT (expected github_pat_… or ghp_…)" ;;
esac

log "checking it can READ the marketplace repo before we install it"
REGISTRY_REPO_NAME="${REGISTRY_REPO:-monacodigital/ClaudeCodeTeam}"
# The token goes to curl through --config on stdin, never in argv: an -H argument would
# be readable in ps by anyone on the box for the life of the request. printf is a bash
# builtin, so it forks nothing that could expose it either.
code=$(printf 'silent\nshow-error\nheader = "Accept: application/vnd.github+json"\nheader = "X-GitHub-Api-Version: 2022-11-28"\nheader = "Authorization: Bearer %s"\nurl = "https://api.github.com/repos/%s"\noutput = "/tmp/ghcheck.json"\nmax-time = 25\nwrite-out = "%%{http_code}"\n' \
  "$TOKEN" "$REGISTRY_REPO_NAME" | curl --config - || echo ERR)
if [ "$code" != "200" ]; then
  echo "  GitHub answered $code for $REGISTRY_REPO_NAME:"
  head -c 300 /tmp/ghcheck.json 2>/dev/null; echo
  rm -f /tmp/ghcheck.json
  die "token cannot read the repo — nothing installed"
fi
echo "  200 OK — repo is readable with this token"
priv=$(python3 -c "import json;print(json.load(open('/tmp/ghcheck.json')).get('private'))" 2>/dev/null || echo "?")
echo "  repo private: $priv"
rm -f /tmp/ghcheck.json

log "storing it as podman secret $SECRET"
podman secret rm "$SECRET" >/dev/null 2>&1 || true
printf '%s' "$TOKEN" | podman secret create "$SECRET" - >/dev/null
unset TOKEN
echo "  stored (never written to a file on disk)"

log "recreating cp-api with the secret mounted"
recreate_cp_api with

log "confirming cp-api picked it up"
podman exec cp-api sh -lc 'test -s /run/secrets/'"$SECRET"' && echo "  secret visible inside cp-api" || echo "  SECRET MISSING"'
code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:$API_PORT/registry/items" || echo ERR)
echo "  /registry/items -> $code (401 expected: route alive, auth required)"

cat <<EOF

== DONE ==
cp-api can now READ $REGISTRY_REPO_NAME. It still cannot write: the write PAT lives only
in the tenant pods, injected by the egress proxy.

Remove again: sudo bash $HERE/m8.2-github-read-token.sh --remove
EOF
