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
