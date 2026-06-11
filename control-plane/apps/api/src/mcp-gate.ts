// M5.5 — gated MCP connect (docs/M5.5-mcp-gate-design.md). BOUNDARY-2 (ADR-004):
// pre-screening at the untrusted entry. A user-authored mcpServers stanza reaches
// the tenant config ONLY after (1) shape validation + inline-secret refusal,
// (2) the L4 scanner gate (deterministic + judge, fail-closed) and (3) an explicit
// owner approval (M5.4b). Apply writes the stanza to <home>/work/.mcp.json and
// enables it in ~/.claude/settings.json#enabledMcpjsonServers (WP7 passes both
// through — no rebaseline), then best-effort commits settings.json to the
// ~/.claude git HEAD AS THE TENANT UID so the legacy restore-from-HEAD can't
// silently drop the enable. Disconnect needs no approval: removing a capability
// is the safe direction (and doubles as the one-command rollback of a connect).
import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { scanArtifact, httpJudgeClient, type ScanResult } from "@fleet/scanners";
import { sendAudit } from "./audit.js";

const execFileP = promisify(execFile);

export const MCP_APPROVAL_KIND = "mcp.connect";
export const MCP_TTL_SECONDS = 600;

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
const MAX_STANZA_BYTES = 16 * 1024;
const STDIO_KEYS = new Set(["type", "command", "args", "env", "timeout"]);
const REMOTE_KEYS = new Set(["type", "url", "headers", "timeout"]);

// v1 refuses inline secrets (the invariant: secrets live in OneCLI, files hold
// placeholders — M5.5b adds the vault intake). Two deterministic nets: known
// token shapes anywhere in string values, and secret-ish KEY names whose value
// is not a ${…} placeholder.
const SECRET_VALUE_RE =
  /\b(sk-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{15,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,})/;
const SECRETY_KEY_RE = /(token|secret|key|password|passwd|credential|auth)/i;
const PLACEHOLDER_RE = /^\$\{[^}]+\}$/;

export interface McpGateDeps {
  homeRoot: string; // tenant home = <homeRoot>/<osUsername>
  judgeUrl: string;
  auditSocket: string;
}

export type McpStanza = Record<string, unknown>;

function tenantHome(deps: McpGateDeps, osUsername: string): string {
  return path.resolve(path.join(deps.homeRoot, osUsername));
}
function mcpJsonPath(deps: McpGateDeps, osUsername: string): string {
  return path.join(tenantHome(deps, osUsername), "work", ".mcp.json");
}
function settingsPath(deps: McpGateDeps, osUsername: string): string {
  return path.join(tenantHome(deps, osUsername), ".claude", "settings.json");
}

// ── validation ───────────────────────────────────────────────────────────────

function isStringRecord(v: unknown): v is Record<string, string> {
  return (
    typeof v === "object" &&
    v !== null &&
    !Array.isArray(v) &&
    Object.values(v).every((x) => typeof x === "string")
  );
}

function secretIn(values: Record<string, string>, where: string): string | null {
  for (const [k, v] of Object.entries(values)) {
    if (SECRET_VALUE_RE.test(v)) {
      return `${where}.${k} выглядит как живой секрет — в v1 секреты в стансу нельзя (M5.5b: ключ → OneCLI)`;
    }
    if (SECRETY_KEY_RE.test(k) && v.trim() !== "" && !PLACEHOLDER_RE.test(v)) {
      return `${where}.${k}: значение секретного ключа должно быть заполнителем \${…}, не сырым значением`;
    }
  }
  return null;
}

