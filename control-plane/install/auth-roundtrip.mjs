// M1.6 acceptance helper: sign a synthetic initData with the bot token (read
// from the mounted podman secret), then exercise POST /auth/session + GET /me
// against cp-api. Runs inside a throwaway container on cp-net so the token is
// never handled in cleartext on the host. Exits non-zero on any failure.
import { createHmac } from "node:crypto";
import fs from "node:fs";

const token = fs.readFileSync(process.env.BOT_TOKEN_FILE, "utf8").trim();
const tg = Number(process.env.TG_ID || "2112420187");
const api = process.env.API || "http://cp-api:8080";

const fields = {
  user: JSON.stringify({ id: tg, username: "vitaliy", first_name: "V" }),
  auth_date: String(Math.floor(Date.now() / 1000)),
  query_id: "ACCEPT",
};
const params = new URLSearchParams(fields);
const dcs = [...params].map(([k, v]) => `${k}=${v}`).sort().join("\n");
const secret = createHmac("sha256", "WebAppData").update(token).digest();
params.set("hash", createHmac("sha256", secret).update(dcs).digest("hex"));
const initData = params.toString();

const r1 = await fetch(`${api}/auth/session`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ initData }),
});
const j1 = await r1.json();
console.log("POST /auth/session ->", r1.status, JSON.stringify(j1));
if (!r1.ok) process.exit(1);

const r2 = await fetch(`${api}/me`, { headers: { authorization: `Bearer ${j1.token}` } });
const j2 = await r2.json();
console.log("GET /me ->", r2.status, JSON.stringify(j2));
if (!r2.ok || j2.telegramUserId !== tg) process.exit(1);

// negative check: a tampered token must be rejected
const bad = initData.replace(/hash=[0-9a-f]+/, "hash=" + "0".repeat(64));
const r3 = await fetch(`${api}/auth/session`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ initData: bad }),
});
console.log("POST /auth/session (tampered) ->", r3.status, "(expect 401)");
if (r3.status !== 401) process.exit(1);

console.log("AUTH ROUND-TRIP OK");
