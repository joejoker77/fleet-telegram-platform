# @fleet/miniapp — Telegram Mini App (authoring, M5)

Structured authoring surface over the tenant's `.claude/` sandbox (design doc:
`upgrade/10-authoring-miniapp-ide.md`). M5.2 scaffold scope: **auth → FileTree →
view/edit/diff/save** against the M5.1 fs API. Builders, ScanResults, approvals,
live activity come in later M5 increments.

## How it works

- Opened from Telegram (menu button / inline button pointing at
  `https://miniapp.ai-assistant.gg`).
- `retrieveRawInitData()` (`@telegram-apps/sdk`) → `POST /api/auth/session` —
  the API verifies the initData HMAC against the bot token and issues a JWT
  bound to the tenant (`apps/api/src/initdata.ts`). No tokens in the client
  beyond the short-lived JWT in `sessionStorage`.
- `GET /api/fs/tree`, `GET/PUT /api/fs/file` — the M5.1 sandbox-scoped fs API
  (path-traversal-safe, 1 MiB cap, scanner advisory on write, audited).

## Dev

```sh
pnpm install
pnpm --filter @fleet/miniapp dev        # vite on :5173, /api → 127.0.0.1:8080
MINIAPP_DEV_API=http://other:8080 pnpm --filter @fleet/miniapp dev
```

Real Telegram auth needs the app to be opened from Telegram; in a plain
browser the app shows the "open via the bot" error state by design.

## Build / deploy

```sh
pnpm --filter @fleet/miniapp build      # → apps/miniapp/dist
```

Serve `dist/` as static files on `miniapp.ai-assistant.gg` and reverse-proxy
`/api/` to cp-api — vhost template: `deploy/nginx-miniapp.conf`. The domain is
Cloudflare-proxied; until the vhost exists the origin's default server (n8n)
answers — deploy the vhost before pointing the bot's menu button at it.

The vhost root is `/var/www/miniapp/dist` — a COPY, not the working tree, so
building alone deploys nothing (bit us 2026-06-11: prod kept serving a stale
bundle). After every build, publish it (as root on the host):

```sh
cp -a apps/miniapp/dist/. /var/www/miniapp/dist/
```

Hashed asset names make this safe with Cloudflare caching; no reloads needed.
