// M5.1 authoring file API — the tenant edits the exact bytes of their OWN
// ~/.claude sandbox. This is BOUNDARY-1 (ADR-004): containment, NOT pre-screening.
// So PUT does NOT judge-gate; it writes (path-confined, as the tenant uid) +
// audits, and attaches a free, NON-blocking deterministic advisory (builtin regex,
// no LLM) for the UI to inform the user. The blocking judge-gate is at PUBLISH
// (M5.5, boundary-2). settings.json security keys are independently protected by
// the WP7 settings-guard; runtime risk is handled by containment when code runs.
import fs from "node:fs";
import path from "node:path";
import type { FastifyInstance } from "fastify";
import type { Redis } from "ioredis";
import { builtinScan } from "@fleet/scanners";
import { sendAudit } from "./audit.js";
import { requireAuth, AuthError } from "./authz.js";
import { safeResolve, assertRealInside } from "./fs-safety.js";

const MAX_FILE = 1024 * 1024; // 1 MiB cap per file
const SKIP_DIRS = new Set(["node_modules", ".git"]);

export interface FsDeps {
  redis: Redis;
  jwtSecret: Uint8Array;
  auditSocket: string;
  homeRoot: string; // e.g. /home  → tenant sandbox = <homeRoot>/<osUsername>/.claude
}

function tenantRoot(homeRoot: string, osUsername: string): string {
  return path.resolve(path.join(homeRoot, osUsername, ".claude"));
}

export function registerFsRoutes(app: FastifyInstance, deps: FsDeps): void {
  const auth = (req: Parameters<typeof requireAuth>[0]) => requireAuth(req, deps.redis, deps.jwtSecret);

  // GET /fs/tree — list the sandbox tree (files + dirs, relative paths, sizes).
  app.get("/fs/tree", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const root = tenantRoot(deps.homeRoot, ctx.osUsername);
    if (!fs.existsSync(root)) return reply.send({ root: ".claude", entries: [] });

    const entries: { path: string; type: "file" | "dir"; size: number }[] = [];
    const walk = (dir: string) => {
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        if (ent.isDirectory() && SKIP_DIRS.has(ent.name)) continue;
        const abs = path.join(dir, ent.name);
        const rel = path.relative(root, abs);
        if (ent.isDirectory()) {
          entries.push({ path: rel, type: "dir", size: 0 });
          walk(abs);
        } else if (ent.isFile()) {
          let size = 0;
          try {
            size = fs.statSync(abs).size;
          } catch {
            /* ignore */
          }
          entries.push({ path: rel, type: "file", size });
        }
      }
    };
    try {
      walk(root);
    } catch (err) {
      app.log.error({ err }, "fs/tree walk failed");
    }
    return reply.send({ root: ".claude", entries });
  });

  // GET /fs/file?path=<rel> — read one file.
  app.get("/fs/file", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const rel = (req.query as Record<string, string>)?.path;
    if (!rel) return reply.code(400).send({ error: "missing ?path" });
    const root = tenantRoot(deps.homeRoot, ctx.osUsername);
    let abs: string;
    try {
      abs = safeResolve(root, rel);
      if (fs.existsSync(abs)) assertRealInside(root, abs);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 400).send({ error: err.message });
    }
    if (!fs.existsSync(abs) || !fs.statSync(abs).isFile()) {
      return reply.code(404).send({ error: "no such file" });
    }
    if (fs.statSync(abs).size > MAX_FILE) {
      return reply.code(413).send({ error: "file too large for the editor" });
    }
    const content = fs.readFileSync(abs, "utf8");
    return reply.send({ path: rel, content });
  });

  // PUT /fs/file { path, content } — BOUNDARY-1 save: write to the tenant's own
  // sandbox as the tenant uid, audit, and return a non-blocking advisory. NO judge.
  app.put("/fs/file", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const body = (req.body ?? {}) as { path?: string; content?: string };
    if (typeof body.path !== "string" || typeof body.content !== "string") {
      return reply.code(400).send({ error: "expected { path, content }" });
    }
    if (Buffer.byteLength(body.content, "utf8") > MAX_FILE) {
      return reply.code(413).send({ error: "content exceeds 1 MiB" });
    }
    const root = tenantRoot(deps.homeRoot, ctx.osUsername);
    if (!fs.existsSync(root)) return reply.code(404).send({ error: "tenant sandbox not found" });

    let abs: string;
    try {
      abs = safeResolve(root, body.path);
      assertRealInside(root, abs);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 400).send({ error: err.message });
    }

    // own the new file as the tenant (the sandbox dir's owner = the tenant uid)
    const st = fs.statSync(root);
    const { uid, gid } = st;

    try {
      // create parent dirs within the sandbox, owned by the tenant
      const parent = path.dirname(abs);
      if (!fs.existsSync(parent)) {
        fs.mkdirSync(parent, { recursive: true });
        // chown the chain we just created, best-effort
        let p = parent;
        while (p !== root && p.startsWith(root + path.sep)) {
          try {
            fs.chownSync(p, uid, gid);
          } catch {
            /* ignore */
          }
          p = path.dirname(p);
        }
      }
      const tmp = abs + ".authoring-tmp";
      fs.writeFileSync(tmp, body.content, { mode: 0o644 });
      try {
        fs.chownSync(tmp, uid, gid);
      } catch (err) {
        app.log.warn({ err }, "chown authored file failed (api not root?)");
      }
      fs.renameSync(tmp, abs);
    } catch (err) {
      app.log.error({ err }, "fs/file write failed");
      return reply.code(500).send({ error: "write failed" });
    }

    // Non-blocking deterministic advisory (free, no LLM) — informs, never caged.
    const advisory = builtinScan(body.content);

    await sendAudit(deps.auditSocket, {
      userId: ctx.userId,
      kind: "fs.write",
      actor: ctx.osUsername,
      payload: { path: body.path, bytes: Buffer.byteLength(body.content, "utf8"), advisoryCount: advisory.length },
    });

    return reply.send({ ok: true, path: body.path, advisory });
  });
}
