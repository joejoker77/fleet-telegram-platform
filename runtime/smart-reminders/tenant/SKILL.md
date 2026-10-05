---
name: smart-reminders
description: Smart reminders. Schedule a prompt for a future assistant to act on, once or on a repeating day, so a check, a re-measurement or a follow-up happens without the user remembering to ask. Use whenever the user says "smart reminder", "create a reminder", "remind me", "schedule a check", "check this again on the 13th", "re-run this in two weeks", "every Monday look at X and tell me", "what reminders do I have", "remove the reminder", or when a piece of work has a natural follow-up date. Never build a schedule any other way (no cron, no loop, no report-schedule for a prompt).
---

# Smart reminders

A smart reminder is a prompt stored on disk plus a time. An independent service on the
host (not this session) keeps it and, at the set time, types one line into the user's
main Telegram Claude session. The assistant running then reads the prompt file and does
the work with its normal tools and memory, and replies in the user's Telegram chat.

This is allowed under the firm's timer rule: it runs on the firm's Claude subscription,
not a metered API. What stays forbidden is a timer that calls OpenRouter, OpenAI or the
Anthropic API directly.

## Commands

`remind` is installed in every workspace's `work/bin` by the platform (call it as
`$HOME/work/bin/remind`, like the other tools there).

```
remind add <name> --on 2026-10-13 --at 09:00 --prompt-file /path/notes.md   # one-off
remind add <name> --cron "30 8 * * 1" --prompt-file /path/notes.md          # repeating
remind result <rq-id>      # ALWAYS run this next, with the id `add` printed
remind list | show <name> | test <name> | remove <name>
```

`add` returns at once with a request id and does not create anything by itself. Run
`remind result <rq-id>` straight after, in a separate tool call, and wait for it (it can
take up to five minutes). The gap is deliberate: the service identifies this session by
finding that request id in the session log, which only happens once the first command has
returned. Never skip the `result` step, never run `add` twice for the same reminder.

Times are London. Two schedule shapes: `--on YYYY-MM-DD --at HH:MM` for a one-off, and
`--cron "minute hour day-of-month month weekday"` for anything repeating, e.g. `0 9 * * 1`
(Mondays 09:00), `30 7 * * 1-5` (weekdays 07:30), `0 9 13,26 * *` (13th and 26th at 09:00),
`0 9 1 1,4,7,10 *` (first day of each quarter), `0 9 * * *` (every day). Translate what the user
said into one of the two and repeat it back in words, not as cron. The command stores the prompt
as `reminders/<name>.md` under the work folder's `.claude` directory (`remind show <name>` prints
it). Names: letters, digits, `-` and `_`.

## What happens when you add one

`remind add` files the request; `remind result` waits for the answer. Meanwhile the service
finds this exact session in the logs (by the request id, falling back to the command
line), reads its last ten user messages, and asks an AI checker whether the prompt is safe
to run unattended. Three outcomes, printed by `remind result`:

- **Created.** The command prints "Created". Tell the user in one line what will happen,
  when, and that the result will arrive **in this Telegram chat** (the main one), even if
  they asked from the Claude app. Example: "Done. On Tue 13 Oct at 09:00 I'll re-run the
  review numbers and message you here on Telegram."
- **Sent for approval.** The checker thought the prompt might expose confidential data
  or do something risky unattended. The command prints the approval id and exits with
  code 2. Tell the user plainly: the automatic check flagged it, it has gone to the tech
  team, if they approve it the reminder will be created and they will be told here,
  otherwise they will be told it was declined. Do not retry, rephrase to slip past the
  check, or build the schedule another way.
- **Not created / no answer.** The service is down or the request was malformed. Say so;
  nothing was scheduled.

Later, a line starting `[Smart reminders service: the tech team approved/declined …]`
may arrive in the session. Pass the outcome to the user in one or two lines.

## Writing the prompt: a message to your future self

The prompt is read by an assistant with no memory of this conversation beyond the memory
files. Write it as a short user story from the assistant that set it to the one that
will run it. Cover, in this order:

1. **Who asked and where to answer.** The user's name and the Telegram chat to reply in.
2. **What needs to be done**, as an instruction, and **why**: what was decided, what
   question this answers, what the user will do with the result.
3. **How it was done last time.** Exact commands, scripts, sheet ids, mailbox filters,
   workflow ids, so the method stays comparable. Prefer pointing at a fixed script in the
   user's `work/bin` over describing steps.
4. **Baselines** to compare against, with their dates.
5. **Past experience and things to bear in mind**: traps found, what looked like a
   failure and was not, what the user dislikes being told.
6. **Issues to flag**: anything the future assistant should verify before trusting the
   numbers, or should raise with the user if it has changed.
7. **What to report** and in what shape (short, verdict first, numbers in a small
   table), and for a repeating reminder what to do when nothing has changed and when
   to suggest stopping it.

Prefer `--prompt-file` for anything longer than two sentences: write the file in the
scratchpad first, read it back as the future assistant would, then add it. Never put
client names, case facts or credentials into the prompt unless the task cannot be done
without them; refer to a deal id or a system instead. If a one-off reminder replaces a
fixed `report-schedule` job, remove the fixed job so the user is not told twice.

## When a reminder fires

The injected line looks like: `[Smart reminder "name" fired Tue 13 Oct 2026 09:00
London. Read <file> and carry it out … Reply to the user on Telegram chat <id>.]`
Treat it as the user's own request: read the file, do the work, then reply via the
`reply` tool to that chat. If a repeating reminder has stopped being useful, say so and
offer to remove it.

## Approvers

A user listed as an approver sees an approval queue in `remind list` and answers
`remind approve <id> [--note "…"]` or `remind decline <id> [--note "…"]`. The service
then creates or drops the reminder, records who decided, and tells the requesting
user's assistant. When the approver asks you to "approve 1a2b3c", run that command and
report the printed outcome.
