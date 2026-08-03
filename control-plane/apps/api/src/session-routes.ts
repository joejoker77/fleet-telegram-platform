// M5.7 named sessions/projects (docs/M5.7-sessions-design.md). A session is a
// project dir in the tenant's OWN sandbox (~/work = "default", else
// ~/work/projects/<name>) plus its per-cwd claude conversation. cp-api never
// touches the pod directly: it writes a switch REQUEST file into the tenant
// home and the pod's entrypoint supervisor — the sole executor — respawns the
// claude pane and writes the RESULT file. Same trust boundary as fs-routes
// (boundary-1: the tenant's own files), audited per operation.
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { Redis } from "ioredis";
import { and, eq } from "drizzle-orm";
import { getDb, schema } from "@fleet/db";
import { sendAudit } from "./audit.js";
import { requireAuth, AuthError } from "./authz.js";

const NAME_RE = /^[a-z0-9][a-z0-9-]{0,31}$/;
const SWITCH_TIMEOUT_MS = 90_000; // supervisor tick is 5s + claude respawn time
const POLL_MS = 1_000;

export interface SessionDeps {
  redis: Redis;
  jwtSecret: Uint8Array;
  auditSocket: string;
  homeRoot: string; // e.g. /home
}

interface TenantPaths {
  home: string;
  projects: string;
  runDir: string;
  reqFile: string;
  resFile: string;
  taskReqFile: string; // M5.8 checkpoint/rewind tasks (same executor pattern)
  taskResFile: string;
  activeFile: string;
  ckptRoot: string;
}

function tenantPaths(homeRoot: string, osUsername: string): TenantPaths {
  const home = path.resolve(path.join(homeRoot, osUsername));
  const runDir = path.join(home, ".claude", "run");
  return {
    home,
    projects: path.join(home, "work", "projects"),
    runDir,
    reqFile: path.join(runDir, "session-switch.json"),
    resFile: path.join(runDir, "session-switch.result.json"),
    taskReqFile: path.join(runDir, "session-task.json"),
    taskResFile: path.join(runDir, "session-task.result.json"),
    activeFile: path.join(runDir, "active-session"),
    ckptRoot: path.join(home, ".claude", "checkpoints"),
  };
}

function dirSessions(p: TenantPaths): string[] {
  const names = ["default"];
  try {
    for (const ent of fs.readdirSync(p.projects, { withFileTypes: true })) {
      if (ent.isDirectory() && NAME_RE.test(ent.name)) names.push(ent.name);
    }
  } catch {
    /* no projects dir yet */
  }
  return names;
}

function activeName(p: TenantPaths): string {
  try {
    const n = fs.readFileSync(p.activeFile, "utf8").trim();
    return n || "default";
  } catch {
    return "default";
  }
}

// Supervisor-owned readiness: "switched" (pane respawned) != "ready" (the new
// claude's telegram plugin is actually polling). The supervisor writes
// session-state.json when the plugin comes up; a missing file (pre-readiness
// image) degrades to ready=true so the UI never sticks on "starting…".
function activeReady(p: TenantPaths, active: string): boolean {
  try {
    const s = JSON.parse(fs.readFileSync(path.join(p.runDir, "session-state.json"), "utf8")) as {
      name?: string;
      status?: string;
    };
    if (s.name !== active) return false; // state lags a fresh switch → not ready yet
    return s.status === "ready";
  } catch {
    return true; // legacy image without the state file
  }
}

