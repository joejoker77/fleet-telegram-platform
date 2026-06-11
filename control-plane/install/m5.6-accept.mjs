// M5.6 acceptance — web-IDE forward-auth end-to-end (docs/M5.6-web-ide-design.md).
// Same auth scaffolding as m5.5b-accept (synthetic initData HMAC).
//
// PHASE A (cp-api only — runnable right after the m1.5 re-run):
//   1) POST /ide/ticket → { url } pointing at <ideUrl>/api/ide/login?t=…
//   2) GET /ide/login?t= → 302 + HttpOnly cp_ide cookie
//   3) the SAME ticket again → 401 (GETDEL one-time)
//   4) /ide/auth with cookie + correct X-Ide-Tenant → 204
//   5) /ide/auth with cookie + WRONG tenant → 401
//   6) /ide/auth without cookie / with garbage cookie → 401
//   7) /ide/auth with cookie + MISSING tenant header → 401 (fail-closed)
//
// PHASE B (public e2e through nginx + the pod's unix socket — requires the
// vhost installed AND the pod restarted with CP_IDE_SOCKET; skip before the
// end-of-session restart with SKIP_PUBLIC=1):
//   8) fresh ticket → GET https://ide…/api/ide/login?t= → 302 + cookie
//   9) GET https://ide…/ with the cookie → 200, body looks like code-server
//  10) GET https://ide…/ without a cookie → 401
//
// Run on the HOST (canonical recipe — podman secret, as m5.4b/m5.5b):
//   podman run --rm --network host --secret cp_bot_token \
//     -v /home/vitaliy/work/fleet-platform/control-plane:/cp:ro -w /cp \
//     -e BOT_TOKEN_FILE=/run/secrets/cp_bot_token \
//     docker.io/library/node:22-alpine node install/m5.6-accept.mjs
//   (add -e SKIP_PUBLIC=1 before the pod restart)
import { createHmac } from "node:crypto";
import fs from "node:fs";

const token = fs.readFileSync(process.env.BOT_TOKEN_FILE, "utf8").trim();
const tg = Number(process.env.TG_ID || "2112420187");
const api = process.env.API || "http://127.0.0.1:8080";
const pub = (process.env.IDE_PUBLIC || "https://ide.ai-assistant.gg").replace(/\/$/, "");
const TENANT = process.env.TENANT || "vitaliy";
const skipPublic = process.env.SKIP_PUBLIC === "1";

// ── auth (as in m5.5b-accept) ──
const fields = {
  user: JSON.stringify({ id: tg, username: "vitaliy", first_name: "V" }),
  auth_date: String(Math.floor(Date.now() / 1000)),
  query_id: "M56ACCEPT",
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

const newTicket = async () => {
  const r = await fetch(`${api}/ide/ticket`, { method: "POST", headers: H, body: "{}" });
  const body = await r.json().catch(() => ({}));
  if (r.status !== 200 || typeof body.url !== "string") {
    fails++;
    console.error(`  ✗ POST /ide/ticket → ${r.status} ${JSON.stringify(body).slice(0, 200)}`);
    return null;
  }
  return body;
};
const ticketOf = (url) => new URL(url).searchParams.get("t");
const cookieOf = (res) => {
  const sc = res.headers.get("set-cookie") || "";
  const m = sc.match(/cp_ide=([^;]+)/);
  return m ? `cp_ide=${m[1]}` : null;
};
const authCheck = (headers) => fetch(`${api}/ide/auth`, { headers }).then((r) => r.status);

console.log("PHASE A — cp-api ticket → cookie → auth_request flow");

// 1) ticket
const t1 = await newTicket();
if (!t1) process.exit(1);
ok(t1.url.startsWith(`${pub}/api/ide/login?t=`), `ticket URL points at the IDE origin (${t1.url.split("?")[0]})`);
ok(t1.ttlSeconds === 60, `ticket ttl is 60s (got ${t1.ttlSeconds})`);
const tick = ticketOf(t1.url);

// 2) login → 302 + cookie
const login1 = await fetch(`${api}/ide/login?t=${tick}`, { redirect: "manual" });
ok(login1.status === 302, `login with fresh ticket → 302 (got ${login1.status})`);
const cookie = cookieOf(login1);
ok(!!cookie, "login sets the cp_ide cookie");
const rawSetCookie = login1.headers.get("set-cookie") || "";
ok(/HttpOnly/i.test(rawSetCookie) && /Secure/i.test(rawSetCookie) && /SameSite=Lax/i.test(rawSetCookie),
  "cookie is HttpOnly + Secure + SameSite=Lax");

// 3) one-time: same ticket again → 401
{
  const r = await fetch(`${api}/ide/login?t=${tick}`, { redirect: "manual" });
  ok(r.status === 401, `reused ticket → 401 (got ${r.status})`);
}

// 4-7) auth_request matrix
ok((await authCheck({ cookie, "x-ide-tenant": TENANT })) === 204, "auth: cookie + correct tenant → 204");
ok((await authCheck({ cookie, "x-ide-tenant": "daria" })) === 401, "auth: cookie + WRONG tenant → 401");
ok((await authCheck({ "x-ide-tenant": TENANT })) === 401, "auth: no cookie → 401");
ok((await authCheck({ cookie: "cp_ide=garbage", "x-ide-tenant": TENANT })) === 401, "auth: garbage cookie → 401");
ok((await authCheck({ cookie })) === 401, "auth: missing tenant header → 401 (fail-closed)");

if (skipPublic) {
  console.log("PHASE B — SKIPPED (SKIP_PUBLIC=1; run the full script after the pod restart)");
} else {
  console.log(`PHASE B — public e2e via ${pub} (nginx auth_request + pod unix socket)`);
  // 8) fresh ticket through the public login
  const t2 = await newTicket();
  if (t2) {
    const login2 = await fetch(t2.url, { redirect: "manual" });
    ok(login2.status === 302, `public login → 302 (got ${login2.status}; vhost installed? certbot done?)`);
    const pubCookie = cookieOf(login2);
    ok(!!pubCookie, "public login sets the cookie");
    if (pubCookie) {
      // 9) IDE root with the cookie → 200 from code-server
      const ide = await fetch(`${pub}/`, { headers: { cookie: pubCookie } });
      const html = await ide.text().catch(() => "");
      ok(ide.status === 200, `IDE root with cookie → 200 (got ${ide.status}; pod restarted with CP_IDE_SOCKET?)`);
      ok(/code-?server|vscode|workbench/i.test(html), "response body looks like code-server");
    }
    // 10) without a cookie → 401
    const anon = await fetch(`${pub}/`);
    ok(anon.status === 401, `IDE root without cookie → 401 (got ${anon.status})`);
  }
}

console.log(fails === 0 ? "\nM5.6 web-IDE acceptance: OK" : `\nM5.6 acceptance: ${fails} FAILED`);
process.exit(fails === 0 ? 0 : 1);
