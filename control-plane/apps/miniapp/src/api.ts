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

async function request<T>(path: string, init: RequestInit = {}, token?: string): Promise<T> {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    ...(init.headers as Record<string, string> | undefined),
  };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fetch(`${BASE}${path}`, { ...init, headers });
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
