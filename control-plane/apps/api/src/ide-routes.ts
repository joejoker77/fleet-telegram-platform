// M5.6 — web-IDE auth endpoints (docs/M5.6-web-ide-design.md).
//   POST /ide/ticket  — (Bearer JWT) one-time ticket → { url } the Mini App
//                       opens in the EXTERNAL browser.
//   GET  /ide/login   — ?t=<ticket> → consume it (GETDEL: strictly one-time)
//                       → HttpOnly session cookie → 302 to the IDE root.
//   GET  /ide/auth    — nginx auth_request subrequest: 204/401 per request
//                       (incl. websocket upgrades) by cookie + tenant check.
// All state in Redis; cp-api never touches the IDE socket — it only
// authenticates. No new privileged channels.
import { randomUUID } from "node:crypto";
import type { FastifyInstance, FastifyRequest } from "fastify";
import type { Redis } from "ioredis";
import { requireAuth, AuthError } from "./authz.js";
import { sendAudit } from "./audit.js";

export interface IdeRoutesDeps {
  redis: Redis;
  jwtSecret: Uint8Array;
  auditSocket: string;
  // Public IDE origin, e.g. https://ide.ai-assistant.gg — where /ide/login
  // lives (nginx proxies its /api/ide/* to cp-api, mirroring the miniapp vhost).
  ideUrl: string;
}

// Approved TTLs (design review 2026-06-11): ticket 60 s one-time, session 12 h.
const TICKET_TTL_SECONDS = 60;
const SESSION_TTL_SECONDS = 12 * 3600;
const COOKIE_NAME = "cp_ide";

const ticketKey = (t: string) => `ide:ticket:${t}`;
const sessionKey = (s: string) => `ide:session:${s}`;

// Ticket/session value: who this grants access AS. osUsername is denormalized
// in so the per-request /ide/auth hot path stays Redis-only (no DB hit per IDE
// asset/ws frame). Revocation = delete the ide:session:* key (deprovision does).
interface IdeGrant {
  userId: string;
  osUsername: string;
}

function readCookie(req: FastifyRequest, name: string): string | null {
  const header = req.headers.cookie;
  if (!header) return null;
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq === -1) continue;
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return null;
}

export function registerIdeRoutes(app: FastifyInstance, deps: IdeRoutesDeps): void {
  app.post("/ide/ticket", async (req, reply) => {
    let ctx;
    try {
      ctx = await requireAuth(req, deps.redis, deps.jwtSecret);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const t = randomUUID();
    const grant: IdeGrant = { userId: ctx.userId, osUsername: ctx.osUsername };
    await deps.redis.set(ticketKey(t), JSON.stringify(grant), "EX", TICKET_TTL_SECONDS);
    await sendAudit(deps.auditSocket, {
      userId: ctx.userId,
      kind: "ide.ticket",
      actor: `miniapp:${ctx.osUsername}`,
      payload: { ttlSeconds: TICKET_TTL_SECONDS },
    }).catch(() => {});
    return reply.send({
      url: `${deps.ideUrl}/api/ide/login?t=${t}`,
      ttlSeconds: TICKET_TTL_SECONDS,
    });
  });

  app.get("/ide/login", async (req, reply) => {
    const t = (req.query as { t?: unknown }).t;
    if (typeof t !== "string" || !t) {
      return reply.code(400).type("text/plain").send("missing ticket");
    }
    // GETDEL = atomically consume: a ticket authenticates exactly one browser.
    const raw = await deps.redis.getdel(ticketKey(t));
    if (!raw) {
      return reply
        .code(401)
        .type("text/plain")
        .send("ticket invalid, expired or already used — reopen the IDE from the Mini App");
    }
    const grant = JSON.parse(raw) as IdeGrant;
    const sid = randomUUID();
    await deps.redis.set(sessionKey(sid), raw, "EX", SESSION_TTL_SECONDS);
    await sendAudit(deps.auditSocket, {
      userId: grant.userId,
      kind: "ide.login",
      actor: `ide:${grant.osUsername}`,
      payload: { sessionTtlSeconds: SESSION_TTL_SECONDS },
    }).catch(() => {});
    return reply
      .header(
        "set-cookie",
        // Path=/ — the cookie must ride every IDE request on this origin.
        // Secure+HttpOnly+SameSite=Lax: not readable by IDE-side JS, not sent
        // cross-site; Lax (not Strict) so the 302 right here carries it.
        `${COOKIE_NAME}=${sid}; Path=/; Max-Age=${SESSION_TTL_SECONDS}; HttpOnly; Secure; SameSite=Lax`,
      )
      .redirect("/", 302);
  });

  // nginx auth_request target. Success = 204 (auth_request treats 2xx as
  // allow), anything else = 401. NOT audited: this fires per asset/ws request;
  // failures are visible in the nginx error log.
  app.get("/ide/auth", async (req, reply) => {
    const sid = readCookie(req, COOKIE_NAME);
    if (!sid) return reply.code(401).send();
    const raw = await deps.redis.get(sessionKey(sid));
    if (!raw) return reply.code(401).send();
    const grant = JSON.parse(raw) as IdeGrant;
    // The vhost states whose IDE it fronts (X-Ide-Tenant, static per vhost) —
    // a cookie for tenant A must not open tenant B's vhost. Fail-closed when
    // the header is missing (a misconfigured vhost grants nothing).
    const tenant = req.headers["x-ide-tenant"];
    if (typeof tenant !== "string" || !tenant || tenant !== grant.osUsername) {
      return reply.code(401).send();
    }
    return reply.code(204).send();
  });
}
