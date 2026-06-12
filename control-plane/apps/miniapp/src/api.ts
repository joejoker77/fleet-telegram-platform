// Thin typed client for the control-plane API (apps/api).
// Endpoint contracts mirror apps/api/src/index.ts and fs-routes.ts exactly.

export interface AuthSessionResponse {
  token: string;
  expiresAt: string; // ISO
}

export interface MeResponse {
  id: string;
  osUsername: string;
  telegramUserId: string;
  status: string;
}

export interface FsEntry {
  path: string;
  type: "file" | "dir";
  size: number;
}

export interface FsTreeResponse {
  root: string; // ".claude"
  entries: FsEntry[];
}

export interface FsFileResponse {
  path: string;
  content: string;
}

export interface FsPutResponse {
  ok: boolean;
  path: string;
  /** Scanner advisory (non-blocking findings surfaced to the user). */
  advisory?: unknown;
}

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

const BASE = "/api";

// ── Transparent re-auth on 401 ──
// The JWT lives 1h, but Telegram keeps the webview alive in the background far
// longer — components then hold a stale token prop and every call dies with
// "invalid or expired session" (2026-06-11 incident). Single-user app → one
// module-level live token; App registers a refresher (re-exchange initData,
// valid 24h server-side) and request() retries the call once with the fresh
// token. Components keep their old prop — request() prefers the live token.
let liveToken: string | null = null;
let authRefresher: (() => Promise<string>) | null = null;

export function setLiveToken(token: string): void {
  liveToken = token;
}

export function setAuthRefresher(fn: () => Promise<string>): void {
  authRefresher = fn;
}

async function request<T>(path: string, init: RequestInit = {}, token?: string): Promise<T> {
  const doFetch = (tok?: string) => {
    const headers: Record<string, string> = {
      // content-type only when there IS a body: fastify 400s a bodyless
      // request (e.g. DELETE) that carries a json content-type.
      ...(init.body !== undefined ? { "content-type": "application/json" } : {}),
      ...(init.headers as Record<string, string> | undefined),
    };
    if (tok) headers.authorization = `Bearer ${tok}`;
    return fetch(`${BASE}${path}`, { ...init, headers });
  };
  let res = await doFetch(token ? (liveToken ?? token) : undefined);
  if (res.status === 401 && token && authRefresher) {
    try {
      liveToken = await authRefresher();
      res = await doFetch(liveToken);
    } catch {
      /* refresher failed (outside Telegram / initData >24h) — surface the original 401 */
    }
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = typeof (body as { error?: string }).error === "string" ? (body as { error: string }).error : res.statusText;
    throw new ApiError(res.status, msg);
  }
  return body as T;
}

export function authSession(initData: string): Promise<AuthSessionResponse> {
  return request("/auth/session", { method: "POST", body: JSON.stringify({ initData }) });
}

export function me(token: string): Promise<MeResponse> {
  return request("/me", {}, token);
}

export function fsTree(token: string): Promise<FsTreeResponse> {
  return request("/fs/tree", {}, token);
}

export function fsFile(token: string, path: string): Promise<FsFileResponse> {
  return request(`/fs/file?path=${encodeURIComponent(path)}`, {}, token);
}

export function fsPut(token: string, path: string, content: string): Promise<FsPutResponse> {
  return request("/fs/file", { method: "PUT", body: JSON.stringify({ path, content }) }, token);
}

/** One audit record as streamed by ws /live (mirrors @fleet/shared AuditRecord). */
export interface LiveEvent {
  ts: string;
  userId?: string | null;
  kind: string; // e.g. "auth.session", "fs.put", "usage.turn", "live.hello"
  actor?: string;
  payload?: unknown;
}

/** ws URL for GET /live. Browsers can't set headers on ws upgrades → token in query. */
export function liveWsUrl(token: string): string {
  const proto = window.location.protocol === "https:" ? "wss" : "ws";
  return `${proto}://${window.location.host}${BASE}/live?token=${encodeURIComponent(token)}`;
}

