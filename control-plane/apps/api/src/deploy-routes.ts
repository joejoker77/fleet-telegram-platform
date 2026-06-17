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
import { requireAuth, AuthError } from "./authz.js";
import { reconcileTenant, reconcileAllTenants } from "./deploy-reconcile.js";

export interface DeployRoutesDeps {
  redis: Redis;
  jwtSecret: Uint8Array;
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
}
