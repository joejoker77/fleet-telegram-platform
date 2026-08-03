// M6.2 acceptance — Composio callback route in cp-api (no Composio account
// needed; this validates only OUR surface). The full OAuth e2e ("connect
// Gmail») is M6.4, after the vault staging.
//
// Checks:
//   1) GET /integrations/composio/callback (success params) → 200 text/html
//   2) page mentions the toolkit, says "go back to Telegram"
//   3) status=failed → 200 html with the failure wording
//   4) missing uid → 400; non-numeric uid → 400; bad toolkit chars → 400
//   5) unknown uid does NOT 500 (no tenant → audit skipped, page still OK)
//
// Uses a uid that is NOT a real chat (9000000000000000001) so Telegram
// sendMessage fails silently and nobody gets spammed during acceptance.
//
// Run on the HOST:
//   podman run --rm --network host \
//     -v /home/vitaliy/work/fleet-platform/control-plane:/cp:ro -w /cp \
//     docker.io/library/node:22-alpine node install/m6.2-accept.mjs
const api = process.env.API || "http://127.0.0.1:8080";
const FAKE_UID = "9000000000000000001";

let fails = 0;
const ok = (c, m) => (c ? console.log(`  ✓ ${m}`) : (fails++, console.error(`  ✗ ${m}`)));
const get = async (qs) => {
  const r = await fetch(`${api}/integrations/composio/callback${qs}`);
  return { status: r.status, type: r.headers.get("content-type") ?? "", body: await r.text() };
};

console.log("M6.2 — composio callback route");

// 1) success landing
const s = await get(`?uid=${FAKE_UID}&toolkit=gmail&status=success&connected_account_id=ca_test123`);
ok(s.status === 200, `success callback → 200 (got ${s.status})`);
ok(s.type.includes("text/html"), `content-type html (got ${s.type})`);

// 2) wording
ok(/Gmail/.test(s.body), "page names the toolkit (Gmail)");
ok(/Telegram/.test(s.body), "page tells the user to go back to Telegram");
ok(!/[Cc]omposio|OAuth|MCP/.test(s.body), "page never says Composio/OAuth/MCP (UX rule)");

// 3) failed landing
const f = await get(`?uid=${FAKE_UID}&toolkit=slack&status=failed`);
ok(f.status === 200 && /was not connected|could not connect/i.test(f.body), `failed callback → 200 with failure wording (got ${f.status})`);

// 4) param validation
const noUid = await get(`?toolkit=gmail&status=success`);
ok(noUid.status === 400, `missing uid → 400 (got ${noUid.status})`);
const badUid = await get(`?uid=abc&toolkit=gmail&status=success`);
ok(badUid.status === 400, `non-numeric uid → 400 (got ${badUid.status})`);
const badTk = await get(`?uid=${FAKE_UID}&toolkit=${encodeURIComponent("a b/../c")}&status=success`);
ok(badTk.status === 400, `bad toolkit chars → 400 (got ${badTk.status})`);

// 5) unknown uid never 500s (audit lookup misses, page still renders)
const unk = await get(`?uid=1&toolkit=notion&status=success`);
ok(unk.status === 200, `unknown uid → 200, no crash (got ${unk.status})`);

console.log(fails === 0 ? "M6.2 callback acceptance: OK" : `FAILED: ${fails} check(s)`);
process.exit(fails === 0 ? 0 : 1);
