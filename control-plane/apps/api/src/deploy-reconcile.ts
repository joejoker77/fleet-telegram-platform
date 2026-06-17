// A2 — control-plane deploy reconcile (Option A, docs/10). SKILLS path.
//
// Moves per-tenant skill deployment off the host `deploy-skills` timer into the
// control plane: fetch claude-bot-skills `skills/` + `users.yaml` at a ref over
// HTTPS (the scoped GitHub token is injected by the egress proxy — same path M8
// uses), compute the allow-list (mirrors deploy-skills + the Phase-1-validated
// logic), and reconcile the tenant's ~/.claude/skills/<slug>.
//
// SKILLS only — no OneCLI, no settings.json, no settings-guard interaction (the
// guard protects only permissions/hooks; mcpServers/skills pass through). The MCP
// path (settings.json mcpServers + the OneCLI bound-secret check, W2) is separate.
//
// Dry-run by default (computes + diffs, writes nothing). `--apply` writes.
// Runnable via the project's tsx:  tsx deploy-reconcile.ts <user> [--apply] [--ref <ref>]
import fs from "node:fs";
import path from "node:path";
import { eq } from "drizzle-orm";
import { getDb, schema } from "@fleet/db";

const HOME_ROOT = process.env.TENANT_HOME_ROOT || "/home";
const REPO = process.env.REGISTRY_REPO || "joejoker77/claude-bot-skills";

type FetchedFile = { relPath: string; content: string };

async function ghJson(repo: string, apiPath: string): Promise<unknown> {
  const res = await fetch(`https://api.github.com/repos/${repo}/${apiPath}`, {
    headers: { Accept: "application/vnd.github+json", "User-Agent": "fleet-deploy-reconcile" },
  });
  if (!res.ok) throw new Error(`GitHub ${res.status} on ${apiPath}`);
  return res.json();
}

// dir entries (names) of a repo directory at a ref
async function listDir(repo: string, ref: string, dir: string): Promise<{ name: string; type: string }[]> {
  const node = (await ghJson(repo, `contents/${dir}?ref=${encodeURIComponent(ref)}`)) as
    | Array<{ name: string; type: string }>
    | { message?: string };
  return Array.isArray(node) ? node : [];
}

// recursively fetch every file under skills/<slug>/ (relPath is inside the skill dir)
async function fetchSkill(repo: string, ref: string, slug: string): Promise<FetchedFile[]> {
  const out: FetchedFile[] = [];
  const walk = async (p: string, rel: string): Promise<void> => {
    const node = (await ghJson(repo, `contents/${p}?ref=${encodeURIComponent(ref)}`)) as
      | { type: string; content?: string; encoding?: string }
      | Array<{ type: string; name: string; path: string }>;
    if (Array.isArray(node)) {
      for (const ent of node) await walk(ent.path, rel ? `${rel}/${ent.name}` : ent.name);
      return;
    }
    if (node.type === "file" && node.content) {
      out.push({ relPath: rel, content: Buffer.from(node.content, node.encoding === "base64" ? "base64" : "utf8").toString("utf8") });
    }
  };
  await walk(`skills/${slug}`, "");
  return out;
}

async function fetchText(repo: string, ref: string, file: string): Promise<string> {
  const node = (await ghJson(repo, `contents/${file}?ref=${encodeURIComponent(ref)}`)) as { content?: string; encoding?: string };
  return node.content ? Buffer.from(node.content, node.encoding === "base64" ? "base64" : "utf8").toString("utf8") : "";
}

// Minimal users.yaml reader for the stable structure:
//   <section>:
//     <slug>:
//       users: [ - a, - b ]   # absent/non-list => allowed for everyone
// Ignores comments/blank lines and every other key (reason, user_config, ...).
// Returns slug -> users[] | null (null = no users: key => all). Validated against
// the Phase-1 python output.
export function parseSectionUsers(yamlText: string, section: string): Record<string, string[] | null> {
  const result: Record<string, string[] | null> = {};
  let inSection = false, curSlug: string | null = null, inUsers = false;
  for (const raw of yamlText.split("\n")) {
    if (raw.trim() === "" || raw.trim().startsWith("#")) continue;
    const indent = raw.length - raw.trimStart().length;
    const line = raw.trim();
    if (indent === 0) {
      inSection = (line.split(":")[0] ?? "").trim() === section;
      curSlug = null; inUsers = false;
      continue;
    }
    if (!inSection) continue;
    if (indent === 2 && line.endsWith(":")) {
      curSlug = line.slice(0, -1).trim();
      result[curSlug] = null;
      inUsers = false;
      continue;
    }
    if (indent >= 4 && curSlug) {
      if (line === "users:") { inUsers = true; result[curSlug] = []; continue; }
      if (inUsers && line.startsWith("- ")) { (result[curSlug] as string[]).push(line.slice(2).trim()); continue; }
      inUsers = false; // any other key (reason:, user_config:) ends the users list
    }
  }
  return result;
}

