---
name: relogin
description: Renew this person's own Claude sign-in from their Telegram chat. Use when they ask to "log in again", "sign in", "my session expired", when a sign-in warning has gone out and they ask what to do, or when they send back a code after tapping a sign-in link.
---

# Renewing the person's Claude sign-in

Their Claude session (`refreshTokenExpiresAt`) lasts about 30 days from the last
sign-in and is **not** extended by use. When it lapses their bot stops answering
with no warning to anyone, and only they can fix it.

`~/work/bin/relogin` does the whole thing in this chat. No browser on the server,
no administrator, no terminal for them to open.

```
~/work/bin/relogin status            what, if anything, is in flight
~/work/bin/relogin start             send them a sign-in link with a button
~/work/bin/relogin code <CODE>       hand back the code they pasted
~/work/bin/relogin cancel            drop a flow that has gone stale
```

## How to use it

- **They ask to sign in, or a warning went out.** Run `relogin start`. It sends them
  a message with a *Sign in to Claude* button and tells them to send the code back
  here. Say that you have sent it; do not paste the link into your own reply as well.
- **They send back a code** (a single long token, often with a `#` in it, or the whole
  callback URL). Run `relogin code '<what they sent>'`. On success they get a
  confirmation with the new expiry date — you need add nothing. Exit code 3 means the
  code was refused and they have already been told to send it again.
- **The link has gone stale** (more than about fifteen minutes old). `relogin start`
  again; it begins a fresh sign-in on its own.

## Things worth knowing

- The code is not a secret worth guarding from them, but it is single-use: if they
  paste one twice the second attempt is refused, and that is not a fault.
- Nothing here asks the model, deliberately: the same commands work in a session whose
  login has already lapsed, which is the state the whole thing exists for.
- A lapsed sign-in also freezes that person's Claude Code version — the fleet updater
  skips a tenant who cannot come back — so renewing it fixes two things at once.
