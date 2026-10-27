# home-on-volume — move /home onto the DO volume without changing a path

On 2026-10-27 the firm host was at 84% of a 96 GB root disk with `/home` at 62 GB
across 36 tenants. Dmitriy L. had attached a 500 GB DigitalOcean volume the day
before — `/dev/sda`, xfs, mounted at `/mnt/ms_claude_vol1` by an enabled
`mnt-ms_claude_vol1.mount` with `nofail` — and left it empty.

## Why a bind mount and not a symlink, and not mounting the volume at /home

Every tenant pod is launched with absolute bind mounts: `/home/<u>/work`,
`/home/<u>/.claude`, `/home/<u>/.config`, `/home/<u>/.ssh`, and
`/home/<u>/.claude/.claude.json` onto `/home/<u>/.claude.json`. The cheapest
migration is the one where **those strings stay true**.

So the data goes to `/mnt/ms_claude_vol1/home` and `/home` becomes a bind mount of
it. Nothing else on the host learns a new path: not the pod launcher, not
`/etc/passwd`, not the logrotate globs, not the backup scripts.

Mounting the volume *at* `/home` directly would also work and would be one mount
instead of two — but it spends the whole 500 GB on homes and leaves nowhere to put
`/var/lib/containers` later. The bind keeps that door open.

## Files

```
migrate.sh            the migration, with rollback at every step after the swap
home.mount            /home <- /mnt/ms_claude_vol1/home, Requires= the volume mount
50-home-mount.conf    drop-in: claude-pod@.service gets RequiresMountsFor=/home
notify.py             one Telegram line to the admin, via smart-reminders
```

## How to run it

Stage the copy first, on the live system — it is a plain read, nobody notices:

```bash
rsync -aHAXx --numeric-ids --delete /home/ /mnt/ms_claude_vol1/home/
```

Then the swap. **Not from a shell in a tenant pod**, because step 3 stops every
pod including that one:

```bash
systemd-run --unit=ms-home-migrate --collect --service-type=oneshot \
            /opt/ms-home-migrate/migrate.sh
```

Under systemd the job belongs to PID 1 and outlives the session that started it.
It writes `/var/log/ms-home-migrate.log` and sends the admin the result, because
by then there is no session left to report to.

What it does: records which pods were running, stops the timers that walk or
restart tenants (`fleet-restart-requests` runs every two minutes and would
cheerfully start a pod mid-swap), stops the pods, re-runs rsync to catch the
delta, compares entry counts, renames `/home` to `/home.old`, mounts the volume's
copy at `/home`, checks the tenant count and a sentinel directory, and starts
everything it stopped.

## Rollback

Before the swap, aborting costs nothing — it starts the pods again and exits.
After the swap, any failed check unmounts, puts `/home.old` back as `/home` and
brings the pods up on it. By hand:

```bash
systemctl disable --now home.mount
rm -f /etc/systemd/system/home.mount \
      /etc/systemd/system/claude-pod@.service.d/50-home-mount.conf
systemctl daemon-reload
rmdir /home && mv /home.old /home
systemctl start 'claude-pod@*'
```

## /home.old is the point, not an oversight

The old tree stays as `/home.old`, still on the root disk. **Nothing is freed until
it is deleted** — `df` the morning after will look much as it did before, and that
is correct. Give the new mount a couple of days of real use, then:

```bash
rm -rf /home.old
```

That is the step that turns 84% into about 20%.

## The next reboot is the real test

`home.mount` is `WantedBy=multi-user.target` and `Requires=` the volume mount, and
`50-home-mount.conf` gives `claude-pod@.service` `RequiresMountsFor=/home`. A pod
that starts before `/home` is the volume would bind-mount empty directories into
the container and the tenant would come up with no files, no settings and no
channel — with nothing looking broken. The drop-in makes systemd refuse to start
the pod instead, which is the failure mode worth having.