// Returns a user-facing error message, or null when the stanza is acceptable.
export function validateStanza(name: string, stanza: unknown): string | null {
  if (!NAME_RE.test(name)) return "имя: латиница/цифры/._-, до 64 символов, начинается с буквы или цифры";
  if (typeof stanza !== "object" || stanza === null || Array.isArray(stanza)) return "станса должна быть JSON-объектом";
  if (Buffer.byteLength(JSON.stringify(stanza), "utf8") > MAX_STANZA_BYTES) return "станса больше 16 КиБ";
  const s = stanza as McpStanza;

  const isRemote = typeof s.url === "string" || s.type === "http" || s.type === "sse";
  const allowed = isRemote ? REMOTE_KEYS : STDIO_KEYS;
  for (const k of Object.keys(s)) {
    if (!allowed.has(k)) return `неизвестный ключ "${k}" (разрешены: ${[...allowed].join(", ")})`;
  }
  if (s.timeout !== undefined && (typeof s.timeout !== "number" || s.timeout < 1 || s.timeout > 600_000)) {
    return "timeout: число миллисекунд 1…600000";
  }

  if (isRemote) {
    if (s.type !== undefined && s.type !== "http" && s.type !== "sse") return 'type: "http" или "sse"';
    if (typeof s.url !== "string" || !/^https:\/\/[^\s]+$/.test(s.url)) return "url: обязателен и только https://";
    if (s.headers !== undefined) {
      if (!isStringRecord(s.headers)) return "headers: объект строка→строка";
      const sec = secretIn(s.headers, "headers");
      if (sec) return sec;
    }
    if (SECRET_VALUE_RE.test(s.url)) return "url содержит токеноподобный фрагмент — секреты в v1 нельзя";
    return null;
  }

  if (s.type !== undefined && s.type !== "stdio") return 'type: для локального сервера — "stdio" (или убери поле)';
  if (typeof s.command !== "string" || s.command.trim() === "") return "command: обязателен для stdio-сервера";
  if (s.args !== undefined) {
    if (!Array.isArray(s.args) || !s.args.every((a) => typeof a === "string")) return "args: массив строк";
    const argRec = Object.fromEntries(s.args.map((a, i) => [String(i), a as string]));
    const sec = secretIn(argRec, "args");
    if (sec) return sec;
  }
  if (s.env !== undefined) {
    if (!isStringRecord(s.env)) return "env: объект строка→строка";
    const sec = secretIn(s.env, "env");
    if (sec) return sec;
  }
  return null;
}

// ── scan (L4 gate: deterministic + judge, fail-closed) ──────────────────────

export async function scanMcpStanza(
  deps: McpGateDeps,
  args: { name: string; stanza: McpStanza; actor: string; userId: string },
): Promise<ScanResult> {
  const content = JSON.stringify({ [args.name]: args.stanza }, null, 2);
  return scanArtifact(
    {
      judge: httpJudgeClient(deps.judgeUrl),
      audit: (ev) => void sendAudit(deps.auditSocket, ev).catch(() => {}),
    },
    { kind: "mcp", content, actor: args.actor, userId: args.userId },
  );
}

// ── tenant config IO (cp-api runs as root; files stay tenant-owned) ─────────

interface OwnedJson {
  data: Record<string, unknown>;
  uid: number;
  gid: number;
}

function readJson(file: string, fallback: Record<string, unknown>): Record<string, unknown> {
  if (!fs.existsSync(file)) return fallback;
  const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as unknown;
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`${path.basename(file)} is not a JSON object`);
  }
  return parsed as Record<string, unknown>;
}

function writeOwnedJson(file: string, owned: OwnedJson): void {
  const tmp = file + ".mcp-gate-tmp";
  fs.writeFileSync(tmp, JSON.stringify(owned.data, null, 2) + "\n", { mode: 0o644 });
  try {
    fs.chownSync(tmp, owned.uid, owned.gid);
  } catch {
    /* not root (dev) — leave as-is */
  }
  fs.renameSync(tmp, file);
}

function homeOwner(deps: McpGateDeps, osUsername: string): { uid: number; gid: number } {
  const st = fs.statSync(tenantHome(deps, osUsername));
  return { uid: st.uid, gid: st.gid };
}

export function listMcp(
  deps: McpGateDeps,
  osUsername: string,
): { name: string; kind: "stdio" | "remote"; enabled: boolean }[] {
  let servers: Record<string, unknown> = {};
  let enabled: string[] = [];
  try {
    servers = (readJson(mcpJsonPath(deps, osUsername), {}).mcpServers as Record<string, unknown>) ?? {};
  } catch {
    /* unreadable .mcp.json → show nothing rather than 500 */
  }
  try {
    const e = readJson(settingsPath(deps, osUsername), {}).enabledMcpjsonServers;
    if (Array.isArray(e)) enabled = e.filter((x): x is string => typeof x === "string");
  } catch {
    /* ignore */
  }
  return Object.entries(servers).map(([name, st]) => ({
    name,
    kind: typeof (st as McpStanza)?.url === "string" ? "remote" : "stdio",
    enabled: enabled.includes(name),
  }));
}

export function mcpNameExists(deps: McpGateDeps, osUsername: string, name: string): boolean {
  return listMcp(deps, osUsername).some((s) => s.name === name);
}

