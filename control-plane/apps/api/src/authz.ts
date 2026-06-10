// Shared bearer-JWT auth for the authoring API. Resolves the session to the
// tenant (id + os_username) and rejects suspended/deleted tenants. Factored out
// of the M1 inline checks so every fs/sessions/build endpoint authenticates the
// same way.
import type { FastifyRequest } from "fastify";
import type { Redis } from "ioredis";
import { eq } from "drizzle-orm";
import { getDb, schema } from "@fleet/db";
import { verifySession } from "./auth.js";

export class AuthError extends Error {
  constructor(message: string, public code = 401) {
    super(message);
  }
}

export interface AuthCtx {
  userId: string;
  osUsername: string;
}

export async function requireAuth(
  req: FastifyRequest,
  redis: Redis,
  jwtSecret: Uint8Array,
): Promise<AuthCtx> {
  const auth = req.headers.authorization ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) throw new AuthError("missing bearer token");

  let sub: string;
  try {
    ({ sub } = await verifySession(redis, jwtSecret, token));
  } catch {
    throw new AuthError("invalid or expired session");
  }

  const rows = await getDb()
    .select({ osUsername: schema.users.osUsername, status: schema.users.status })
    .from(schema.users)
    .where(eq(schema.users.id, sub))
    .limit(1);
  const u = rows[0];
  if (!u) throw new AuthError("tenant not found", 404);
  if (u.status === "suspended" || u.status === "deleted") {
    throw new AuthError(`tenant ${u.status}`, 403);
  }
  return { userId: sub, osUsername: u.osUsername };
}
