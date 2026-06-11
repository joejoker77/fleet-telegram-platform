// M5.5b acceptance — secret intake end-to-end (docs/M5.5b-secret-intake-design.md).
// Extends m5.5-accept: same auth (synthetic initData), plus ground-truth vault
// state via the cp-secretd socket (secret_exists returns existence/binding only —
// values are never readable through this channel).
//
//   1) cp-secretd hardwired invariant: bad-convention name → refused
//   2) POST /mcp/connect with an invalid secretSpec → 400 (before the scan)
//   3) benign connect + valid secretSpec → 200, secret staged UNBOUND
//   4) same-name reconnect → rotated=true (Q4: rotation = connect-overwrite)
//   5) allow (the 2nd approval) → applied.ok + secret BOUND + in /mcp/list
//   6) deny the 1st (stale same-name) approval → bound secret SURVIVES
//      (onReject onlyIfUnbound guard)
//   7) disconnect → stanza gone + secret unbound AND deleted
//
// Prereqs: cp-api + cp-judge up, m5.5b-secretd.sh installed (socket present).
// Side effect by design: steps 3/4 send real approval notifications to the pilot.
// Run on the HOST as root:
//   BOT_TOKEN_FILE=<file> node control-plane/install/m5.5b-accept.mjs
import { createHmac } from "node:crypto";
import fs from "node:fs";
import net from "node:net";

const token = fs.readFileSync(process.env.BOT_TOKEN_FILE, "utf8").trim();
const tg = Number(process.env.TG_ID || "2112420187");
const api = process.env.API || "http://127.0.0.1:8080";
const secretdSock = process.env.SECRETD_SOCKET || "/run/cp-secretd/secretd.sock";

const MCP = "m55b-acc";
const SECRET_NAME = `vitaliy-mcp-${MCP}`;
const SPEC = {
  value: "m55b-test-value-not-a-real-secret",
  hostPattern: "api.example.com",
  headerName: "Authorization",
  valueFormat: "Bearer {value}",
};

// ── auth (as in m5.5-accept) ──
const fields = {
  user: JSON.stringify({ id: tg, username: "vitaliy", first_name: "V" }),
  auth_date: String(Math.floor(Date.now() / 1000)),
  query_id: "M55BACCEPT",
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
const post = (path, body) => fetch(`${api}${path}`, { method: "POST", headers: H, body: JSON.stringify(body) }).then(j);
const get = (path) => fetch(`${api}${path}`, { headers: H }).then(j);
const listNames = async () => ((await get("/mcp/list")).body.servers ?? []).map((s) => s.name);

/** One-shot JSON-line exchange with cp-secretd (same protocol as cp-api's secretd.ts). */
function secretd(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const sock = net.connect(secretdSock);
    sock.setTimeout(75_000, () => { sock.destroy(); reject(new Error("cp-secretd timeout")); });
    sock.on("error", reject);
    sock.on("data", (c) => chunks.push(c));
    sock.on("close", () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); }
      catch { reject(new Error("cp-secretd: non-JSON response")); }
    });
    sock.write(JSON.stringify(request) + "\n");
    sock.end();
  });
}
const secretState = () => secretd({ verb: "secret_exists", name: SECRET_NAME });

// 0) pre-clean from earlier runs (idempotent)
await post("/mcp/disconnect", { name: MCP }).catch(() => {});
await secretd({ verb: "delete_secret", name: SECRET_NAME }).catch(() => {});

// 1) cp-secretd refuses a non-convention name (hardwired invariant)
{
  const r = await secretd({ verb: "secret_exists", name: "daria-mcp-evil" });
  ok(r.ok === false, `secretd refuses non-convention name (ok=${r.ok}: ${r.error ?? ""})`);
}

// 2) invalid secretSpec → 400 BEFORE the scan
{
  const r = await post("/mcp/connect", {
    name: MCP,
    stanza: { command: "echo", args: [MCP] },
    secretSpec: { ...SPEC, valueFormat: "Bearer token" }, // no {value}
  });
  ok(r.status === 400, `invalid secretSpec refused with 400 (${r.status}: ${r.body.error ?? ""})`);
  const st = await secretState();
  ok(st.ok && st.exists === false, "nothing staged after the 400");
}

// helper: benign connect with the valid secretSpec
async function connectWithSecret() {
  const r = await post("/mcp/connect", { name: MCP, stanza: { command: "echo", args: [MCP] }, secretSpec: SPEC });
  if (r.status !== 200 || !r.body.approvalId) {
    fails++;
    console.error(`  ✗ connect+secret → ${r.status} ${JSON.stringify(r.body).slice(0, 200)} (cp-judge up? secretd installed?)`);
    return null;
  }
  return r.body;
}

// 3) connect + secret → staged UNBOUND
let firstApprovalId = null;
{
  const body = await connectWithSecret();
  if (body) {
    firstApprovalId = body.approvalId;
    ok(body.secret?.name === SECRET_NAME, `response carries secret.name=${body.secret?.name}`);
    ok(body.secret?.rotated === false, `first stage not a rotation (rotated=${body.secret?.rotated})`);
    const st = await secretState();
    ok(st.ok && st.exists === true && st.bound === false, `secret staged UNBOUND (exists=${st.exists}, bound=${st.bound})`);
  }
}

// 4) same-name reconnect → rotation
let secondApprovalId = null;
{
  const body = await connectWithSecret();
  if (body) {
    secondApprovalId = body.approvalId;
    ok(body.secret?.rotated === true, `re-stage rotates (rotated=${body.secret?.rotated})`);
    const st = await secretState();
    ok(st.ok && st.exists === true && st.bound === false, "rotated secret still UNBOUND");
  }
}

// 5) allow → applied + BOUND + listed
if (secondApprovalId) {
  const ans = await post(`/approvals/${secondApprovalId}/answer`, { decision: "allow" });
  ok(ans.status === 200 && ans.body.applied?.ok === true, `allow applied (${ans.status}, applied=${JSON.stringify(ans.body.applied ?? null)})`);
  const st = await secretState();
  ok(st.ok && st.exists === true && st.bound === true, `secret BOUND after allow (bound=${st.bound})`);
  ok((await listNames()).includes(MCP), `${MCP} present in /mcp/list`);
}

// 6) deny the stale same-name approval → bound secret survives (onlyIfUnbound)
if (firstApprovalId) {
  const ans = await post(`/approvals/${firstApprovalId}/answer`, { decision: "deny" });
  ok(ans.status === 200, `deny stale approval ok (${ans.status})`);
  const st = await secretState();
  ok(st.ok && st.exists === true && st.bound === true, `bound secret SURVIVES the stale deny (exists=${st.exists}, bound=${st.bound})`);
}

// 7) disconnect → stanza gone, secret unbound + deleted
{
  const r = await post("/mcp/disconnect", { name: MCP });
  ok(r.status === 200 && r.body.ok === true, `disconnect ok (${r.status})`);
  ok(!(await listNames()).includes(MCP), `${MCP} gone from /mcp/list`);
  const st = await secretState();
  ok(st.ok && st.exists === false, `secret deleted on disconnect (exists=${st.exists})`);
}

console.log(`\nM5.5b secret-intake acceptance: ${fails ? `FAILED (${fails})` : "OK"}`);
process.exit(fails ? 1 : 0);
