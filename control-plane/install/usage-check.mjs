// M2.5 verify: initData -> /auth/session -> GET /usage for the vitaliy tenant.
// Run inside cp-api (BOT_TOKEN_FILE=/run/secrets/cp_bot_token is vitaliy's token,
// API=http://127.0.0.1:8080). Exits non-zero if /usage has no tokens.
import { createHmac } from "node:crypto";
import fs from "node:fs";

const token = fs.readFileSync(process.env.BOT_TOKEN_FILE, "utf8").trim();
const tg = Number(process.env.TG_ID || "2112420187");
const api = process.env.API || "http://127.0.0.1:8080";

const fields = {
  user: JSON.stringify({ id: tg, username: "vitaliy", first_name: "V" }),
  auth_date: String(Math.floor(Date.now() / 1000)),
  query_id: "USAGE",
};
const params = new URLSearchParams(fields);
const dcs = [...params].map(([k, v]) => `${k}=${v}`).sort().join("\n");
const secret = createHmac("sha256", "WebAppData").update(token).digest();
params.set("hash", createHmac("sha256", secret).update(dcs).digest("hex"));

const r1 = await fetch(`${api}/auth/session`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ initData: params.toString() }),
});
const j1 = await r1.json();
if (!r1.ok) {
  console.log("auth failed", r1.status, JSON.stringify(j1));
  process.exit(1);
}
const r2 = await fetch(`${api}/usage`, { headers: { authorization: `Bearer ${j1.token}` } });
const j2 = await r2.json();
console.log("GET /usage ->", r2.status, JSON.stringify(j2));
if (!r2.ok || (j2.totalTokens || 0) <= 0) process.exit(1);
console.log("USAGE OK totalTokens=" + j2.totalTokens);
