// Self-service sign-in, one tap.
//
//   GET /relogin/:token — mint a FRESH Claude sign-in link for that tenant and
//                         302 the browser straight at it. PUBLIC (no JWT).
//
// WHY THIS EXISTS. The expiry ladder warns a tenant three, two and one day before
// their Claude login lapses, and the warning carries a button. A Telegram inline URL
// button is static: whatever link is in it was fixed when the message was sent. But a
// sign-in link is backed by a live sign-in process in that tenant's pod whose flow
// dies in twenty minutes. So a button minted days ahead sends the person to a page
// that works, hands them a code, and then the code comes back to "the sign-in is no
// longer running". That is a support ticket every single time.
//
// This endpoint inverts it. The button carries a STABLE address — ours — and the
// Claude link is made at the moment the person taps, then returned as a redirect. The
// message can sit unread for a week and the button still works.
//
// THE TOKEN IS THE TENANT'S OWN, NOT A SIGNATURE. Each pod mints a random token once
// into its own state dir and builds its own button URL from it; cp-api verifies by
// reading that same file, the way it already reads each tenant's bot token for
// initData. No shared signing secret has to exist on the host, in this service, or in
// the pod — and rotation is deleting one file.
//
// WHY PUBLIC IS ACCEPTABLE. The token authorises exactly one thing: "start a sign-in
// for this tenant". It is not a Claude credential. Someone who steals it can make the
// pod offer a sign-in page and can complete that page with their OWN Claude account —
// but the resulting code only takes effect if it is delivered to the pod, and the only
// road in is the tenant's own allowlisted Telegram chat. So the realistic abuse is
// noise, which is what the rate limit below is for.
//
// WHY THE TOKEN DOES NOT EXPIRE. The whole defect being fixed is a button that goes
// stale while the message waits to be read. A lifetime on the token would reintroduce
// it in a new place. The token is a long-lived permission to START; the thing that
// must be fresh — the Claude link — is minted per request and never stored.
import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { timingSafeEqual } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { sendAudit } from "./audit.js";

const execFileP = promisify(execFile);

export interface ReloginRoutesDeps {
  /** <tenantHomeRoot>/<user>/.claude/… — the same root the bot-token reader uses. */
  tenantHomeRoot: string;
  /** Host-side trigger that reaches into the tenant's pod. */
  triggerPath: string;
  auditSocket: string;
}

/** Linux usernames we are willing to put on a command line or in a path. */
const TENANT_RE = /^[a-z][a-z0-9_-]{0,31}$/;

/** What the pod writes. Hex keeps it safe in a URL and in a path comparison. */
const SECRET_RE = /^[0-9a-f]{32,128}$/;

/** The in-pod helper waits up to 45s for the link; leave room for podman exec. */
const TRIGGER_TIMEOUT_MS = 75_000;

/** One start per tenant per window. A second tap inside it is a double-tap. */
const RATE_WINDOW_MS = 30_000;

/** Only a real Anthropic/Claude authorize URL is ever worth redirecting at. */
const URL_RE = /^https:\/\/[a-z0-9.-]*(anthropic|claude)\.(com|ai)\/[^\s]*$/i;

function tokenPath(homeRoot: string, tenant: string): string {
  return path.join(homeRoot, tenant, ".claude", "channels", `telegram-${tenant}`, "relogin-token");
}

/** Constant-time compare of the presented secret against the tenant's own file. */
function verify(homeRoot: string, token: string): string | null {
  const dot = token.lastIndexOf(".");
  if (dot <= 0) return null;
  const tenant = token.slice(0, dot);
  const presented = token.slice(dot + 1);
  if (!TENANT_RE.test(tenant) || !SECRET_RE.test(presented)) return null;

  let stored: string;
  try {
    stored = fs.readFileSync(tokenPath(homeRoot, tenant), "utf8").trim();
  } catch {
    return null;
  }
  if (!SECRET_RE.test(stored)) return null;

  const a = Buffer.from(stored, "utf8");
  const b = Buffer.from(presented, "utf8");
  if (a.length !== b.length) return null;
  return timingSafeEqual(a, b) ? tenant : null;
}

/** A page, not a bare status: whoever is reading it is a lawyer on a phone. */
function problem(reply: any, status: number, line: string) {
  return reply.code(status).type("text/html; charset=utf-8").send(
    `<!doctype html><meta charset="utf-8">` +
      `<meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<title>Sign-in</title>` +
      `<body style="font:16px/1.5 system-ui;margin:0;padding:2rem;max-width:34rem">` +
      `<p>${line}</p>` +
      `<p>Send the word <b>relogin</b> to your assistant in Telegram and it will ` +
      `set up a new sign-in for you.</p>`,
  );
}

export function registerReloginRoutes(app: FastifyInstance, deps: ReloginRoutesDeps) {
  const lastStart = new Map<string, number>();

  app.get<{ Params: { token: string } }>("/relogin/:token", async (req, reply) => {
    const tenant = verify(deps.tenantHomeRoot, req.params.token ?? "");
    if (!tenant) {
      // Deliberately the same answer as a valid-looking token for a tenant that does
      // not exist: a probe learns nothing about who is on this host.
      return problem(reply, 404, "This sign-in link is not valid.");
    }

    const now = Date.now();
    if (now - (lastStart.get(tenant) ?? 0) < RATE_WINDOW_MS) {
      return problem(reply, 429, "A sign-in was just started for you — check Telegram.");
    }
    lastStart.set(tenant, now);

    let url = "";
    try {
      const { stdout } = await execFileP(deps.triggerPath, [tenant, "--print-url"], {
        timeout: TRIGGER_TIMEOUT_MS,
        maxBuffer: 1 << 20,
      });
      url = stdout.trim().split("\n").pop()?.trim() ?? "";
    } catch (err: any) {
      lastStart.delete(tenant); // a failure must not lock them out for the window
      void sendAudit(deps.auditSocket, {
        userId: null,
        kind: "relogin.redirect_failed",
        actor: tenant,
        payload: { error: String(err?.stderr || err?.message || err).slice(0, 400) },
      }).catch(() => {});
      return problem(reply, 503, "I could not start a sign-in just now.");
    }

    // Never redirect at something we did not recognise. If the helper's output shape
    // drifts, a stray line must not become an open redirect.
    if (!URL_RE.test(url)) {
      lastStart.delete(tenant);
      void sendAudit(deps.auditSocket, {
        userId: null,
        kind: "relogin.redirect_bad_url",
        actor: tenant,
        payload: { got: url.slice(0, 200) },
      }).catch(() => {});
      return problem(reply, 502, "I could not start a sign-in just now.");
    }

    void sendAudit(deps.auditSocket, {
      userId: null,
      kind: "relogin.redirect",
      actor: tenant,
      payload: { mintedOnTap: true },
    }).catch(() => {});

    // 302 and no-store: the next tap must come back here for a new link, never reuse
    // this one out of the browser's cache.
    return reply
      .code(302)
      .header("cache-control", "no-store, no-cache, must-revalidate")
      .header("location", url)
      .send();
  });
}
