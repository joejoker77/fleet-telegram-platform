// M5.1 acceptance — mint a JWT (synthetic initData signed with the bot token,
// like auth-roundtrip), then exercise the authoring fs API end-to-end against
// cp-api: write a file into the tenant sandbox, list the tree, read it back, and
// confirm a path-escape is rejected. Runs in a throwaway container (bot-token
// secret mounted; api on host loopback). Exits non-zero on any failure.
import { createHmac } from "node:crypto";
import fs from "node:fs";

const token = fs.readFileSync(process.env.BOT_TOKEN_FILE, "utf8").trim();
const tg = Number(process.env.TG_ID || "2112420187");
const api = process.env.API || "http://127.0.0.1:8080";
const TESTPATH = "_authoring-selftest.md";
const CONTENT = "# authoring selftest\nbenign note written by m5.1-fs-accept\n";

const fields = {
  user: JSON.stringify({ id: tg, username: "vitaliy", first_name: "V" }),
  auth_date: String(Math.floor(Date.now() / 1000)),
  query_id: "M5ACCEPT",
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

// 1) PUT (boundary-1 save)
const put = await fetch(`${api}/fs/file`, { method: "PUT", headers: H, body: JSON.stringify({ path: TESTPATH, content: CONTENT }) });
const putBody = await put.json();
ok(put.status === 200 && putBody.ok === true, `PUT /fs/file ok (${put.status})`);
ok(Array.isArray(putBody.advisory), "PUT returns an advisory array (non-blocking)");
ok((putBody.advisory ?? []).length === 0, "benign content → empty advisory");

// 2) tree lists it
const tree = await (await fetch(`${api}/fs/tree`, { headers: H })).json();
ok((tree.entries ?? []).some((e) => e.path === TESTPATH), "GET /fs/tree includes the new file");

// 3) read back
const got = await (await fetch(`${api}/fs/file?path=${encodeURIComponent(TESTPATH)}`, { headers: H })).json();
ok(got.content === CONTENT, "GET /fs/file returns the exact bytes");

// 4) path escape rejected
const esc = await fetch(`${api}/fs/file`, { method: "PUT", headers: H, body: JSON.stringify({ path: "../../etc/x", content: "x" }) });
ok(esc.status === 400, `path-escape PUT rejected (${esc.status})`);

console.log(`\nM5.1 fs acceptance: ${fails ? `FAILED (${fails})` : "OK"}`);
process.exit(fails ? 1 : 0);
