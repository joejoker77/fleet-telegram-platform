// M5.13 acceptance — UsageDashboard backend (GET /usage/summary).
// Same auth scaffolding as m5.8-accept (synthetic initData HMAC).
//
// Checks (cp-api + PG only — safe, never touches the pod):
//   1) GET /usage/summary → 200, shape {days[], byModel{}, last5h{}}
//   2) days zero-filled: exactly `days` entries, ascending, last = today (UTC)
//   3) ?days clamp: days=7 → 7 entries; days=500 → 90 (max)
//   4) every day has numeric in/out/cacheRead/cacheWrite/legacy/turns
//   5) old GET /usage still works (back-compat untouched)
//   6) no auth → 401
//   7) usage_records split columns live: if any turn happened since the
//      migration, today's (in+out) > 0 OR total turns == legacy-only — both
//      acceptable right after deploy; report which.
//
// Run on the HOST (canonical recipe — podman secret, as m5.8):
//   podman run --rm --network host --secret cp_bot_token \
//     -v /home/vitaliy/work/fleet-platform/control-plane:/cp:ro -w /cp \
//     -e BOT_TOKEN_FILE=/run/secrets/cp_bot_token \
//     docker.io/library/node:22-alpine node install/m5.13-accept.mjs
import { createHmac } from "node:crypto";
import fs from "node:fs";

const token = fs.readFileSync(process.env.BOT_TOKEN_FILE, "utf8").trim();
const tg = Number(process.env.TG_ID || "2112420187");
const api = process.env.API || "http://127.0.0.1:8080";

// ── auth ──
const fields = {
  user: JSON.stringify({ id: tg, username: "vitaliy", first_name: "V" }),
  auth_date: String(Math.floor(Date.now() / 1000)),
  query_id: "M513ACCEPT",
};
const params = new URLSearchParams(fields);
const dcs = [...params].map(([k, v]) => `${k}=${v}`).sort().join("\n");
const hmacKey = createHmac("sha256", "WebAppData").update(token).digest();
params.set("hash", createHmac("sha256", hmacKey).update(dcs).digest("hex"));

const sess = await (await fetch(`${api}/auth/session`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ initData: params.toString() }),
})).json();
if (!sess.token) {
  console.error("auth failed:", JSON.stringify(sess));
  process.exit(1);
}
const H = { authorization: `Bearer ${sess.token}` };

let fails = 0;
const ok = (c, m) => (c ? console.log(`  ✓ ${m}`) : (fails++, console.error(`  ✗ ${m}`)));
const j = async (r) => ({ status: r.status, body: await r.json().catch(() => ({})) });
const summary = async (days) =>
  j(await fetch(`${api}/usage/summary${days ? `?days=${days}` : ""}`, { headers: H }));

console.log("M5.13 — usage summary endpoint");

// 1) default shape
const s = await summary();
ok(s.status === 200, `GET /usage/summary → 200 (got ${s.status})`);
ok(Array.isArray(s.body.days), "days is an array");
ok(s.body.byModel !== null && typeof s.body.byModel === "object", "byModel is an object");
const l5 = s.body.last5h ?? {};
ok(["in", "out", "cacheRead", "cacheWrite", "turns"].every((k) => typeof l5[k] === "number"), "last5h has numeric counters");

// 2) zero-fill + ordering
const days = s.body.days ?? [];
ok(days.length === 30, `default range = 30 days (got ${days.length})`);
const today = new Date().toISOString().slice(0, 10);
ok(days.length > 0 && days[days.length - 1].date === today, `last entry is today UTC (${today})`);
ok(days.every((d, i) => i === 0 || d.date > days[i - 1].date), "days ascending");

// 3) clamp
const s7 = await summary(7);
ok((s7.body.days ?? []).length === 7, `days=7 → 7 entries (got ${(s7.body.days ?? []).length})`);
const s500 = await summary(500);
ok((s500.body.days ?? []).length === 90, `days=500 clamps to 90 (got ${(s500.body.days ?? []).length})`);

// 4) per-day field types
const FIELDS = ["in", "out", "cacheRead", "cacheWrite", "legacy", "turns"];
ok(days.every((d) => FIELDS.every((f) => typeof d[f] === "number")), "every day has numeric counters");

// 5) old /usage back-compat
const old = j(await fetch(`${api}/usage`, { headers: H }));
const o = await old;
ok(o.status === 200 && typeof o.body.totalTokens === "number", `GET /usage still 200 (got ${o.status})`);

// 6) auth required
const noauth = await fetch(`${api}/usage/summary`);
ok(noauth.status === 401, `no token → 401 (got ${noauth.status})`);

// 7) split columns live (informational)
const turns = days.reduce((n, d) => n + d.turns, 0);
const split = days.reduce((n, d) => n + d.in + d.out, 0);
const legacy = days.reduce((n, d) => n + d.legacy, 0);
console.log(`  ℹ ${turns} turns in range: ${split} split tokens, ${legacy} legacy tokens`);
if (turns > 0) ok(split > 0 || legacy > 0, "recorded turns carry tokens (split or legacy)");

console.log(fails === 0 ? "M5.13 usage summary acceptance: OK" : `FAILED: ${fails} check(s)`);
process.exit(fails === 0 ? 0 : 1);
