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
import { getDb, schema } from "@fleet/db";
import { and, eq } from "drizzle-orm";
import { sendAudit } from "./audit.js";
import { callSecretd } from "./secretd.js";

const execFileP = promisify(execFile);

// A2(c) populate-on-bind: keep `secret_bindings` (the deploy-reconcile bound-secret
// source of truth) in sync as the productized mcp-installer binds/unbinds vault
// secrets — so it stays accurate without re-running the one-time backfill.
// placeholder = the full OneCLI secret name the reconcile reads. Best-effort: a DB
// hiccup must NEVER fail the connect/disconnect — the host secret-bindings-backfill.py
// re-sync remains the safety net (and is the only sync for the legacy mcp-set-secret
// path, which is slated for elimination). Idempotent (delete the (user,placeholder)
// row, then insert).
async function upsertSecretBinding(userId: string, placeholder: string, host: string): Promise<void> {
  try {
    const db = getDb();
    await db
      .delete(schema.secretBindings)
      .where(and(eq(schema.secretBindings.userId, userId), eq(schema.secretBindings.placeholder, placeholder)));
    await db.insert(schema.secretBindings).values({ userId, placeholder, host });
  } catch {
    /* projection is best-effort; backfill re-syncs from OneCLI */
  }
}

async function removeSecretBinding(userId: string, placeholder: string): Promise<void> {
  try {
    const db = getDb();
    await db
      .delete(schema.secretBindings)
      .where(and(eq(schema.secretBindings.userId, userId), eq(schema.secretBindings.placeholder, placeholder)));
  } catch {
    /* best-effort */
  }
}

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
  secretdSocket: string; // cp-secretd unix socket (M5.5b); helper may be absent
}

export type McpStanza = Record<string, unknown>;

// ── M5.5b: secret intake (value → OneCLI vault via cp-secretd) ───────────────

// What the user submits alongside the stanza. The VALUE never goes anywhere
// except the cp-secretd socket (→ vault): not into the approval payload, not
// into Redis, not into audit, not into any tenant file.
export interface SecretSpec {
  value: string;
  hostPattern: string;
  headerName: string;
  valueFormat: string; // e.g. "Bearer {value}" — must contain {value}
}

// Vault-side meta that DOES travel in the approval payload (no value).
export interface SecretMeta {
  name: string; // <osUsername>-mcp-<mcpName> (helper enforces the convention)
  hostPattern: string;
  headerName: string;
  valueFormat: string;
}

export function secretNameFor(osUsername: string, mcpName: string): string {
  return `${osUsername}-mcp-${mcpName}`;
}

// Mirrors cp-secretd's own validation (defense in depth + friendlier errors
// before a socket round-trip). The helper's name regex is lowercase-only, so
// an MCP carrying a secret gets the stricter name rule.
const SECRET_MCP_NAME_RE = /^[a-z0-9][a-z0-9._-]{0,48}$/;
const HOST_PATTERN_RE = /^(\*\.)?[A-Za-z0-9][A-Za-z0-9.-]{1,200}\.[A-Za-z]{2,}$/;
const HEADER_NAME_RE = /^[A-Za-z0-9-]{1,64}$/;
const MAX_SECRET_VALUE = 4096;

export function validateSecretSpec(mcpName: string, spec: unknown): string | null {
  if (typeof spec !== "object" || spec === null || Array.isArray(spec)) {
    return "secretSpec: должен быть объектом { value, hostPattern, headerName, valueFormat }";
  }
  const s = spec as Record<string, unknown>;
  if (!SECRET_MCP_NAME_RE.test(mcpName)) {
    return "имя MCP с секретом: строчные латиница/цифры/._-, до 49 символов (имя секрета строится из него)";
  }
  if (typeof s.value !== "string" || s.value.trim() === "" || s.value.length > MAX_SECRET_VALUE) {
    return `секрет: непустая строка до ${MAX_SECRET_VALUE} символов`;
  }
  if (/[\n\r\0]/.test(s.value)) return "секрет: без переводов строк";
  if (typeof s.hostPattern !== "string" || !HOST_PATTERN_RE.test(s.hostPattern)) {
    return "hostPattern: домен вида api.example.com или *.example.com";
  }
  if (typeof s.headerName !== "string" || !HEADER_NAME_RE.test(s.headerName)) {
    return "headerName: 1–64 символа [A-Za-z0-9-]";
  }
  if (typeof s.valueFormat !== "string" || !s.valueFormat.includes("{value}") || s.valueFormat.length > 64) {
    return 'valueFormat: до 64 символов, обязан содержать "{value}"';
  }
  return null;
}

