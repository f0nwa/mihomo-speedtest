#!/bin/sh
set -eu

DIR=${DIR:-/opt/etc/mihomo}
STATS_AUTH_PYTHON=${STATS_AUTH_PYTHON:-python3}
STATS_AUTH_PY=${STATS_AUTH_PY:-$DIR/stats_auth.py}
STATS_AUTH_STATE_DIR=${STATS_AUTH_STATE_DIR:-$DIR/.stats-auth}
STATS_AUTH_RUNTIME_DIR=${STATS_AUTH_RUNTIME_DIR:-/tmp/mihomo-speedtest-auth}
INITD_SCRIPT=${INITD_SCRIPT:-/opt/etc/init.d/S80speedtest-stats}

usage() {
  echo "использование: sh $0 reset" >&2
}

[ "${1:-}" = reset ] && [ "$#" -eq 1 ] || {
  usage
  exit 2
}

command -v "$STATS_AUTH_PYTHON" >/dev/null 2>&1 || {
  echo "stats_auth.sh: Python 3 не найден: $STATS_AUTH_PYTHON" >&2
  exit 1
}

[ -f "$STATS_AUTH_PY" ] || {
  echo "stats_auth.sh: stats_auth.py не найден: $STATS_AUTH_PY" >&2
  exit 1
}

code=$(
  "$STATS_AUTH_PYTHON" "$STATS_AUTH_PY" reset \
    --state-dir "$STATS_AUTH_STATE_DIR" \
    --runtime-dir "$STATS_AUTH_RUNTIME_DIR"
)

printf 'Одноразовый код: %s\n' "$code"
printf 'Откройте /setup в веб-интерфейсе и задайте логин и пароль.\n'

[ -x "$INITD_SCRIPT" ] || {
  echo "stats_auth.sh: init-скрипт веб-службы не найден: $INITD_SCRIPT" >&2
  exit 1
}

"$INITD_SCRIPT" restart || {
  echo "stats_auth.sh: не удалось перезапустить веб-службу" >&2
  exit 1
}
