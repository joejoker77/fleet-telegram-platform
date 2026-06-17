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

// Like fileOrEnv but returns "" when neither is set (an optional credential).
function fileOrEnvOptional(envName: string): string {
  const filePath = process.env[`${envName}_FILE`];
  if (filePath) return fs.readFileSync(filePath, "utf8").trim();
  return process.env[envName] ?? "";
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
  // Public Mini App URL. When set, approval notifications use a web_app button
  // (opens the app directly, no BotFather Main-App / client-cache dependency —
  // the t.me?startapp= deep link proved unreliable on real clients, 2026-06-11).
  miniappUrl: string;
  jwtSecret: Uint8Array;
  jwtTtlSeconds: number;
  initDataMaxAgeSeconds: number;
  // Root under which tenant homes live; the authoring sandbox for a tenant is
  // <tenantHomeRoot>/<osUsername>/.claude (bind-mounted into cp-api).
  tenantHomeRoot: string;
  // Judge Orchestrator (WP3) for the M5.5 MCP gate — host network, same box.
  judgeUrl: string;
  // cp-secretd unix socket (M5.5b secret intake). The helper may be absent —
  // secret-less connects are unaffected; secretSpec ones fail with a clear error.
  secretdSocket: string;
  // Public web-IDE origin (M5.6) — where the nginx forward-auth vhost lives;
  // /ide/ticket builds its login URL against this.
  ideUrl: string;
  // M8.1 marketplace store repo (owner/name). Publish dispatches to the pod
  // (which holds the PAT); import reads this repo's public contents.
  registryRepo: string;
  // A2 GitHub push-webhook HMAC secret (inbound verification — cp-api needs the
  // raw value to recompute X-Hub-Signature-256, so it's a LOCAL credential like
  // jwtSecret/botToken, NOT an OneCLI outbound-injection secret). Empty = the
  // /deploy/webhook/github route is dormant (503) until the operator wires it.
  githubWebhookSecret: string;
}

export function loadConfig(): Config {
  return {
    port: Number(process.env.PORT ?? 8080),
    host: process.env.HOST ?? "127.0.0.1",
    redisUrl: process.env.REDIS_URL ?? "redis://127.0.0.1:6380",
    auditSocket: process.env.AUDIT_SOCKET ?? "/run/audit/collector.sock",
    botToken: fileOrEnv("TELEGRAM_BOT_TOKEN"),
    botUsername: (process.env.TELEGRAM_BOT_USERNAME ?? "").replace(/^@/, ""),
    miniappUrl: (process.env.MINIAPP_URL ?? "https://miniapp.ai-assistant.gg").replace(/\/$/, ""),
    jwtSecret: new TextEncoder().encode(fileOrEnv("JWT_SECRET")),
    jwtTtlSeconds: Number(process.env.JWT_TTL_SECONDS ?? 3600),
    initDataMaxAgeSeconds: Number(process.env.INITDATA_MAX_AGE_SECONDS ?? 86400),
    tenantHomeRoot: process.env.TENANT_HOME_ROOT ?? "/home",
    judgeUrl: process.env.JUDGE_URL ?? "http://127.0.0.1:8090",
    secretdSocket: process.env.SECRETD_SOCKET ?? "/run/cp-secretd/secretd.sock",
    ideUrl: (process.env.IDE_URL ?? "https://ide.ai-assistant.gg").replace(/\/$/, ""),
    registryRepo: process.env.REGISTRY_REPO ?? "joejoker77/claude-bot-skills",
    githubWebhookSecret: fileOrEnvOptional("GITHUB_WEBHOOK_SECRET"),
  };
}
