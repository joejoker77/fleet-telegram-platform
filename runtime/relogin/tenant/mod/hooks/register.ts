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

    const text = (e.text ?? '').trim()

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

    const run = await $.process.run([helper, 'code', text], { timeoutMs: CODE_TIMEOUT_MS })
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
        const { days_left: daysLeft, flow } = JSON.parse(status.stdout) as {
          days_left: number | null
          flow: string
        }
        // Only the dead case. The living ones are the host's 3/2/1-day warning, which
        // works even when the pod never comes up — this hook, by definition, does not.
        if (daysLeft !== null && daysLeft > 0) return
        if (flow === 'awaiting_code') return

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
