# Working on matters at Monaco Solicitors

Tools installed in `~/work/bin`. They are not on PATH, so call them by path.
All of the matter tools read only. None writes to Pipedrive and none sends anything.

| Command | What it answers |
|---|---|
| `~/work/bin/check-my-access` | which of my systems are actually connected, and what to do about the gaps |
| `~/work/bin/my-deadlines` | which of my matters have a limitation date that has passed or is close |
| `~/work/bin/my-matters` | which of my matters have gone quiet with nothing diarised |
| `~/work/bin/deal-brief <deal-id>` | everything on one matter, on one screen |
| `~/work/bin/pd-attachments list\|get\|send <id>` | documents attached to a matter's emails |
| `~/work/bin/report-schedule` | reports that arrive in Telegram on a timer |
| `~/work/bin/tg-file <path> "caption"` | send the user a real file in Telegram |

Each takes `--help`. `my-deadlines` and `my-matters` take `--days` / `--quiet-days`
and `--json`. When the user asks for something one of these already answers, run it
rather than writing fresh Pipedrive queries: the tools already know the field keys,
the pagination and the traps below.

## Skills

Four are installed in `~/work/.claude/skills`: `matter-brief`, `chase-draft`,
`week-ahead`, `client-update`. Use them when the request matches. Write new ones
there when the user asks you to remember how they like a job done. Never write to
`~/.claude/skills`, which is a managed directory and gets reverted.

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
