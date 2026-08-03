#!/usr/bin/env node
// telegram-progress-sidecar — in-chat "what Claude is doing now" progress,
// IDENTICAL to the fleet's hand-patched telegram plugin, but as a NO-PATCH
// sidecar process (the product bakes the CLEAN official plugin, which has no
// progress feature). Launched by the pod entrypoint alongside the claude tmux
// session; reaped on entrypoint exit.
//
// Mechanism (ported verbatim from the patched server.ts FSM, patches 21-36):
//   • 10 Hz `tmux capture-pane` sampler over the live Claude TUI → ring buffer.
//   • 1 Hz FSM: "active" iff the spinner glyph rotated OR the "Xm Ys" time-
//     counter advanced across the 1 s window (a bit-identical spinner line is
//     stale scrollback from a finished turn).
//   • The status text is CLAUDE'S OWN activity gerund pulled from the spinner
//     line ("Running… (2m)"), seconds STRIPPED to minute resolution so edits
//     don't fire every second and trip Telegram flood-bans. Never raw args.
//   • Leading icon = the SAME animated Telegram Premium custom emoji the fleet
//     uses (tg-emoji id 5377731669467884550, parse_mode=HTML; non-Premium
//     clients fall back to the 🟠 glyph) — the blinking red dot.
//   • Tool-line fallback (`● Tool(`) → friendly labelForTool map.
//   • Hysteresis: placeholder appears after ACTIVE_CREATE_TICKS active ticks,
//     retires after IDLE_RETIRE_TICKS idle ticks. Idle but no fresh phrase →
//     rotate a FUN_STATUS every STATUS_ROTATE_MS so it never looks frozen.
//   • Blocked TUI (permission prompt / unrecoverable error) → one-shot ⚠️ line
//     after BLOCKED_WARNING_DELAY_MS of continuous blocked state.
//
// Per-tenant state is read from $TELEGRAM_STATE_DIR (bot token in .env, current
// chat/thread in last_chat.json — written by the telegram-track-chat.sh hook on
// every inbound). Telegram API calls go through `curl` so they ride the pod's
// HTTPS_PROXY exactly like the other hooks (api.telegram.org is pass-through).
//
// Opt out with DISABLE_PROGRESS_SIDECAR=1.

import { spawn } from 'node:child_process'
import { readFileSync, writeFileSync, appendFileSync, unlinkSync, statSync } from 'node:fs'

const STATE_DIR = process.env.TELEGRAM_STATE_DIR
const SESSION = process.env.PROGRESS_TMUX_SESSION || 'claude'
if (!STATE_DIR) {
  process.stderr.write('progress-sidecar: no TELEGRAM_STATE_DIR, exiting\n')
  process.exit(0)
}
const LAST_CHAT_FILE = `${STATE_DIR}/last_chat.json`
const ENV_FILE = `${STATE_DIR}/.env`
const PERSIST_FILE = `${STATE_DIR}/progress_placeholder.json`
const LOG_FILE = `${STATE_DIR}/logs/progress-sidecar.log`

// Self-logging so the process keeps a record even when launched detached
// (the entrypoint also redirects stdout/err here; both append harmlessly).
function logln(msg) {
  const line = `[${new Date().toISOString()}] ${msg}\n`
  try { appendFileSync(LOG_FILE, line) } catch {}
  try { process.stderr.write(line) } catch {}
}

// ─── tunables (ported) ───────────────────────────────────────────────────
const STATUS_ROTATE_MS = 4000
const IDLE_RETIRE_TICKS = 3
const ACTIVE_CREATE_TICKS = 3
const PROBE_INTERVAL_MS = 100
const PROBE_WINDOW = 10
const STATUS_TICK_MS = 1000
const TYPING_PULSE_MS = 4000
const BLOCKED_WARNING_DELAY_MS = 30 * 1000
const SUPPORT_HANDLE = process.env.SUPPORT_HANDLE ?? '@ai_assistant_gg_support_bot'

