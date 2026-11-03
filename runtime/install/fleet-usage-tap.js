// fleet-usage-tap — preloaded into every Claude Code process in a tenant pod
// (claude-pod-run sets BUN_OPTIONS=--preload <this file>). Two jobs, nothing else:
//
// 1. USAGE, WITHOUT A REQUEST OF OUR OWN. Anthropic returns the account's 5-hour and weekly
//    limit state on every /v1/messages response (anthropic-ratelimit-unified-* headers).
//    We observe those headers as Claude Code itself reads them and write the latest values
//    to ~/.claude/fleet-usage.json. This covers the Telegram session, every Claude App
//    session and every subagent, because they all run through this code.
//
// 2. CONTEXT WINDOW, LIVE. fleet-governor writes the tenant's window to /etc/fleet-ctl/window
//    (root-owned, mounted read-only). We mirror it into process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW,
//    which Claude Code re-reads before every request (resolveAutoCompactWindow), so a change
//    reaches sessions that are already running, App sessions included. Verified 2026-09-29:
//    1M -> 400k -> 200k in a live headless session, and a 120k conversation compacted to 20k
//    on the next turn after the window went to 100k.
//
// WHY JOB 1 OBSERVES Headers AND NOT fetch — this is the whole history, so nobody rebuilds the
// broken version. Until 2026-11-03 job 1 wrapped globalThis.fetch. Somewhere in the 2.1.3xx
// line Claude Code moved its model requests to Bun's own `fetch` (`Bun.fetch`), a DIFFERENT
// object whose descriptor is non-writable and non-configurable, so it cannot be hooked at all.
// Measured against 2.1.316: pointed at a mock API, the mock logged POST /v1/messages and the
// fetch hook saw none of them, while it kept seeing the MCP servers and the telemetry batch,
// which do go through globalThis.fetch. The cost of that blind spot was seven weeks of
// fleet-governor answering "no fresh usage data" on every tick, no tenant ever leaving step 0,
// and conversations reaching 700k tokens resent on every single request.
//
// The fix does not care which fetch produced the response. Whoever makes the request, the
// headers are read back through the standard Headers object, and Headers.prototype IS
// writable and configurable. So we wrap the READ side — get and forEach — and watch the
// values go past. Proved end to end on 2026-11-03 with the real claude.exe 2.1.316 against a
// local mock: all six unified headers captured, 15 reads in a single request, CLI unaffected.
//
// Observation only: every wrapper returns exactly what the original returned, so a request
// cannot be changed, delayed or failed by this file. Nothing is in the model path — there is
// no proxy and no base-URL redirection, which ADR-001 forbids and which Anthropic fingerprints.
// If the header names change, the snapshot simply stops updating and the governor holds its
// current decision (it never tightens on stale data).
(function () {
  "use strict";
  let fs;
  try {
    // The telegram plugin and any other Bun script in the pod inherit BUN_OPTIONS too; only
    // Claude Code itself should be touched.
    const exe = String(process.execPath || "") + " " + String((process.argv || [])[0] || "");
    if (!/claude/i.test(exe)) return;
    fs = require("fs");
  } catch (e) { return; }

  const HOME = process.env.HOME || "";
  const OUT = HOME + "/.claude/fleet-usage.json";
  const CTL = process.env.FLEET_CTL_FILE || "/etc/fleet-ctl/window";
  const PREFIX = "anthropic-ratelimit-unified-";
  const MIN_WRITE_MS = 2000;
  let lastWrite = 0, lastKey = "";

  function num(v) { const n = Number(v); return Number.isFinite(n) ? n : null; }

  // The reset headers have been epoch seconds on every response we have seen; accept an ISO
  // timestamp too, so a format change costs the governor nothing.
  function epoch(v) {
    const n = Number(v);
    if (Number.isFinite(n)) return n;
    const t = Date.parse(String(v || ""));
    return Number.isFinite(t) ? Math.floor(t / 1000) : null;
  }

  function record(cap) {
    const w = (p) => {
      const u = num(cap[PREFIX + p + "-utilization"]);
      const r = epoch(cap[PREFIX + p + "-reset"]);
      if (u === null || r === null) return null;
      return { utilization: u, resets_at: r, status: cap[PREFIX + p + "-status"] || null };
    };
    const five = w("5h"), seven = w("7d");
    if (!five && !seven) return;
    const now = Date.now();
    const key = JSON.stringify([five, seven]);
    // New numbers are written at once (at most one write per 2 s); unchanged numbers are
    // re-stamped once a minute so the governor can tell "quiet" from "stale".
    if (key === lastKey ? now - lastWrite < 60000 : now - lastWrite < MIN_WRITE_MS) return;
    lastKey = key; lastWrite = now;
    const snap = { ts: Math.floor(now / 1000), pid: process.pid, five_hour: five, seven_day: seven,
                   status: cap[PREFIX + "status"] || null };
    try {
      const tmp = OUT + ".tmp-" + process.pid;
      fs.writeFileSync(tmp, JSON.stringify(snap));
      fs.renameSync(tmp, OUT);
    } catch (e) { /* best effort */ }
  }

  // Headers are read one at a time, so collect a response's values and write the snapshot once
  // the burst is over. 50 ms is far longer than the reads take and far shorter than a turn.
  const cap = Object.create(null);
  let flushTimer = null;

  function flush() {
    flushTimer = null;
    try { record(cap); } catch (e) { /* never interfere */ }
    // A model response has just landed, so the governor is deciding right now; pick its
    // answer up promptly instead of waiting for the next one-second tick.
    try { const t = setTimeout(applyWindow, 1500); if (t && t.unref) t.unref(); } catch (e) {}
  }

  function capture(name, value) {
    try {
      if (typeof name !== "string" || value === null || value === undefined) return;
      const k = name.toLowerCase();
      if (k.lastIndexOf(PREFIX, 0) !== 0) return;
      cap[k] = String(value);
      if (!flushTimer) {
        flushTimer = setTimeout(flush, 50);
        if (flushTimer && flushTimer.unref) flushTimer.unref();
      }
    } catch (e) { /* never interfere */ }
  }

  try {
    const H = (typeof Headers === "function") && Headers.prototype;
    if (H && !H.__fleetTap) {
      const get = H.get;
      if (typeof get === "function") {
        H.get = function (name) { const v = get.call(this, name); capture(name, v); return v; };
      }
      const forEach = H.forEach;
      if (typeof forEach === "function") {
        H.forEach = function (cb, thisArg) {
          return forEach.call(this, function (value, name, parent) {
            capture(name, value);
            return cb.call(thisArg, value, name, parent);
          });
        };
      }
      H.__fleetTap = true;
    }
  } catch (e) { /* leave Headers alone */ }

  // The governor's window, mirrored into the env var Claude Code re-reads per request.
  // Missing/garbled file -> leave whatever the pod started with (normally unset = auto).
  const startEnv = process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW;
  function applyWindow() {
    try {
      const v = fs.readFileSync(CTL, "utf8").trim();
      if (/^[0-9]{5,8}$/.test(v)) process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = v;
      else if (v === "auto") {
        if (startEnv === undefined) delete process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW;
        else process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = startEnv;
      }
    } catch (e) { /* no control file: nothing to do */ }
  }
  // Every second (a tiny file read) — the governor decides within a second of each response,
  // so the new window is in place before Claude Code prepares the next request.
  try { applyWindow(); const t = setInterval(applyWindow, 1000); if (t && t.unref) t.unref(); } catch (e) {}
})();
