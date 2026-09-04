// M8.1 — artifact marketplace HTTP surface (docs/M8.1-sharing-marketplace-design.md).
//
//   GET    /registry/items?type=&visibility=   catalog: my artifacts + public ones
//   GET    /registry/items/:id                  one artifact + its versions
//   POST   /registry/publish  { type,name,version,visibility?,description? }
//                              → scan (fail-closed) → admin: publish now;
//                                non-admin: approval → publish on allow
//   POST   /registry/import   { artifactVersionId }
//                              → fetch pinned version → re-scan → approval (always)
//                                → install into the importer's .claude/ on allow
//   DELETE /registry/items/:id                   unpublish (owner only)
//
// SECRET/EGRESS SPLIT: cp-api runs host-side WITHOUT the GitHub PAT (OneCLI
// injects it only at the tenant pod's egress proxy). So PUBLISH (git WRITE) is
// dispatched to the pod via the session-task supervisor pattern; IMPORT only
// READS the public marketplace repo (no auth) and writes local files, so it
// runs entirely in cp-api.
import type { FastifyInstance, FastifyRequest, FastifyReply } from "fastify";
import type { Redis } from "ioredis";
import fs from "node:fs";
import path from "node:path";
import { randomUUID, createHash } from "node:crypto";
import { and, eq, or, desc } from "drizzle-orm";
import { getDb, schema } from "@fleet/db";
import { scanArtifact, httpJudgeClient, type ScanInput, type ScanResult } from "@fleet/scanners";
import { requireAuth, AuthError, type AuthCtx } from "./authz.js";
import { createApproval, type ApprovalsDeps } from "./approvals.js";
import { sendAudit } from "./audit.js";

const db = getDb();

export const REGISTRY_PUBLISH_KIND = "registry.publish";
export const REGISTRY_IMPORT_KIND = "registry.import";
const APPROVAL_TTL = 600; // 10 min to decide a publish/import
const POLL_TIMEOUT_MS = 90_000; // pod publish round-trip budget
const POLL_INTERVAL_MS = 1000;

const ARTIFACT_TYPES = ["skill", "subagent", "command", "workflow"] as const;
type ArtType = (typeof ARTIFACT_TYPES)[number];
const NAME_RE = /^[a-z0-9][a-z0-9._-]{0,48}$/i;
const VERSION_RE = /^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$/;

export interface RegistryDeps {
  redis: Redis;
  jwtSecret: Uint8Array;
  homeRoot: string; // tenant home = <homeRoot>/<osUsername>
  judgeUrl: string;
  auditSocket: string;
  approvals: ApprovalsDeps;
  repo: string; // marketplace store, e.g. "joejoker77/claude-bot-skills"
  // Read-only PAT for that repo. Empty string = not configured, which is only
  // survivable while the repo is public; a private repo 404s without it.
  githubReadToken?: string;
}

// ── source/destination layout (mirrors the pod helper) ──────────────────────
function tenantHome(deps: RegistryDeps, os: string): string {
  return path.join(deps.homeRoot, os);
}
// A tenant has TWO .claude trees: the user-scoped ~/.claude and the project-scoped
// ~/work/.claude, and Claude Code reads artifacts from both. On the firm host every
// real artifact lives in the PROJECT one — audited 2026-09-04: all 30 tenants have
// ~/work/.claude/skills populated (6 firm + 24 private skills) and ~/.claude/skills
// does not exist for a single one of them. Resolving only ~/.claude, as this did,
// means publish fails "source not found" for every skill anybody actually has.
// Tuple, not string[], so [0] is a string under noUncheckedIndexedAccess.
function claudeDirs(deps: RegistryDeps, os: string): [project: string, user: string] {
  const home = tenantHome(deps, os);
  return [path.join(home, "work", ".claude"), path.join(home, ".claude")];
}
function relForType(type: ArtType, name: string): string {
  switch (type) {
    case "skill":
      return path.join("skills", name);
    case "subagent":
      return path.join("agents", `${name}.md`);
    case "command":
    case "workflow":
      return path.join("commands", `${name}.md`);
  }
}
function artifactSourcePath(deps: RegistryDeps, os: string, type: ArtType, name: string): string {
  const rel = relForType(type, name);
  const [project, user] = claudeDirs(deps, os);
  const candidates: [string, string] = [path.join(project, rel), path.join(user, rel)];
  // Prefer whichever one exists; fall back to the project tree so the error message
  // names the path a tenant would actually look at.
  return candidates.find((p) => fs.existsSync(p)) ?? candidates[0];
}
// where an imported artifact is written in the importer's sandbox — always the
// project tree, so an imported skill lands beside the tenant's own ones instead of
// in a directory none of them has.
function artifactInstallTargets(deps: RegistryDeps, os: string, type: ArtType, name: string): {
  baseDir: string;
} {
  const c = claudeDirs(deps, os)[0];
  switch (type) {
    case "skill":
      return { baseDir: path.join(c, "skills", name) };
    case "subagent":
      return { baseDir: path.join(c, "agents") };
    case "command":
    case "workflow":
      return { baseDir: path.join(c, "commands") };
  }
}

