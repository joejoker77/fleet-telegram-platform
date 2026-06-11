// M5.4b acceptance — mint a JWT (synthetic initData signed with the bot token,
// like m5.1-fs-accept), then exercise the platform-approvals pipeline end-to-end
// against cp-api:
//   1) GET /approvals answers (queue may be empty)
//   2) POST /approvals/test (admin-only, blocks) + answer "allow" from a second
//      request → outcome=allowed via Redis pubsub wakeup
//   3) same with "deny" → outcome=denied
//   4) answering a settled approval again → 404 (idempotence)
//   5) short-ttl approval left unanswered → outcome=expired (fail-closed)
// Side effect by design: each create fires a real sendMessage notification to
// the pilot's Telegram — seeing 3 messages during the run proves notify works.
// Exits non-zero on any failure.
import { createHmac } from "node:crypto";
import fs from "node:fs";

const token = fs.readFileSync(process.env.BOT_TOKEN_FILE, "utf8").trim();
const tg = Number(process.env.TG_ID || "2112420187");
const api = process.env.API || "http://127.0.0.1:8080";

const fields = {
  user: JSON.stringify({ id: tg, username: "vitaliy", first_name: "V" }),
  auth_date: String(Math.floor(Date.now() / 1000)),
  query_id: "M54BACCEPT",
};
const params = new URLSearchParams(fields);
const dcs = [...params].map(([k, v]) => `${k}=${v}`).sort().join("\n");
const secret = createHmac("sha256", "WebAppData").update(token).digest();
params.set("hash", createHmac("sha256", secret).update(dcs).digest("hex"));

const sess = await (await fetch(`${api}/auth/session`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ initData: params.toString() }),
})).json();
if (!sess.token) {
  console.error("auth failed:", JSON.stringify(sess));
  process.exit(1);
}
const H = { authorization: `Bearer ${sess.token}`, "content-type": "application/json" };

let fails = 0;
const ok = (c, m) => (c ? console.log(`  ✓ ${m}`) : (fails++, console.error(`  ✗ ${m}`)));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 1) queue endpoint answers
const q0 = await fetch(`${api}/approvals`, { headers: H });
const q0body = await q0.json();
ok(q0.status === 200 && Array.isArray(q0body.approvals), `GET /approvals ok (${q0.status})`);

// Start a blocking test approval, then find it pending in the queue and answer.
// Returns { outcome, id } from the test endpoint's eventual response.
async function roundTrip(decision, ttlSeconds) {
  const before = new Set(q0body.approvals.map((a) => a.id));
  const testP = fetch(`${api}/approvals/test`, {
    method: "POST",
    headers: H,
    body: JSON.stringify({ title: `m5.4b acceptance (${decision ?? "expire"})`, ttlSeconds }),
  }).then((r) => r.json());

  // poll for the new pending row
  let row = null;
  for (let i = 0; i < 20 && !row; i++) {
    await sleep(500);
    const q = await (await fetch(`${api}/approvals`, { headers: H })).json();
    row = (q.approvals ?? []).find((a) => a.status === "pending" && !before.has(a.id)) ?? null;
  }
  if (decision && row) {
    const ans = await fetch(`${api}/approvals/${row.id}/answer`, {
      method: "POST",
      headers: H,
      body: JSON.stringify({ decision }),
    });
    ok(ans.status === 200, `POST /approvals/:id/answer (${decision}) ok (${ans.status})`);
  }
  const res = await testP;
  return { res, row };
}

// 2) allow round-trip (pubsub wakeup)
{
  const t0 = Date.now();
  const { res, row } = await roundTrip("allow", 60);
  ok(!!row, "pending approval appears in GET /approvals");
  ok(res.outcome === "allowed", `allow round-trip → outcome=allowed (got ${res.outcome})`);
  ok(Date.now() - t0 < 30_000, "answered well before ttl (pubsub wakeup, not timeout)");

  // 4) settled approval cannot be re-answered
  if (row) {
    const again = await fetch(`${api}/approvals/${row.id}/answer`, {
      method: "POST",
      headers: H,
      body: JSON.stringify({ decision: "deny" }),
    });
    ok(again.status === 404, `re-answer of settled approval rejected (${again.status})`);
  }
}

// 3) deny round-trip
{
  const { res, row } = await roundTrip("deny", 60);
  ok(!!row, "second pending approval appears");
  ok(res.outcome === "denied", `deny round-trip → outcome=denied (got ${res.outcome})`);
}

// 5) unanswered short-ttl approval expires (fail-closed)
{
  const { res } = await roundTrip(null, 10);
  ok(res.outcome === "expired", `unanswered ttl=10s → outcome=expired (got ${res.outcome})`);
  const q = await (await fetch(`${api}/approvals`, { headers: H })).json();
  const expired = (q.approvals ?? []).filter((a) => a.status === "expired");
  ok(expired.length >= 1, "expired row visible in history with status=expired");
}

console.log(`\nM5.4b approvals acceptance: ${fails ? `FAILED (${fails})` : "OK"}`);
process.exit(fails ? 1 : 0);
