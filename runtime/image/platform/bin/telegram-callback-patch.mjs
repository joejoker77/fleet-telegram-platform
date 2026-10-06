#!/usr/bin/env node
// telegram-callback-patch — teach the official Telegram plugin to hand our own
// inline-button taps to the session, instead of swallowing them.
//
// WHY THIS EXISTS. A Telegram inline URL button carries a STATIC url, baked in when
// the message is sent. The relogin flow needs the opposite: the sign-in link must be
// minted at the moment the person taps, because the link is backed by a live
// `claude auth login` process whose flow expires in 20 minutes, while the warning that
// carries it is sent 3, 2 and 1 DAYS ahead. Tap a day-old link today and you sign in
// fine, send the code back, and get "the sign-in is no longer running".
//
// A callback button is the only shape Telegram offers where the bot learns about the
// tap itself. The plugin already receives callback queries, but its handler matches
// exactly `perm:(allow|deny|more):<id>` and answers everything else with a bare
// answerCallbackQuery() and a silent return — our tap is received and dropped, and no
// mod hook ever sees it, because a mod's events are Claude Code lifecycle events and
// the only road from Telegram into the session is handleInbound().
//
// WHY A PATCH AND NOT A SIDECAR. Sending can be done beside the plugin — that is what
// telegram-progress-sidecar.mjs does, and nothing in Telegram objects to several
// senders on one token. Receiving cannot: getUpdates allows exactly ONE consumer per
// token and a second one takes the slot with a 409, which is the outage this fleet
// already guards against. So the code that receives has to be the plugin's own.
//
// WHAT IT CHANGES. One branch. Unmatched callback data whose prefix is ours is acked
// and passed to handleInbound(), the same function every text message goes through —
// so it inherits the plugin's allowlist gate unchanged. Everything else keeps the old
// behaviour exactly.
//
// IDEMPOTENT. Re-running is a no-op: the marker below is checked first.
//
// Usage:  telegram-callback-patch.mjs [--dir <plugin version dir>] [--check] [--all]
//   --check  report only, exit 1 if an active copy is unpatched
//   --all    patch every version dir found, not just the newest

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync, copyFileSync } from 'node:fs'
import { join } from 'node:path'

const MARKER = 'relogin-callback-bridge'
const PREFIX_CONST = "const RELOGIN_CB_PREFIXES = ['relogin:']"

const HOME = process.env.HOME || '/root'
const CACHE = join(HOME, '.claude/plugins/cache/claude-plugins-official/telegram')

const args = process.argv.slice(2)
const CHECK = args.includes('--check')
const ALL = args.includes('--all')
const DIR_ARG = args.includes('--dir') ? args[args.indexOf('--dir') + 1] : null

function log(...a) { console.log('[callback-patch]', ...a) }

function versionDirs() {
  if (DIR_ARG) return [DIR_ARG]
  if (!existsSync(CACHE)) return []
  const dirs = readdirSync(CACHE)
    .map(v => join(CACHE, v))
    .filter(p => { try { return statSync(p).isDirectory() } catch { return false } })
  if (ALL) return dirs
  // Newest by mtime: that is the one Claude Code just repointed installed_plugins.json at.
  return dirs.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs).slice(0, 1)
}

// The branch we replace, verbatim from upstream 0.0.7. Matching the exact text (not a
// regex over a shape) is deliberate: if upstream rewrites this handler, the match fails
// and we refuse loudly instead of silently producing a plugin that looks patched and
// is not.
const ANCHOR = `  const m = /^perm:(allow|deny|more):([a-km-z]{5})$/.exec(data)
  if (!m) {
    await ctx.answerCallbackQuery().catch(() => {})
    return
  }`

const REPLACEMENT = `  const m = /^perm:(allow|deny|more):([a-km-z]{5})$/.exec(data)
  if (!m) {
    // ${MARKER}: our own buttons must reach the session. A URL button cannot carry a
    // link that is minted at tap time; a callback button can, but only if the tap is
    // delivered. Route it through handleInbound so it passes the SAME allowlist gate
    // as a typed message — never bypass gate() here.
    ${PREFIX_CONST}
    if (RELOGIN_CB_PREFIXES.some(p => data.startsWith(p))) {
      await ctx.answerCallbackQuery().catch(() => {})
      await handleInbound(ctx, data, undefined).catch(() => {})
      return
    }
    await ctx.answerCallbackQuery().catch(() => {})
    return
  }`

let failed = 0
const dirs = versionDirs()
if (dirs.length === 0) { log('no plugin copy found under', CACHE); process.exit(CHECK ? 1 : 0) }

for (const dir of dirs) {
  const file = join(dir, 'server.ts')
  if (!existsSync(file)) { log('no server.ts in', dir); continue }
  const src = readFileSync(file, 'utf8')

  if (src.includes(MARKER)) { log('already patched:', dir); continue }

  if (CHECK) { log('UNPATCHED:', dir); failed = 1; continue }

  if (!src.includes(ANCHOR)) {
    log('REFUSING:', dir, '— the upstream callback branch is not the shape this patch knows.')
    log('          Upstream probably rewrote it. Re-derive the patch; do not force it.')
    failed = 1
    continue
  }

  copyFileSync(file, file + '.orig')
  writeFileSync(file, src.replace(ANCHOR, REPLACEMENT))

  // Verify what landed, rather than trusting the write.
  const after = readFileSync(file, 'utf8')
  if (!after.includes(MARKER) || !after.includes('handleInbound(ctx, data, undefined)')) {
    log('VERIFY FAILED:', dir, '— restoring the original')
    copyFileSync(file + '.orig', file)
    failed = 1
    continue
  }
  log('patched:', dir)
}

process.exit(failed)
