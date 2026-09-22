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
STATS_SERVICE_DEST=${STATS_SERVICE_DEST:-$DIR/stats_service.sh}
INITD_DIR=${INITD_DIR:-/opt/etc/init.d}
INITD_SCRIPT=${INITD_SCRIPT:-$INITD_DIR/S80speedtest-stats}

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
  echo "install.sh: фильтр обязателен - без него подписка может подставить российскую ноду, которая выиграет замер по пингу. Установка остановлена." >&2
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
  case $src in *.sh) mode=0755 ;; *) mode=0644 ;; esac
  if ! chmod "$mode" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
}

# Полные инструменты проекта, нужные для планирования обновления.
PROJECT_TOOLS="migrate_config.sh migrate_config.awk config_diff.awk install.sh uninstall.sh version_check.sh VERSIONS setup.sh detect_ua.sh render_config.awk existing_config.awk config.example.yaml update.sh update_plan.awk update_prepare.sh update_transaction.sh providers.awk"

install_files() {
  for project_file in $PROJECT_TOOLS; do
    atomic_install "$SELFDIR/$project_file" "$DIR/$project_file" || return 1
  done
  atomic_install "$SELFDIR/speedtest2.sh" "$DIR/speedtest2.sh" || return 1
  chmod +x "$DIR/speedtest2.sh"
  atomic_install "$SELFDIR/prep.awk" "$DIR/prep.awk" || return 1
  atomic_install "$SELFDIR/render_stats.awk" "$DIR/render_stats.awk" || return 1
  atomic_install "$SELFDIR/stats_cgi.sh" "$DIR/stats_cgi.sh" || return 1
  chmod +x "$DIR/stats_cgi.sh"
  atomic_install "$SELFDIR/stats_run.sh" "$DIR/stats_run.sh" || return 1
  chmod +x "$DIR/stats_run.sh"
  # статические файлы SPA-shell (см. docs/plans/2026-09-12-web-spa-migration-design.md)
  # веб-сервиса статистики - копируются в раздаваемый каталог сами,
  # write_stats_static() из speedtest2.sh; исполняемый бит не нужен.
  # stats_chart.js - вендоренная UMD-сборка Chart.js для графика по нодам
  # (buildNodeChart() в stats_app.js), не наш код, ставится так же.
  atomic_install "$SELFDIR/stats_index.html" "$DIR/stats_index.html" || return 1
  atomic_install "$SELFDIR/stats_style.css" "$DIR/stats_style.css" || return 1
  atomic_install "$SELFDIR/stats_app.js" "$DIR/stats_app.js" || return 1
  atomic_install "$SELFDIR/stats_chart.js" "$DIR/stats_chart.js" || return 1
  # обязательный веб-сервер на python3 (см. docs/guide.md, "Обязательная
  # авторизация веб-интерфейса") - запускается start_backend() в
  # stats_service.sh (порция 3, независимая служба); исполняемый бит не
  # нужен, он вызывается как "python3 stats_httpd.py", а не напрямую.
  # stats_auth.py - ядро авторизации (импортируется stats_httpd.py),
  # stats_auth.sh - сброс логина и пароля по SSH (sh stats_auth.sh reset).
  atomic_install "$SELFDIR/stats_httpd.py" "$DIR/stats_httpd.py" || return 1
  atomic_install "$SELFDIR/stats_auth.py" "$DIR/stats_auth.py" || return 1
  atomic_install "$SELFDIR/stats_auth.sh" "$DIR/stats_auth.sh" || return 1
  # вызывается напрямую через "awk -f", как prep.awk/render_stats.awk -
  # исполняемый бит не нужен.
  atomic_install "$SELFDIR/node_stats_update.awk" "$DIR/node_stats_update.awk" || return 1
  # вызывается напрямую через "awk -f" в speedtest2.sh - исполняемый бит не нужен.
  atomic_install "$SELFDIR/sub_convert.awk" "$DIR/sub_convert.awk" || return 1
  # прогресс скоростного теста по нодам текущего прогона (write_progress()
  # в speedtest2.sh) - вызывается напрямую через "awk -f", исполняемый бит
  # не нужен.
  atomic_install "$SELFDIR/render_progress.awk" "$DIR/render_progress.awk" || return 1
  # независимая служба веб-интерфейса статистики (порция 3, см.
  # docs/superpowers/specs/2026-09-15-independent-stats-service-design.md) -
  # supervisor ставится рядом с остальными файлами в $DIR, а сам
  # init-скрипт - прямо в каталог автозапуска Entware, чтобы rc.unslung
  # подхватил его при следующей загрузке /opt без отдельного шага.
  atomic_install "$SELFDIR/stats_service.sh" "$STATS_SERVICE_DEST" || return 1
  chmod +x "$STATS_SERVICE_DEST"
  mkdir -p "$INITD_DIR" 2>/dev/null || true
  atomic_install "$SELFDIR/stats_init.sh" "$INITD_SCRIPT" || return 1
  chmod +x "$INITD_SCRIPT"
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
    # При повторной установке сохраняем пользовательские лимиты отбора.
    for limit_key in MAX_TESTED TOPN ENOUGH MIN_WINNERS; do
      saved_limit=$(sed -n "/^$limit_key=/p" "$dst" 2>/dev/null | tail -1)
      if [ -n "$saved_limit" ]; then
        printf '%s\n' "$saved_limit"
      else
        case $limit_key in
          MAX_TESTED) limit_default=40 ;;
          TOPN) limit_default=15 ;;
          ENOUGH) limit_default=20 ;;
          MIN_WINNERS) limit_default=3 ;;
        esac
        printf "%s='%s'\n" "$limit_key" "$(read_speedtest_const "$limit_key" "$limit_default")"
      fi
    done
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
  # в speedtest2.sh - источник истины для этой арифметики).
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
  # оттуда же через read_speedtest_const; 0.25/524288 ниже - fallback
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

