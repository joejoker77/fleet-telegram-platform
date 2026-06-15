// Multi-bot Mini App auth: each tenant's bot has its OWN Telegram token, and
// initData must be HMAC-verified against the token of the bot it was opened from.
// cp-api reads that token from the tenant's own runtime env file (the same place
// the bot itself reads it). Bot tokens are LOCAL credentials for initData HMAC
// (not outbound-request secrets → not OneCLI vault) — see config.ts.
import fs from "node:fs";
import path from "node:path";

// Peek the claimed Telegram user id from initData WITHOUT verifying. Safe to use
// only for selecting which bot token to verify against: a forged id can't yield a
// valid HMAC without that bot's real token, so the verify step still gates auth.
export function peekInitDataUserId(initData: string): number | null {
  try {
    const userJson = new URLSearchParams(initData).get("user");
    if (!userJson) return null;
    const id = (JSON.parse(userJson) as { id?: unknown }).id;
    return typeof id === "number" && Number.isFinite(id) ? id : null;
  } catch {
    return null;
  }
}

// Read TELEGRAM_BOT_TOKEN from a tenant's runtime env file:
//   <homeRoot>/<user>/.claude/channels/telegram-<user>/.env
// Returns null if the file or key is absent/unreadable (caller falls back).
export function readTenantBotToken(homeRoot: string, osUsername: string): string | null {
  // Guard the path component — osUsername comes from our own DB, but never let a
  // stray value traverse out of the home root.
  if (!/^[a-z_][a-z0-9_-]*$/i.test(osUsername)) return null;
  const envPath = path.join(homeRoot, osUsername, ".claude", "channels", `telegram-${osUsername}`, ".env");
  let text: string;
  try {
    text = fs.readFileSync(envPath, "utf8");
  } catch {
    return null;
  }
  for (const line of text.split("\n")) {
    const m = /^\s*TELEGRAM_BOT_TOKEN\s*=\s*(.+?)\s*$/.exec(line);
    if (m) {
      const tok = (m[1] ?? "").replace(/^["']|["']$/g, "").trim();
      return tok || null;
    }
  }
  return null;
}
