// M5.8 acceptance — checkpoints / rewind (docs/M5.8-checkpoints-design.md).
// Same auth scaffolding as m5.7-accept (synthetic initData HMAC).
//
// PHASE A (cp-api only — safe, does NOT touch the running bot's pane;
// requires the REBUILT pod image: the supervisor executes checkpoint tasks):
//   1) GET /sessions → pick the "default" session id
//   2) GET /sessions/:id/checkpoints → 200, array
//   3) POST /sessions/:id/checkpoints {label} → 200 + checkpoint id
//      (live session, nothing restarts — supervisor handles it in ≤5s tick)
//   4) the new checkpoint appears in the list (newest first), label matches
//   5) rewind to a bogus cid → 400/404; bogus session id → 404
//   6) DELETE the test checkpoint → 200; gone from the list
//
// PHASE B (DO_REWIND=1 — DESTRUCTIVE: respawns the bot's claude pane.
// Run only when the bot is idle):
//   7) create checkpoint C on default, then POST .../checkpoints/<C>/rewind
//      → 200 within 90s
//   8) a pre-rewind auto-checkpoint ("auto: before rewind") appeared
//   9) GET /sessions eventually reports activeReady=true again (≤3 min poll)
//
// Run on the HOST (canonical recipe — podman secret, as m5.4b/m5.5b/m5.6/m5.7):
//   podman run --rm --network host --secret cp_bot_token \
//     -v /home/vitaliy/work/fleet-platform/control-plane:/cp:ro -w /cp \
//     -e BOT_TOKEN_FILE=/run/secrets/cp_bot_token \
//     docker.io/library/node:22-alpine node install/m5.8-accept.mjs
//   (add -e DO_REWIND=1 for the destructive rewind round-trip)
import { createHmac } from "node:crypto";
import fs from "node:fs";

const token = fs.readFileSync(process.env.BOT_TOKEN_FILE, "utf8").trim();
const tg = Number(process.env.TG_ID || "2112420187");
const api = process.env.API || "http://127.0.0.1:8080";
const doRewind = process.env.DO_REWIND === "1";

// ── auth (as in m5.7-accept) ──
const fields = {
  user: JSON.stringify({ id: tg, username: "vitaliy", first_name: "V" }),
  auth_date: String(Math.floor(Date.now() / 1000)),
  query_id: "M58ACCEPT",
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
const j = async (r) => ({ status: r.status, body: await r.json().catch(() => ({})) });

const sessions = async () => j(await fetch(`${api}/sessions`, { headers: H }));
const ckptList = async (id) => j(await fetch(`${api}/sessions/${id}/checkpoints`, { headers: H }));
const ckptCreate = async (id, label) =>
  j(await fetch(`${api}/sessions/${id}/checkpoints`, { method: "POST", headers: H, body: JSON.stringify({ label }) }));
const ckptRewind = async (id, cid) =>
  j(await fetch(`${api}/sessions/${id}/checkpoints/${cid}/rewind`, { method: "POST", headers: H, body: "{}" }));
const ckptDelete = async (id, cid) =>
  // no content-type on a bodyless DELETE: fastify 400s "body cannot be empty"
  j(await fetch(`${api}/sessions/${id}/checkpoints/${cid}`, { method: "DELETE", headers: { authorization: H.authorization } }));

console.log("PHASE A — list / create / delete checkpoint (no pane respawn)");

// 1) find default
const l1 = await sessions();
ok(l1.status === 200, `GET /sessions → 200 (got ${l1.status})`);
const def = (l1.body.sessions || []).find((s) => s.name === "default");
ok(!!def, "default session present");
if (!def) {
  console.error("cannot continue without default session");
  process.exit(1);
}

// 2) baseline checkpoint list
const c1 = await ckptList(def.id);
ok(c1.status === 200 && Array.isArray(c1.body.checkpoints), `GET checkpoints → 200 + array (got ${c1.status})`);

// 3) create (supervisor executes — needs the rebuilt image; 504 = old image)
const LABEL = `m58-acc ${new Date().toISOString()}`;
const cr = await ckptCreate(def.id, LABEL);
ok(
  cr.status === 200 && cr.body.ok === true && typeof cr.body.checkpoint === "string",
  `POST checkpoint → 200 + id (got ${cr.status} ${JSON.stringify(cr.body).slice(0, 140)})`,
);
const cid = cr.body.checkpoint;

// 4) appears in the list, newest first
if (cid) {
  const c2 = await ckptList(def.id);
  const entry = (c2.body.checkpoints || []).find((c) => c.id === cid);
  ok(!!entry, "new checkpoint appears in the list");
  ok(entry && entry.label === LABEL, "label round-trips");
  ok(entry && entry.auto === false, "manual checkpoint has auto=false");
  ok((c2.body.checkpoints || [])[0]?.id === cid, "list is newest-first");
}

// 5) bogus inputs
{
  const r = await ckptRewind(def.id, "not-a-ckpt-id");
  ok(r.status === 400, `rewind with malformed cid → 400 (got ${r.status})`);
  const r2 = await ckptRewind(def.id, "20200101T000000Z-1234");
  ok(r2.status === 404, `rewind to nonexistent cid → 404 (got ${r2.status})`);
  const r3 = await ckptList("00000000-0000-4000-8000-000000000000");
  ok(r3.status === 404, `checkpoints of bogus session → 404 (got ${r3.status})`);
}

// 6) delete the test checkpoint (keep it if PHASE B will rewind to it)
if (cid && !doRewind) {
  const d = await ckptDelete(def.id, cid);
  ok(d.status === 200 && d.body.ok === true, `DELETE checkpoint → 200 (got ${d.status})`);
  const c3 = await ckptList(def.id);
  ok(!(c3.body.checkpoints || []).some((c) => c.id === cid), "deleted checkpoint is gone");
}

if (!doRewind) {
  console.log("PHASE B — SKIPPED (set DO_REWIND=1 when the bot is idle;");
  console.log("          it interrupts the bot: the claude pane respawns)");
} else if (cid) {
  console.log("PHASE B — destructive rewind of the ACTIVE default session (≤90s)");

  const before = await ckptList(def.id);
  const nBefore = (before.body.checkpoints || []).length;

  let t0 = Date.now();
  const rw = await ckptRewind(def.id, cid);
  ok(
    rw.status === 200 && rw.body.ok === true,
    `rewind confirmed in ${Math.round((Date.now() - t0) / 1000)}s (got ${rw.status} ${JSON.stringify(rw.body).slice(0, 120)})`,
  );

  // 8) pre-rewind auto-checkpoint exists
  const after = await ckptList(def.id);
  const autos = (after.body.checkpoints || []).filter((c) => c.auto && /before rewind/.test(c.label));
  ok(autos.length > 0 && (after.body.checkpoints || []).length > nBefore, "pre-rewind auto-checkpoint recorded");

  // 9) readiness comes back (the supervisor readiness watch flips it ≤3 min)
  t0 = Date.now();
  let ready = false;
  while (Date.now() - t0 < 200_000) {
    const l = await sessions();
    if (l.body.activeReady === true) { ready = true; break; }
    await new Promise((r) => setTimeout(r, 3000));
  }
  ok(ready, `activeReady=true again after rewind (${Math.round((Date.now() - t0) / 1000)}s)`);

  console.log("  → spot-check on the host: ask the bot in Telegram — it must answer,");
  console.log("    and `session-ctl checkpoints` in the pod must show the new entries");
}

console.log(fails === 0 ? "\nM5.8 checkpoints acceptance: OK" : `\nM5.8 acceptance: ${fails} FAILED`);
process.exit(fails === 0 ? 0 : 1);