// Best-effort: commit settings.json to the ~/.claude git HEAD AS THE TENANT UID
// (correct object ownership + no safe.directory friction). Absent git binary /
// not-a-repo / nothing-to-commit all degrade to committed=false, never an error.
async function commitSettings(deps: McpGateDeps, osUsername: string, msg: string): Promise<boolean> {
  const claudeDir = path.join(tenantHome(deps, osUsername), ".claude");
  const { uid, gid } = homeOwner(deps, osUsername);
  const opts = {
    cwd: claudeDir,
    uid,
    gid,
    timeout: 10_000,
    env: { HOME: tenantHome(deps, osUsername), PATH: process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin" },
  };
  try {
    await execFileP("git", ["add", "--", "settings.json"], opts);
    await execFileP(
      "git",
      ["-c", "user.name=cp-api", "-c", "user.email=cp-api@fleet.local", "commit", "-m", msg, "--", "settings.json"],
      opts,
    );
    return true;
  } catch {
    return false;
  }
}

export interface McpApplyResult {
  ok: boolean;
  name: string;
  committed: boolean;
  error?: string;
}

// Called from the approval-answer handler (status already "allowed"). Re-validates
// the payload before touching files — the approval row is data, not trust.
export async function applyMcpConnect(
  deps: McpGateDeps,
  args: { userId: string; osUsername: string; name: string; stanza: McpStanza },
): Promise<McpApplyResult> {
  const fail = async (error: string): Promise<McpApplyResult> => {
    await sendAudit(deps.auditSocket, {
      userId: args.userId,
      kind: "mcp.connect.apply_failed",
      actor: "cp-api",
      payload: { name: args.name, error },
    }).catch(() => {});
    return { ok: false, name: args.name, committed: false, error };
  };

  const invalid = validateStanza(args.name, args.stanza);
  if (invalid) return fail(`re-validation: ${invalid}`);
  if (!fs.existsSync(tenantHome(deps, args.osUsername))) return fail("tenant home not found");

  try {
    const owner = homeOwner(deps, args.osUsername);

    const mcpFile = mcpJsonPath(deps, args.osUsername);
    const mcpJson = readJson(mcpFile, { mcpServers: {} });
    const servers = (mcpJson.mcpServers ?? {}) as Record<string, unknown>;
    servers[args.name] = args.stanza;
    mcpJson.mcpServers = servers;
    writeOwnedJson(mcpFile, { data: mcpJson, ...owner });

    const setFile = settingsPath(deps, args.osUsername);
    if (!fs.existsSync(setFile)) return fail("settings.json not found in tenant sandbox");
    const settings = readJson(setFile, {});
    const enabled = Array.isArray(settings.enabledMcpjsonServers)
      ? (settings.enabledMcpjsonServers as unknown[]).filter((x): x is string => typeof x === "string")
      : [];
    if (!enabled.includes(args.name)) {
      settings.enabledMcpjsonServers = [...enabled, args.name];
      writeOwnedJson(setFile, { data: settings, ...owner });
    }

    const committed = await commitSettings(deps, args.osUsername, `mcp-gate: enable ${args.name} (approved)`);
    await sendAudit(deps.auditSocket, {
      userId: args.userId,
      kind: "mcp.connect.applied",
      actor: "cp-api",
      payload: { name: args.name, committed },
    }).catch(() => {});
    return { ok: true, name: args.name, committed };
  } catch (err) {
    return fail((err as Error).message.slice(0, 200));
  }
}

// Remove a server from both files. No approval: capability removal is safe and
// is exactly the rollback of a connect.
export async function disconnectMcp(
  deps: McpGateDeps,
  args: { userId: string; osUsername: string; name: string },
): Promise<McpApplyResult> {
  try {
    const owner = homeOwner(deps, args.osUsername);
    let removed = false;

    const mcpFile = mcpJsonPath(deps, args.osUsername);
    if (fs.existsSync(mcpFile)) {
      const mcpJson = readJson(mcpFile, { mcpServers: {} });
      const servers = (mcpJson.mcpServers ?? {}) as Record<string, unknown>;
      if (args.name in servers) {
        delete servers[args.name];
        mcpJson.mcpServers = servers;
        writeOwnedJson(mcpFile, { data: mcpJson, ...owner });
        removed = true;
      }
    }

    const setFile = settingsPath(deps, args.osUsername);
    if (fs.existsSync(setFile)) {
      const settings = readJson(setFile, {});
      if (Array.isArray(settings.enabledMcpjsonServers)) {
        const next = (settings.enabledMcpjsonServers as unknown[]).filter((x) => x !== args.name);
        if (next.length !== settings.enabledMcpjsonServers.length) {
          settings.enabledMcpjsonServers = next;
          writeOwnedJson(setFile, { data: settings, ...owner });
          removed = true;
        }
      }
    }

    if (!removed) return { ok: false, name: args.name, committed: false, error: "нет такого MCP" };
    const committed = await commitSettings(deps, args.osUsername, `mcp-gate: disconnect ${args.name}`);
    await sendAudit(deps.auditSocket, {
      userId: args.userId,
      kind: "mcp.disconnect",
      actor: "cp-api",
      payload: { name: args.name, committed },
    }).catch(() => {});
    return { ok: true, name: args.name, committed };
  } catch (err) {
    return { ok: false, name: args.name, committed: false, error: (err as Error).message.slice(0, 200) };
  }
}
