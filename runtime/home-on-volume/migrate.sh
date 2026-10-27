#!/usr/bin/env bash
# migrate.sh — move /home onto the ms-claude-vol1 volume without changing a single path.
#
# The tenant pods bind-mount absolute paths (/home/<u>/work, /home/<u>/.claude), so the
# one move that costs nothing is a bind mount: the data lives at /mnt/ms_claude_vol1/home
# and /home keeps being /home. Nothing else on the host has to learn a new path.
#
# Run it as a TRANSIENT SYSTEMD UNIT, not from a shell:
#
#     systemd-run --unit=ms-home-migrate --collect --service-type=oneshot \
#                 /opt/ms-home-migrate/migrate.sh
#
# because step 3 stops every tenant pod, and whoever launched this from inside one of them
# is about to be stopped too. Under systemd the job belongs to PID 1 and survives that.
#
# Everything before the swap is reversible by doing nothing. After the swap, any failed
# check rolls back: /home.old goes back to /home and the pods come up on it again. The old
# tree is KEPT as /home.old -- deleting it is what actually frees the root disk, and that
# is a separate, deliberate step once the new mount has proved itself.
set -uo pipefail

VOL=/mnt/ms_claude_vol1
DST="$VOL/home"
OLD=/home.old
LOG=/var/log/ms-home-migrate.log
STATE=/var/lib/ms-home-migrate
UNITS="$STATE/pods.list"
HERE=/opt/ms-home-migrate

# Timers that walk, exec into, or restart tenants. fleet-restart-requests runs every two
# minutes and would happily start a pod in the middle of the swap.
TIMERS="fleet-restart-requests.timer reap-stale-app-sessions.timer disk-alert.timer
        skill-autoshare.timer tenant-logcaps.timer cli-update-relay.timer
        staff-activity-collect.timer cc-cli-update.timer podman-auto-update.timer
        logrotate.timer"
SERVICES="smart-reminders.service"

mkdir -p "$STATE"
exec >>"$LOG" 2>&1
echo
echo "================ $(date -Is) migrate start ================"

notify() { printf '%s\n' "$1" | "$HERE/notify.py" || echo "NOTIFY FAILED"; }

start_everything() {
  if [ -s "$UNITS" ]; then xargs -r -a "$UNITS" systemctl start; fi
  # shellcheck disable=SC2086
  systemctl start $SERVICES $TIMERS
}

die() {                       # nothing has been swapped yet
  echo "ABORT (pre-swap): $*"
  start_everything
  notify "Перенос /home остановлен до переключения: $*

Ничего не изменено, поды поднимаю обратно. Лог: $LOG"
  exit 1
}

rollback() {                  # the swap happened and something is wrong
  echo "ROLLBACK: $*"
  systemctl disable --now home.mount 2>/dev/null
  rm -f /etc/systemd/system/home.mount \
        /etc/systemd/system/claude-pod@.service.d/50-home-mount.conf
  systemctl daemon-reload
  if mountpoint -q /home; then umount /home || umount -l /home; fi
  if [ -d /home ] && [ -z "$(ls -A /home 2>/dev/null)" ]; then rmdir /home; fi
  if [ -d "$OLD" ] && [ ! -e /home ]; then mv "$OLD" /home; fi
  start_everything
  notify "Перенос /home ОТКАЧЕН: $*

Старый /home вернулся на место, поды поднимаю. Том не тронут, данные целы. Лог: $LOG"
  exit 1
}

# ---------------------------------------------------------------- 1. preconditions
mountpoint -q "$VOL"            || die "том $VOL не смонтирован"
[ -d "$DST/vitaliy" ]           || die "в $DST нет подготовленной копии"
[ ! -e "$OLD" ]                 || die "$OLD уже существует — похоже, предыдущий запуск не завершился"
[ -x "$HERE/notify.py" ]        || echo "WARNING: no notifier, running silent"

need=$(du -sx --block-size=1M /home 2>/dev/null | awk '{print $1}')
free=$(df --output=avail --block-size=1M "$VOL" | tail -1 | tr -d ' ')
echo "need ${need}M, free on volume ${free}M"
[ "$free" -gt "$need" ]         || die "на томе ${free}M, нужно ${need}M"