// Seed per-project MCP approvals into a new session dir. Claude discovers
// ~/work/.mcp.json from project subdirs, but approval is per-project
// (<dir>/.claude/settings.local.json) — without it the first launch blocks
// forever on the interactive "New MCP server found" dialog and the bot is
// mute (2026-06-11 incident). The servers are platform-vetted (M5.5 gate), so
// a new session inherits the default session's approvals verbatim.
function seedMcpApprovals(p: TenantPaths, dir: string): void {
  const src = path.join(p.home, "work", ".claude", "settings.local.json");
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(fs.readFileSync(src, "utf8")) as Record<string, unknown>;
  } catch {
    return; // nothing to inherit
  }
  const out: Record<string, unknown> = {};
  for (const k of ["enableAllProjectMcpServers", "enabledMcpjsonServers"]) {
    if (k in parsed) out[k] = parsed[k];
  }
  if (Object.keys(out).length === 0) return;
  const dstDir = path.join(dir, ".claude");
  const dst = path.join(dstDir, "settings.local.json");
  if (fs.existsSync(dst)) return;
  fs.mkdirSync(dstDir, { recursive: true });
  fs.writeFileSync(dst, JSON.stringify(out, null, 2) + "\n", { mode: 0o644 });
  try {
    const { uid, gid } = tenantOwner(p);
    fs.chownSync(dstDir, uid, gid);
    fs.chownSync(dst, uid, gid);
  } catch {
    /* api not root in dev */
  }
}

function tenantOwner(p: TenantPaths): { uid: number; gid: number } {
  const st = fs.statSync(p.home);
  return { uid: st.uid, gid: st.gid };
}

// Write a file owned by the tenant, atomically (tmp + rename).
function writeAsTenant(p: TenantPaths, file: string, content: string): void {
  if (!fs.existsSync(p.runDir)) {
    fs.mkdirSync(p.runDir, { recursive: true });
    const { uid, gid } = tenantOwner(p);
    try {
      fs.chownSync(p.runDir, uid, gid);
    } catch {
      /* api not root in dev */
    }
  }
  const tmp = file + ".cp-tmp";
  fs.writeFileSync(tmp, content, { mode: 0o644 });
  try {
    const { uid, gid } = tenantOwner(p);
    fs.chownSync(tmp, uid, gid);
  } catch {
    /* api not root in dev */
  }
  fs.renameSync(tmp, file);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ── M5.8 checkpoints (docs/M5.8-checkpoints-design.md) ──
// A checkpoint = shadow-git commit of the session dir + a copy of its newest
// conversation jsonl, both under ~/.claude/checkpoints/<session>/ in the
// tenant home. The pod supervisor is the SOLE executor (single writer of
// index.json, git available in the pod); cp-api only writes task request
// files and reads index.json (fs is ground truth, no DB table).
const CKPT_ID_RE = /^\d{8}T\d{6}Z-\d{1,6}$/; // entrypoint: date -u +%Y%m%dT%H%M%SZ-$RANDOM

interface CheckpointEntry {
  id: string;
  label: string;
  ts: string;
  commit: string;
  auto: boolean;
  convSource: string | null;
}

function readCheckpoints(p: TenantPaths, name: string): CheckpointEntry[] {
  try {
    const arr = JSON.parse(
      fs.readFileSync(path.join(p.ckptRoot, name, "index.json"), "utf8"),
    ) as CheckpointEntry[];
    return Array.isArray(arr) ? arr : [];
  } catch {
    return []; // no checkpoints yet
  }
}

// Write a checkpoint/rewind task for the pod supervisor and wait for the
// result file — the exact contract switch uses (≤90s, 1s poll, id match).
async function runSupervisorTask(
  p: TenantPaths,
  payload: { action: string; name: string; label?: string; checkpoint?: string },
): Promise<{ ok: boolean; error?: string; checkpoint?: string; timeout?: boolean }> {
  const reqId = randomUUID();
  try {
    fs.rmSync(p.taskResFile, { force: true });
  } catch {
    /* ignore */
  }
  writeAsTenant(p, p.taskReqFile, JSON.stringify({ id: reqId, ...payload }) + "\n");
  const deadline = Date.now() + SWITCH_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await sleep(POLL_MS);
    let res: { id?: string; ok?: boolean; error?: string; checkpoint?: string };
    try {
      res = JSON.parse(fs.readFileSync(p.taskResFile, "utf8"));
    } catch {
      continue; // not written yet (or torn read — next poll re-reads)
    }
    if (res.id !== reqId) continue; // stale result from an earlier task
    return { ok: !!res.ok, error: res.error, checkpoint: res.checkpoint };
  }
  return { ok: false, timeout: true, error: "the task was not acknowledged within 90s (is the pod stopped, or running an old image?)" };
}