// ─── rendering (verbatim from the patched plugin, Patch 27) ──────────────
const SPINNER_EMOJI_ID = '5377731669467884550'
const SPINNER_EMOJI_FALLBACK = '🟠'
const SPINNER_EMOJI_HTML = `<tg-emoji emoji-id="${SPINNER_EMOJI_ID}">${SPINNER_EMOJI_FALLBACK}</tg-emoji>`
function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
function activeStatus(phrase) {
  return `${SPINNER_EMOJI_HTML} ${escapeHtml(phrase)}`
}
const TOOL_LABELS = {
  Bash: '🛠️ Running a command',
  Read: '📄 Reading a file',
  Write: '📝 Writing a file',
  Edit: '✏️ Editing code',
  Grep: '🔎 Searching the text',
  Glob: '📂 Looking for files',
  Find: '📂 Looking for files',
  WebFetch: '🌐 Fetching a page',
  WebSearch: '🌐 Searching the web',
  Task: '🤖 Delegating to a sub-agent',
  Agent: '🤖 Delegating to a sub-agent',
  TodoWrite: '📋 Updating the plan',
  NotebookEdit: '📓 Editing a notebook',
}
function labelForTool(name) {
  return TOOL_LABELS[name] ?? `🛠️ Working on ${name}…`
}
const FUN_STATUSES = [
  'Thinking…',
  'Digging through files…',
  'Weighing the options…',
  'Scratching my head…',
  'Skimming the logs…',
  'Mulling it over…',
  'Putting the pieces together…',
  'Sorting it out…',
  'Reasoning it through…',
  'Cranking the gears…',
  'Picking the right words…',
  'Rummaging through memory…',
  'Checking my notes…',
  'Running grep on my brain…',
  'Reading the last paragraph…',
  'Thinking a bit slower than usual…',
  'Almost there…',
]
function pickStatus(prev) {
  if (FUN_STATUSES.length === 1) return FUN_STATUSES[0]
  let pick = FUN_STATUSES[Math.floor(Math.random() * FUN_STATUSES.length)]
  let guard = 0
  while (pick === prev && guard++ < 5) {
    pick = FUN_STATUSES[Math.floor(Math.random() * FUN_STATUSES.length)]
  }
  return pick
}

