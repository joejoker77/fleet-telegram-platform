---
name: share-skill
description: Share one of the user's own skills with colleagues, or install a colleague's. Use when asked to "share this skill", "поделись скиллом", "publish my skill", "what skills do colleagues have", "какие скиллы есть у других", "get X's skill", "забери скилл", or when the user has just built something and wonders whether the team could use it.
---

# Sharing a skill with the firm

Skills a person writes are private to their own machine. Nothing copies them across, so
five people have independently built without-prejudice tooling that none of the others can
see. This is how that stops.

## The four things you can do

```
~/work/bin/share-skill list                      # what colleagues have offered, and what you have
~/work/bin/share-skill publish <name> --note "one line about it"
~/work/bin/share-skill get <name>                # install a colleague's
~/work/bin/share-skill unpublish <name> --yes    # take it back out of the catalogue
```

`publish` takes `--version 1.0.1` when re-publishing a change (the first publish defaults
to 1.0.0), and `--public` to list it for everyone rather than keeping it visible only to
the owner.

## What to tell the user, and what not to promise

- **Both directions take effect immediately** — no approval, nobody to wait for. Report
  what the command printed: a successful publish says colleagues can install it now, a
  successful install says how many files landed. If it says a version is recorded but not
  on the shared branch, that is NOT done — say so and give the reason it printed.
- **A safety scan runs first and can refuse**, either direction. Relay the reason. Never
  retry around it and never copy the folder by hand instead — that skips the scan and the
  record of who shared what.
- **A newly installed skill appears on the next message, not instantly.** The skills list
  is re-read between turns. Tell the user to send anything and it will be there; do not
  tell them to restart.
- **Names are per person.** If the user asks for "Daria's WP letter skill", run `list`
  first and use the exact name from it rather than guessing.

## Taking something back out

`unpublish` removes the catalogue entry. The user can always do it to their own; an
administrator can also do it to a colleague's, which is how something shared by mistake,
or left behind by someone who has gone, gets pulled.

Two things to say plainly when you run it, because neither is obvious:

- **It stops new installs; it does not recall the copies already taken.** Whoever
  installed it still has their own copy in their workspace. If it must actually go —
  a client name, a credential — say so and tell the user who needs telling.
- **Without `--yes` the command only describes what it would do.** Run it that way first
  when you are acting on a vague instruction, show the user the line, and then confirm.

An administrator removing a colleague's skill is recorded, with both names. Say that too.

## Judgement before publishing

Two of these are worth a word before you publish:

- A skill built around one person's writing voice or their own preferences (`paul-voice`,
  `i-have-adhd`) only makes sense on their machine. Say so instead of sharing it.
- A skill with a client name, a deal number or a matter reference baked into it should be
  generalised first — the catalogue is firm-wide.

If the user asks you to share something that fails the safety check, relay the reason the
tool prints. Do not try to work around it, and do not copy the folder into someone else's
machine by hand — that bypasses both the check and the record of who shared what.
