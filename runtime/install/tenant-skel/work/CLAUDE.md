# Working on matters at Monaco Solicitors

Tools installed in `~/work/bin`. They are not on PATH, so call them by path.
Every one of them reads only, with one exception: **`sa-sign` sends.** It emails a
client and writes a note on the deal. It will not do either until a plan on disk
says `"confirmed": true`, which you set after looking at a picture of the page.
Nothing else here writes to Pipedrive or sends anything.

| Command | What it answers |
|---|---|
| `~/work/bin/check-my-access` | which of my systems are actually connected, and what to do about the gaps |
| `~/work/bin/my-deadlines` | which of my matters have a limitation date that has passed or is close |
| `~/work/bin/my-matters` | which of my matters have gone quiet with nothing diarised |
| `~/work/bin/deal-brief <deal-id>` | everything on one matter, on one screen |
| `~/work/bin/pd-attachments list\|get\|send <id>` | documents attached to a matter's emails |
| `~/work/bin/sa-sign scan\|prepare\|publish` | send a settlement agreement to a client for e-signature |
| `~/work/bin/report-schedule` | reports that arrive in Telegram on a timer |
| `~/work/bin/tg-file <path> "caption"` | send the user a real file in Telegram |

Each takes `--help`. `my-deadlines` and `my-matters` take `--days` / `--quiet-days`
and `--json`. When the user asks for something one of these already answers, run it
rather than writing fresh Pipedrive queries: the tools already know the field keys,
the pagination and the traps below.

## Skills

Installed in `~/work/.claude/skills`. Six firm ones ship to everyone —
`matter-brief`, `chase-draft`, `week-ahead`, `client-update`, `field-lookup`,
`send-for-signature` — plus `share-skill`, plus anything this user has written.
A skill is a playbook: read it and do what it says when its description matches.
Use them when the request matches, and write new ones there when the user asks you
to remember how they like a job done.

Skills written here are private to this machine until they are shared deliberately:

```
~/work/bin/share-skill list                      # what colleagues have offered
~/work/bin/share-skill publish <name> --note "one line about it"
~/work/bin/share-skill get <name>                # install a colleague's
```

Both directions take effect immediately — no approval to wait for — but a safety
scan runs first and can refuse, in which case relay the reason rather than working
around it. Never copy a skill folder between people by hand: that skips the scan
and the record of who shared what. A new or newly installed skill becomes usable on
the NEXT message, because the list is re-read between turns; nothing needs
restarting.

## Scheduled reports, and the one hard rule

`report-schedule add <name> --at 08:00 --days mon -- <command>` gets a report into
the user's Telegram on a timer. The daemon runs the command and sends the output.

**A timer may run a program. A timer may never call an AI model.** That is a firm
rule with no exceptions. So a scheduled report is a fixed query whose output goes
through unchanged. If the user asks for something that "keeps an eye on things" or
"reviews my matters every morning with AI", say no and offer the fixed report
instead. Do not build it, and do not put a Claude call in a cron job or a loop.

## Things about this firm's data that will mislead you

**"Open" does not mean live.** Around 1,967 deals sit open in the DO_NOT_USE and
Case closed stages. Any caseload count that includes them is wrong. The live
pipelines are 7 (Cases) and 28 (ATJ); the tools above already exclude the rest.

**PI means pre-instruction, not personal injury.** A deal at a `PI ...` stage, at
`Chatbot Sent`, `CCL sent` or `CCL Sent & No Reply`, is an enquiry. Not yet a client.

**Email attachments are not in the deal's Files tab.** `GET /v1/deals/<id>/files`
answers `success: true` with zero items on a deal whose emails carry attachments,
and `GET /v1/files?deal_id=` ignores its filter and returns the whole account.
Never say a document does not exist on the strength of either. Use `pd-attachments`.

**`GET /v1/activities?deal_id=` also ignores its filter.** Use the nested
`GET /v1/deals/<id>/activities`.

**`email_messages_count` counts thread events, not emails,** and reads about six
times too high. Count what `/v1/deals/<id>/mailMessages` actually returns, and page
it with `start` / `next_start`: `limit=100` truncates silently.

**A missing limitation date is a gap, not a fact.** 1,226 of 1,977 instructed
matters have no ACAS or ET1 date recorded. On a settlement agreement that is
normal. On a claim it means nobody wrote it down.

## Confidentiality

Client names, matter facts and personal data stay inside the firm's systems.
Never put them into a web search, into a personal app, or into any external model.
When something needs working out, work it out against Pipedrive directly.