before_dirs=$(find /home -xdev -maxdepth 1 -mindepth 1 -type d | wc -l)
echo "tenant home directories before: $before_dirs"
[ "$before_dirs" -ge 20 ]       || die "в /home всего $before_dirs каталогов — это не похоже на правду"

# ---------------------------------------------------------------- 2. quiesce
systemctl list-units --type=service --state=active --no-legend 'claude-pod@*' \
  | awk '{print $1}' > "$UNITS"
pods=$(wc -l < "$UNITS")
echo "pods running: $pods"
[ "$pods" -ge 1 ]               || die "ни один под не запущен — состояние хоста не то, что ожидалось"

echo "--- stopping timers and services"
# shellcheck disable=SC2086
systemctl stop $TIMERS $SERVICES

echo "--- stopping $pods pods"
xargs -r -a "$UNITS" systemctl stop
sleep 5
left=$(podman ps --quiet --filter name=claude- | wc -l)
echo "containers still up: $left"
[ "$left" -eq 0 ]               || die "$left контейнеров не остановились"

# No `fuser -m /home` here: /home is not its own filesystem yet, so -m would name every
# process on the root filesystem and tell us nothing. The swap is a rename within one
# filesystem anyway -- it succeeds regardless of open files. Stopping the pods above is
# about not letting anyone WRITE into a tree that is about to stop being /home.

# ---------------------------------------------------------------- 3. catch up the copy
echo "--- delta rsync"
rsync -aHAXx --numeric-ids --delete /home/ "$DST/" || die "догоняющий rsync упал"

src_n=$(find /home -xdev | wc -l)
dst_n=$(find "$DST" -xdev | wc -l)
echo "entries: source $src_n, copy $dst_n"
[ "$src_n" -eq "$dst_n" ]       || die "копия не сошлась: $src_n против $dst_n"

chown root:root "$DST"
chmod 755 "$DST"

# ---------------------------------------------------------------- 4. the swap
echo "--- swapping"
mv /home "$OLD"                 || die "не смог отодвинуть /home"
mkdir -m 755 /home              || rollback "не смог создать точку монтирования /home"
chown root:root /home

install -m 0644 "$HERE/home.mount" /etc/systemd/system/home.mount
install -d -m 0755 /etc/systemd/system/claude-pod@.service.d
install -m 0644 "$HERE/50-home-mount.conf" \
                /etc/systemd/system/claude-pod@.service.d/50-home-mount.conf
systemctl daemon-reload
systemctl enable --now home.mount || rollback "home.mount не поднялся"

# ---------------------------------------------------------------- 5. prove it
mountpoint -q /home             || rollback "/home не стал точкой монтирования"
src=$(findmnt -no SOURCE --target /home)
echo "/home now served from: $src"
after_dirs=$(find /home -maxdepth 1 -mindepth 1 -type d | wc -l)
echo "tenant home directories after: $after_dirs"
[ "$after_dirs" -eq "$before_dirs" ] || rollback "каталогов стало $after_dirs вместо $before_dirs"
[ -d /home/vitaliy/.claude ]    || rollback "нет /home/vitaliy/.claude — смонтировалось не то"

# ---------------------------------------------------------------- 6. bring it all back
echo "--- starting $pods pods"
start_everything
sleep 20
up=$(systemctl list-units --type=service --state=active --no-legend 'claude-pod@*' | wc -l)
echo "pods active: $up of $pods"

root_use=$(df -h / | tail -1 | awk '{print $3" из "$2" ("$5")"}')
vol_use=$(df -h "$VOL" | tail -1 | awk '{print $3" из "$2" ("$5")"}')
echo "root: $root_use | volume: $vol_use"
echo "================ $(date -Is) migrate done ================"

notify "Перенос /home завершён.

/home теперь на томе: $src
Каталогов тенантов: $after_dirs (было $before_dirs)
Поды подняты: $up из $pods
Системный диск: $root_use
Том: $vol_use

Старый каталог лежит как /home.old и всё ещё занимает место на системном диске — место освободится, когда его удалим. Пусть полежит пару дней.
Лог: $LOG"
exit 0
