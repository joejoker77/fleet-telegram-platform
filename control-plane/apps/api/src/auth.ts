// JWT issue/verify with Redis-backed session tracking, so a session can be
// revoked server-side (delete the Redis key) before the JWT's own expiry.
import { randomUUID } from "node:crypto";
import { SignJWT, jwtVerify } from "jose";
import type { Redis } from "ioredis";

const ALG = "HS256";
const sessionKey = (jti: string) => `session:${jti}`;

export interface SessionClaims {
  sub: string; // users.id (uuid)
  jti: string;
}

export async function issueSession(
  redis: Redis,
  secret: Uint8Array,
  userId: string,
  ttlSeconds: number,
): Promise<{ token: string; expiresAt: Date; jti: string }> {
  // jti = random id; unique enough without Date/random ban concerns (Node crypto).
  const jti = randomUUID();
  const expiresAt = new Date(Date.now() + ttlSeconds * 1000);
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: ALG })
    .setSubject(userId)
    .setJti(jti)
    .setIssuedAt()
    .setExpirationTime(Math.floor(expiresAt.getTime() / 1000))
    .sign(secret);
  await redis.set(sessionKey(jti), userId, "EX", ttlSeconds);
  return { token, expiresAt, jti };
}

export async function verifySession(
  redis: Redis,
  secret: Uint8Array,
  token: string,
): Promise<SessionClaims> {
  const { payload } = await jwtVerify(token, secret, { algorithms: [ALG] });
  const jti = payload.jti;
  const sub = payload.sub;
  if (typeof jti !== "string" || typeof sub !== "string") {
    throw new Error("malformed session token");
  }
  const stored = await redis.get(sessionKey(jti));
  if (stored !== sub) throw new Error("session revoked or expired");
  return { sub, jti };
}