// ─── TUI parsing (verbatim) ──────────────────────────────────────────────
const SPINNER_LINE_RE = /(?:^|\n)\s*[*✢✺✷✶✱✸✻✽]\s+([^…\r\n]+?)…\s*(?:\(([^)]+)\))?/g
const TOOL_LINE_RE = /●\s+([A-Z]\w{1,30})\(/g
const SPINNER_TIME_RE = /\((\d+(?:m\s*\d+)?s)\b/

function detectBlockedState(out) {
  const tail = out.slice(-1500)
  if (/❯\s+\d\.\s/.test(tail)) return 'prompt'
  if (/\b1\.\s+Yes\b[\s\S]{0,300}\b2\.\s+/i.test(tail)) return 'prompt'
  const errorPatterns = [
    /credit balance is too low/i,
    /insufficient credit/i,
    /authentication (failed|error|token (has )?expired)/i,
    /invalid api key/i,
    /rate.?limit(ed| exceeded| reached)/i,
    /usage limit (reached|exceeded)/i,
    /approaching usage limit/i,
    /\bapi error:\s*[45]\d\d\b/i,
    /5-hour limit/i,
  ]
  if (errorPatterns.some((re) => re.test(tail))) return 'error'
  return null
}

// ─── 10 Hz capture sampler → ring buffer ─────────────────────────────────
const probeBuffer = []
let probeRunning = false

function captureFrame() {
  return new Promise((resolve) => {
    let resolved = false
    const finish = (v) => {
      if (resolved) return
      resolved = true
      resolve(v)
    }
    try {
      const child = spawn('tmux', ['capture-pane', '-t', SESSION, '-p', '-S', '-60'], {
        stdio: ['ignore', 'pipe', 'ignore'],
      })
      let out = ''
      const t = setTimeout(() => {
        try { child.kill() } catch {}
        finish({ spinnerLine: null, toolLine: null, blocked: null })
      }, 800)
      child.stdout.on('data', (d) => { out += d.toString() })
      child.on('close', () => {
        clearTimeout(t)
        const blocked = detectBlockedState(out)
        const sMatches = [...out.matchAll(SPINNER_LINE_RE)]
        const spinnerLine = sMatches.length > 0 ? sMatches[sMatches.length - 1][0] : null
        const tMatches = [...out.matchAll(TOOL_LINE_RE)]
        const toolLine = tMatches.length > 0 ? tMatches[tMatches.length - 1][0] : null
        finish({ spinnerLine, toolLine, blocked })
      })
      child.on('error', () => { clearTimeout(t); finish({ spinnerLine: null, toolLine: null, blocked: null }) })
    } catch {
      finish({ spinnerLine: null, toolLine: null, blocked: null })
    }
  })
}

async function probeTick() {
  if (probeRunning) return
  probeRunning = true
  try {
    const f = await captureFrame()
    probeBuffer.push(f)
    while (probeBuffer.length > PROBE_WINDOW) probeBuffer.shift()
  } finally {
    probeRunning = false
  }
}
setInterval(() => { void probeTick() }, PROBE_INTERVAL_MS)

function pollClaudeActivity() {
  const frames = probeBuffer.slice()
  if (frames.length === 0) return { status: null, active: false, blocked: null }
  const lastFrame = frames[frames.length - 1]
  const blocked = lastFrame.blocked ?? frames.find((f) => f.blocked != null)?.blocked ?? null
  const spinnerLines = frames.map((f) => f.spinnerLine).filter((l) => l != null)
  const distinctSpinners = new Set(spinnerLines)
  const metas = spinnerLines
    .map((s) => s.match(SPINNER_TIME_RE)?.[1] ?? null)
    .filter((m) => m != null)
  const distinctMetas = new Set(metas)
  const active =
    spinnerLines.length >= 2 &&
    (distinctSpinners.size >= 2 || distinctMetas.size >= 2)
  let status = null
  if (lastFrame.spinnerLine != null) {
    const m = lastFrame.spinnerLine.match(/[*✢✺✷✶✱✸✻✽]\s+([^…\r\n]+?)…\s*(?:\(([^)]+)\))?/)
    if (m) {
      const word = m[1]
      let meta = m[2] ? m[2].split('·')[0].trim() : ''
      if (meta) meta = meta.replace(/\s*\d+s\b/, '').trim()
      status = meta ? `${word}… (${meta})` : `${word}…`
    }
  }
  if (status == null && lastFrame.toolLine != null) {
    const m = lastFrame.toolLine.match(/●\s+([A-Z]\w{1,30})\(/)
    if (m) status = `${labelForTool(m[1])}…`
  }
  return { status, active, blocked }
}

// ─── per-tenant config (token + current chat/thread) ─────────────────────
let cachedToken = null
function getToken() {
  if (cachedToken) return cachedToken
  try {
    const env = readFileSync(ENV_FILE, 'utf8')
    const line = env.split('\n').find((l) => l.startsWith('TELEGRAM_BOT_TOKEN='))
    if (line) cachedToken = line.slice('TELEGRAM_BOT_TOKEN='.length).replace(/^['"]|['"]$/g, '').trim()
  } catch {}
  return cachedToken
}

// Only become active for a chat the user touched AFTER this process started —
// mirrors the patched plugin's lastActiveChat, which is set in-process on a
// real inbound (not by stale boot state). Prevents a spinner during the
// silent session-restore the entrypoint pastes at boot.
const T0_MS = Date.now()
function currentTarget() {
  try {
    const st = statSync(LAST_CHAT_FILE)
    if (st.mtimeMs <= T0_MS) return null
    const j = JSON.parse(readFileSync(LAST_CHAT_FILE, 'utf8'))
    const chat_id = String(j.chat_id ?? '')
    if (!chat_id) return null
    const t = j.message_thread_id
    const message_thread_id =
      t != null && String(t) !== '' && !Number.isNaN(Number(t)) ? Number(t) : undefined
    return { chat_id, message_thread_id }
  } catch {
    return null
  }
}

// ─── Telegram API via curl (rides HTTPS_PROXY; api.telegram.org pass-through) ─
// Flood guard: Telegram answers a too-busy chat with 429 + retry_after (can be
// minutes—hours). Honour it — suppress ALL sends until it passes so the sidecar
// never piles rejected calls onto a flood-wait (which is what got the chat
// limited in the first place). A progress placeholder is disposable; skipping
// it during a back-off is strictly correct.
let suppressUntil = 0
function tg(method, params) {
  return new Promise((resolve) => {
    if (Date.now() < suppressUntil) { resolve({ ok: false, description: 'suppressed (429 backoff)' }); return }
    const token = getToken()
    if (!token) { resolve({ ok: false, description: 'no token' }); return }
    const body = {}
    for (const [k, v] of Object.entries(params)) if (v !== undefined) body[k] = v
    const url = `https://api.telegram.org/bot${token}/${method}`
    const child = spawn(
      'curl',
      ['-s', '-m', '10', '-X', 'POST', url, '-H', 'Content-Type: application/json', '-d', JSON.stringify(body)],
      { stdio: ['ignore', 'pipe', 'ignore'] },
    )
    let out = ''
    const to = setTimeout(() => { try { child.kill() } catch {}; resolve({ ok: false, description: 'timeout' }) }, 12000)
    child.stdout.on('data', (d) => { out += d.toString() })
    child.on('close', () => {
      clearTimeout(to)
      try {
        const j = JSON.parse(out)
        if (j.error_code === 429) {
          const ra = Number(j.parameters?.retry_after ?? 5)
          suppressUntil = Date.now() + (ra + 1) * 1000
          logln(`429 flood-wait ${ra}s on ${method} — suppressing sends until it clears`)
        }
        resolve({ ok: !!j.ok, result: j.result, error_code: j.error_code, description: j.description })
      } catch { resolve({ ok: false, description: 'parse:' + out.slice(0, 120) }) }
    })
    child.on('error', () => { clearTimeout(to); resolve({ ok: false, description: 'spawn-error' }) })
  })
}

// ─── placeholder persistence (orphan recovery across sidecar restart) ─────
function persist(p) {
  try {
    writeFileSync(
      PERSIST_FILE,
      JSON.stringify({ chat_id: p.chat_id, message_id: p.message_id, message_thread_id: p.message_thread_id }),
    )
  } catch {}
}
function clearPersist() {
  try { unlinkSync(PERSIST_FILE) } catch {}
}
async function reapOrphan() {
  let prev
  try { prev = JSON.parse(readFileSync(PERSIST_FILE, 'utf8')) } catch { return }
  clearPersist()
  if (prev && prev.chat_id && prev.message_id) {
    await tg('deleteMessage', { chat_id: prev.chat_id, message_id: prev.message_id })
  }
}

// ─── 1 Hz FSM (ported) ───────────────────────────────────────────────────
let placeholder = null
let pendingActiveTicks = 0
let fsmRunning = false

function newState(chat_id, message_thread_id, message_id, initial_status) {
  return {
    message_id,
    chat_id,
    message_thread_id,
    last_status: initial_status,
    last_edit_at: Date.now(),
    blocked_notified: false,
    first_blocked_at: null,
    idle_ticks: 0,
  }
}

async function fsmTick() {
  if (fsmRunning) return
  const target = currentTarget()
  if (!target) return
  fsmRunning = true
  try {
    const { chat_id, message_thread_id } = target
    // User moved to another chat/topic → retire the stale placeholder there.
    if (placeholder && (placeholder.chat_id !== chat_id || placeholder.message_thread_id !== message_thread_id)) {
      const old = placeholder
      placeholder = null
      clearPersist()
      pendingActiveTicks = 0
      void tg('deleteMessage', { chat_id: old.chat_id, message_id: old.message_id })
    }

    const snap = pollClaudeActivity()
    let state = placeholder

    // Blocked TUI → one-shot warning after sustained blocked state.
    if (snap.blocked && state && !state.blocked_notified) {
      if (state.first_blocked_at == null) state.first_blocked_at = Date.now()
      if (Date.now() - state.first_blocked_at >= BLOCKED_WARNING_DELAY_MS) {
        const line = snap.blocked === 'prompt'
          ? `⚠️ Stuck on a choice in the terminal I can't reach. Please ping ${SUPPORT_HANDLE}.`
          : `⚠️ Hit an error I can't recover from. Please ping ${SUPPORT_HANDLE}.`
        state.blocked_notified = true
        state.last_status = line
        state.last_edit_at = Date.now()
        await tg('editMessageText', { chat_id, message_id: state.message_id, text: line })
        return
      }
    }
    if (!snap.blocked && state) {
      state.blocked_notified = false
      state.first_blocked_at = null
    }

    if (snap.active) {
      if (!state) {
        pendingActiveTicks += 1
        if (pendingActiveTicks < ACTIVE_CREATE_TICKS) return
        const initial = snap.status ?? pickStatus()
        const rendered = activeStatus(initial)
        const r = await tg('sendMessage', { chat_id, text: rendered, parse_mode: 'HTML', message_thread_id })
        if (r.ok && r.result) {
          placeholder = newState(chat_id, message_thread_id, r.result.message_id, rendered)
          persist(placeholder)
          pendingActiveTicks = 0
        }
      } else {
        state.idle_ticks = 0
        pendingActiveTicks = 0
        const now = Date.now()
        let next = null
        if (snap.status != null) {
          const candidate = activeStatus(snap.status)
          if (candidate !== state.last_status) next = candidate
        }
        if (next == null && now - state.last_edit_at >= STATUS_ROTATE_MS) {
          const candidate = activeStatus(pickStatus())
          if (candidate !== state.last_status) next = candidate
        }
        if (next == null) return
        const r = await tg('editMessageText', { chat_id, message_id: state.message_id, text: next, parse_mode: 'HTML' })
        if (r.ok) {
          state.last_status = next
          state.last_edit_at = now
        } else {
          const gone =
            r.error_code === 400 &&
            /not found|can'?t be edited|MESSAGE_ID_INVALID|message to edit/i.test(r.description || '')
          if (gone) { placeholder = null; clearPersist() }
        }
      }
    } else {
      pendingActiveTicks = 0
      if (!state) return
      state.idle_ticks += 1
      if (state.idle_ticks >= IDLE_RETIRE_TICKS) {
        const msgId = state.message_id
        placeholder = null
        clearPersist()
        const r = await tg('deleteMessage', { chat_id, message_id: msgId })
        if (!r.ok) await tg('editMessageText', { chat_id, message_id: msgId, text: '✓' })
      }
    }
  } finally {
    fsmRunning = false
  }
}

// One typing pulse while a placeholder is alive (Telegram clears it ~5 s).
setInterval(() => {
  if (!placeholder) return
  void tg('sendChatAction', {
    chat_id: placeholder.chat_id,
    action: 'typing',
    message_thread_id: placeholder.message_thread_id,
  })
}, TYPING_PULSE_MS)

process.on('uncaughtException', (e) => logln(`uncaught: ${e?.stack || e}`))
process.on('unhandledRejection', (e) => logln(`unhandled: ${e}`))

await reapOrphan()
setInterval(() => { void fsmTick() }, STATUS_TICK_MS)
logln(`up (session=${SESSION}, token=${getToken() ? 'present' : 'MISSING'})`)
