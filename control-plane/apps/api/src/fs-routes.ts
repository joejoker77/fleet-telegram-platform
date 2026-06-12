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

// ── M5.10 workspace scopes (docs/M5.10-workspace-scopes-design.md) ──
// Three fixed roots, ALL inside the tenant's own home (boundary-1 unchanged):
//   project   → the ACTIVE session dir (~/work or ~/work/projects/<name>)
//   artifacts → ~/.claude (legacy root), tree top level curated by whitelist
//   home      → ~ (expert mode)
// The client picks a scope NAME only — roots are this server-side dictionary.
export type FsScope = "project" | "artifacts" | "home";
const SCOPES = new Set<string>(["project", "artifacts", "home"]);

// Junk classes hidden from the tree by default (?all=1 shows them). A display
// filter for the UI, NOT a security control — everything here is the tenant's
// own home either way.
const HIDE_DIRS = new Set([
  ".trash",
  "node_modules",
  ".git",
  "dist",
  "build",
  ".venv",
  "venv",
  "__pycache__",
  ".cache",
  ".npm",
  ".local",
  ".config",
]);
const HIDE_FILE_RE = /\.(log|tmp)$/i;

// artifacts scope, top level: only what the user actually authors. The rest of
// ~/.claude is Claude Code runtime state (backups, file-history, telemetry…).
const ARTIFACTS_TOP = new Set(["agents", "commands", "skills", "CLAUDE.md", "settings.json"]);

export interface FsDeps {
  redis: Redis;
  jwtSecret: Uint8Array;
  auditSocket: string;
  homeRoot: string; // e.g. /home  → tenant sandbox = <homeRoot>/<osUsername>/.claude
}

function tenantRoot(homeRoot: string, osUsername: string): string {
  return path.resolve(path.join(homeRoot, osUsername, ".claude"));
}

// Resolve a scope to its root dir + display label. project follows the ACTIVE
// session marker maintained by the pod supervisor (same source as M5.7
// session-routes activeName()).
function scopeRoot(homeRoot: string, osUsername: string, scope: FsScope): { root: string; label: string } {
  const home = path.resolve(path.join(homeRoot, osUsername));
  if (scope === "home") return { root: home, label: "~" };
  if (scope === "artifacts") return { root: path.join(home, ".claude"), label: ".claude" };
  let name = "default";
  try {
    name = fs.readFileSync(path.join(home, ".claude", "run", "active-session"), "utf8").trim() || "default";
  } catch {
    /* no marker yet → default */
  }
  return name === "default"
    ? { root: path.join(home, "work"), label: "~/work" }
    : { root: path.join(home, "work", "projects", name), label: `~/work/projects/${name}` };
}

