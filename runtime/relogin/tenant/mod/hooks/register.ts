/**
 * relogin — the one bridge the helper cannot build for itself.
 *
 * `~/work/bin/relogin` does the whole sign-in: it drives `claude auth login` in a tmux
 * session, sends the link to the person's Telegram chat, and types back the code they
 * paste. What it cannot do is HEAR that code in the one state this is all for.
 *
 * There are two of those states and they need different things:
 *
 *   * the session came up with no valid login at all. No channel, so no poller, so the
 *     single getUpdates slot is free and `relogin watch` takes it itself. This module
 *     starts the flow and that watcher at `session.start`.
 *   * the login lapsed under a session that was already running. The poller is still
 *     up — it was started when the login was good — so inbound messages still arrive,
 *     and `watch` must not run beside it (two pollers on one token is a 409 and lost
 *     messages). But the model cannot be reached, so the assistant cannot act on the
 *     code either. `prompt.submit` is the gap: it fires BEFORE the model request, so a
 *     hook here sees the person's message in a session that can no longer think.
 *
 * It also makes "relogin" a word the person can send at any time, working login or not,
 * which is the manual way in and what the 3/2/1-day warning tells them to use when a
 * link has gone stale.
 *
 * NOTHING HERE ASKS THE MODEL. Every branch ends in a child process and a dropped
 * prompt; that is the point, since the model is exactly what is unavailable.
 */
import type { Register } from 'claude-code'

/** Long enough for `claude auth login` to print its link on a loaded pod. */
const START_TIMEOUT_MS = 90_000
/** The code exchange is a round trip to Anthropic; the helper itself waits 90 s. */
const CODE_TIMEOUT_MS = 120_000

/** The whole message is the word, give or take the slash people add out of habit. */
const SUMMONS = /^\/?re-?login[.!]?$/i

/**
 * A message that arrived over a channel is NOT submitted as the person typed it.
 * Claude Code wraps it first, and `prompt.submit` sees the wrapper:
 *
 *     <channel source="plugin:telegram:telegram" chat_id="…" message_id="…" …>
 *     relogin
 *     </channel>
 *
 * Both tests below are exact — one word, or one token with no whitespace — so until
 * this was unwrapped NOTHING sent from Telegram could match either, and Telegram is
 * the only way the people this mod exists for ever reach it. It read as working
 * because it was first verified by typing into the pod's own pane, which has no
 * envelope. Found 2026-10-24: a lapsed tenant's code went to the model, which was
 * the one thing that could not answer it.
 */
const CHANNEL_ENVELOPE =
  /^<channel(?:\s+[A-Za-z_][\w-]*="[^"]*")*\s*>\s*([\s\S]*?)\s*<\/channel>$/

function unwrapChannel(text: string): string {
  return CHANNEL_ENVELOPE.exec(text)?.[1]?.trim() ?? text
}

/**
 * Could this message be a sign-in code? Deliberately loose — the helper decides, and it
 * also accepts the whole callback URL. The one job here is to let ordinary prose
 * through: a code is a single token with a digit, dash, underscore or '#' in it.
 */
function looksLikeCode(text: string): boolean {
  if (text.length < 8 || text.length > 512) return false
  if (/\s/.test(text)) return false
  return /[0-9_\-#]/.test(text) || text.startsWith('http')
}

export const register: Register = (on) => {
  on('prompt.submit', async ($, e, next) => {
    const home = await $.env.get('HOME')
    if (!home) return next(e)
    const helper = `${home}/work/bin/relogin`
    if (!(await $.fs.exists(helper))) return next(e)

    const text = unwrapChannel((e.text ?? '').trim())

    if (SUMMONS.test(text)) {
      const run = await $.process.run([helper, 'start'], { timeoutMs: START_TIMEOUT_MS })
      return {
        drop: run.exitCode === 0
          ? 'relogin: sign-in link sent to this chat'
          : `relogin: could not start a sign-in — ${run.stderr.trim() || 'see the pod log'}`,
      }
    }

    // Past this point we only care while a sign-in is actually waiting for a code, and
    // that is a file test rather than a subprocess: this hook is on every prompt the
    // person ever sends, and most sessions never have a flow in flight at all.
    const configDir = (await $.env.get('CLAUDE_CONFIG_DIR')) || `${home}/.claude`
    if (!(await $.fs.exists(`${configDir}/run/relogin.json`))) return next(e)
    if (!looksLikeCode(text)) return next(e)

    // `-` and stdin, not an argument: a sign-in code is single-use but it is a
    // credential until it is spent, and an argument is readable out of /proc.
    const run = await $.process.run([helper, 'code', '-'],
                                    { stdin: text, timeoutMs: CODE_TIMEOUT_MS })
    if (run.exitCode === 0) return { drop: 'relogin: signed in' }
    if (run.exitCode === 3) return { drop: 'relogin: that code was refused' }
    // Anything else and we were wrong about the message: it was not a code after all,
    // or the flow had already gone. Let it through to the session as the person typed
    // it, so a real question is never eaten by this hook.
    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    // Fire and forget: a session must not wait on a sign-in to come up, and this runs
    // in every session the tenant has, App ones included.
    void (async () => {
      try {
        const home = await $.env.get('HOME')
        if (!home) return
        const helper = `${home}/work/bin/relogin`
        if (!(await $.fs.exists(helper))) return

        const status = await $.process.run([helper, 'status', '--json'], { timeoutMs: 20_000 })
        if (status.exitCode !== 0) return
        const { days_left: daysLeft, flow, tmux_alive: tmuxAlive } =
          JSON.parse(status.stdout) as {
            days_left: number | null
            flow: string
            tmux_alive: boolean
          }
        // Only the dead case. The living ones are the host's 3/2/1-day warning, which
        // works even when the pod never comes up — this hook, by definition, does not.
        if (daysLeft !== null && daysLeft > 0) return
        // A flow only holds this off while it is actually running. State that says
        // `awaiting_code` with no tmux behind it is a corpse, and it does not clear
        // itself: it blocked every later restart from starting a real sign-in, which
        // is how damani-lealh sat awaiting_code from 9 to 24 October 2026 with a dead
        // login and no way back. `start` retires a flow past its TTL by itself.
        if (flow === 'awaiting_code' && tmuxAlive) return

        // The helper keeps its own ten-minute quiet period, so a pod restarting in a
        // loop sends one link, not one per restart.
        const begun = await $.process.run([helper, 'start', '--reason', 'expired'],
                                          { timeoutMs: START_TIMEOUT_MS })
        if (begun.exitCode !== 0) return

        // No valid login means no channel, which means no poller, which is the only
        // condition under which taking the getUpdates slot is safe. `watch` checks that
        // again for itself and refuses if the poller is up after all.
        const watcher = $.process.spawn({ argv: [helper, 'watch', '--timeout', '3600'] })
        for await (const piece of watcher) $.ui.log(piece.text, { to: 'debug' })
      } catch (err) {
        $.ui.log(`relogin: ${String(err)}`, { to: 'debug' })
      }
    })()
    return started
  })
}
