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

// CLI: tsx deploy-reconcile.ts <user> [--apply] [--ref <ref>]
const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const args = process.argv.slice(2);
  const user = args.find((a) => !a.startsWith("--"));
  const apply = args.includes("--apply");
  const refIdx = args.indexOf("--ref");
  const ref = refIdx >= 0 ? args[refIdx + 1] : "main";
  if (!user) { console.error("usage: deploy-reconcile.ts <user> [--apply] [--ref <ref>]"); process.exit(2); }
  reconcileSkills({ user, ref, apply })
    .then((r) => { console.log(JSON.stringify(r, null, 2)); })
    .catch((e) => { console.error("reconcile failed:", e?.message || e); process.exit(1); });
}