// The scanner's ScanKind has no subagent/command/workflow member; every non-mcp
// artifact is an instruction bundle, so we scan it as "skill" (deterministic +
// judge). For an actual skill DIR we pass the path so the Cisco skill-scanner
// also runs; for single-file artifacts we pass inline content (no path → Cisco
// is skipped, which is correct — it expects a skill dir).
function buildScanInput(type: ArtType, src: string, actor: string, userId: string): ScanInput {
  if (type === "skill") return { kind: "skill", path: src, actor, userId };
  const content = fs.readFileSync(src, "utf8");
  return { kind: "skill", content, actor, userId };
}
async function scanArtifactSource(deps: RegistryDeps, type: ArtType, src: string, actor: string, userId: string): Promise<ScanResult> {
  return scanArtifact(
    {
      judge: httpJudgeClient(deps.judgeUrl),
      audit: (ev) => void sendAudit(deps.auditSocket, ev).catch(() => {}),
    },
    buildScanInput(type, src, actor, userId),
  );
}

// ── pod dispatch (publish git WRITE happens where the PAT is injected) ───────
async function dispatchPublishToPod(
  deps: RegistryDeps,
  args: { os: string; type: ArtType; name: string; version: string; source: string },
): Promise<{ ok: boolean; gitRef?: string; commitSha?: string; prNumber?: number; prUrl?: string; merged?: boolean; mergeState?: string; error?: string }> {
  const runDir = path.join(tenantHome(deps, args.os), ".claude", "run");
  const reqFile = path.join(runDir, "registry-task.json");
  const resFile = path.join(runDir, "registry-task.result.json");
  const requestId = randomUUID();
  try {
    fs.mkdirSync(runDir, { recursive: true });
  } catch { /* tenant owns it; mkdir best-effort */ }
  // stale result from a prior job must not satisfy this poll
  try { fs.rmSync(resFile, { force: true }); } catch { /* ignore */ }
  const job = {
    requestId,
    type: args.type,
    name: args.name,
    version: args.version,
    repo: deps.repo,
    ownerUsername: args.os,
    source: args.source,
    // Land it, do not park it. Everything upstream of here has already decided the
    // artefact may be shared: the scanners passed (fail-closed) and a non-admin's
    // publish carried an approval. Leaving a PR for a human to merge would re-ask a
    // question that was just answered, and until someone clicks, the colleague who
    // asked for the skill still cannot import it — the version row exists but the ref
    // is not on the default branch. The helper squash-merges via the API and reports
    // mergeState; if branch protection refuses, it degrades to merge-deferred rather
    // than failing the publish, so the PR is still there as a fallback.
    merge: true,
  };
  fs.writeFileSync(reqFile, JSON.stringify(job) + "\n", { mode: 0o644 });
  // keep the file tenant-owned so the pod supervisor (tenant uid) can rm it
  chownToTenant(deps, args.os, reqFile);

  const deadline = Date.now() + POLL_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await sleep(POLL_INTERVAL_MS);
    if (!fs.existsSync(resFile)) continue;
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(fs.readFileSync(resFile, "utf8")) as Record<string, unknown>;
    } catch {
      continue; // mid-write; retry
    }
    if (parsed.requestId && parsed.requestId !== requestId) continue; // older job's result
    try { fs.rmSync(resFile, { force: true }); } catch { /* ignore */ }
    if (parsed.ok === true) {
      return {
        ok: true,
        gitRef: parsed.gitRef as string,
        commitSha: parsed.commitSha as string,
        prNumber: parsed.prNumber as number,
        prUrl: parsed.prUrl as string,
        // Whether it actually landed on the default branch. A colleague can only
        // import a merged version, so this is the difference between "shared" and
        // "waiting on a human" — it has to reach the caller, not just the log.
        merged: parsed.merged === true,
        mergeState: (parsed.mergeState as string) || undefined,
      };
    }
    return { ok: false, error: (parsed.error as string) || "publish failed" };
  }
  return { ok: false, error: "publish timed out (pod did not respond)" };
}

