#!/bin/sh
# HTTPS Time Sync Safety v5 FINAL - Universal / Low Resource
# Common VPS Linux, including systemd systems and Alpine/BusyBox crond.
# No package install, timezone change, NTP disable, firewall/network/V2Node restart.
# Short-lived HTTPS check every 30 minutes; adjusts only when skew >= 10 seconds.

set -u

SYNC=/usr/local/sbin/https-time-sync
CMD=/usr/local/bin/https-time-sync
SERVICE=/etc/systemd/system/https-time-sync.service
TIMER=/etc/systemd/system/https-time-sync.timer
CRON_D=/etc/cron.d/https-time-sync
ALPINE_CRON=/etc/crontabs/root
MARK_BEGIN="# BEGIN HTTPS-TIME-SYNC"
MARK_END="# END HTTPS-TIME-SYNC"

say(){ printf '%s\n' "$*"; }
fail(){ say "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run as root"

# Never install packages automatically.
for c in curl date grep head tr sed; do
  command -v "$c" >/dev/null 2>&1 || fail "required command '$c' is missing; nothing installed"
done

cat >"$SYNC" <<'EOF'
#!/bin/sh
set -u

THRESHOLD=10
MODE="${1:-sync}"
REMOTE_EPOCH=
REMOTE_SOURCE=

parse_http_date() {
  d="$1"

  # GNU/coreutils date.
  x="$(date -u -d "$d" +%s 2>/dev/null || true)"
  case "$x" in ''|*[!0-9]*) ;; *) printf '%s' "$x"; return 0;; esac

  # BusyBox-compatible RFC7231 conversion.
  clean="$(printf '%s\n' "$d" | sed 's/^[A-Za-z][A-Za-z][A-Za-z], //; s/ GMT$//')"
  set -- $clean
  [ "$#" -eq 4 ] || return 1
  day="$1"; mon="$2"; year="$3"; tim="$4"

  case "$mon" in
    Jan) m=01;; Feb) m=02;; Mar) m=03;; Apr) m=04;; May) m=05;; Jun) m=06;;
    Jul) m=07;; Aug) m=08;; Sep) m=09;; Oct) m=10;; Nov) m=11;; Dec) m=12;;
    *) return 1;;
  esac

  x="$(date -u -D '%Y-%m-%d %H:%M:%S' -d "$year-$m-$day $tim" +%s 2>/dev/null || true)"
  case "$x" in ''|*[!0-9]*) return 1;; *) printf '%s' "$x"; return 0;; esac
}

get_remote_epoch() {
  # Independent HTTPS sources; first valid Date header wins.
  for url in \
    https://www.cloudflare.com/ \
    https://www.google.com/ \
    https://www.microsoft.com/
  do
    h="$(curl -4 -fsSI --connect-timeout 3 --max-time 6 "$url" 2>/dev/null |
      tr -d '\r' | grep -i '^date:' | head -n 1)"
    [ -n "$h" ] || continue

    e="$(parse_http_date "${h#*: }" 2>/dev/null || true)"
    case "$e" in ''|*[!0-9]*) continue;; esac

    REMOTE_EPOCH="$e"
    REMOTE_SOURCE="$url"
    return 0
  done
  return 1
}

can_set_epoch() {
  e="$1"

  # GNU date supports @epoch directly.
  date --version >/dev/null 2>&1 && return 0

  # BusyBox/other: verify conversion capability without changing the clock.
  f="$(date -u -d "@$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  [ -n "$f" ]
}

set_epoch() {
  e="$1"

  if date --version >/dev/null 2>&1; then
    date -u -s "@$e" >/dev/null 2>&1
    return $?
  fi

  f="$(date -u -d "@$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  [ -n "$f" ] || return 1
  date -u -s "$f" >/dev/null 2>&1
}

ntp_state() {
  if command -v timedatectl >/dev/null 2>&1; then
    n="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    [ "$n" = yes ] && { printf OK; return; }
    [ "$n" = no ] && { printf NOT_SYNCED; return; }
  fi

  if command -v chronyc >/dev/null 2>&1; then
    chronyc tracking 2>/dev/null | grep -qi 'Leap status.*Normal' &&
      { printf OK; return; }
    printf NOT_SYNCED
    return
  fi

  printf UNKNOWN
}

scheduler_state() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl is-active --quiet https-time-sync.timer 2>/dev/null &&
      { printf 'ACTIVE (systemd)'; return; }
    printf 'INACTIVE (systemd)'
    return
  fi

  [ -f /etc/cron.d/https-time-sync ] &&
    { printf 'INSTALLED (cron.d)'; return; }

  if [ -f /etc/crontabs/root ] &&
     grep -q '^# BEGIN HTTPS-TIME-SYNC$' /etc/crontabs/root 2>/dev/null; then
    printf 'INSTALLED (crond)'
    return
  fi

  printf NOT_INSTALLED
}

if ! get_remote_epoch; then
  if [ "$MODE" = status ]; then
    echo "Clock difference : UNKNOWN"
    echo "Clock status     : UNKNOWN"
    echo "NTP status       : $(ntp_state)"
    echo "Fallback timer   : $(scheduler_state)"
    echo "Reason           : cannot obtain/parse HTTPS reference time"
  fi
  exit 0
