// M5.10 acceptance — workspace scopes (docs/M5.10-workspace-scopes-design.md).
// Same auth scaffolding as m5.7/m5.8-accept (synthetic initData HMAC).
// Entirely SAFE: read-only except one PUT into the project's hidden .trash/.
//
//   1) /fs/tree without params → legacy recursive contract (root ".claude")
//   2) scope=project → root label matches the active session dir; junk
//      (.trash/node_modules/*.log) absent by default, all=1 reveals more
//   3) scope=artifacts → top level is ONLY the whitelist
//   4) scope=home → dotfiles hidden at root, all=1 reveals .claude
//   5) scope=home&dir=work → one level, paths prefixed "work/"
//   6) scope=evil → 400 bad_scope; dir escape → 400; bogus dir → 404
//   7) GET fs/file scope=project CLAUDE.md → 200
//   8) PUT scope=project .trash/m510-accept.txt → ok + GET round-trip
//
// Run on the HOST (canonical recipe — podman secret, as m5.4b…m5.8):
//   podman run --rm --network host --secret cp_bot_token \
//     -v /home/vitaliy/work/fleet-platform/control-plane:/cp:ro -w /cp \
//     -e BOT_TOKEN_FILE=/run/secrets/cp_bot_token \
//     docker.io/library/node:22-alpine node install/m5.10-accept.mjs
import { createHmac } from "node:crypto";
import fs from "node:fs";

const token = fs.readFileSync(process.env.BOT_TOKEN_FILE, "utf8").trim();
const tg = Number(process.env.TG_ID || "2112420187");
const api = process.env.API || "http://127.0.0.1:8080";

// ── auth (as in m5.7/m5.8-accept) ──
const fields = {
  user: JSON.stringify({ id: tg, username: "vitaliy", first_name: "V" }),
  auth_date: String(Math.floor(Date.now() / 1000)),
  query_id: "M510ACCEPT",
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
const tree = async (qs) => j(await fetch(`${api}/fs/tree${qs ? `?${qs}` : ""}`, { headers: H }));

// 1) legacy contract intact
{
  const r = await tree("");
  ok(r.status === 200 && r.body.root === ".claude" && Array.isArray(r.body.entries), `legacy /fs/tree → 200 root=.claude (got ${r.status} root=${r.body.root})`);
  ok(r.body.scope === undefined, "legacy response carries no scope field");
}

// 2) project scope
{
  const r = await tree("scope=project");
  ok(r.status === 200 && r.body.scope === "project", `scope=project → 200 (got ${r.status})`);
  ok(typeof r.body.root === "string" && r.body.root.startsWith("~/work"), `project root label is ~/work[...] (got ${r.body.root})`);
  const names = (r.body.entries || []).map((e) => e.name);
  ok(!names.includes(".trash") && !names.includes("node_modules") && !names.some((n) => /\.log$/.test(n)), "junk classes hidden by default");
  ok((r.body.entries || []).every((e) => !e.path.includes("/")), "one level only (no nested paths)");
  const ra = await tree("scope=project&all=1");
  ok(ra.status === 200 && (ra.body.entries || []).length >= (r.body.entries || []).length, "all=1 reveals ≥ default");
  ok(ra.body.hidden === 0, "all=1 → hidden=0");
}

// 3) artifacts scope = whitelist
{
  const r = await tree("scope=artifacts");
  const allowed = new Set(["agents", "commands", "skills", "CLAUDE.md", "settings.json"]);
  const names = (r.body.entries || []).map((e) => e.name);
  ok(r.status === 200 && names.length > 0, `scope=artifacts → 200 + entries (got ${r.status}, n=${names.length})`);
  ok(names.every((n) => allowed.has(n)), `artifacts top level ⊆ whitelist (got: ${names.join(", ")})`);
  ok(!names.includes("backups") && !names.includes("file-history"), "runtime clutter absent");
}

// 4) home scope: dotfiles hidden, all=1 reveals .claude
{
  const r = await tree("scope=home");
  const names = (r.body.entries || []).map((e) => e.name);
  ok(r.status === 200 && r.body.root === "~", `scope=home → 200 root=~ (got ${r.status} ${r.body.root})`);
  ok(names.every((n) => !n.startsWith(".")), "dotfiles hidden at home root by default");
  ok(r.body.hidden > 0, `hidden counter > 0 at home root (got ${r.body.hidden})`);
  const ra = await tree("scope=home&all=1");
  ok((ra.body.entries || []).some((e) => e.name === ".claude"), "all=1 reveals .claude at home root");
}

// 5) lazy subdir listing
{
  const r = await tree("scope=home&dir=work");
  ok(r.status === 200 && r.body.dir === "work", `scope=home&dir=work → 200 (got ${r.status})`);
  ok((r.body.entries || []).every((e) => e.path.startsWith("work/")), "entry paths are dir-prefixed");
  ok((r.body.entries || []).every((e) => e.path.split("/").length === 2), "one level only");
}

// 6) invalid inputs
{
  const r1 = await tree("scope=evil");
  ok(r1.status === 400 && r1.body.code === "bad_scope", `scope=evil → 400 bad_scope (got ${r1.status} ${r1.body.code})`);
  const r2 = await tree(`scope=home&dir=${encodeURIComponent("../../etc")}`);
  ok(r2.status === 400, `dir escape → 400 (got ${r2.status})`);
  const r3 = await tree("scope=project&dir=no-such-dir-m510");
  ok(r3.status === 404 && r3.body.code === "not_found", `bogus dir → 404 not_found (got ${r3.status})`);
}

// 7) scoped file read
{
  const r = await j(await fetch(`${api}/fs/file?path=CLAUDE.md&scope=project`, { headers: H }));
  ok(r.status === 200 && typeof r.body.content === "string", `GET fs/file scope=project CLAUDE.md → 200 (got ${r.status})`);
}

// 8) scoped write round-trip (lands in the project's hidden .trash/ — invisible, inert)
{
  const PATH = ".trash/m510-accept.txt";
  const CONTENT = `m510 accept ${new Date().toISOString()}\n`;
  const w = await j(await fetch(`${api}/fs/file`, {
    method: "PUT",
    headers: H,
    body: JSON.stringify({ path: PATH, content: CONTENT, scope: "project" }),
  }));
  ok(w.status === 200 && w.body.ok === true, `PUT scope=project → 200 (got ${w.status})`);
  const r = await j(await fetch(`${api}/fs/file?path=${encodeURIComponent(PATH)}&scope=project`, { headers: H }));
  ok(r.status === 200 && r.body.content === CONTENT, "PUT/GET round-trip matches");
  const t2 = await tree("scope=project");
  ok(!(t2.body.entries || []).some((e) => e.name === ".trash"), ".trash stays hidden in the default tree");
}

console.log(fails === 0 ? "\nM5.10 scopes acceptance: OK" : `\nM5.10 acceptance: ${fails} FAILED`);
process.exit(fails === 0 ? 0 : 1);