export function registerSessionRoutes(app: FastifyInstance, deps: SessionDeps): void {
  const db = getDb();
  const auth = (req: Parameters<typeof requireAuth>[0]) =>
    requireAuth(req, deps.redis, deps.jwtSecret);

  // GET /sessions — dirs are ground truth, DB rows are reconciled to them
  // (self-heal: a dir created by hand still shows up; a row without a dir is
  // closed). The active marker is maintained by the pod supervisor.
  app.get("/sessions", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const p = tenantPaths(deps.homeRoot, ctx.osUsername);
    const names = dirSessions(p);
    const active = activeName(p);
    const ready = activeReady(p, active);

    const rows = await db
      .select()
      .from(schema.sessions)
      .where(eq(schema.sessions.userId, ctx.userId));
    const byName = new Map(rows.map((r) => [r.sessionName, r]));

    for (const name of names) {
      const want = name === active ? "active" : "idle";
      const row = byName.get(name);
      if (!row) {
        const inserted = await db
          .insert(schema.sessions)
          .values({ userId: ctx.userId, sessionName: name, state: want })
          .returning();
        if (inserted[0]) byName.set(name, inserted[0]);
      } else if (row.state !== want && row.state !== "closed") {
        await db
          .update(schema.sessions)
          .set({ state: want })
          .where(eq(schema.sessions.id, row.id));
        row.state = want;
      } else if (row.state === "closed") {
        // dir is back → reopen
        await db
          .update(schema.sessions)
          .set({ state: want })
          .where(eq(schema.sessions.id, row.id));
        row.state = want;
      }
    }
    for (const row of rows) {
      if (!names.includes(row.sessionName) && row.state !== "closed") {
        await db
          .update(schema.sessions)
          .set({ state: "closed" })
          .where(eq(schema.sessions.id, row.id));
        row.state = "closed";
      }
    }

    const sessions = [...byName.values()]
      .filter((r) => r.state !== "closed")
      .sort((a, b) => (a.sessionName === "default" ? -1 : b.sessionName === "default" ? 1 : a.sessionName.localeCompare(b.sessionName)))
      .map((r) => ({
        id: r.id,
        name: r.sessionName,
        state: r.state,
        active: r.sessionName === active,
        ready: r.sessionName === active ? ready : true,
        startedAt: r.startedAt,
        lastMessageAt: r.lastMessageAt,
      }));
    return reply.send({ active, activeReady: ready, sessions });
  });

  // POST /sessions { name } — create the project dir (owned by the tenant) + row.
  app.post("/sessions", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const name = (req.body as { name?: string } | null)?.name;
    if (typeof name !== "string" || !NAME_RE.test(name)) {
      return reply.code(400).send({ error: "name must match ^[a-z0-9][a-z0-9-]{0,31}$" });
    }
    if (name === "default") return reply.code(409).send({ error: "default always exists" });
    const p = tenantPaths(deps.homeRoot, ctx.osUsername);
    const dir = path.join(p.projects, name);
    if (fs.existsSync(dir)) return reply.code(409).send({ error: "session already exists" });

    try {
      fs.mkdirSync(dir, { recursive: true });
      const { uid, gid } = tenantOwner(p);
      try {
        fs.chownSync(p.projects, uid, gid);
        fs.chownSync(dir, uid, gid);
      } catch {
        /* api not root in dev */
      }
    } catch (err) {
      app.log.error({ err }, "session dir create failed");
      return reply.code(500).send({ error: "mkdir failed" });
    }
    seedMcpApprovals(p, dir);

    const existing = await db
      .select()
      .from(schema.sessions)
      .where(and(eq(schema.sessions.userId, ctx.userId), eq(schema.sessions.sessionName, name)));
    let row = existing[0];
    if (row) {
      await db.update(schema.sessions).set({ state: "idle" }).where(eq(schema.sessions.id, row.id));
      row.state = "idle";
    } else {
      const inserted = await db
        .insert(schema.sessions)
        .values({ userId: ctx.userId, sessionName: name, state: "idle" })
        .returning();
      row = inserted[0];
    }
    if (!row) return reply.code(500).send({ error: "session row insert failed" });

    await sendAudit(deps.auditSocket, {
      userId: ctx.userId,
      kind: "session.create",
      actor: ctx.osUsername,
      payload: { name },
    });
    return reply.send({ ok: true, session: { id: row.id, name, state: row.state, active: false } });
  });

  // POST /sessions/:id/switch — request file → the pod supervisor respawns the
  // claude pane in the project dir → result file. Synchronous from the Mini
  // App's point of view (≤90s), 504 on timeout.
  app.post("/sessions/:id/switch", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const id = (req.params as { id?: string })?.id ?? "";
    const rows = await db
      .select()
      .from(schema.sessions)
      .where(and(eq(schema.sessions.id, id), eq(schema.sessions.userId, ctx.userId)))
      .limit(1);
    const row = rows[0];
    if (!row) return reply.code(404).send({ error: "no such session" });
    const name = row.sessionName;
    const p = tenantPaths(deps.homeRoot, ctx.osUsername);
    if (name !== "default" && !fs.existsSync(path.join(p.projects, name))) {
      return reply.code(409).send({ error: "session dir is gone" });
    }

    const reqId = randomUUID();
    try {
      try {
        fs.rmSync(p.resFile, { force: true });
      } catch {
        /* ignore */
      }
      writeAsTenant(p, p.reqFile, JSON.stringify({ id: reqId, action: "switch", name }) + "\n");
    } catch (err) {
      app.log.error({ err }, "switch request write failed");
      return reply.code(500).send({ error: "could not write switch request" });
    }

    const deadline = Date.now() + SWITCH_TIMEOUT_MS;
    while (Date.now() < deadline) {
      await sleep(POLL_MS);
      let res: { id?: string; ok?: boolean; error?: string };
      try {
        res = JSON.parse(fs.readFileSync(p.resFile, "utf8"));
      } catch {
        continue; // not written yet (or torn read — next poll re-reads)
      }
      if (res.id !== reqId) continue; // stale result from an earlier request
      if (!res.ok) {
        await sendAudit(deps.auditSocket, {
          userId: ctx.userId,
          kind: "session.switch.fail",
          actor: ctx.osUsername,
          payload: { name, error: res.error ?? "unknown" },
        });
        return reply.code(409).send({ error: res.error ?? "switch failed" });
      }
      // success → flip states (single active per tenant)
      await db
        .update(schema.sessions)
        .set({ state: "idle" })
        .where(and(eq(schema.sessions.userId, ctx.userId), eq(schema.sessions.state, "active")));
      await db.update(schema.sessions).set({ state: "active" }).where(eq(schema.sessions.id, row.id));
      await sendAudit(deps.auditSocket, {
        userId: ctx.userId,
        kind: "session.switch",
        actor: ctx.osUsername,
        payload: { name },
      });
      return reply.send({ ok: true, name });
    }
    return reply.code(504).send({
      error: "switch not confirmed in 90s (pod down or pre-M5.7 image?)",
    });
  });

  // DELETE /sessions/:id — remove a NON-active session from the list. Nothing
  // is destroyed: the project dir is moved to ~/work/.trash/<name>-<ts> (the
  // tenant can recover it or ask the bot to purge it), the row goes to
  // state=closed. The active session and "default" are refused — switch away
  // first; no supervisor involvement needed since no pane respawn happens.
  app.delete("/sessions/:id", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const id = (req.params as { id?: string })?.id ?? "";
    const rows = await db
      .select()
      .from(schema.sessions)
      .where(and(eq(schema.sessions.id, id), eq(schema.sessions.userId, ctx.userId)))
      .limit(1);
    const row = rows[0];
    if (!row || row.state === "closed") return reply.code(404).send({ error: "session not found" });
    const name = row.sessionName;
    if (name === "default") return reply.code(409).send({ error: "the default session cannot be deleted" });
    const p = tenantPaths(deps.homeRoot, ctx.osUsername);
    if (name === activeName(p)) {
      return reply.code(409).send({ error: "that session is active — switch to another one first" });
    }

    const dir = path.join(p.projects, name);
    if (fs.existsSync(dir)) {
      try {
        const trash = path.join(p.home, "work", ".trash");
        fs.mkdirSync(trash, { recursive: true });
        try {
          const { uid, gid } = tenantOwner(p);
          fs.chownSync(trash, uid, gid);
        } catch {
          /* api not root in dev */
        }
        const stamp = new Date().toISOString().replace(/[:.]/g, "-");
        fs.renameSync(dir, path.join(trash, `${name}-${stamp}`));
      } catch (err) {
        app.log.error({ err }, "session dir trash failed");
        return reply.code(500).send({ error: "could not move the session folder to .trash" });
      }
    }

    await db.update(schema.sessions).set({ state: "closed" }).where(eq(schema.sessions.id, row.id));
    await sendAudit(deps.auditSocket, {
      userId: ctx.userId,
      kind: "session.delete",
      actor: ctx.osUsername,
      payload: { name },
    });
    return reply.send({ ok: true, name });
  });

  // ── M5.8 checkpoint routes ──

  // Resolve a /sessions/:id route param to the session row of THIS user.
  const sessionById = async (id: string, userId: string) => {
    const rows = await db
      .select()
      .from(schema.sessions)
      .where(and(eq(schema.sessions.id, id), eq(schema.sessions.userId, userId)))
      .limit(1);
    const row = rows[0];
    return row && row.state !== "closed" ? row : null;
  };

  // GET /sessions/:id/checkpoints — index.json, newest first.
  app.get("/sessions/:id/checkpoints", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const id = (req.params as { id?: string })?.id ?? "";
    const row = await sessionById(id, ctx.userId);
    if (!row) return reply.code(404).send({ error: "session not found" });
    const p = tenantPaths(deps.homeRoot, ctx.osUsername);
    const checkpoints = readCheckpoints(p, row.sessionName).slice().reverse();
    return reply.send({ name: row.sessionName, checkpoints });
  });

  // POST /sessions/:id/checkpoints { label? } — snapshot files + conversation.
  // Safe on a LIVE session (nothing is restarted); executed by the supervisor
  // within one 5s tick.
  app.post("/sessions/:id/checkpoints", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const id = (req.params as { id?: string })?.id ?? "";
    const row = await sessionById(id, ctx.userId);
    if (!row) return reply.code(404).send({ error: "session not found" });
    const rawLabel = (req.body as { label?: string } | null)?.label;
    const label = typeof rawLabel === "string" && rawLabel.trim() ? rawLabel.trim().slice(0, 120) : "manual";
    const p = tenantPaths(deps.homeRoot, ctx.osUsername);

    let res;
    try {
      res = await runSupervisorTask(p, { action: "checkpoint", name: row.sessionName, label });
    } catch (err) {
      app.log.error({ err }, "checkpoint task write failed");
      return reply.code(500).send({ error: "could not write checkpoint request" });
    }
    if (!res.ok) {
      return reply.code(res.timeout ? 504 : 409).send({ error: res.error ?? "checkpoint failed" });
    }
    await sendAudit(deps.auditSocket, {
      userId: ctx.userId,
      kind: "checkpoint.create",
      actor: ctx.osUsername,
      payload: { name: row.sessionName, checkpoint: res.checkpoint, label },
    });
    const entry = readCheckpoints(p, row.sessionName).find((c) => c.id === res.checkpoint) ?? null;
    return reply.send({ ok: true, checkpoint: res.checkpoint, entry });
  });

  // POST /sessions/:id/checkpoints/:cid/rewind — restore files (shadow-git
  // reset+clean) AND the conversation jsonl. For the ACTIVE session the
  // supervisor parks the pane first and respawns claude after — same readiness
  // flow as switch (Mini App polls until 🟢). A pre-rewind auto-checkpoint
  // makes the operation always undoable.
  app.post("/sessions/:id/checkpoints/:cid/rewind", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const { id = "", cid = "" } = (req.params as { id?: string; cid?: string }) ?? {};
    const row = await sessionById(id, ctx.userId);
    if (!row) return reply.code(404).send({ error: "session not found" });
    if (!CKPT_ID_RE.test(cid)) return reply.code(400).send({ error: "malformed checkpoint id" });
    const p = tenantPaths(deps.homeRoot, ctx.osUsername);
    if (!readCheckpoints(p, row.sessionName).some((c) => c.id === cid)) {
      return reply.code(404).send({ error: "checkpoint not found" });
    }

    let res;
    try {
      res = await runSupervisorTask(p, { action: "rewind", name: row.sessionName, checkpoint: cid });
    } catch (err) {
      app.log.error({ err }, "rewind task write failed");
      return reply.code(500).send({ error: "could not write rewind request" });
    }
    if (!res.ok) {
      await sendAudit(deps.auditSocket, {
        userId: ctx.userId,
        kind: "checkpoint.rewind.fail",
        actor: ctx.osUsername,
        payload: { name: row.sessionName, checkpoint: cid, error: res.error ?? "unknown" },
      });
      return reply.code(res.timeout ? 504 : 409).send({ error: res.error ?? "rewind failed" });
    }
    await sendAudit(deps.auditSocket, {
      userId: ctx.userId,
      kind: "checkpoint.rewind",
      actor: ctx.osUsername,
      payload: { name: row.sessionName, checkpoint: cid },
    });
    return reply.send({ ok: true, checkpoint: cid });
  });

  // DELETE /sessions/:id/checkpoints/:cid — drop one entry (index + conv copy;
  // git objects are reclaimed by gc --auto on later creates). Supervisor does
  // it to keep index.json single-writer.
  app.delete("/sessions/:id/checkpoints/:cid", async (req, reply) => {
    let ctx;
    try {
      ctx = await auth(req);
    } catch (e) {
      const err = e as AuthError;
      return reply.code(err.code ?? 401).send({ error: err.message });
    }
    const { id = "", cid = "" } = (req.params as { id?: string; cid?: string }) ?? {};
    const row = await sessionById(id, ctx.userId);
    if (!row) return reply.code(404).send({ error: "session not found" });
    if (!CKPT_ID_RE.test(cid)) return reply.code(400).send({ error: "malformed checkpoint id" });
    const p = tenantPaths(deps.homeRoot, ctx.osUsername);
    if (!readCheckpoints(p, row.sessionName).some((c) => c.id === cid)) {
      return reply.code(404).send({ error: "checkpoint not found" });
    }

    let res;
    try {
      res = await runSupervisorTask(p, { action: "ckpt-delete", name: row.sessionName, checkpoint: cid });
    } catch (err) {
      app.log.error({ err }, "ckpt-delete task write failed");
      return reply.code(500).send({ error: "could not write delete request" });
    }
    if (!res.ok) {
      return reply.code(res.timeout ? 504 : 409).send({ error: res.error ?? "delete failed" });
    }
    await sendAudit(deps.auditSocket, {
      userId: ctx.userId,
      kind: "checkpoint.delete",
      actor: ctx.osUsername,
      payload: { name: row.sessionName, checkpoint: cid },
    });
    return reply.send({ ok: true, checkpoint: cid });
  });
}
