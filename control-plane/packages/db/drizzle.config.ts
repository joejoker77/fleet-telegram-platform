import { defineConfig } from "drizzle-kit";

// Connection string is read from the environment at deploy/migrate time.
// Never committed: secrets live in OneCLI; for local dev set DATABASE_URL inline.
const url = process.env.DATABASE_URL ?? "postgres://cplane@127.0.0.1:5433/control_plane";

export default defineConfig({
  schema: "./src/schema.ts",
  out: "./drizzle",
  dialect: "postgresql",
  dbCredentials: { url },
  strict: true,
  verbose: true,
});