// Stage = create the secret in the vault UNBOUND (inert: no agent can use it).
// Runs after scan-pass, before the approval. Rotation (same name exists) is
// unbind+delete+recreate — approved M5.5b decision Q4.
export async function stageSecret(
  deps: McpGateDeps,
  args: { userId: string; osUsername: string; mcpName: string; spec: SecretSpec },
): Promise<{ ok: boolean; meta?: SecretMeta; rotated?: boolean; error?: string }> {
  const name = secretNameFor(args.osUsername, args.mcpName);
  const res = await callSecretd(deps.secretdSocket, {
    verb: "stage_secret",
    name,
    value: args.spec.value,
    hostPattern: args.spec.hostPattern,
    headerName: args.spec.headerName,
    valueFormat: args.spec.valueFormat,
  });
  if (!res.ok) return { ok: false, error: res.error ?? "stage_secret failed" };
  await sendAudit(deps.auditSocket, {
    userId: args.userId,
    kind: "mcp.secret.staged",
    actor: "cp-api",
    payload: { name, hostPattern: args.spec.hostPattern, headerName: args.spec.headerName, rotated: res.rotated === true },
  }).catch(() => {});
  return {
    ok: true,
    rotated: res.rotated === true,
    meta: {
      name,
      hostPattern: args.spec.hostPattern,
      headerName: args.spec.headerName,
      valueFormat: args.spec.valueFormat,
    },
  };
}

// Best-effort cleanup of a staged secret (deny path; unbound = inert, so a
// failed delete is logged, never fatal). Expired approvals are not swept:
// the orphan is unbound, and a same-name reconnect rotates it away.
export async function deleteStagedSecret(
  deps: McpGateDeps,
  userId: string | null,
  secretName: string,
  opts: { onlyIfUnbound?: boolean } = {},
): Promise<void> {
  // onlyIfUnbound (deny/onReject path): if the same-name secret is already
  // BOUND, a parallel same-name approval was allowed first — deleting here
  // would yank a live secret from under an applied stanza. Skip instead;
  // disconnect remains the authoritative cleanup for bound secrets.
  if (opts.onlyIfUnbound) {
    const st = await callSecretd(deps.secretdSocket, { verb: "secret_exists", name: secretName }).catch(() => null);
    if (st?.ok && st.bound === true) {
      await sendAudit(deps.auditSocket, {
        userId,
        kind: "mcp.secret.deleted",
        actor: "cp-api",
        payload: { name: secretName, ok: true, skipped: "bound" },
      }).catch(() => {});
      return;
    }
  }
  const res = await callSecretd(deps.secretdSocket, { verb: "delete_secret", name: secretName });
  await sendAudit(deps.auditSocket, {
    userId,
    kind: "mcp.secret.deleted",
    actor: "cp-api",
    payload: { name: secretName, ok: res.ok, ...(res.ok ? {} : { error: res.error }) },
  }).catch(() => {});
}

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
// M5.5b: when the approval carries a staged secret, BIND it first; a stanza
// whose secret can't bind is never written (the MCP would just fail opaquely).
export async function applyMcpConnect(
  deps: McpGateDeps,
  args: { userId: string; osUsername: string; name: string; stanza: McpStanza; secret?: SecretMeta },
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

  if (args.secret) {
    if (args.secret.name !== secretNameFor(args.osUsername, args.name)) {
      return fail("secret name does not match the convention for this MCP"); // payload is data, not trust
    }
    const bind = await callSecretd(deps.secretdSocket, { verb: "bind_secret", name: args.secret.name });
    if (!bind.ok) return fail(`bind_secret: ${bind.error ?? "failed"}`);
    await sendAudit(deps.auditSocket, {
      userId: args.userId,
      kind: "mcp.secret.bound",
      actor: "cp-api",
      payload: { name: args.secret.name, hostPattern: args.secret.hostPattern },
    }).catch(() => {});
    // A2(c): record the binding in the reconcile's source of truth.
    await upsertSecretBinding(args.userId, args.secret.name, args.secret.hostPattern);
  }

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
// is exactly the rollback of a connect. M5.5b: the MCP's convention-named
// vault secret (if any) is unbound+deleted too — best-effort, after the files.
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

    // M5.5b: drop the paired vault secret. Idempotent (deleted:false when none);
    // helper absent (pre-M5.5b deploys) degrades silently — deleted stays false.
    let secretDeleted = false;
    if (SECRET_MCP_NAME_RE.test(args.name)) {
      const secretName = secretNameFor(args.osUsername, args.name);
      const del = await callSecretd(deps.secretdSocket, {
        verb: "delete_secret",
        name: secretName,
      });
      secretDeleted = del.ok && del.deleted === true;
      // A2(c): drop the binding from the reconcile's source of truth (idempotent,
      // independent of del.deleted — clears any stale row).
      await removeSecretBinding(args.userId, secretName);
    }

    await sendAudit(deps.auditSocket, {
      userId: args.userId,
      kind: "mcp.disconnect",
      actor: "cp-api",
      payload: { name: args.name, committed, secretDeleted },
    }).catch(() => {});
    return { ok: true, name: args.name, committed };
  } catch (err) {
    return { ok: false, name: args.name, committed: false, error: (err as Error).message.slice(0, 200) };
  }
}
