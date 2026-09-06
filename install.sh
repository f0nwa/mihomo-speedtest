#!/bin/sh
# Устанавливает speedtest2 на роутере: извлекает SOURCES и фильтры из
# config.yaml, калибрует порог скорости, ставит cron и делает пробный запуск.
# Запускать из каталога, где рядом лежат speedtest2.sh, prep.awk, providers.awk.
set -eu

DIR=${DIR:-/opt/etc/mihomo}
BIN=${BIN:-/opt/sbin/mihomo}
API_MAIN=${API_MAIN:-127.0.0.1:9090}
SPEED_URL=${SPEED_URL:-"https://speed.cloudflare.com/__down?bytes=10485760"}
TMPROOT=${TMPROOT:-/tmp}
SELFDIR=${SELFDIR:-.}
CONFIG=${CONFIG:-$DIR/config.yaml}
INSTALLED_SCRIPT=${INSTALLED_SCRIPT:-$DIR/speedtest2.sh}

. "$SELFDIR/version_check.sh"

resolve_block() {
  if [ -n "${BLOCK:-}" ]; then
    BLOCK_SOURCE="переменная окружения"
    return 0
  fi

  count=${BLOCK_COUNT:-0}

  if [ "$count" -eq 1 ]; then
    BLOCK=$BLOCK_1
    BLOCK_SOURCE="из конфига"
    return 0
  fi

  if [ "$count" -gt 1 ]; then
    echo "Найдено несколько разных гео-фильтров:" >&2
    i=1
    while [ "$i" -le "$count" ]; do
      eval "val=\$BLOCK_$i"
      echo "  $i) $val" >&2
      i=$((i + 1))
    done
    printf 'Введите номер варианта или свой фильтр: ' >&2
    read -r choice || choice=""
    case $choice in
      ''|*[!0-9]*)
        BLOCK=$choice
        BLOCK_SOURCE="введён вручную"
        ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
          eval "BLOCK=\$BLOCK_$choice"
          BLOCK_SOURCE="из конфига (вариант $choice)"
        else
          echo "install.sh: номер вне диапазона" >&2
          BLOCK=""
        fi
        ;;
    esac
    if [ -z "$BLOCK" ]; then
      echo "install.sh: пустой или неверный фильтр недопустим. Повторите с BLOCK='...' sh install.sh" >&2
      return 1
    fi
    return 0
  fi

  attempt=1
  while [ "$attempt" -le 3 ]; do
    echo "Гео-фильтр не найден в конфиге." >&2
    printf 'Введите фильтр: ' >&2
    read -r input || input=""
    if [ -n "$input" ]; then
      BLOCK=$input
      BLOCK_SOURCE="введён вручную"
      return 0
    fi
    echo "install.sh: пустой фильтр не принимается (попытка $attempt из 3)" >&2
    attempt=$((attempt + 1))
  done
  echo "install.sh: фильтр обязателен — без него подписка может подставить российскую ноду, которая выиграет замер по пингу. Установка остановлена." >&2
  return 1
}

install_cron() {
  cron_line="0 */3 * * * $INSTALLED_SCRIPT"
  current=$(crontab -l 2>/dev/null || true)
  if printf '%s\n' "$current" | grep -qF "$INSTALLED_SCRIPT"; then
    return 0
  fi
  printf '%s\n' "$current" > "$TMPROOT/cron.bak"
  { [ -n "$current" ] && printf '%s\n' "$current"; echo "$cron_line"; } | crontab -
}

atomic_install() {
  src=$1
  dst=$2
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  if ! cp "$src" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
}

install_files() {
  atomic_install "$SELFDIR/speedtest2.sh" "$DIR/speedtest2.sh" || return 1
  chmod +x "$DIR/speedtest2.sh"
  atomic_install "$SELFDIR/prep.awk" "$DIR/prep.awk" || return 1
}

