# disk-alert — tell the admin before the disk fills, not after

Reads `df` every 15 minutes and messages the admin on Telegram at or above a
threshold (default 80%). **No model calls** — it is a timer, and the firm rule
is that a timer may run a program but never a metered LLM API. It reaches
Telegram through smart-reminders' admin channel (`sr.tg_admin`), so
`/opt/smart-reminders` has to be installed first; `install.sh` refuses without it.

Written by Dmitriy L. on the host on 2026-10-26 while adding the 500 GB volume,
and brought into the repo on 2026-10-27 — until then it existed only on the
machine and would have been lost on a rebuild.

## Noise control

It alerts when the threshold is first crossed, then at most once a day while it
stays above, and once more when it drops back below. State is
`/var/lib/disk-alert/state.json`.

## Watches more than one filesystem

`DISK_ALERT_PATHS` (default `/,/home`), each path checked and reported on its own;
two paths on the same filesystem are reported once.

This matters because of what happened the same week. `/home` moved onto its own
500 GB volume on 2026-10-27, so `/` dropped to about 20% and would have stayed
there for ever — while the volume that actually holds the growth filled up
unwatched. Watching `/home` by name rather than by device means the alert follows
the homes wherever they live.

The state file written before that change had `above` / `last_alert` at the top
level for `/` only; it is migrated to the per-path shape on first run.

## Files

```
disk_alert.py        the check
disk-alert.service   oneshot; DISK_ALERT_PCT and DISK_ALERT_PATHS set here
disk-alert.timer     OnBootSec=5min, OnUnitActiveSec=15min
install.sh           idempotent install / --rollback
```

## Use

```bash
sudo ./install.sh
/opt/disk-alert/disk_alert.py --dry-run   # what it would say, sends nothing, writes no state
sudo ./install.sh --rollback
```
