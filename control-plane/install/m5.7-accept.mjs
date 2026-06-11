// M5.7 acceptance — named sessions/projects (docs/M5.7-sessions-design.md).
// Same auth scaffolding as m5.5b/m5.6-accept (synthetic initData HMAC).
//
// PHASE A (cp-api only — safe, does NOT touch the running bot):
//   1) GET /sessions → 200, contains "default", exactly one active
//   2) name validation: "Bad", "-x", "a_b", 33 chars → 400; "default" → 409
//   3) POST /sessions {name:"m57-acc"} → 200 (or 409 if left from a prior run)
//   4) GET /sessions shows m57-acc as idle (created ≠ switched)
//   5) duplicate create → 409
//   6) switch to a bogus id → 404
//
// PHASE B (DO_SWITCH=1 — DESTRUCTIVE: respawns the bot's claude pane TWICE.
// Run only after the image rebuild + pod restart, when the bot is idle):
//   7) POST /sessions/<m57-acc>/switch → 200 within 90s
//   8) GET /sessions → active=m57-acc
//   9) operator spot-check (printed, not asserted): in-pod cwd really changed
//  10) switch back to default → 200, GET → active=default
//
// Run on the HOST (canonical recipe — podman secret, as m5.4b/m5.5b/m5.6):
//   podman run --rm --network host --secret cp_bot_token \
//     -v /home/vitaliy/work/fleet-platform/control-plane:/cp:ro -w /cp \
//     -e BOT_TOKEN_FILE=/run/secrets/cp_bot_token \
//     docker.io/library/node:22-alpine node install/m5.7-accept.mjs
//   (add -e DO_SWITCH=1 for the destructive switch round-trip)
import { createHmac } from "node:crypto";
import fs from "node:fs";

const token = fs.readFileSync(process.env.BOT_TOKEN_FILE, "utf8").trim();
const tg = Number(process.env.TG_ID || "2112420187");
const api = process.env.API || "http://127.0.0.1:8080";
const doSwitch = process.env.DO_SWITCH === "1";
const NAME = process.env.SESSION_NAME || "m57-acc";

// ── auth (as in m5.5b-accept) ──
const fields = {
  user: JSON.stringify({ id: tg, username: "vitaliy", first_name: "V" }),
  auth_date: String(Math.floor(Date.now() / 1000)),
  query_id: "M57ACCEPT",
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
const H = { authorization: `Bearer ${sess.token}`, "content-type": "application/json" };

let fails = 0;
const ok = (c, m) => (c ? console.log(`  ✓ ${m}`) : (fails++, console.error(`  ✗ ${m}`)));

const list = async () => {
  const r = await fetch(`${api}/sessions`, { headers: H });
  const body = await r.json().catch(() => ({}));
  return { status: r.status, body };
};
const create = async (name) => {
  const r = await fetch(`${api}/sessions`, { method: "POST", headers: H, body: JSON.stringify({ name }) });
  return { status: r.status, body: await r.json().catch(() => ({})) };
};
const swtch = async (id) => {
  const r = await fetch(`${api}/sessions/${id}/switch`, { method: "POST", headers: H, body: "{}" });
  return { status: r.status, body: await r.json().catch(() => ({})) };
};
const byName = (l, name) => (l.body.sessions || []).find((s) => s.name === name);

console.log("PHASE A — list / validate / create (non-destructive)");

// 1) baseline list
const l1 = await list();
ok(l1.status === 200, `GET /sessions → 200 (got ${l1.status})`);
ok(!!byName(l1, "default"), "list contains the default session");
ok((l1.body.sessions || []).filter((s) => s.active).length === 1, "exactly one active session");
ok(typeof l1.body.active === "string", `active marker present (= "${l1.body.active}")`);

// 2) name validation
for (const bad of ["Bad", "-x", "a_b", "a".repeat(33)]) {
  const r = await create(bad);
  ok(r.status === 400, `create "${bad.slice(0, 12)}${bad.length > 12 ? "…" : ""}" → 400 (got ${r.status})`);
}
{
  const r = await create("default");
  ok(r.status === 409, `create "default" → 409 (got ${r.status})`);
}

// 3) create the test session (tolerate leftovers from a previous run)
{
  const r = await create(NAME);
  ok(
    r.status === 200 || (r.status === 409 && /exists/.test(String(r.body.error))),
    `create "${NAME}" → 200 (got ${r.status}${r.status === 409 ? ", leftover from a prior run — ok" : ""})`,
  );
}

// 4) shows up as idle
const l2 = await list();
const row = byName(l2, NAME);
ok(!!row, `"${NAME}" appears in the list`);
ok(row && row.state === "idle" && !row.active, "created session is idle (create ≠ switch)");

// 5) duplicate → 409
{
  const r = await create(NAME);
  ok(r.status === 409, `duplicate create → 409 (got ${r.status})`);
}

// 6) bogus id → 404
{
  const r = await swtch("00000000-0000-4000-8000-000000000000");
  ok(r.status === 404, `switch to bogus id → 404 (got ${r.status})`);
}

if (!doSwitch) {
  console.log("PHASE B — SKIPPED (set DO_SWITCH=1 after the image rebuild + pod restart;");
  console.log("          it interrupts the bot: the claude pane respawns twice)");
} else if (row) {
  console.log("PHASE B — destructive switch round-trip (≤90s each way)");

  // 7-8) switch to the test session
  let t0 = Date.now();
  const s1 = await swtch(row.id);
  ok(s1.status === 200 && s1.body.ok === true, `switch → ${NAME} confirmed in ${Math.round((Date.now() - t0) / 1000)}s (got ${s1.status} ${JSON.stringify(s1.body).slice(0, 120)})`);
  const l3 = await list();
  ok(l3.body.active === NAME, `GET /sessions → active=${NAME} (got ${l3.body.active})`);
  const a3 = byName(l3, NAME);
  ok(a3 && a3.active && a3.state === "active", "row state flipped to active");

  // 9) operator spot-check (not asserted — needs pod exec)
  console.log("  → spot-check on the host:");
  console.log("    podman exec claude-vitaliy tmux display-message -p -t claude '#{pane_current_path}'");
  console.log(`    (expect …/work/projects/${NAME}; and the channel stays alive)`);

  // 10) switch back to default
  const defRow = byName(l3, "default");
  t0 = Date.now();
  const s2 = defRow ? await swtch(defRow.id) : { status: 0, body: {} };
  ok(s2.status === 200 && s2.body.ok === true, `switch back → default confirmed in ${Math.round((Date.now() - t0) / 1000)}s (got ${s2.status})`);
  const l4 = await list();
  ok(l4.body.active === "default", `GET /sessions → active=default (got ${l4.body.active})`);
}

console.log(fails === 0 ? "\nM5.7 sessions acceptance: OK" : `\nM5.7 acceptance: ${fails} FAILED`);
process.exit(fails === 0 ? 0 : 1);