export function registerFsRoutes(app: FastifyInstance, deps: FsDeps): void {
  const auth = (req: Parameters<typeof requireAuth>[0]) => requireAuth(req, deps.redis, deps.jwtSecret);

  // GET /fs/tree — two contracts:
  //   ?scope=project|artifacts|home[&dir=<rel>][&all=1]  (M5.10, LAZY: one
  //     directory level per call; junk classes hidden unless all=1)
  //   no params → legacy recursive dump of ~/.claude (back-compat for the old
  //     bundle during deploy + the builders' existingPaths collision check)
  app.get("/fs/tree", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const q = (req.query ?? {}) as Record<string, string>;

    if (q.scope !== undefined) {
      if (!SCOPES.has(q.scope)) {
        return reply.code(400).send({ error: "unknown scope", code: "bad_scope" });
      }
      const scope = q.scope as FsScope;
      const showAll = q.all === "1";
      const dirRel = (q.dir ?? "").replace(/\/+$/, "");
      const { root, label } = scopeRoot(deps.homeRoot, ctx.osUsername, scope);
      if (!fs.existsSync(root)) return reply.send({ scope, root: label, dir: dirRel, entries: [], hidden: 0 });

      let absDir: string;
      try {
        absDir = safeResolve(root, dirRel);
        assertRealInside(root, absDir);
      } catch (e) {
        const err = e as AuthError;
        return reply.code(err.code ?? 400).send({ error: err.message, code: "bad_path" });
      }
      if (!fs.existsSync(absDir) || !fs.statSync(absDir).isDirectory()) {
        return reply.code(404).send({ error: "no such directory", code: "not_found" });
      }

      const entries: { path: string; name: string; type: "file" | "dir"; size: number }[] = [];
      let hidden = 0;
      try {
        for (const ent of fs.readdirSync(absDir, { withFileTypes: true })) {
          const isDir = ent.isDirectory();
          if (!isDir && !ent.isFile()) continue; // sockets/symlinks — as in the legacy walk
          // curated top level of the artifacts scope (whitelist, not a toggle)
          if (scope === "artifacts" && dirRel === "" && !ARTIFACTS_TOP.has(ent.name)) continue;
          if (!showAll) {
            const junk =
              (isDir && HIDE_DIRS.has(ent.name)) ||
              (!isDir && HIDE_FILE_RE.test(ent.name)) ||
              // home root: dot-entries (.bashrc, .ssh, .claude…) ARE the clutter
              (scope === "home" && dirRel === "" && ent.name.startsWith("."));
            if (junk) {
              hidden++;
              continue;
            }
          }
          let size = 0;
          if (!isDir) {
            try {
              size = fs.statSync(path.join(absDir, ent.name)).size;
            } catch {
              /* ignore */
            }
          }
          entries.push({
            path: dirRel ? `${dirRel}/${ent.name}` : ent.name,
            name: ent.name,
            type: isDir ? "dir" : "file",
            size,
          });
        }
      } catch (err) {
        app.log.error({ err }, "fs/tree scoped list failed");
        return reply.code(500).send({ error: "list failed", code: "list_failed" });
      }
      entries.sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name) : a.type === "dir" ? -1 : 1));
      return reply.send({ scope, root: label, dir: dirRel, entries, hidden });
    }

    // ── legacy contract: recursive ~/.claude dump ──
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

  // GET /fs/file?path=<rel>[&scope=…] — read one file. Default scope =
  // artifacts (= the legacy ~/.claude root, back-compat).
  app.get("/fs/file", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const q = (req.query ?? {}) as Record<string, string>;
    const rel = q.path;
    if (!rel) return reply.code(400).send({ error: "missing ?path", code: "bad_path" });
    if (q.scope !== undefined && !SCOPES.has(q.scope)) {
      return reply.code(400).send({ error: "unknown scope", code: "bad_scope" });
    }
    const root = scopeRoot(deps.homeRoot, ctx.osUsername, (q.scope as FsScope) ?? "artifacts").root;
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

  // PUT /fs/file { path, content, scope? } — BOUNDARY-1 save: write to the
  // tenant's own home as the tenant uid, audit, and return a non-blocking
  // advisory. NO judge. Default scope = artifacts (legacy ~/.claude root).
  // home scope is read-write by design (same trust boundary — Vitaliy msg 2967).
  app.put("/fs/file", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const body = (req.body ?? {}) as { path?: string; content?: string; scope?: string };
    if (typeof body.path !== "string" || typeof body.content !== "string") {
      return reply.code(400).send({ error: "expected { path, content }", code: "bad_request" });
    }
    if (body.scope !== undefined && !SCOPES.has(body.scope)) {
      return reply.code(400).send({ error: "unknown scope", code: "bad_scope" });
    }
    const scope = (body.scope as FsScope) ?? "artifacts";
    if (Buffer.byteLength(body.content, "utf8") > MAX_FILE) {
      return reply.code(413).send({ error: "content exceeds 1 MiB", code: "file_too_large" });
    }
    const root = scopeRoot(deps.homeRoot, ctx.osUsername, scope).root;
    if (!fs.existsSync(root)) return reply.code(404).send({ error: "scope root not found", code: "not_found" });

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
      payload: { path: body.path, scope, bytes: Buffer.byteLength(body.content, "utf8"), advisoryCount: advisory.length },
    });

    return reply.send({ ok: true, path: body.path, advisory });
  });
}