write_env() {
  dst=$1
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  {
    echo "# создано install.sh $(date '+%F %T')"
    echo "# фильтр: $BLOCK_SOURCE"
    printf "SOURCES='%s'\n" "$SOURCES"
    [ -n "${EXTYPE:-}" ] && printf "EXTYPE='%s'\n" "$EXTYPE"
    printf "BLOCK='%s'\n" "$BLOCK"
    printf "MIN_SPEED='%s'\n" "$MIN_SPEED"
  } > "$tmp"
  mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

recalibrate_env() {
  dst=$1
  new_min=$2
  [ -f "$dst" ] || { echo "install.sh: $dst не найден, сначала обычная установка" >&2; return 1; }
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  awk -v v="$new_min" -v q="'" '
    /^MIN_SPEED=/ { print "MIN_SPEED=" q v q; done = 1; next }
    { print }
    END { if (!done) print "MIN_SPEED=" q v q }
  ' "$dst" > "$tmp"
  mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

read_speedtest_const() {
  # Читает числовую константу вида "ИМЯ=значение  # комментарий" из
  # шапки speedtest2.sh. Используется, чтобы MIN_RATIO/MIN_FLOOR не
  # дублировались magic-числами в install.sh (см. compute_threshold()
  # в speedtest2.sh — источник истины для этой арифметики).
  name=$1
  default=$2
  val=$(awk -v n="$name" '
    $0 ~ "^" n "=" {
      v = $0
      sub("^" n "=", "", v)
      sub(/[ \t]*#.*/, "", v)
      gsub(/[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$SELFDIR/speedtest2.sh" 2>/dev/null) || val=""
  if [ -n "$val" ]; then
    echo "$val"
  else
    echo "$default"
  fi
}

compute_min_speed() {
  # $1 = CHANNEL (байт/с прямого замера).
  # Дублирует compute_threshold() из speedtest2.sh на числах, прочитанных
  # оттуда же через read_speedtest_const; 0.25/524288 ниже — fallback
  # ТОЛЬКО если строки MIN_RATIO=/MIN_FLOOR= не найдены в speedtest2.sh
  # (они ДОЛЖНЫ совпадать с дефолтами в его шапке).
  channel=$1
  ratio=$(read_speedtest_const MIN_RATIO 0.25)
  floor=$(read_speedtest_const MIN_FLOOR 524288)
  awk -v c="$channel" -v r="$ratio" -v f="$floor" 'BEGIN {
    t = int(c * r)
    print (t > f) ? t : f
  }'
}

measure_channel() {
  METRICS=$(curl -s -m 15 -o /dev/null -w '%{http_code} %{speed_download}' \
            "$SPEED_URL" 2>/dev/null) || METRICS=""
  status=${METRICS%% *}
  raw=${METRICS#* }
  case $status in
    2[0-9][0-9]) echo "${raw%%.*}" ;;
    *) echo 0 ;;
  esac
}

main() {
  check_mihomo_process && check_versions || return 1

  [ -f "$CONFIG" ] || { echo "install.sh: $CONFIG не найден" >&2; return 1; }
  for f in speedtest2.sh prep.awk providers.awk; do
    [ -f "$SELFDIR/$f" ] || {
      echo "install.sh: $SELFDIR/$f не найден рядом с install.sh" >&2
      return 1
    }
  done
  "$BIN" -t -d "$DIR" -f "$CONFIG" >/dev/null 2>&1 || {
    echo "install.sh: $CONFIG не проходит mihomo -t" >&2
    return 1
  }

  if ! PARSED=$(awk -v CONFIG="$CONFIG" -v CONFDIR="$DIR" -f "$SELFDIR/providers.awk" "$CONFIG"); then
    echo "install.sh: providers.awk не смог разобрать $CONFIG" >&2
    return 1
  fi
  eval "$PARSED"

  for src in $SOURCES; do
    [ -f "$src" ] && continue
    name=$(basename "$src" .yaml)
    curl -f -s -m 10 -X PUT "http://$API_MAIN/providers/proxies/$name" >/dev/null 2>&1 || true
    sleep 3
    [ -f "$src" ] || {
      echo "install.sh: кэш $src не появился, сначала чините подписку $name" >&2
      return 1
    }
  done

  resolve_block || return 1
  echo "install.sh: фильтр ($BLOCK_SOURCE): $BLOCK" >&2

  CHANNEL=$(measure_channel)
  if [ "$CHANNEL" -gt 0 ] 2>/dev/null; then
    MIN_SPEED=$(compute_min_speed "$CHANNEL")
    echo "install.sh: канал $((CHANNEL/1048576)) МБ/с, порог $((MIN_SPEED/1048576)) МБ/с" >&2
  else
    # MIN_SPEED в шапке speedtest2.sh — не в кавычках (число), в отличие
    # от BLOCK; читаем тем же read_speedtest_const, что и MIN_RATIO/MIN_FLOOR.
    MIN_SPEED=$(read_speedtest_const MIN_SPEED 1048576)
    echo "install.sh: прямой замер канала не удался, порог из дефолта: $MIN_SPEED" >&2
  fi

  write_env "$DIR/speedtest2.env" || {
    echo "install.sh: не удалось записать speedtest2.env" >&2
    return 1
  }
  install_files || {
    echo "install.sh: не удалось установить файлы" >&2
    return 1
  }
  install_cron

  if [ "${SKIP_TRIAL:-0}" != 1 ]; then
    "$DIR/speedtest2.sh" || true
    echo "install.sh: пробный запуск завершён, хвост журнала:" >&2
    tail -5 "$DIR/speedtest.log" 2>/dev/null >&2 || true
  fi

  echo "install.sh: установка завершена" >&2
}

recalibrate_main() {
  ENVFILE=${ENVFILE:-$DIR/speedtest2.env}
  [ -f "$ENVFILE" ] || {
    echo "install.sh: $ENVFILE не найден, сначала обычная установка" >&2
    return 1
  }
  CHANNEL=$(measure_channel)
  if [ "$CHANNEL" -gt 0 ] 2>/dev/null; then
    NEW_MIN=$(compute_min_speed "$CHANNEL")
  else
    echo "install.sh: прямой замер канала не удался, MIN_SPEED не изменён" >&2
    return 1
  fi
  recalibrate_env "$ENVFILE" "$NEW_MIN" || return 1
  echo "install.sh: MIN_SPEED пересчитан: $((NEW_MIN/1048576)) МБ/с" >&2
}

if [ "${INSTALL_LIB_ONLY:-0}" != 1 ]; then
  if [ "${1:-}" = "--recalibrate" ]; then
    recalibrate_main
  else
    main "$@"
  fi
fi