/** Platform approval (mirrors apps/api approvals.ts ApprovalRow; dates are ISO strings). */
export interface Approval {
  id: string;
  kind: string;
  title: string;
  payload: unknown;
  status: "pending" | "allowed" | "denied" | "expired";
  answeredVia: string | null;
  ttlSeconds: number;
  createdAt: string;
  answeredAt: string | null;
}

export function approvalsList(token: string): Promise<{ approvals: Approval[] }> {
  return request("/approvals", {}, token);
}

export function approvalAnswer(
  token: string,
  id: string,
  decision: "allow" | "deny",
): Promise<{ ok: boolean; approval: Approval; applied?: { ok: boolean; error?: string; committed?: boolean } }> {
  return request(`/approvals/${id}/answer`, { method: "POST", body: JSON.stringify({ decision }) }, token);
}

// ── M5.5 gated MCP connect (mirrors apps/api mcp-routes.ts) ──

export interface McpServerInfo {
  name: string;
  kind: "stdio" | "remote";
  enabled: boolean;
}

export interface McpFinding {
  ruleId: string;
  severity: "low" | "medium" | "high" | "critical";
  message: string;
  source: string;
}

export interface McpConnectResponse {
  approvalId: string;
  ttlSeconds: number;
  overwrite: boolean;
  verdict: "pass";
  severity: string | null;
  findings: McpFinding[];
  /** M5.5b: present when a secret was staged in the vault (unbound until allow). */
  secret?: { name: string; hostPattern: string; rotated: boolean };
}

/** M5.5b secret intake (mirrors apps/api mcp-gate.ts SecretSpec). The value goes
 *  straight to the vault via cp-secretd; it never lands in the stanza, the scan,
 *  the approval payload or any file. */
export interface McpSecretSpec {
  value: string;
  hostPattern: string; // api.example.com | *.example.com
  headerName: string; // e.g. Authorization, X-API-Key
  valueFormat: string; // must contain {value}, e.g. "Bearer {value}"
}

/** 422 body when the scanner blocks (ApiError carries only the message — use mcpConnectRaw for details). */
export function mcpList(token: string): Promise<{ servers: McpServerInfo[] }> {
  return request("/mcp/list", {}, token);
}

export function mcpConnect(
  token: string,
  name: string,
  stanza: unknown,
  secretSpec?: McpSecretSpec,
): Promise<McpConnectResponse> {
  return request(
    "/mcp/connect",
    { method: "POST", body: JSON.stringify({ name, stanza, ...(secretSpec ? { secretSpec } : {}) }) },
    token,
  );
}

/** Like mcpConnect but surfaces the full 422 scanner verdict instead of a bare error string. */
export async function mcpConnectRaw(
  token: string,
  name: string,
  stanza: unknown,
  secretSpec?: McpSecretSpec,
): Promise<
  | { kind: "approval"; res: McpConnectResponse }
  | { kind: "blocked"; verdict: string; severity: string | null; findings: McpFinding[]; reportRef: string | null; error: string }
> {
  const res = await fetch(`${BASE}/mcp/connect`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ name, stanza, ...(secretSpec ? { secretSpec } : {}) }),
  });
  const body = (await res.json().catch(() => ({}))) as Record<string, unknown>;
  if (res.ok) return { kind: "approval", res: body as unknown as McpConnectResponse };
  if (res.status === 422) {
    return {
      kind: "blocked",
      verdict: String(body.verdict ?? "fail"),
      severity: (body.severity as string | null) ?? null,
      findings: (body.findings as McpFinding[] | undefined) ?? [],
      reportRef: (body.reportRef as string | null) ?? null,
      error: String(body.error ?? "станса не прошла сканер"),
    };
  }
  throw new ApiError(res.status, typeof body.error === "string" ? body.error : res.statusText);
}