export function allowedFor(all: string[], restrictions: Record<string, string[] | null>, user: string): string[] {
  return all.filter((slug) => {
    const u = restrictions[slug];
    return !Array.isArray(u) || u.includes(user); // not listed / no users => all; else only listed
  });
}

function tenantIds(home: string): { uid: number; gid: number } {
  const st = fs.statSync(path.join(home, ".claude"));
  return { uid: st.uid, gid: st.gid };
}

export interface ReconcileResult {
  user: string; ref: string;
  available: string[]; allowed: string[]; installedNow: string[];
  added: string[]; removed: string[]; matchesLive: boolean; applied: boolean;
}

export async function reconcileSkills(opts: { user: string; ref?: string; apply?: boolean }): Promise<ReconcileResult> {
  const { user } = opts;
  const ref = opts.ref || "main";
  const apply = !!opts.apply;
  const home = path.join(HOME_ROOT, user);
  const skillsDir = path.join(home, ".claude", "skills");

  const entries = await listDir(REPO, ref, "skills");
  const available = entries.filter((e) => e.type === "dir").map((e) => e.name).sort();
  const restrictions = parseSectionUsers(await fetchText(REPO, ref, "users.yaml"), "skills");
  const allowed = allowedFor(available, restrictions, user);

  const installedNow = fs.existsSync(skillsDir)
    ? fs.readdirSync(skillsDir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort()
    : [];
  const want = new Set(allowed), have = new Set(installedNow);
  const added = allowed.filter((s) => !have.has(s));
  const removed = installedNow.filter((s) => !want.has(s)); // mirrors deploy-skills: owns ~/.claude/skills
  const matchesLive = added.length === 0 && removed.length === 0;

  if (apply && !matchesLive) {
    const { uid, gid } = tenantIds(home);
    fs.mkdirSync(skillsDir, { recursive: true });
    fs.chownSync(skillsDir, uid, gid);
    for (const slug of removed) fs.rmSync(path.join(skillsDir, slug), { recursive: true, force: true });
    for (const slug of added) {
      const files = await fetchSkill(REPO, ref, slug);
      for (const f of files) {
        const dest = path.join(skillsDir, slug, f.relPath);
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.writeFileSync(dest, f.content, { mode: 0o644 });
        try { fs.chownSync(dest, uid, gid); } catch { /* best-effort */ }
        try { fs.chownSync(path.dirname(dest), uid, gid); } catch { /* best-effort */ }
      }
    }
  }
  return { user, ref, available, allowed, installedNow, added, removed, matchesLive, applied: apply && !matchesLive };
}

// ── MCP path ─────────────────────────────────────────────────────────────────
// Bound-secret check reads secret_bindings (the cp-api DB, backfilled by
// secret-bindings-backfill.py) — NO onecli in cp-api, NO privileged vault creds
// (option (c)). Mirrors deploy-mcp.v2.4: ${USER_CONFIG} from users.yaml,
// ${SECRET:name} -> literal ${ONECLI:name} marker (never the value) + the secret
// must be bound, else the MCP is skipped.
const USER_CONFIG_RE = /\$\{USER_CONFIG:([a-z0-9_]+)\}/g;
const SECRET_RE = /\$\{SECRET:([a-z0-9_-]+)\}/g;

// secret_bindings.placeholder values (full OneCLI names `<user>-<slug>-<name>`) for a tenant.
export async function getBoundPlaceholders(user: string): Promise<Set<string>> {
  const db = getDb();
  const rows = await db
    .select({ placeholder: schema.secretBindings.placeholder })
    .from(schema.secretBindings)
    .innerJoin(schema.users, eq(schema.users.id, schema.secretBindings.userId))
    .where(eq(schema.users.osUsername, user));
  return new Set(rows.map((r) => r.placeholder));
}

// bare secret names bound for (user, slug): strip the `<user>-<slug>-` prefix.
function boundBareNames(user: string, slug: string, placeholders: Set<string>): Set<string> {
  const prefix = `${user}-${slug}-`;
  const out = new Set<string>();
  for (const p of placeholders) if (p.startsWith(prefix)) out.add(p.slice(prefix.length));
  return out;
}

// users.yaml mcp.<slug>.user_config.<user> -> {key: value}. Minimal parse of the
// 4-level block; returns {} when the mcp section is empty/absent (current state).
export function parseMcpUserConfig(yamlText: string, slug: string, user: string): Record<string, string> {
  const out: Record<string, string> = {};
  let inMcp = false, curSlug: string | null = null, inUcfg = false, curUser: string | null = null;
  for (const raw of yamlText.split("\n")) {
    if (raw.trim() === "" || raw.trim().startsWith("#")) continue;
    const indent = raw.length - raw.trimStart().length;
    const line = raw.trim();
    if (indent === 0) { inMcp = (line.split(":")[0] ?? "").trim() === "mcp"; curSlug = null; inUcfg = false; curUser = null; continue; }
    if (!inMcp) continue;
    if (indent === 2 && line.endsWith(":")) { curSlug = line.slice(0, -1).trim(); inUcfg = false; curUser = null; continue; }
    if (curSlug !== slug) continue;
    if (indent === 4) { inUcfg = line === "user_config:"; curUser = null; continue; }
    if (inUcfg && indent === 6 && line.endsWith(":")) { curUser = line.slice(0, -1).trim(); continue; }
    if (inUcfg && curUser === user && indent === 8) {
      const i = line.indexOf(":");
      if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^["']|["']$/g, "");
    }
  }
  return out;
}

function resolveStanza(node: unknown, userConfig: Record<string, string>, bareSecrets: Set<string>, miss: { cfg: string[]; sec: string[] }): unknown {
  if (Array.isArray(node)) return node.map((n) => resolveStanza(n, userConfig, bareSecrets, miss));
  if (node && typeof node === "object") {
    const o: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(node)) o[k] = resolveStanza(v, userConfig, bareSecrets, miss);
    return o;
  }
  if (typeof node === "string") {
    let s = node.replace(USER_CONFIG_RE, (_m, k: string) => {
      if (!(k in userConfig)) { if (!miss.cfg.includes(k)) miss.cfg.push(k); return _m; }
      return userConfig[k]!;
    });
    s = s.replace(SECRET_RE, (_m, name: string) => {
      if (!bareSecrets.has(name) && !miss.sec.includes(name)) miss.sec.push(name);
      return `\${ONECLI:${name}}`;
    });
    return s;
  }
  return node;
}

export interface McpResult {
  user: string; ref: string; available: string[]; allowed: string[];
  wouldManage: string[]; skipped: Record<string, { missing_config?: string[]; missing_secrets?: string[] }>;
  liveMcpServers: string[];
}

export async function reconcileMcp(opts: { user: string; ref?: string; boundPlaceholders?: Set<string> }): Promise<McpResult> {
  const { user } = opts;
  const ref = opts.ref || "main";
  const entries = await listDir(REPO, ref, "mcp");
  const available = entries.filter((e) => e.type === "dir").map((e) => e.name).sort();
  const yamlText = await fetchText(REPO, ref, "users.yaml");
  const allowed = allowedFor(available, parseSectionUsers(yamlText, "mcp"), user);
  const bound = opts.boundPlaceholders ?? (await getBoundPlaceholders(user));

  const wouldManage: string[] = [];
  const skipped: McpResult["skipped"] = {};
  for (const slug of allowed) {
    let tpl: { mcp_stanza?: unknown };
    try { tpl = JSON.parse(await fetchText(REPO, ref, `mcp/${slug}/template.json`)); }
    catch (e) { skipped[slug] = {}; continue; }
    const stanza = tpl.mcp_stanza ?? tpl;
    const miss = { cfg: [] as string[], sec: [] as string[] };
    resolveStanza(stanza, parseMcpUserConfig(yamlText, slug, user), boundBareNames(user, slug, bound), miss);
    if (miss.cfg.length || miss.sec.length) skipped[slug] = { missing_config: miss.cfg, missing_secrets: miss.sec };
    else wouldManage.push(slug);
  }
  const sp = path.join(HOME_ROOT, user, ".claude", "settings.json");
  let live: string[] = [];
  if (fs.existsSync(sp)) { try { live = Object.keys(JSON.parse(fs.readFileSync(sp, "utf8")).mcpServers || {}).sort(); } catch { /* */ } }
  return { user, ref, available, allowed, wouldManage, skipped, liveMcpServers: live };
}

// CLI: tsx deploy-reconcile.ts <user> [--apply] [--ref <ref>]
const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const args = process.argv.slice(2);
  const user = args.find((a) => !a.startsWith("--"));
  const apply = args.includes("--apply");
  const refIdx = args.indexOf("--ref");
  const ref = refIdx >= 0 ? args[refIdx + 1] : "main";
  if (!user) { console.error("usage: deploy-reconcile.ts <user> [--mcp] [--apply] [--ref <ref>] [--bound a,b]"); process.exit(2); }
  const mcp = args.includes("--mcp");
  const boundIdx = args.indexOf("--bound");
  const boundPlaceholders = boundIdx >= 0 ? new Set((args[boundIdx + 1] || "").split(",").filter(Boolean)) : undefined;
  const run = mcp ? reconcileMcp({ user, ref, boundPlaceholders }) : reconcileSkills({ user, ref, apply });
  run
    .then((r) => { console.log(JSON.stringify(r, null, 2)); })
    .catch((e) => { console.error("reconcile failed:", e?.message || e); process.exit(1); });
}