fi

LOCAL_EPOCH="$(date -u +%s)"
case "$LOCAL_EPOCH" in ''|*[!0-9]*) exit 0;; esac

DIFF=$((REMOTE_EPOCH - LOCAL_EPOCH))
[ "$DIFF" -lt 0 ] && ABS=$((-DIFF)) || ABS=$DIFF

if [ "$MODE" = probe ]; then
  can_set_epoch "$REMOTE_EPOCH" || exit 2
  exit 0
fi

if [ "$MODE" = status ]; then
  echo "Clock difference : ${DIFF}s"
  [ "$ABS" -lt "$THRESHOLD" ] &&
    echo "Clock status     : OK" ||
    echo "Clock status     : WRONG"
  echo "NTP status       : $(ntp_state)"
  echo "Fallback timer   : $(scheduler_state)"
  can_set_epoch "$REMOTE_EPOCH" &&
    echo "Clock setter     : SUPPORTED" ||
    echo "Clock setter     : UNSUPPORTED"
  exit 0
fi

# No clock write when skew is below threshold.
[ "$ABS" -lt "$THRESHOLD" ] && exit 0

# Fail closed: never change time unless platform capability was verified.
can_set_epoch "$REMOTE_EPOCH" || exit 0
set_epoch "$REMOTE_EPOCH" || exit 0

# RTC write is best-effort only.
command -v hwclock >/dev/null 2>&1 &&
  hwclock --systohc --utc >/dev/null 2>&1 || true

logger -t https-time-sync "Clock corrected by ${DIFF}s using ${REMOTE_SOURCE}" 2>/dev/null || true
exit 0
EOF

chmod 0755 "$SYNC"
mkdir -p /usr/local/bin
ln -sf "$SYNC" "$CMD"

# Preflight tests parsing + date implementation WITHOUT changing the clock.
if ! "$SYNC" probe; then
  rm -f "$CMD" "$SYNC"
  fail "this Linux/date implementation cannot safely parse/set HTTPS reference time; scheduler NOT installed"
fi

SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  SYSTEMD=1
fi

if [ "$SYSTEMD" -eq 1 ]; then
  cat >"$SERVICE" <<EOF
[Unit]
Description=HTTPS Time Sync Safety
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SYNC sync
Nice=19
IOSchedulingClass=idle
EOF

  cat >"$TIMER" <<'EOF'
[Unit]
Description=HTTPS Time Sync Safety Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
AccuracySec=1min
RandomizedDelaySec=30s
Persistent=true
Unit=https-time-sync.service

[Install]
WantedBy=timers.target
EOF

  rm -f "$CRON_D"

  # Remove only our own marked Alpine entry, if an older install created it.
  if [ -f "$ALPINE_CRON" ]; then
    sed -i '/^# BEGIN HTTPS-TIME-SYNC$/,/^# END HTTPS-TIME-SYNC$/d' "$ALPINE_CRON" 2>/dev/null || true
  fi

  systemctl daemon-reload
  systemctl enable --now https-time-sync.timer >/dev/null 2>&1 ||
    fail "cannot enable systemd timer"

  SCHEDULER=systemd

else
  CRON_RUNNING=0

  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x cron >/dev/null 2>&1 && CRON_RUNNING=1
    pgrep -x crond >/dev/null 2>&1 && CRON_RUNNING=1
  elif command -v pidof >/dev/null 2>&1; then
    pidof cron >/dev/null 2>&1 && CRON_RUNNING=1
    pidof crond >/dev/null 2>&1 && CRON_RUNNING=1
  fi

  [ "$CRON_RUNNING" -eq 1 ] ||
    fail "no active supported scheduler (systemd/cron/crond); automatic scheduling NOT installed"

  if [ -d /etc/crontabs ] && [ -f "$ALPINE_CRON" ]; then
    # Alpine/BusyBox crond format: no username field.
    sed -i '/^# BEGIN HTTPS-TIME-SYNC$/,/^# END HTTPS-TIME-SYNC$/d' "$ALPINE_CRON" 2>/dev/null || true

    {
      printf '%s\n' "$MARK_BEGIN"
      printf '*/30 * * * * %s sync >/dev/null 2>&1\n' "$SYNC"
      printf '%s\n' "$MARK_END"
    } >>"$ALPINE_CRON"

    chmod 0600 "$ALPINE_CRON" 2>/dev/null || true
    rm -f "$CRON_D"
    SCHEDULER=crond

  elif [ -d /etc/cron.d ]; then
    # Debian/RHEL-style /etc/cron.d format includes the user field.
    printf '*/30 * * * * root %s sync >/dev/null 2>&1\n' "$SYNC" >"$CRON_D"
    chmod 0644 "$CRON_D"
    SCHEDULER=cron.d

  else
    fail "cron daemon is active but no supported cron configuration path was found"
  fi
fi

# Immediate safe check after installation.
"$SYNC" sync

say "======================================"
say " HTTPS TIME SYNC SAFETY v5 FINAL"
say "======================================"
say "Scheduler        : $SCHEDULER"
"$SYNC" status
say
say "Check later with : https-time-sync status"
