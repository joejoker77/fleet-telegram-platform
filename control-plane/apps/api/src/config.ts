// Runtime config for @fleet/api. Secrets are read from mounted files
// (…_FILE) when present, else from env — the M1.5 installer wires the bot
// token and JWT secret as podman/systemd credentials (NOT the repo, NOT plain
// env in a unit file). The bot token here is used for LOCAL initData HMAC
// verification (not an outbound request), so it's delivered as a local
// credential; OneCLI remains for external-request secrets.
import fs from "node:fs";

function reqEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

function fileOrEnv(envName: string): string {
  const filePath = process.env[`${envName}_FILE`];
  if (filePath) return fs.readFileSync(filePath, "utf8").trim();
  return reqEnv(envName);
}

export interface Config {
  port: number;
  host: string;
  redisUrl: string;
  auditSocket: string;
  botToken: string;
  // Bot username (no @) for Mini App deep links (t.me/<bot>?startapp=…).
  // Optional: empty → approval notifications go out without the url-button.
  botUsername: string;
  jwtSecret: Uint8Array;
  jwtTtlSeconds: number;
  initDataMaxAgeSeconds: number;
  // Root under which tenant homes live; the authoring sandbox for a tenant is
  // <tenantHomeRoot>/<osUsername>/.claude (bind-mounted into cp-api).
  tenantHomeRoot: string;
  // Judge Orchestrator (WP3) for the M5.5 MCP gate — host network, same box.
  judgeUrl: string;
}

export function loadConfig(): Config {
  return {
    port: Number(process.env.PORT ?? 8080),
    host: process.env.HOST ?? "127.0.0.1",
    redisUrl: process.env.REDIS_URL ?? "redis://127.0.0.1:6380",
    auditSocket: process.env.AUDIT_SOCKET ?? "/run/audit/collector.sock",
    botToken: fileOrEnv("TELEGRAM_BOT_TOKEN"),
    botUsername: (process.env.TELEGRAM_BOT_USERNAME ?? "").replace(/^@/, ""),
    jwtSecret: new TextEncoder().encode(fileOrEnv("JWT_SECRET")),
    jwtTtlSeconds: Number(process.env.JWT_TTL_SECONDS ?? 3600),
    initDataMaxAgeSeconds: Number(process.env.INITDATA_MAX_AGE_SECONDS ?? 86400),
    tenantHomeRoot: process.env.TENANT_HOME_ROOT ?? "/home",
    judgeUrl: process.env.JUDGE_URL ?? "http://127.0.0.1:8090",
  };
}
