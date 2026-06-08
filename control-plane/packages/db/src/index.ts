// DB client factory for control-plane services. Connection string comes from
// the environment (DATABASE_URL); the value itself is provisioned outside the
// repo (OneCLI / install.sh), never committed.

import { drizzle, type NodePgDatabase } from "drizzle-orm/node-postgres";
import pg from "pg";
import * as schema from "./schema.js";

export * as schema from "./schema.js";
export type Db = NodePgDatabase<typeof schema>;

let pool: pg.Pool | undefined;

export function getPool(): pg.Pool {
  if (!pool) {
    const connectionString = process.env.DATABASE_URL;
    if (!connectionString) {
      throw new Error("DATABASE_URL is not set");
    }
    pool = new pg.Pool({ connectionString });
  }
  return pool;
}

export function getDb(): Db {
  return drizzle(getPool(), { schema });
}
