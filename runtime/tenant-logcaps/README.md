# tenant-logcaps — a ceiling on Claude's own logs in tenant homes

On 2026-10-27 the firm host was at 89% of its 96 GB root disk. `/home` was
66 GB of it, and roughly half of that was not anybody's work:

| Under `/home/<user>/.claude` | Fleet-wide | Rotation before this |
|---|---|---|
| `projects/**/*.jsonl` — raw session transcripts | 23.9 GB | none |
| `channels/*/logs/` — tmux pane dumps + sidecar logs | 6.6 GB | pane log only, `rotate 7 size 50M` |
| `channels/*/inbox/` — files sent to the bot on Telegram | small, unbounded | none |

Measured growth was ~9.5 GB a week, about 40 GB a month. Moving `/home` to a
bigger volume buys time; it does not stop the growth.

## Why deleting a transcript is safe

Nothing here deletes history. The pipeline that already exists is:

```
~/.claude/projects/**/<uuid>.jsonl          raw, ~5 MB a session
        │  transcript-exporter.py
        ▼
~/.claude/channels/<ch>/logs/sessions/session_<utc>_<uuid8>.txt   compact, ~15x smaller
        │  session_indexer.py
        ▼
~/.claude/channels/<ch>/logs/.index/session_index.db   FTS5 — what `session-search` reads
```

`session-search` never opens a `.jsonl`. So an exported transcript can go
without losing anything searchable. The one thing that is lost is resuming a
session older than the cutoff.

The sweeper therefore deletes a `.jsonl` **only** when the exporter's own
`.export_state.json` names it, records the same size and mtime it has on disk
now, and the exported `.txt` is still there. A transcript it cannot prove was
exported is kept and counted as `not-yet-exported` in the report.

## What it never touches

* `logs/claude-pane.log` — the live dump; logrotate owns that one
* `logs/.index/` — the search database
* `logs/sessions/*.txt` — the exported transcripts, i.e. the thing we keep
* `logs/session_current.txt`
* everything at the channel root — `.env`, `access.json`, `bot.pid`,
  `relogin-token`, `last_chat.json`. That is the channel's identity, not a log.

## Files

```
tenant-logcaps.py        the sweeper; dry run unless given --apply
tenant-logcaps.service   oneshot, runs it with --apply
tenant-logcaps.timer     daily 03:40 UTC, Persistent=true
claude-pane.logrotate    replaces /etc/logrotate.d/claude-pane:
                         rotate 7 size 50M delaycompress -> rotate 3 size 20M,
                         plus a stanza for the sidecar logs, which had none
install.sh               idempotent install / --rollback
```

## Use

```bash
sudo ./install.sh                       # sweeper + tighter rotation + daily timer
/opt/tenant-logcaps/tenant-logcaps.py   # dry run: what would go, per tenant
sudo /opt/tenant-logcaps/tenant-logcaps.py --apply
sudo ./install.sh --rollback            # one command back to where we were
```

Defaults: transcripts older than 30 days, channel logs and inbox files older
than 14 days. Override per run with `--projects-days` / `--channels-days`, or
for good by editing the constants at the top of the script.

Each `--apply` run writes a JSON report to `/var/log/tenant-logcaps/`, so what
a sweep removed is answerable after the fact.

## Never leave a backup in /etc/logrotate.d

logrotate reads **every** file in that directory, whatever it is called. A copy
of a config kept beside the original is therefore read as a second config, trips
`duplicate log entry`, and logrotate exits 1 — having rotated **nothing at all**,
including the other, perfectly good configs.

That is not hypothetical. `rsyslog.bak-20261020`, left there on 2026-10-20 while
fixing syslog rotation, took `logrotate.service` down with it and the host went
a week with no rotation of anything. It is a large part of why the pane dumps
reached 6.6 GB. Both strays (that one and an August `claude-pane.pre-logcaps`)
were moved to `/var/backups/logrotate-superseded/` on 2026-10-27.

So: this component keeps its backup in `/var/backups/logrotate-superseded/`, and
`install.sh` parses the whole of `/etc/logrotate.conf` after writing and warns if
anything in the directory is broken. Check `systemctl is-failed logrotate.service`
before trusting that any log on this host is being rotated.

## Steady state

Transcripts settle at roughly a month of sessions; pane dumps at ~25 MB a
tenant instead of ~400 MB. Expect `/home` to hold around 30 GB and stay there
rather than climbing 40 GB a month.