// ── record a published version in the registry ───────────────────────────────
async function recordPublishedVersion(
  args: {
    ownerUserId: string;
    type: ArtType;
    name: string;
    version: string;
    visibility: string;
    description: string | null;
    gitRef: string;
    scanSummary: Record<string, unknown>;
    provenance: Record<string, unknown>;
  },
): Promise<{ artifactId: string; versionId: string }> {
  // upsert the artifact (one row per owner+type+name)
  const existing = await db
    .select({ id: schema.artifacts.id })
    .from(schema.artifacts)
    .where(
      and(
        eq(schema.artifacts.ownerUserId, args.ownerUserId),
        eq(schema.artifacts.type, args.type),
        eq(schema.artifacts.name, args.name),
      ),
    )
    .limit(1);
  let artifactId: string;
  if (existing[0]) {
    artifactId = existing[0].id;
    await db
      .update(schema.artifacts)
      .set({ visibility: args.visibility, description: args.description })
      .where(eq(schema.artifacts.id, artifactId));
  } else {
    const ins = await db
      .insert(schema.artifacts)
      .values({
        ownerUserId: args.ownerUserId,
        type: args.type,
        name: args.name,
        visibility: args.visibility,
        description: args.description,
      })
      .returning({ id: schema.artifacts.id });
    artifactId = ins[0]!.id;
  }
  const ver = await db
    .insert(schema.artifactVersions)
    .values({
      artifactId,
      version: args.version,
      status: "published",
      gitRef: args.gitRef,
      scanSummary: args.scanSummary,
      provenance: args.provenance,
      publishedAt: new Date(),
    })
    .returning({ id: schema.artifactVersions.id });
  return { artifactId, versionId: ver[0]!.id };
}

// ── shared publish step (admin path + approval-apply path) ───────────────────
type PublishPayload = {
  osUsername: string;
  ownerUserId: string;
  type: ArtType;
  name: string;
  version: string;
  visibility: string;
  description: string | null;
  source: string;
  scan: { verdict: string; severity: string | null; decidedBy: string; cacheHit: boolean };
};

