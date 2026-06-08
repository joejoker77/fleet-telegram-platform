# control-plane (M1)

Central services of the fleet platform — built **alongside** the Genesis
prototype, off the Telegram message path. Source of truth for M1; deployed
to `/opt/control-plane` on the server (repo-layout ≠ deployed-layout).

Design doc: `../../upgrade/07-control-plane.md`. Master sequence: `06`.

## Stack
TypeScript/Node (pnpm workspaces) · Fastify (HTTP) · BullMQ/Redis (queues) ·
Drizzle/Postgres (ORM) · zod (validation) · pino (logs).

## Layout
```
packages/
  db/                 # Drizzle schema (= doc-07 DDL) + migrations + pilot seed
  shared/             # zod contracts + inferred types (auth, profile, audit)
apps/
  api/                # Fastify: initData auth → /auth/session, /me  (M1.4)
  audit-collector/    # unix-socket, hash-chain, WORM append-only store (M1.3)
```
Later milestones add `apps/{provisioner,registry,judge-orchestrator,notifier,miniapp}`
and `packages/scanners`.

## M1 step breakdown
- **M1.0 scaffold** — workspace, toolchain pins, lockfile. *(no root)* ✅
- **M1.1 data model** — Drizzle schema + idempotent migrations + pilot seed. *(no root)* ✅
- **M1.2 Postgres + Redis** — isolated on 127.0.0.1, run migrations. *(root)*
- **M1.3 audit-collector** — socket + hash-chain + WORM; tenant can't mutate. *(root)*
- **M1.4 api** — initData HMAC (bot secret from OneCLI) → JWT + `/me`. *(root)*
- **M1.5 systemd + install segment** — `cp-*.service`, `cplane` service user. *(root)*
- **M1.6 acceptance** — migrations idempotent; signed initData → JWT; `/me`
  returns the vitaliy profile; hash-chain verifies; `claude-tg@*` untouched.

## Acceptance gate (doc 07)
Postgres schema deployed (idempotent migrations); `POST /auth/session` validates
initData and issues a JWT; `/me` returns the profile; `audit-collector` accepts
records with a verifiable hash-chain that the tenant cannot alter; services run
as systemd units without disturbing running `claude-tg@*`.

## Invariants honoured
No TG-plugin patch · secrets only in OneCLI (repo holds placeholders) ·
append-only audit · LLM calls event-driven only (no scheduled runs) ·
in-place, no mass restarts · **pilot = vitaliy only**.

## Local dev (once infra exists, M1.2+)
```bash
pnpm install
DATABASE_URL=postgres://cplane@127.0.0.1:5433/control_plane pnpm db:generate
DATABASE_URL=... pnpm db:migrate
DATABASE_URL=... pnpm db:seed
```
