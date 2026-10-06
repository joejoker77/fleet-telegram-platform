#!/usr/bin/env node
// telegram-patch-watcher — re-apply our callback patch the moment Claude Code
// installs a new copy of the Telegram plugin.
//
// WHY A WATCHER AND NOT A STEP IN THE ENTRYPOINT. Claude Code re-installs the newest
// marketplace plugin by itself, and it does so 3-5 MINUTES AFTER the session starts,
// not at start: it downloads into a brand-new directory
// `~/.claude/plugins/cache/claude-plugins-official/telegram/<version>/` and repoints
// installed_plugins.json. Measured across this fleet on 2026-08-24, per-bot and
// staggered — our own restarts are what trigger it. So a patch applied before launch
// is correct for five minutes and then sits in a directory nobody reads any more.
// The event we need is the appearance of that directory.
//
// inotify-tools is not in the pod image; node is. fs.watch on the parent directory is
// the same kernel notification without the dependency. A slow poll runs underneath it
// because fs.watch is not reliable on every overlay filesystem, and a missed event
// here means a dead button, not a crash — it must not depend on one mechanism.
//
// Opt out with DISABLE_PATCH_WATCHER=1.

import { watch, existsSync, mkdirSync, appendFileSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

if (process.env.DISABLE_PATCH_WATCHER === '1') process.exit(0)

const HOME = process.env.HOME || '/root'
const CACHE = join(HOME, '.claude/plugins/cache/claude-plugins-official/telegram')
const PATCHER = join(dirname(fileURLToPath(import.meta.url)), 'telegram-callback-patch.mjs')
const LOG_DIR = process.env.TELEGRAM_STATE_DIR
  ? join(process.env.TELEGRAM_STATE_DIR, 'logs')
  : '/tmp'
const LOG = join(LOG_DIR, 'patch-watcher.log')

const DEBOUNCE_MS = 3000          // a download writes many entries; patch once it settles
const SAFETY_POLL_MS = 5 * 60_000 // backstop if fs.watch never fires on this filesystem

function log(msg) {
  const line = `${new Date().toISOString()} ${msg}\n`
  try { mkdirSync(LOG_DIR, { recursive: true }); appendFileSync(LOG, line) } catch {}
  process.stdout.write(`[patch-watcher] ${msg}\n`)
}

let running = false
let pending = null

function runPatcher(why) {
  if (running) return
  running = true
  const p = spawn(process.execPath, [PATCHER], { stdio: ['ignore', 'pipe', 'pipe'] })
  let out = ''
  p.stdout.on('data', d => { out += d })
  p.stderr.on('data', d => { out += d })
  p.on('close', code => {
    running = false
    const text = out.trim().replace(/\n/g, ' | ')
    // "already patched" is the steady state and would otherwise fill the log every
    // five minutes forever; only say something when something happened or broke.
    if (code !== 0 || !/already patched/.test(text) || /patched:/.test(text.replace(/already patched/g, ''))) {
      log(`${why} -> exit ${code}: ${text}`)
    }
  })
}

function schedule(why) {
  clearTimeout(pending)
  pending = setTimeout(() => runPatcher(why), DEBOUNCE_MS)
}

function arm() {
  if (!existsSync(CACHE)) {
    setTimeout(arm, 10_000)
    return
  }
  try {
    watch(CACHE, (event, name) => schedule(`fs.watch ${event} ${name ?? ''}`.trim()))
    log(`watching ${CACHE}`)
  } catch (err) {
    log(`fs.watch unavailable (${err?.message ?? err}) — relying on the safety poll`)
  }
}

runPatcher('startup')
arm()
setInterval(() => runPatcher('safety poll'), SAFETY_POLL_MS)