async function runPublish(deps: RegistryDeps, p: PublishPayload): Promise<{ ok: boolean; error?: string; versionId?: string; prUrl?: string; gitRef?: string; merged?: boolean; mergeState?: string }> {
  const disp = await dispatchPublishToPod(deps, {
    os: p.osUsername,
    type: p.type,
    name: p.name,
    version: p.version,
    source: p.source,
  });
  if (!disp.ok) {
    await sendAudit(deps.auditSocket, {
      userId: p.ownerUserId,
      kind: "registry.publish.failed",
      actor: `miniapp:${p.osUsername}`,
      payload: { type: p.type, name: p.name, version: p.version, error: disp.error },
    }).catch(() => {});
    return { ok: false, error: disp.error };
  }
  const rec = await recordPublishedVersion({
    ownerUserId: p.ownerUserId,
    type: p.type,
    name: p.name,
    version: p.version,
    visibility: p.visibility,
    description: p.description,
    gitRef: disp.gitRef!,
    scanSummary: {
      verdict: p.scan.verdict,
      severity: p.scan.severity,
      decidedBy: p.scan.decidedBy,
      cacheHit: p.scan.cacheHit,
    },
    provenance: {
      author: p.osUsername,
      prNumber: disp.prNumber,
      prUrl: disp.prUrl,
      commitSha: disp.commitSha,
      scanVerdict: p.scan.verdict,
      scanDecidedBy: p.scan.decidedBy,
    },
  });
  await sendAudit(deps.auditSocket, {
    userId: p.ownerUserId,
    kind: "registry.publish",
    actor: `miniapp:${p.osUsername}`,
    payload: { type: p.type, name: p.name, version: p.version, gitRef: disp.gitRef, prUrl: disp.prUrl, versionId: rec.versionId },
  }).catch(() => {});
  return { ok: true, versionId: rec.versionId, prUrl: disp.prUrl, gitRef: disp.gitRef, merged: disp.merged, mergeState: disp.mergeState };
}

// ── GitHub READ (import fetch) ───────────────────────────────────────────────
// Originally written for a PUBLIC marketplace repo and sent no credential at all. The
// firm's repo is private, where GitHub answers 404 — indistinguishable from a missing
// file — so an unauthenticated import failed with a message that pointed at the wrong
// thing. A read-only token is attached when configured. It is a SEPARATE token from the
// pods' write PAT on purpose: cp-api can read the marketplace and still cannot push to
// it, which keeps the git-write capability where the egress proxy injects it.
type FetchedFile = { relPath: string; content: string };
async function ghGetJson(repo: string, apiPath: string, readToken?: string): Promise<unknown> {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "User-Agent": "fleet-registry-import",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  if (readToken) headers.Authorization = `Bearer ${readToken}`;
  const res = await fetch(`https://api.github.com/repos/${repo}/${apiPath}`, { headers });
  if (!res.ok) {
    // 404 on a private repo without a credential is the common case, and saying
    // "not found" would send someone hunting for a missing file.
    if ((res.status === 404 || res.status === 403) && !readToken) {
      throw new Error(
        `GitHub ${res.status} on ${apiPath} and no read token is configured — ` +
        `a private marketplace repo cannot be read anonymously (set GITHUB_READ_TOKEN)`,
      );
    }
    throw new Error(`GitHub ${res.status} on ${apiPath}`);
  }
  return res.json();
}
// Recursively fetch the artifact's files at a pinned ref. destBase is the repo
// path the publish wrote to (skills/<name>, agents/<name>.md, …) derived from type/name.
function repoDestFor(type: ArtType, name: string): { repoPath: string; isDir: boolean } {
  switch (type) {
    case "skill":
      return { repoPath: `skills/${name}`, isDir: true };
    case "subagent":
      return { repoPath: `agents/${name}.md`, isDir: false };
    case "command":
      return { repoPath: `commands/${name}.md`, isDir: false };
    case "workflow":
      return { repoPath: `workflows/${name}.md`, isDir: false };
  }
}
async function fetchArtifactFiles(repo: string, ref: string, type: ArtType, name: string, readToken?: string): Promise<FetchedFile[]> {
  const { repoPath, isDir } = repoDestFor(type, name);
  const out: FetchedFile[] = [];
  const walk = async (p: string, rel: string): Promise<void> => {
    const node = (await ghGetJson(repo, `contents/${p}?ref=${encodeURIComponent(ref)}`, readToken)) as
      | { type: string; content?: string; encoding?: string }
      | Array<{ type: string; name: string; path: string }>;
    if (Array.isArray(node)) {
      for (const ent of node) {
        const childRel = rel ? `${rel}/${ent.name}` : ent.name;
        if (ent.type === "dir") await walk(ent.path, childRel);
        else await walk(ent.path, childRel);
      }
      return;
    }
    if (node.type === "file" && node.content) {
      out.push({ relPath: rel, content: Buffer.from(node.content, node.encoding === "base64" ? "base64" : "utf8").toString("utf8") });
    }
  };
  await walk(repoPath, isDir ? "" : path.basename(repoPath));
  return out;
}

