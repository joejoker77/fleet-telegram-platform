# Self-service sign-in (`relogin`)

Built 6 October 2026 on the claude-fleet-monaco host. Decision owner: Dmitrii Rudenko.
Rolled out as a canary of one (`vitaliy`); `--all` is deliberately behind a flag.

## The problem

A tenant's Claude session (`refreshTokenExpiresAt`) lasts about 30 days from the last
sign-in and is **not** extended by use. When it lapses the pod keeps running and the bot
keeps looking alive, but every model call fails: the person writes and nothing comes back.
Nobody is told. Only that person can fix it, and the fix — signing in — has until now
required a terminal and an administrator walking them through it. On 17 September 2026 six
of thirty-two tenants were past expiry; one had written to her bot that morning and been
met with silence.

A lapsed sign-in also freezes that person's Claude Code version: `cc-cli-update.sh` skips a
tenant whose refresh token is in the past ("others cannot come back anyway"), which is why
the two dead pods were on 2.1.280 while the fleet was on 2.1.290.

## What this does

The whole sign-in happens in the person's own Telegram chat.

1. They get a message with a **Sign in to Claude** button — at three days, two days and one
   day before expiry, once a day after it has lapsed, or whenever they send the word
   `relogin`.
2. They tap it, approve with their Claude account, and the page gives them a code.
3. They send the code back as an ordinary message.
4. They get "Signed in. You are good until 29 October 2026."

No browser on the server, no administrator, no terminal. The model is not involved at any
point, which is what makes it work in the one state it is for.

## Pieces

| Piece | Where | Notes |
|---|---|---|
| Helper | canonical `/opt/relogin/tenant/relogin`, installed as `~/work/bin/relogin` | Python 3, stdlib only, runs as the tenant inside their pod. Does the whole flow. |
| Mod | canonical `/opt/relogin/tenant/mod/`, installed as `~/work/.claude/skills/relogin/` | A plugin of function hooks. Catches the pasted code in a session whose model cannot be reached. Also a `SKILL.md` for the assistant. |
| Host trigger | `/usr/local/sbin/relogin-trigger` (repo `runtime/relogin/relogin-trigger`) | `podman exec`s the helper as the tenant. The timer and any manual test both go through it. |
| Rollout | `/opt/relogin/rollout.py` | Idempotent; names tenants, `--all` behind a flag, `--status` lists who has it. |
| Expiry timer | `/usr/local/sbin/login-expiry-notify` + `login-expiry-notify.timer` | Daily 07:30 UTC. Now walks the 3/2/1 ladder for enrolled tenants as well as reporting to the admin. |
| Flow state | `~/.claude/run/relogin.json` in the tenant's home | Survives a pod restart, so a half-finished sign-in is not lost. |
| Ladder state | `/var/lib/fleet/login-expiry-personal.json` | Which rung each person was last told about. Delete a name to let a rung fire again. |

## How the sign-in is actually driven

`claude auth login` is interactive: it prints an authorisation URL and waits on
"Paste code here if prompted >". There is no flag that takes the code on the command line,
and a mod's `$.process.spawn` can only write stdin once and close it — so the process has
to be held open by something that can type into it later. That something is **tmux**, which
is already in the pod, already supervises the main session, and is already driven this way
by the entrypoint (which answers the "Press Enter to continue" modal with `send-keys`). The
sign-in runs in its own tmux session, `relogin`, on the tenant's own socket.

The URL is read with `capture-pane -J`. The `-J` is not optional: the link is about 470
characters, tmux wraps it, and without rejoining the lines you send the person a link in
pieces.

**Success is read from the credentials file, not from the screen.** The wording of the
success line has changed between releases and scraping it is how a working sign-in gets
reported as a failure. `relogin code` records `refreshTokenExpiresAt` before typing the
code and waits for it to move forward. The pane is read only for the "Invalid code" line,
which means ask again rather than keep waiting.

## Why there is a mod as well as a helper

The helper can do everything except *hear* the code, and the chat behaves differently on
each side of expiry:

- **Login still valid** (the 3/2/1 warning, or a manual run). The poller is up, the message
  reaches the session, and the assistant runs `relogin code` — the `SKILL.md` tells it how.
- **Login already lapsed, session still running.** The poller was started while the login
  was good and is still polling, so inbound messages arrive — but the model cannot be
  reached, so the assistant cannot act. The mod's `prompt.submit` hook fires *before* the
  model request, so it sees the code in a session that can no longer think. This is the
  only reason the mod exists.
- **Login lapsed and the session restarted.** A session that starts without a valid login
  brings up no channel at all ("Channels are not currently available"), so no poller holds
  the single getUpdates slot and `relogin watch` may take it itself. The mod starts that
  watcher at `session.start`; `watch` re-checks `bot.pid` and refuses if the poller is up
  after all, because two pollers on one token lose each other's messages (409).

## Operating it

```
/opt/relogin/rollout.py --status              who is enrolled
/opt/relogin/rollout.py <tenant>              enrol one (or update their copy)
relogin-trigger <tenant>                      send them a link now
relogin-trigger <tenant> --status             what is in flight
relogin-trigger <tenant> --cancel             drop a stale flow
relogin-trigger --all-expiring --days 3       what the timer would do
login-expiry-notify --dry-run                 the whole picture, sending nothing
```

Inside a pod, as the tenant: `~/work/bin/relogin status | start | cancel`, and
`printf %s '<code>' | ~/work/bin/relogin code -` — on standard input, never as an
argument, because a sign-in code is single-use but is a credential until it is spent and
an argument is readable out of `/proc` by anything on the host.

## Limits, stated plainly

- **The pod must be running.** A sign-in has to run beside the credentials it renews, so a
  stopped container has to be started first. That was always an administrator's job.
- **The mod's hooks are read at session start.** Installing it does not arm it until the
  next restart (`graceful-restart-pod-bot <tenant>`). The helper works immediately.
- **One sign-in at a time per person.** A live flow is re-used rather than restarted: the
  page the person may already have open is bound to that flow's PKCE challenge, and
  starting a new one would invalidate it. `--force` overrides.
- **A ten-minute quiet period** between sends, because a pod whose login has lapsed
  restarts every few minutes and `session.start` runs each time. Without it the person's
  phone buzzes all night with the same link.
- **Not yet in the image.** For a full rollout the `expired` branch belongs in the pod
  entrypoint's supervise loop, so it runs even when no session starts at all. While the
  canary is one person, the host timer covers that case.
- **Not yet in provisioning.** `add-user.sh` does not install this; `rollout.py <new-user>`
  does it in one line. Fold it in when the canary is over.