have_python3() {
  command -v python3 >/dev/null 2>&1
}

have_opkg() {
  command -v opkg >/dev/null 2>&1
}

ensure_python3() {
  # Полная авторизация реализована в stats_httpd.py, поэтому незащищённого
  # BusyBox fallback больше нет. Неудача не отменяет CLI и speedtest, но
  # веб-службу после такой установки запускать нельзя.
  have_python3 && return 0

  if ! have_opkg; then
    echo "install.sh: python3 не найден, а opkg недоступен - веб-интерфейс не будет запущен. Поставьте python3 вручную, выполните sh $DIR/stats_auth.sh initialize и затем $INITD_SCRIPT restart" >&2
    return 1
  fi

  echo "install.sh: python3 не найден, пробую поставить через opkg install python3..." >&2
  if ! opkg install python3 >/dev/null 2>&1; then
    echo "install.sh: opkg install python3 не удался с первого раза, обновляю список пакетов (opkg update) и пробую ещё раз..." >&2
    opkg update >/dev/null 2>&1 || true
    opkg install python3 >/dev/null 2>&1 || true
  fi

  if have_python3; then
    echo "install.sh: python3 успешно установлен через opkg" >&2
    return 0
  else
    echo "install.sh: не удалось автоматически поставить python3 через opkg - веб-интерфейс не будет запущен. Поставьте python3 вручную, выполните sh $DIR/stats_auth.sh initialize и затем $INITD_SCRIPT restart" >&2
    return 1
  fi
}

initialize_web_auth() {
  code=$(python3 "$DIR/stats_auth.py" initialize \
    --state-dir "$DIR/.stats-auth" \
    --runtime-dir "${STATS_AUTH_RUNTIME_DIR:-/tmp/mihomo-speedtest-auth}") || return 1
  if [ -n "$code" ]; then
    echo "install.sh: одноразовый код первичной настройки: $code" >&2
    echo "install.sh: откройте http://<адрес роутера>:${STATS_HTTP_PORT:-8899}/setup и задайте логин и пароль" >&2
  fi
}

main() {
  check_mihomo_process && check_versions || return 1

  [ -f "$CONFIG" ] || { echo "install.sh: $CONFIG не найден" >&2; return 1; }
  for f in $PROJECT_TOOLS speedtest2.sh prep.awk providers.awk render_stats.awk stats_cgi.sh stats_run.sh stats_httpd.py stats_auth.py stats_auth.sh stats_index.html stats_style.css stats_app.js stats_chart.js node_stats_update.awk sub_convert.awk render_progress.awk stats_service.sh stats_init.sh; do
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
    # MIN_SPEED в шапке speedtest2.sh - не в кавычках (число), в отличие
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

  # Ставим python3 (если получится) ДО запуска веб-службы: без него
  # stats_httpd.py не запустится, а резервного сервера без пароля больше
  # нет - веб-интерфейс тогда просто не поднимается (см. ensure_python3).
  web_ready=1
  ensure_python3 || web_ready=0

  # Порция 3 (см. design): веб-интерфейс статистики поднимается независимо
  # от пробного прогона speedtest - "restart", а не "start", чтобы при
  # переустановке (изменился порт/bind/логин в $CONFIG или окружении)
  # уже запущенная служба сразу подхватила свежий speedtest2.env, а не
  # промолчала как "уже запущена" на старых настройках.
  if [ "$web_ready" = 1 ] && ! initialize_web_auth; then
    web_ready=0
    echo "install.sh: WARN - не удалось инициализировать авторизацию, веб-интерфейс не запущен" >&2
  fi
  if [ "$web_ready" = 1 ] && [ -x "$INITD_SCRIPT" ]; then
    if "$INITD_SCRIPT" restart >/dev/null 2>&1; then
      echo "install.sh: веб-сервис статистики запущен ($INITD_SCRIPT restart)" >&2
    else
      echo "install.sh: WARN - $INITD_SCRIPT restart не удался, веб-сервис статистики не поднят - проверьте вручную" >&2
    fi
  elif [ "$web_ready" = 1 ]; then
    echo "install.sh: WARN - $INITD_SCRIPT не найден после установки, веб-сервис статистики не запущен" >&2
  else
    [ ! -x "$INITD_SCRIPT" ] || "$INITD_SCRIPT" stop >/dev/null 2>&1 || true
    echo "install.sh: CLI, speedtest и обновлятор установлены; веб-интерфейс отключён до установки Python 3" >&2
  fi

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