// ── install fetched files into the importer's sandbox (tenant-owned) ─────────
function installFiles(deps: RegistryDeps, os: string, type: ArtType, name: string, files: FetchedFile[]): string[] {
  const { baseDir } = artifactInstallTargets(deps, os, type, name);
  const written: string[] = [];
  for (const f of files) {
    // skill: files are relative inside skills/<name>/; others: single file under baseDir
    const dest = type === "skill" ? path.join(baseDir, f.relPath) : path.join(baseDir, f.relPath);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, f.content, { mode: 0o644 });
    chownToTenant(deps, os, dest);
    written.push(dest);
  }
  return written;
}

// ── route registration ───────────────────────────────────────────────────────
export function registerRegistryRoutes(app: FastifyInstance, deps: RegistryDeps): void {
  // Two ways in, both resolving to the same AuthCtx:
  //   * a Mini App session JWT — the browser path;
  //   * a per-tenant registry token — the CHAT path. The tenants here live in Telegram
  //     and there is no web front end on the firm host (nginx exposes only the Composio
  //     callback and the deploy webhook), so without this there is no way for a person
  //     to reach publish/import at all.
  // Deliberately the same shape as the dbread gateway (apps/dbread-gateway/src/index.ts):
  // the map on disk holds only sha256(token) → os username, so it is not itself a
  // credential; it is re-read per request, so deleting a line revokes immediately; and an
  // unreadable/missing map authorises nobody (fail-closed).
  // NOTE this widens auth for /registry/* ONLY, and the token still buys exactly what a
  // session buys — scan and approval still gate every publish and import.
  const tokensFile = process.env.REGISTRY_TOKENS_FILE ?? "/etc/claudeapp/registry/tokens.json";
  const tenantForToken = async (token: string): Promise<AuthCtx | null> => {
    let osUsername: string | undefined;
    try {
      const digest = createHash("sha256").update(token).digest("hex");
      const map = JSON.parse(fs.readFileSync(tokensFile, "utf8")) as Record<string, string>;
      osUsername = map[digest];
    } catch {
      return null;
    }
    if (!osUsername) return null;
    const rows = await db
      .select({ id: schema.users.id, status: schema.users.status, isAdmin: schema.users.isAdmin })
      .from(schema.users)
      .where(eq(schema.users.osUsername, osUsername))
      .limit(1);
    const u = rows[0];
    if (!u || u.status === "suspended" || u.status === "deleted") return null;
    return { userId: u.id, osUsername, isAdmin: u.isAdmin };
  };

  const authed = async (req: FastifyRequest, reply: FastifyReply): Promise<AuthCtx | null> => {
    try {
      return await requireAuth(req, deps.redis, deps.jwtSecret);
    } catch (e) {
      const auth = req.headers.authorization ?? "";
      const raw = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
      if (raw) {
        const ctx = await tenantForToken(raw);
        if (ctx) return ctx;
      }
      const err = e as AuthError;
      reply.code(err.code ?? 401).send({ error: err.message });
      return null;
    }
  };

  // catalog: my artifacts + everyone's public ones
  app.get("/registry/items", async (req, reply) => {
    const ctx = await authed(req, reply);
    if (!ctx) return;
    const q = (req.query ?? {}) as { type?: string; visibility?: string };
    const rows = await db
      .select({
        id: schema.artifacts.id,
        type: schema.artifacts.type,
        name: schema.artifacts.name,
        description: schema.artifacts.description,
        visibility: schema.artifacts.visibility,
        ownerUserId: schema.artifacts.ownerUserId,
        ownerUsername: schema.users.osUsername,
      })
      .from(schema.artifacts)
      .leftJoin(schema.users, eq(schema.users.id, schema.artifacts.ownerUserId))
      .where(or(eq(schema.artifacts.visibility, "public"), eq(schema.artifacts.ownerUserId, ctx.userId)));
    const items = rows
      .filter((r) => (q.type ? r.type === q.type : true))
      .filter((r) => (q.visibility ? r.visibility === q.visibility : true))
      .map((r) => ({ ...r, mine: r.ownerUserId === ctx.userId }));
    return reply.send({ items });
  });

  // one artifact + its versions (own, or public)
  app.get("/registry/items/:id", async (req, reply) => {
    const ctx = await authed(req, reply);
    if (!ctx) return;
    const id = (req.params as { id: string }).id;
    const art = (
      await db.select().from(schema.artifacts).where(eq(schema.artifacts.id, id)).limit(1)
    )[0];
    if (!art) return reply.code(404).send({ error: "not found" });
    if (art.visibility !== "public" && art.ownerUserId !== ctx.userId) {
      return reply.code(403).send({ error: "private artifact" });
    }
    const versions = await db
      .select()
      .from(schema.artifactVersions)
      .where(eq(schema.artifactVersions.artifactId, id))
      .orderBy(desc(schema.artifactVersions.publishedAt));
    return reply.send({ artifact: art, versions, mine: art.ownerUserId === ctx.userId });
  });

  // publish
  app.post("/registry/publish", async (req, reply) => {
    const ctx = await authed(req, reply);
    if (!ctx) return;
    const body = (req.body ?? {}) as {
      type?: unknown; name?: unknown; version?: unknown; visibility?: unknown; description?: unknown;
    };
    if (typeof body.type !== "string" || !ARTIFACT_TYPES.includes(body.type as ArtType)) {
      return reply.code(400).send({ error: `type ∈ ${ARTIFACT_TYPES.join("|")}` });
    }
    if (typeof body.name !== "string" || !NAME_RE.test(body.name)) {
      return reply.code(400).send({ error: "name: [a-z0-9._-], ≤49" });
    }
    if (typeof body.version !== "string" || !VERSION_RE.test(body.version)) {
      return reply.code(400).send({ error: "version: semver-ish x.y.z" });
    }
    const type = body.type as ArtType;
    const name = body.name;
    const version = body.version;
    const visibility = body.visibility === "public" ? "public" : "private";
    const description = typeof body.description === "string" ? body.description.slice(0, 500) : null;

    const src = artifactSourcePath(deps, ctx.osUsername, type, name);
    if (!fs.existsSync(src)) return reply.code(404).send({ error: `artifact not found in your sandbox: ${type}/${name}` });

    const scan = await scanArtifactSource(deps, type, src, `miniapp:${ctx.osUsername}`, ctx.userId);
    if (scan.verdict !== "pass") {
      await sendAudit(deps.auditSocket, {
        userId: ctx.userId,
        kind: "registry.publish.blocked",
        actor: `miniapp:${ctx.osUsername}`,
        payload: { type, name, version, verdict: scan.verdict, severity: scan.severity, decidedBy: scan.decidedBy },
      }).catch(() => {});
      return reply.code(422).send({
        error: scan.verdict === "error" ? "scanner unavailable — refused (fail-closed)" : "the artefact did not pass the scanner",
        verdict: scan.verdict,
        severity: scan.severity,
        decidedBy: scan.decidedBy,
        findings: scan.findings,
        reportRef: scan.reportRef,
      });
    }

    const payload: PublishPayload = {
      osUsername: ctx.osUsername,
      ownerUserId: ctx.userId,
      type,
      name,
      version,
      visibility,
      description,
      source: src,
      scan: { verdict: scan.verdict, severity: scan.severity, decidedBy: scan.decidedBy, cacheHit: scan.cacheHit },
    };

    // admins publish without an approval card; everyone else must confirm (design §3).
    if (ctx.isAdmin) {
      const res = await runPublish(deps, payload);
      if (!res.ok) return reply.code(502).send({ error: res.error });
      return reply.send({ published: true, versionId: res.versionId, prUrl: res.prUrl, gitRef: res.gitRef, merged: res.merged, mergeState: res.mergeState, verdict: scan.verdict });
    }
    const approval = await createApproval(deps.approvals, {
      userId: ctx.userId,
      kind: REGISTRY_PUBLISH_KIND,
      title: `Publish ${type} "${name}" v${version} (${visibility})`,
      payload,
      ttlSeconds: APPROVAL_TTL,
    });
    return reply.send({ approvalId: approval.id, ttlSeconds: approval.ttlSeconds, verdict: scan.verdict });
  });

  // import
  app.post("/registry/import", async (req, reply) => {
    const ctx = await authed(req, reply);
    if (!ctx) return;
    const body = (req.body ?? {}) as { artifactVersionId?: unknown };
    if (typeof body.artifactVersionId !== "string") return reply.code(400).send({ error: "expected { artifactVersionId }" });

    const ver = (
      await db
        .select({
          vId: schema.artifactVersions.id,
          gitRef: schema.artifactVersions.gitRef,
          version: schema.artifactVersions.version,
          status: schema.artifactVersions.status,
          artId: schema.artifacts.id,
          type: schema.artifacts.type,
          name: schema.artifacts.name,
          visibility: schema.artifacts.visibility,
          ownerUserId: schema.artifacts.ownerUserId,
        })
        .from(schema.artifactVersions)
        .leftJoin(schema.artifacts, eq(schema.artifacts.id, schema.artifactVersions.artifactId))
        .where(eq(schema.artifactVersions.id, body.artifactVersionId))
        .limit(1)
    )[0];
    if (!ver || !ver.artId) return reply.code(404).send({ error: "version not found" });
    if (ver.visibility !== "public" && ver.ownerUserId !== ctx.userId) {
      return reply.code(403).send({ error: "private artifact" });
    }
    if (ver.status !== "published" || !ver.gitRef) return reply.code(409).send({ error: "version not published" });
    const type = ver.type as ArtType;

    // pull the pinned version from the public repo, re-scan under current rules
    let files: FetchedFile[];
    try {
      files = await fetchArtifactFiles(deps.repo, ver.gitRef, type, ver.name!, deps.githubReadToken);
    } catch (e) {
      return reply.code(502).send({ error: `fetch from marketplace failed: ${(e as Error).message}` });
    }
    if (!files.length) return reply.code(502).send({ error: "no files at pinned version" });
    const concat = files.map((f) => `# ${f.relPath}\n${f.content}`).join("\n\n");
    const scan = await scanArtifact(
      { judge: httpJudgeClient(deps.judgeUrl), audit: (ev) => void sendAudit(deps.auditSocket, ev).catch(() => {}) },
      { kind: "skill", content: concat, actor: `miniapp:${ctx.osUsername}`, userId: ctx.userId },
    );
    if (scan.verdict !== "pass") {
      await sendAudit(deps.auditSocket, {
        userId: ctx.userId,
        kind: "registry.import.blocked",
        actor: `miniapp:${ctx.osUsername}`,
        payload: { artifactVersionId: ver.vId, verdict: scan.verdict, severity: scan.severity },
      }).catch(() => {});
      return reply.code(422).send({ error: "the import did not pass the re-scan (fail-closed)", verdict: scan.verdict, severity: scan.severity });
    }

    // Install straight away. The approval card this used to raise was unanswerable on a
    // deployment with no Mini App — it notified the tenant with a button leading nowhere,
    // so every import parked forever. And on Vitaliy's call (2026-09-04) it was not
    // earning its keep either: the scanners above are the gate, they run fail-closed on
    // the pinned files under current rules, and re-asking the person who just typed
    // "install this" adds a click, not a decision.
    // What still stops a bad import: visibility/ownership checks, published-status check,
    // the fail-closed re-scan, and the audit line below.
    const written = installFiles(deps, ctx.osUsername, type, ver.name!, files);
    await db
      .insert(schema.installs)
      .values({ userId: ctx.userId, artifactVersionId: ver.vId, pinnedVersion: ver.version! })
      .onConflictDoNothing();
    await sendAudit(deps.auditSocket, {
      userId: ctx.userId,
      kind: "registry.import",
      actor: `chat:${ctx.osUsername}`,
      payload: { artifactVersionId: ver.vId, type, name: ver.name, version: ver.version, files: written.length },
    }).catch(() => {});
    return reply.send({
      installed: true,
      type,
      name: ver.name,
      version: ver.version,
      files: written.length,
      verdict: scan.verdict,
    });
  });

  // unpublish (owner only) — removes the registry rows; does not rewrite git history
  app.delete("/registry/items/:id", async (req, reply) => {
    const ctx = await authed(req, reply);
    if (!ctx) return;
    const id = (req.params as { id: string }).id;
    const art = (await db.select().from(schema.artifacts).where(eq(schema.artifacts.id, id)).limit(1))[0];
    if (!art) return reply.code(404).send({ error: "not found" });
    if (art.ownerUserId !== ctx.userId) return reply.code(403).send({ error: "not your artifact" });
    await db.delete(schema.artifacts).where(eq(schema.artifacts.id, id)); // versions cascade
    await sendAudit(deps.auditSocket, {
      userId: ctx.userId,
      kind: "registry.unpublish",
      actor: `miniapp:${ctx.osUsername}`,
      payload: { artifactId: id, type: art.type, name: art.name },
    }).catch(() => {});
    return reply.send({ ok: true });
  });
}

