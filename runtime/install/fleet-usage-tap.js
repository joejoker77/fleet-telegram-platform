// fleet-usage-tap — preloaded into every Claude Code process in a tenant pod
// (claude-pod-run sets BUN_OPTIONS=--preload <this file>). Two jobs, nothing else:
//
// 1. USAGE, WITHOUT A REQUEST OF OUR OWN. Anthropic returns the account's 5-hour and weekly
//    limit state on every /v1/messages response (anthropic-ratelimit-unified-* headers).
//    We read those headers off responses Claude Code already receives and write the latest
//    values to ~/.claude/fleet-usage.json. This covers the Telegram session, every Claude
//    App session and every subagent, because they all run through this code. Verified on
//    2.1.280, 2026-09-29.
//
// 2. CONTEXT WINDOW, LIVE. fleet-governor writes the tenant's window to /etc/fleet-ctl/window
//    (root-owned, mounted read-only). We mirror it into process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW,
//    which Claude Code re-reads before every request (resolveAutoCompactWindow), so a change
//    reaches sessions that are already running, App sessions included. Verified 2026-09-29:
//    1M -> 400k -> 200k in a live headless session, and a 120k conversation compacted to 20k
//    on the next turn after the window went to 100k.
//
// Never throws, never delays a response, never sends anything anywhere. If Claude Code stops
// using fetch or changes the header names, the snapshot just stops updating and the governor
// holds its current decision (it never tightens on stale data).
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
  const MIN_WRITE_MS = 2000;
  let lastWrite = 0, lastKey = "";

  function num(v) { const n = Number(v); return Number.isFinite(n) ? n : null; }

  function record(h) {
    const w = (p) => {
      const u = num(h.get("anthropic-ratelimit-unified-" + p + "-utilization"));
      const r = num(h.get("anthropic-ratelimit-unified-" + p + "-reset"));
      if (u === null || r === null) return null;
      return { utilization: u, resets_at: r, status: h.get("anthropic-ratelimit-unified-" + p + "-status") || null };
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
                   status: h.get("anthropic-ratelimit-unified-status") || null };
    try {
      const tmp = OUT + ".tmp-" + process.pid;
      fs.writeFileSync(tmp, JSON.stringify(snap));
      fs.renameSync(tmp, OUT);
    } catch (e) { /* best effort */ }
  }

  try {
    const orig = globalThis.fetch;
    if (typeof orig === "function" && !orig.__fleetTap) {
      const tapped = async function (input) {
        const res = await orig.apply(this, arguments);
        try {
          const url = typeof input === "string" ? input : (input && input.url) || String(input || "");
          if (url.indexOf("/v1/messages") !== -1 && res && res.headers) {
            record(res.headers);
            // The governor answers this response's numbers within ~1 s; pick that up promptly.
            const t2 = setTimeout(applyWindow, 1500); if (t2 && t2.unref) t2.unref();
          }
        } catch (e) { /* never interfere */ }
        return res;
      };
      tapped.__fleetTap = true;
      globalThis.fetch = tapped;
    }
  } catch (e) { /* leave fetch alone */ }

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