export function mcpDisconnect(token: string, name: string): Promise<{ ok: boolean; name: string }> {
  return request("/mcp/disconnect", { method: "POST", body: JSON.stringify({ name }) }, token);
}

// M5.6 web-IDE: one-time login ticket → URL to open in the EXTERNAL browser
// (the IDE is unusable inside the Telegram webview).
export interface IdeTicketResponse {
  url: string;
  ttlSeconds: number;
}

export function ideTicket(token: string): Promise<IdeTicketResponse> {
  // explicit empty JSON body: fastify 400s an empty body with a json content-type
  return request("/ide/ticket", { method: "POST", body: "{}" }, token);
}

// ── M5.7 named sessions/projects (mirrors apps/api session-routes.ts) ──

export interface SessionInfo {
  id: string;
  name: string;
  state: string; // active | idle
  active: boolean;
  /** Supervisor-confirmed readiness: the active session's claude+plugin are
   *  actually up. false while the fresh pane is still starting. Non-active
   *  sessions are always true. Missing on a pre-readiness API → treat as true. */
  ready?: boolean;
  startedAt: string;
  lastMessageAt: string | null;
}

export function sessionsList(
  token: string,
): Promise<{ active: string; activeReady?: boolean; sessions: SessionInfo[] }> {
  return request("/sessions", {}, token);
}

export function sessionCreate(token: string, name: string): Promise<{ ok: boolean; session: SessionInfo }> {
  return request("/sessions", { method: "POST", body: JSON.stringify({ name }) }, token);
}

/** Synchronous switch: the API waits (≤90s) for the pod supervisor to respawn
 *  the claude pane in the project dir. The bot's current task IS interrupted. */
export function sessionSwitch(token: string, id: string): Promise<{ ok: boolean; name: string }> {
  return request(`/sessions/${id}/switch`, { method: "POST", body: "{}" }, token);
}

/** Delete a non-active session: the project dir is moved to ~/work/.trash/
 *  (recoverable, nothing is destroyed), the row is closed. 409 for the active
 *  session or "default". */
export function sessionDelete(token: string, id: string): Promise<{ ok: boolean; name: string }> {
  return request(`/sessions/${id}`, { method: "DELETE" }, token);
}

// ── M5.8 checkpoints (mirrors apps/api session-routes.ts checkpoint routes) ──

export interface CheckpointInfo {
  id: string;
  label: string;
  ts: string; // ISO UTC
  commit: string;
  auto: boolean;
  convSource: string | null;
}

/** Newest first. */
export function checkpointsList(
  token: string,
  sessionId: string,
): Promise<{ name: string; checkpoints: CheckpointInfo[] }> {
  return request(`/sessions/${sessionId}/checkpoints`, {}, token);
}

/** Snapshot files + conversation of a session. Safe on a live session —
 *  nothing is restarted; the pod supervisor executes within ~5s. */
export function checkpointCreate(
  token: string,
  sessionId: string,
  label?: string,
): Promise<{ ok: boolean; checkpoint: string; entry: CheckpointInfo | null }> {
  return request(
    `/sessions/${sessionId}/checkpoints`,
    { method: "POST", body: JSON.stringify(label ? { label } : {}) },
    token,
  );
}

/** Restore files AND conversation to a checkpoint. For the active session the
 *  claude pane respawns (current bot task IS interrupted) — poll readiness
 *  like after a switch. A pre-rewind auto-checkpoint is always taken first. */
export function checkpointRewind(
  token: string,
  sessionId: string,
  checkpointId: string,
): Promise<{ ok: boolean; checkpoint: string }> {
  return request(`/sessions/${sessionId}/checkpoints/${checkpointId}/rewind`, { method: "POST", body: "{}" }, token);
}

export function checkpointDelete(
  token: string,
  sessionId: string,
  checkpointId: string,
): Promise<{ ok: boolean; checkpoint: string }> {
  return request(`/sessions/${sessionId}/checkpoints/${checkpointId}`, { method: "DELETE" }, token);
}