// ── approval-apply handlers (registered in index.ts) ─────────────────────────
export function makePublishApply(deps: RegistryDeps) {
  return async (row: { payload?: unknown }): Promise<{ ok: boolean; error?: string }> => {
    const p = (row.payload ?? {}) as PublishPayload;
    if (typeof p.osUsername !== "string" || typeof p.ownerUserId !== "string" || typeof p.source !== "string") {
      return { ok: false, error: "malformed publish payload" };
    }
    const res = await runPublish(deps, p);
    return res.ok ? { ok: true } : { ok: false, error: res.error };
  };
}
export function makeImportApply(deps: RegistryDeps) {
  return async (row: { payload?: unknown }): Promise<{ ok: boolean; error?: string }> => {
    const p = (row.payload ?? {}) as {
      osUsername: string; ownerUserId: string; artifactVersionId: string; type: ArtType; name: string; version: string; gitRef: string;
    };
    if (typeof p.osUsername !== "string" || typeof p.gitRef !== "string" || !ARTIFACT_TYPES.includes(p.type)) {
      return { ok: false, error: "malformed import payload" };
    }
    let files: FetchedFile[];
    try {
      files = await fetchArtifactFiles(deps.repo, p.gitRef, p.type, p.name, deps.githubReadToken);
    } catch (e) {
      return { ok: false, error: `fetch failed: ${(e as Error).message}` };
    }
    if (!files.length) return { ok: false, error: "no files at pinned version" };
    const written = installFiles(deps, p.osUsername, p.type, p.name, files);
    await db
      .insert(schema.installs)
      .values({ userId: p.ownerUserId, artifactVersionId: p.artifactVersionId, pinnedVersion: p.version })
      .onConflictDoNothing();
    await sendAudit(deps.auditSocket, {
      userId: p.ownerUserId,
      kind: "registry.import",
      actor: `miniapp:${p.osUsername}`,
      payload: { type: p.type, name: p.name, version: p.version, files: written.length, gitRef: p.gitRef },
    }).catch(() => {});
    return { ok: true };
  };
}

// ── helpers ───────────────────────────────────────────────────────────────────
function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
// cp-api runs as root; keep written files owned by the tenant (uid/gid of their
// ~/.claude), mirroring mcp-gate's owned-write convention.
function chownToTenant(deps: RegistryDeps, os: string, file: string): void {
  try {
    const ref = path.join(tenantHome(deps, os), ".claude");
    const st = fs.statSync(ref);
    fs.chownSync(file, st.uid, st.gid);
  } catch {
    /* best-effort; a root-owned file under a tenant dir is still readable by claude */
  }
}
