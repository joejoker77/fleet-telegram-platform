#!/usr/bin/env bash
# Stop the host's automatic OS updates from restarting the tenant fleet.
# See runtime/host/needrestart-claude-fleet.conf for the incident this comes from.
# Idempotent. Rollback: needrestart-guard-rollback.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
SRC="$REPO/runtime/host/needrestart-claude-fleet.conf"
DST=/etc/needrestart/conf.d/90-claude-fleet.conf

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC — wrong checkout?"; exit 1; }
[ -d /etc/needrestart/conf.d ] || { echo "needrestart is not installed here — nothing to guard"; exit 0; }

install -m 0644 "$SRC" "$DST"
echo "installed $DST"

# A broken fragment here does not fail loudly — it takes the host's automatic
# updates down with it. So prove two separate things before walking away.

# 1. needrestart still runs at all, with our file in conf.d. List mode only.
if command -v needrestart >/dev/null 2>&1; then
  if err="$(needrestart -r l -b 2>&1 >/dev/null)"; then
    echo "needrestart still runs with the new file in place"
  else
    echo "needrestart FAILED with the new config — removing it again" >&2
    printf '%s\n' "$err" | head -5 >&2
    rm -f "$DST"
    exit 1
  fi
fi

# 2. The rules actually decide what we think they decide. Loading the fragment and
#    matching real unit names against it is the only answer that is not a guess —
#    and it catches the whole-hash-assignment mistake, which parses fine and
#    quietly throws away needrestart's own defaults.
echo
echo "what the rules decide:"
perl -e '
  our %nrconf = (override_rc => { qr(^dbus) => 0 });   # a stand-in default
  do "'"$DST"'"; die "  fragment failed to load: $@\n" if $@;
  my @want = ("claude-pod\@sshjulianpg.service", "podman-restart.service",
              "cl-egress-forwarder.service", "cp-secretd.socket");
  my @must_survive = ("dbus.service");
  my $bad = 0;
  for my $svc (@want, @must_survive) {
    my $v;
    for my $re (keys %{$nrconf{override_rc}}) {
      if ($svc =~ /$re/) { $v = $nrconf{override_rc}{$re}; last }
    }
    printf("  %-34s %s\n", $svc, defined $v ? ($v ? "restart" : "left alone") : "NO RULE");
    $bad++ unless defined $v && $v == 0;
  }
  exit($bad ? 1 : 0);
' || { echo "the rules do not do what they claim — removing the file again" >&2; rm -f "$DST"; exit 1; }
