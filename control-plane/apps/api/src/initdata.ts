// Telegram WebApp initData verification.
// https://core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app
//
// secret_key = HMAC_SHA256(key="WebAppData", message=bot_token)
// expected   = HMAC_SHA256(key=secret_key, message=data_check_string), hex
// where data_check_string = the received key=value pairs (hash excluded),
// sorted alphabetically, joined by "\n". Constant-time compared to the hash.
// Pure + dependency-free so it can be unit-tested without any infra.
import { createHmac, timingSafeEqual } from "node:crypto";

export interface InitDataUser {
  id: number;
  is_bot?: boolean;
  first_name?: string;
  last_name?: string;
  username?: string;
  language_code?: string;
}

export interface VerifiedInitData {
  telegramUserId: number;
  user: InitDataUser;
  authDate: number;
}

export class InitDataError extends Error {}

export function verifyInitData(
  initData: string,
  botToken: string,
  maxAgeSeconds = 86400,
): VerifiedInitData {
  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) throw new InitDataError("initData missing hash");

  const pairs: string[] = [];
  for (const [k, v] of params) {
    if (k !== "hash") pairs.push(`${k}=${v}`);
  }
  pairs.sort();
  const dataCheckString = pairs.join("\n");

  const secretKey = createHmac("sha256", "WebAppData").update(botToken).digest();
  const expected = createHmac("sha256", secretKey).update(dataCheckString).digest("hex");

  const a = Buffer.from(expected, "hex");
  const b = Buffer.from(hash, "hex");
  if (a.length !== b.length || !timingSafeEqual(a, b)) {
    throw new InitDataError("initData HMAC mismatch");
  }

  const authDate = Number(params.get("auth_date") ?? 0);
  if (!authDate || Date.now() / 1000 - authDate > maxAgeSeconds) {
    throw new InitDataError("initData expired or missing auth_date");
  }

  const userJson = params.get("user");
  if (!userJson) throw new InitDataError("initData missing user");
  let user: InitDataUser;
  try {
    user = JSON.parse(userJson) as InitDataUser;
  } catch {
    throw new InitDataError("initData user is not valid JSON");
  }
  if (typeof user.id !== "number") throw new InitDataError("initData user.id missing");

  return { telegramUserId: user.id, user, authDate };
}
