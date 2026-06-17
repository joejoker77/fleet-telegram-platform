// A2 — HTTP trigger for the control-plane deploy reconcile (docs/10). This is the
// manual/CI/admin entry point that replaces the host skill-deploy@/mcp-deploy@
// timers; the GitHub push webhook (repo changes) and the bind flow (per-tenant
// secret changes) call the same orchestrator (reconcileTenant/reconcileAllTenants)
// in-process. Admin-only: a tenant must not be able to force a fleet reconcile.
//
//   POST /deploy/reconcile  { user?, apply?, ref? }
//     user   — reconcile just this os_username; omit to sweep every active tenant
//     apply  — default false (dry-run: compute + diff, write nothing)
//     ref    — repo ref to reconcile against (default "main")
import type { FastifyInstance } from "fastify";
import type { Redis } from "ioredis";
import { createHmac, timingSafeEqual } from "node:crypto";
import { requireAuth, AuthError } from "./authz.js";
import { reconcileTenant, reconcileAllTenants } from "./deploy-reconcile.js";

// The JSON content-type parser in index.ts stashes the raw bytes here so we can
// recompute the GitHub HMAC (parsed JSON re-serialized would not byte-match).
declare module "fastify" {
  interface FastifyRequest {
    rawBody?: Buffer;
  }
}

export interface DeployRoutesDeps {
  redis: Redis;
  jwtSecret: Uint8Array;
  // GitHub push-webhook HMAC secret; empty → the webhook route is dormant (503).
  githubWebhookSecret: string;
}

export function registerDeployRoutes(app: FastifyInstance, deps: DeployRoutesDeps): void {
  app.post("/deploy/reconcile", async (req, reply) => {
    let ctx;
    try {
      ctx = await requireAuth(req, deps.redis, deps.jwtSecret);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    if (!ctx.isAdmin) return reply.code(403).send({ error: "admin only" });

    const body = (req.body ?? {}) as { user?: string; apply?: boolean; ref?: string };
    const apply = body.apply === true;
    const ref = typeof body.ref === "string" && body.ref ? body.ref : "main";

    if (typeof body.user === "string" && body.user) {
      const tenant = await reconcileTenant({ user: body.user, ref, apply });
      return reply.send({ apply, ref, tenants: [tenant] });
    }
    const tenants = await reconcileAllTenants({ ref, apply });
    return reply.send({ apply, ref, tenants });
  });

  // GitHub push webhook (repo-change trigger). Configure the repo webhook with
  // content-type application/json + the shared secret. On a push to the default
  // branch we ACK fast (202) and sweep every active tenant in the background —
  // GitHub expects a sub-10s response and a multi-tenant apply can take seconds.
  app.post("/deploy/webhook/github", async (req, reply) => {
    if (!deps.githubWebhookSecret) return reply.code(503).send({ error: "webhook not configured" });
    const raw = req.rawBody;
    if (!raw || raw.length === 0) return reply.code(400).send({ error: "no raw body (content-type must be application/json)" });

    // constant-time compare of X-Hub-Signature-256
    const sig = String(req.headers["x-hub-signature-256"] ?? "");
    const expected = "sha256=" + createHmac("sha256", deps.githubWebhookSecret).update(raw).digest("hex");
    const a = Buffer.from(sig);
    const b = Buffer.from(expected);
    if (a.length !== b.length || !timingSafeEqual(a, b)) return reply.code(401).send({ error: "bad signature" });

    const event = String(req.headers["x-github-event"] ?? "");
    if (event === "ping") return reply.send({ ok: true, pong: true });
    if (event !== "push") return reply.send({ ok: true, ignored: event });

    const body = (req.body ?? {}) as { ref?: string };
    const branch = (body.ref ?? "").replace(/^refs\/heads\//, "");
    if (branch !== "main") return reply.send({ ok: true, ignoredBranch: branch });

    // ack fast, reconcile in the background (fire-and-forget; errors logged)
    reply.code(202).send({ ok: true, scheduled: true });
    reconcileAllTenants({ ref: "main", apply: true })
      .then((tenants) => {
        req.log.info({ changed: tenants.filter((t) => t.changed).map((t) => t.user) }, "deploy webhook reconcile done");
      })
      .catch((e) => {
        req.log.error({ err: String(e) }, "deploy webhook reconcile failed");
      });
  });
}
