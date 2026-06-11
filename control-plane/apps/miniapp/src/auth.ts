// Telegram Mini App auth: hand the raw initData string to POST /auth/session,
// get back a short-lived JWT. The HMAC check happens server-side (initdata.ts);
// the client never interprets initData beyond passing it through.

import { retrieveRawInitData } from "@telegram-apps/sdk";

import { authSession } from "./api";

export interface Session {
  token: string;
  expiresAt: number; // epoch ms
}

const STORAGE_KEY = "miniapp.session";

function loadCached(): Session | null {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const s = JSON.parse(raw) as Session;
    // 30s slack so we never present an about-to-expire token
    if (typeof s.token !== "string" || s.expiresAt - 30_000 < Date.now()) return null;
    return s;
  } catch {
    return null;
  }
}

/**
 * Resolve a usable session: cached JWT if still valid, otherwise exchange
 * Telegram initData. Throws (with a user-presentable message) outside
 * Telegram or when the backend rejects the auth.
 */
export async function ensureSession(): Promise<Session> {
  const cached = loadCached();
  if (cached) return cached;

  let initData: string | undefined;
  try {
    initData = retrieveRawInitData();
  } catch {
    initData = undefined;
  }
  if (!initData) {
    throw new Error("Не похоже на запуск из Telegram — откройте мини-приложение через бота.");
  }

  const res = await authSession(initData);
  const session: Session = { token: res.token, expiresAt: Date.parse(res.expiresAt) };
  try {
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify(session));
  } catch {
    /* storage unavailable (private mode) — auth again next reload */
  }
  return session;
}

export function dropSession(): void {
  try {
    sessionStorage.removeItem(STORAGE_KEY);
  } catch {
    /* ignore */
  }
}

/**
 * start_param from a t.me/<bot>?startapp=<value> deep link (e.g. approval
 * notifications link to startapp=approvals). null outside Telegram / no param.
 */
export function startParam(): string | null {
  try {
    const raw = retrieveRawInitData();
    if (!raw) return null;
    return new URLSearchParams(raw).get("start_param");
  } catch {
    return null;
  }
}
