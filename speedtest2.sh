#!/bin/sh
# Замер скорости нод на собственном ядре mihomo -> fast.yaml. Запуск по cron.
# В отличие от clash-speedtest тестирует ВСЕ транспорты, которые понимает установленный mihomo
# (xhttp, hysteria2, AmneziaWG и прочее): поднимает второй экземпляр на своих портах,
# переключает селектор через API и качает файл через локальный прокси.

DIR=${DIR:-/opt/etc/mihomo}
PROV=${PROV:-$DIR/proxy-providers}
SOURCES=${SOURCES:-"$DIR/config.yaml"}   # установщик добавляет кэши провайдеров через speedtest2.env
OUT=${OUT:-$DIR/fast.yaml}
LOG=${LOG:-$DIR/speedtest.log}
LAST=${LAST:-$DIR/speedtest_last.txt}
BIN=${BIN:-/opt/sbin/mihomo}
PREP=${PREP:-$DIR/prep.awk}
SUB_CONVERT=${SUB_CONVERT:-$DIR/sub_convert.awk}
TMPROOT=${TMPROOT:-/tmp}
WORK=${WORK:-$TMPROOT/mst.$$}
LOCK=${LOCK:-$TMPROOT/mst.lock}
LOCK_HELD=0
FORCE=${FORCE:-0}             # 1 -- ручной внеочередной запуск: живой вывод в терминал,
                              # ожидание/захват чужой блокировки вместо немедленного выхода
FORCE_WAIT=${FORCE_WAIT:-180} # force: сколько ждать (сек) чужую блокировку, прежде чем сдаться
CHECK_UPDATE=${CHECK_UPDATE:-0} # 1 -- только --check-update: сверить версии и выйти, main() не запускать
UPDATE_CORE=${UPDATE_CORE:-0}   # 1 -- только --update-core: скачать и применить core, main() не запускать
UPDATE_STATS=${UPDATE_STATS:-0} # 1 -- только --update-stats: скачать и применить stats, main() не запускать
MPID=
PUBLISH_TMP=
RUN_LOG=${RUN_LOG:-$WORK/speedtest.log}
LOG_LIMIT=${LOG_LIMIT:-102400}
LOG_FLUSHED=0

MIXED_PORT=7899
API=127.0.0.1:9099
API_MAIN=127.0.0.1:9090

SIZE=10485760         # сколько качать с каждой ноды, байт. Меньше 10 МБ занижает: на 3 МБ
                      # треть времени уходит на TTFB и та же нода показывает 4.5 вместо 12 МБ/с
DL_TIMEOUT=15         # потолок на одну закачку, секунд
MIN_SPEED=1048576     # порог отбора, байт/с (1 МБ/с для текущего канала)
MIN_RATIO=0.25         # динамический порог = доля от прямого канала
MIN_FLOOR=524288       # абсолютный минимум порога, байт/с (0.5 МиБ/с)
TOPN=20               # сколько нод класть в fast.yaml
ENOUGH=25             # набрали столько выше порога - дальше не меряем
MIN_WINNERS=3         # минимум нод в fast.yaml, если есть из кого выбрать - см. select_winners()
DELAY_URL='https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204'
# SPEED_URL строится ниже, ПОСЛЕ считывания speedtest2.env - иначе смена
# SIZE через веб-форму/env молча не действовала бы (строка была бы уже
# подставлена со старым SIZE до чтения $ENV).
# гео-стоп-лист: ноды с такими кусками в имени не тестируются вовсе
EXTYPE='trojan|ss'      # типы нод, которые вообще не тестируем
BLOCK=${BLOCK:-}       # обязательный фильтр загружает install.sh через speedtest2.env

HISTORY_RUNS=${HISTORY_RUNS:-$DIR/speedtest_runs.tsv}       # сводка по прогонам: канал, порог, счётчики
HISTORY_NODES=${HISTORY_NODES:-$DIR/speedtest_history.tsv}  # история нод-победителей по прогонам
HISTORY_KEEP_RUNS=${HISTORY_KEEP_RUNS:-200}   # хранить не больше стольких последних прогонов (0 = не ограничивать)
HISTORY_KEEP_DAYS=${HISTORY_KEEP_DAYS:-30}    # и не старше стольких дней (0 = не ограничивать)
HISTORY_STABILITY=${HISTORY_STABILITY:-$DIR/node_stability.tsv}  # агрегат стабильности всех нод пула (доступность delay-check, не скорость)
NODE_STATS_UPDATE=${NODE_STATS_UPDATE:-$DIR/node_stats_update.awk}
STABILITY_WINDOW=${STABILITY_WINDOW:-200}          # длина окна "недавних" прогонов на ноду (символы A/D/.), ~месяц при прогоне раз в 3 часа
STABILITY_DROP_AFTER=${STABILITY_DROP_AFTER:-$HISTORY_KEEP_RUNS}  # прогонов подряд без ноды в пуле -> строка удаляется из node_stability.tsv (0 = не удалять)

STATS_HTML=${STATS_HTML:-$DIR/stats_www/stats.html}   # страница статистики (раздаётся отдельным веб-сервисом, см. STATS_HTTP_* ниже)
STATS_JSON=${STATS_JSON:-$DIR/stats_www/stats.json}   # тот же дашборд в JSON (см. render_stats.awk -v format=json, шаг 2 SPA-миграции) - раздаётся как /api/stats
RENDER_STATS=${RENDER_STATS:-$DIR/render_stats.awk}
STATS_HTTP_ENABLE=${STATS_HTTP_ENABLE:-1}          # 1 = поднимать отдельный веб-сервис со статистикой, 0 = только писать файл
STATS_HTTP_BIND=${STATS_HTTP_BIND:-0.0.0.0}        # адрес привязки (0.0.0.0 = вся локальная сеть, как и 9090)
STATS_HTTP_PORT=${STATS_HTTP_PORT:-8899}           # порт веб-сервиса статистики; должен быть свободен (не 5000/5001/9090)
STATS_HTTP_DIR=${STATS_HTTP_DIR:-$DIR/stats_www}   # каталог, который раздаётся; создаётся сам, с zashboard не связан
STATS_HTTP_PIDFILE=${STATS_HTTP_PIDFILE:-$DIR/stats_httpd.pid}
STATS_HTTP_LOG=${STATS_HTTP_LOG:-$DIR/stats_httpd.log}
STATS_HTTPD_CMD=${STATS_HTTPD_CMD:-"busybox httpd"} # резервный сервер (шаг 5 SPA-миграции - см. design-док) - только старые адреса /stats.html и /cgi-bin/*, без чистых URL; используется, если недоступен python3 (см. STATS_HTTPD_PY ниже); -f -p BIND:PORT -h DIR -c CONF добавляются автоматически
STATS_HTTPD_PY=${STATS_HTTPD_PY:-$DIR/stats_httpd.py}   # основной сервер (нужен python3) - чистые URL (/, /stats, /settings) и /api/*, см. README; если python3 недоступен - используется резервный STATS_HTTPD_CMD выше
STATS_HTTPD_PY_CMD=${STATS_HTTPD_PY_CMD:-python3}       # интерпретатор для основного сервера
STATS_HTTPD_IP_CMD=${STATS_HTTPD_IP_CMD:-ip}            # чем определять LAN-адрес роутера для адреса в консоли, см. stats_httpd_advertise_host()
STATS_NODE_CAP=${STATS_NODE_CAP:-8}                 # сколько нод показывать на графике по нодам, 1..8 (см. render_stats.awk)
STATS_AUTH_USER=${STATS_AUTH_USER:-}                # логин для формы настройки /cgi-bin/config; пусто = без пароля
STATS_AUTH_PASS=${STATS_AUTH_PASS:-}                # пароль для формы настройки; сама статистика (stats.html) паролем не защищается
STATS_HTTP_CONF=${STATS_HTTP_CONF:-$DIR/stats_httpd.conf}          # конфиг busybox httpd (Basic Auth только на /cgi-bin), пишется сам
STATS_CGI_SOURCE=${STATS_CGI_SOURCE:-$DIR/stats_cgi.sh}            # исходник CGI-скрипта формы настройки, ставится install.sh
STATS_CGI_SCRIPT=${STATS_CGI_SCRIPT:-$STATS_HTTP_DIR/cgi-bin/config} # его же копия внутри раздаваемого каталога, пишется сама
STATS_RUN_SOURCE=${STATS_RUN_SOURCE:-$DIR/stats_run.sh}              # исходник CGI-скрипта кнопки force-прогона, ставится install.sh
STATS_RUN_SCRIPT=${STATS_RUN_SCRIPT:-$STATS_HTTP_DIR/cgi-bin/run}    # его же копия внутри раздаваемого каталога, пишется сама
STATS_INDEX_SOURCE=${STATS_INDEX_SOURCE:-$DIR/stats_index.html}     # исходник SPA-shell (см. docs/plans/2026-09-12-web-spa-migration-design.md), ставится install.sh
STATS_INDEX_HTML=${STATS_INDEX_HTML:-$STATS_HTTP_DIR/index.html}    # его же копия внутри раздаваемого каталога, пишется сама
STATS_STYLE_SOURCE=${STATS_STYLE_SOURCE:-$DIR/stats_style.css}      # исходник общего CSS для SPA-shell, ставится install.sh
STATS_STYLE_CSS=${STATS_STYLE_CSS:-$STATS_HTTP_DIR/style.css}       # его же копия внутри раздаваемого каталога, пишется сама
STATS_APP_SOURCE=${STATS_APP_SOURCE:-$DIR/stats_app.js}             # исходник клиентского роутера/логики SPA-shell, ставится install.sh
STATS_APP_JS=${STATS_APP_JS:-$STATS_HTTP_DIR/app.js}                # его же копия внутри раздаваемого каталога, пишется сама
STATS_CHARTJS_SOURCE=${STATS_CHARTJS_SOURCE:-$DIR/stats_chart.js}   # вендоренная UMD-сборка Chart.js для графика по нодам, ставится install.sh
STATS_CHARTJS_JS=${STATS_CHARTJS_JS:-$STATS_HTTP_DIR/chart.js}      # его же копия внутри раздаваемого каталога, пишется сама

# Проверка обновлений (см. README, "Перенос файлов на роутер и обновление
# после правок") - только по команде --check-update, без автозапуска по
# cron. CORE_VERSION/STATS_VERSION - версии этого файла и связанных с ним
# частей; меняются вручную при подготовке релиза и сверяются с файлом
# VERSIONS в репозитории (не путать со STATS_* выше - в speedtest2.env
# им быть не следует).
CORE_VERSION=${CORE_VERSION:-3}    # speedtest2.sh, install.sh, setup.sh, version_check.sh, detect_ua.sh, render_config.awk, existing_config.awk, config.example.yaml, prep.awk, providers.awk, node_stats_update.awk, sub_convert.awk
STATS_VERSION=${STATS_VERSION:-2}  # render_stats.awk, stats_cgi.sh, stats_run.sh, stats_httpd.py, stats_index.html, stats_style.css, stats_app.js, stats_chart.js
UPDATE_SOURCE_BASE=${UPDATE_SOURCE_BASE:-https://raw.githubusercontent.com/f0nwa/mihomo-speedtest/main}
UPDATE_MIRROR_BASE=${UPDATE_MIRROR_BASE:-https://cdn.jsdelivr.net/gh/f0nwa/mihomo-speedtest@main}
UPDATE_HTTP_CMD=${UPDATE_HTTP_CMD:-}       # переопределить команду загрузки целиком (тесты/нестандартные прошивки)
UPDATE_HTTP_TIMEOUT=${UPDATE_HTTP_TIMEOUT:-15}
# Отдельные UPDATE_*-переменные ниже - только для файлов, у которых нет
# своего "канонического" имени переменной за пределами этого блока
# (prep.awk/node_stats_update.awk/sub_convert.awk и все stats_*-файлы для
# --update-stats используют уже существующие PREP/NODE_STATS_UPDATE/
# SUB_CONVERT/RENDER_STATS/STATS_CGI_SOURCE/STATS_RUN_SOURCE/
# STATS_HTTPD_PY/STATS_INDEX_SOURCE/STATS_STYLE_SOURCE/STATS_APP_SOURCE/
# STATS_CHARTJS_SOURCE, объявленные выше). version_check.sh/setup.sh/
# detect_ua.sh/render_config.awk/existing_config.awk/config.example.yaml -
# инструментарий setup.sh (см. его же комментарий в шапке) - сам
# speedtest2.sh их не использует, поэтому у них тоже нет отдельного
# канонического имени, только это. version_check.sh нужен install.sh при
# КАЖДОМ запуске (source в его же шапке, включая --recalibrate) - без
# него в "core" install.sh на устаревшем version_check.sh тихо сверялся
# бы со старыми минимальными версиями.
UPDATE_SELF_SCRIPT=${UPDATE_SELF_SCRIPT:-$DIR/speedtest2.sh}
UPDATE_INSTALL_SH=${UPDATE_INSTALL_SH:-$DIR/install.sh}
UPDATE_PROVIDERS_AWK=${UPDATE_PROVIDERS_AWK:-$DIR/providers.awk}
UPDATE_VERSION_CHECK_SH=${UPDATE_VERSION_CHECK_SH:-$DIR/version_check.sh}
UPDATE_SETUP_SH=${UPDATE_SETUP_SH:-$DIR/setup.sh}
UPDATE_DETECT_UA_SH=${UPDATE_DETECT_UA_SH:-$DIR/detect_ua.sh}
UPDATE_RENDER_CONFIG_AWK=${UPDATE_RENDER_CONFIG_AWK:-$DIR/render_config.awk}
UPDATE_EXISTING_CONFIG_AWK=${UPDATE_EXISTING_CONFIG_AWK:-$DIR/existing_config.awk}
UPDATE_CONFIG_EXAMPLE_YAML=${UPDATE_CONFIG_EXAMPLE_YAML:-$DIR/config.example.yaml}

ENV=${ENV:-$DIR/speedtest2.env}
[ -f "$ENV" ] && . "$ENV"
SPEED_URL="https://speed.cloudflare.com/__down?bytes=$SIZE"  # см. комментарий у DELAY_URL выше

say() {
  log_line="$(date '+%H:%M:%S') $*"
  [ "$FORCE" = 1 ] && echo "$log_line"
  run_dir=${RUN_LOG%/*}
  if [ -d "$run_dir" ]; then
    echo "$log_line" >> "$RUN_LOG"
  else
    echo "$log_line" >> "$LOG" 2>/dev/null || echo "$log_line" >&2
  fi
}

flush_log() {
  [ "$LOG_FLUSHED" = 1 ] && return 0
  LOG_FLUSHED=1
  [ -s "$RUN_LOG" ] || return 0

  if ! cat "$RUN_LOG" >> "$LOG"; then
    cat "$RUN_LOG" >&2
    return 1
  fi

  log_size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "$log_size" -gt "$LOG_LIMIT" ]; then
    log_tmp=${LOG%/*}/.${LOG##*/}.$$
    if tail -300 "$LOG" > "$log_tmp"; then
      mv "$log_tmp" "$LOG" || rm -f "$log_tmp"
    else
      rm -f "$log_tmp"
    fi
  fi
}

acquire_lock() {
  if [ "$FORCE" = 1 ]; then
    waited=0
    while ! mkdir "$LOCK" 2>/dev/null; do
      old_pid=$(cat "$LOCK/pid" 2>/dev/null)
      if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
        say "force: забираю зависшую блокировку (pid $old_pid не отвечает)"
        rm -rf "$LOCK"
        continue
      fi
      if [ "$waited" -ge "$FORCE_WAIT" ]; then
        say "WARN: force -- блокировка занята${old_pid:+ (pid $old_pid)} дольше ${FORCE_WAIT}с, выхожу"
        return 1
      fi
      [ "$waited" -eq 0 ] && say "force: блокировка занята${old_pid:+ (pid $old_pid)}, жду освобождения..."
      sleep 2
      waited=$((waited + 2))
    done
  else
    if ! mkdir "$LOCK" 2>/dev/null; then
      return 1
    fi
  fi
  LOCK_HELD=1
  if ! echo $$ > "$LOCK/pid"; then
    rm -rf "$LOCK"
    LOCK_HELD=0
    return 1
  fi
}

install_traps() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

publish_file() {
  src=$1
  dst=$2
  FILE_CHANGED=0

  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    return 0
  fi

  dstdir=${dst%/*}
  dstbase=${dst##*/}
  PUBLISH_TMP=$dstdir/.$dstbase.$$
  if ! cp "$src" "$PUBLISH_TMP"; then
    rm -f "$PUBLISH_TMP"
    PUBLISH_TMP=
    return 1
  fi
  if ! mv "$PUBLISH_TMP" "$dst"; then
    rm -f "$PUBLISH_TMP"
    PUBLISH_TMP=
    return 1
  fi
  PUBLISH_TMP=
  FILE_CHANGED=1
}

publish_fast() {
  publish_file "$1" "$2" || return 1
  FAST_CHANGED=$FILE_CHANGED
}

remember_name() {
  name=$1
  seen_file=$2
  if grep -qxF "$name" "$seen_file" 2>/dev/null; then
    return 1
  fi
  echo "$name" >> "$seen_file"
}

select_winners() {
  # $6 (min_winners) - если нод, прошедших порог $4 (minimum), набралось
  # меньше, добираем из остальных РАБОЧИХ (speed > 0, т.е. реально
  # ответивших - нерабочие с speed=0 в добор никогда не идут) по убыванию
  # скорости, пока не наберём min_winners или top. Смысл: пустая/куцая
  # "самая быстрая" группа хуже, чем нода медленнее порога, но живая -
  # см. CHANGELOG.
  results=$1
  mapfile=$2
  output=$3
  minimum=$4
  top=$5
  min_winners=$6

  sort -rn "$results" | awk -F ' ' -v mapfile="$mapfile" -v minimum="$minimum" -v top="$top" -v min_winners="$min_winners" '
    BEGIN {
      bn = 0
      while ((getline line < mapfile) > 0) {
        tab = index(line, "\t")
        if (tab > 0) names[substr(line, 1, tab - 1)] = substr(line, tab + 1)
      }
      close(mapfile)
    }
    {
      name = names[$2]
      if (name == "" || seen[name]) next
      if ($1 >= minimum && count < top) {
        print $1, $2
        seen[name] = 1
        count++
      } else if ($1 > 0) {
        # кандидат на добор ниже порога - вход уже отсортирован по
        # убыванию скорости (sort -rn), поэтому backlog тоже в порядке
        # убывания - на случай, если прошедших порог не хватит на
        # min_winners
        backlog_sp[bn] = $1
        backlog_idx[bn] = $2
        backlog_name[bn] = name
        bn++
      }
    }
    END {
      for (i = 0; i < bn && count < min_winners && count < top; i++) {
        if (seen[backlog_name[i]]) continue
        print backlog_sp[i], backlog_idx[i]
        seen[backlog_name[i]] = 1
        count++
      }
    }
  ' > "$output"
}

trim_runs() {
  # $1=входной TSV (эпоха первым полем, строки в хронологическом порядке),
  # $2=выходной файл, $3=HISTORY_KEEP_RUNS (0=не ограничивать по числу),
  # $4=HISTORY_KEEP_DAYS (0=не ограничивать по времени), $5=текущая эпоха.
  src=$1; dst=$2; keep_runs=$3; keep_days=$4; now=$5
  awk -F'\t' -v keep_runs="$keep_runs" -v keep_days="$keep_days" -v now="$now" '
    { lines[NR] = $0; epoch[NR] = $1; n = NR }
    END {
      cutoff = (keep_days > 0) ? now - keep_days * 86400 : -1
      start = 1
      if (keep_runs > 0 && n > keep_runs) start = n - keep_runs + 1
      for (i = start; i <= n; i++) {
        if (cutoff >= 0 && epoch[i] + 0 < cutoff) continue
        print lines[i]
      }
    }
  ' "$src" > "$dst"
}

trim_nodes_since() {
  # $1=входной TSV, $2=выходной файл, $3=минимальная эпоха (пусто = не оставлять ничего).
  # Держит историю нод строго в границах уже обрезанной speedtest_runs.tsv:
  # $3 берётся как эпоха самой старой оставшейся строки сводки прогонов.
  src=$1; dst=$2; cutoff=$3
  if [ -z "$cutoff" ]; then
    : > "$dst"
    return 0
  fi
  awk -F'\t' -v c="$cutoff" '$1 + 0 >= c + 0' "$src" > "$dst"
}

stop_stats_httpd() {
  # Останавливает веб-сервис статистики, если он поднят (используется, когда
  # STATS_HTTP_ENABLE=0, и внутри ensure_stats_httpd() перед перезапуском на
  # новый адрес/порт). Отсутствие pid-файла или мёртвый pid - не ошибка.
  pid=$(cat "$STATS_HTTP_PIDFILE" 2>/dev/null) || true
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    say "веб-сервис статистики остановлен (pid $pid)"
  fi
  rm -f "$STATS_HTTP_PIDFILE" "$STATS_HTTP_PIDFILE.addr"
}

write_stats_httpd_conf() {
  # Пишет конфиг busybox httpd для веб-сервиса статистики: если заданы
  # STATS_AUTH_USER/STATS_AUTH_PASS, Basic Auth защищает только каталог
  # /cgi-bin (форму настройки) - саму статистику (stats.html) можно
  # смотреть без пароля. Пустой файл конфига = вообще без ограничений.
  # свой tmp+mv рядом с конфигом (а не в $WORK), т.к. ensure_stats_httpd()
  # может вызываться и без $WORK - например, из CGI-скрипта формы настройки.
  conf_dir=${STATS_HTTP_CONF%/*}
  if [ ! -d "$conf_dir" ]; then
    say "WARN: каталог $conf_dir не найден, конфиг Basic Auth не обновлён"
    return 0
  fi
  conf_tmp=$STATS_HTTP_CONF.$$.tmp
  if [ -n "$STATS_AUTH_USER" ]; then
    printf '/cgi-bin:%s:%s\n' "$STATS_AUTH_USER" "$STATS_AUTH_PASS" > "$conf_tmp"
  else
    : > "$conf_tmp"
  fi
  if ! publish_file "$conf_tmp" "$STATS_HTTP_CONF"; then
    say "WARN: не удалось записать $STATS_HTTP_CONF, конфиг Basic Auth не обновлён"
  fi
  rm -f "$conf_tmp"
}

write_stats_cgi() {
  # Копирует CGI-скрипт формы настройки статистики ($STATS_CGI_SOURCE,
  # ставится install.sh рядом со speedtest2.sh) в раздаваемый каталог
  # ($STATS_CGI_SCRIPT), откуда его запускает busybox httpd. Сам скрипт
  # подключает speedtest2.sh через экспортированные DIR/ENV (см.
  # ensure_stats_httpd() ниже и комментарий в начале stats_cgi.sh) - здесь
  # только физическое размещение файла внутри cgi-bin, логика не меняется.
  # Каталог $STATS_CGI_SCRIPT уже создан вызывающим ensure_stats_httpd()
  # (mkdir -p "$STATS_HTTP_DIR/cgi-bin"), отдельная проверка не нужна.
  if [ ! -f "$STATS_CGI_SOURCE" ]; then
    say "WARN: $STATS_CGI_SOURCE не найден, форма настройки статистики недоступна (переустановите install.sh)"
    return 0
  fi
  if ! publish_file "$STATS_CGI_SOURCE" "$STATS_CGI_SCRIPT"; then
    say "WARN: не удалось записать $STATS_CGI_SCRIPT, форма настройки не обновлена"
    return 0
  fi
  chmod +x "$STATS_CGI_SCRIPT" 2>/dev/null || true
}

write_stats_run() {
  # Копирует CGI-скрипт кнопки "Запустить прогон сейчас" ($STATS_RUN_SOURCE,
  # ставится install.sh рядом со speedtest2.sh) в раздаваемый каталог
  # ($STATS_RUN_SCRIPT) - см. комментарий в начале stats_run.sh. Как и
  # write_stats_cgi(), каталог $STATS_HTTP_DIR/cgi-bin уже создан
  # вызывающим ensure_stats_httpd(), отдельная проверка не нужна.
  if [ ! -f "$STATS_RUN_SOURCE" ]; then
    say "WARN: $STATS_RUN_SOURCE не найден, кнопка force-прогона недоступна (переустановите install.sh)"
    return 0
  fi
  if ! publish_file "$STATS_RUN_SOURCE" "$STATS_RUN_SCRIPT"; then
    say "WARN: не удалось записать $STATS_RUN_SCRIPT, кнопка force-прогона не обновлена"
    return 0
  fi
  chmod +x "$STATS_RUN_SCRIPT" 2>/dev/null || true
}

write_stats_static() {
  # Копирует статические файлы SPA-shell ($STATS_INDEX_SOURCE/$STATS_STYLE_SOURCE/
  # $STATS_APP_SOURCE/$STATS_CHARTJS_SOURCE, ставятся install.sh рядом со
  # speedtest2.sh) в раздаваемый каталог - см.
  # docs/plans/2026-09-12-web-spa-migration-design.md. Файлы статические
  # (без подстановки значений из $ENV, в отличие от stats.html из
  # render_stats()) - copy как есть, исполняемый бит не нужен.
  # $STATS_CHARTJS_SOURCE - вендоренная UMD-сборка Chart.js для графика по
  # нодам (buildNodeChart() в stats_app.js), не наш код - тоже просто
  # копируется как есть, отдельной логики не требует. Как и
  # write_stats_cgi()/write_stats_run() - отсутствие источника или
  # неудачная запись только логируют WARN и НЕ прерывают ensure_stats_httpd()
  # (return 0 в любом случае): stats_httpd.py просто продолжит отдавать "/"
  # как stats.html (или 404 на новых путях), как было до этой функции -
  # см. _full_path_for()/_spa_fallback() в нём (для chart.js - график
  # покажет "chart.js не загрузился", см. buildNodeChart() в stats_app.js).
  for pair in "$STATS_INDEX_SOURCE:$STATS_INDEX_HTML" "$STATS_STYLE_SOURCE:$STATS_STYLE_CSS" "$STATS_APP_SOURCE:$STATS_APP_JS" "$STATS_CHARTJS_SOURCE:$STATS_CHARTJS_JS"; do
    src=${pair%%:*}
    dst=${pair#*:}
    if [ ! -f "$src" ]; then
      say "WARN: $src не найден, SPA-интерфейс (/stats, /settings) недоступен (переустановите install.sh)"
      continue
    fi
    if ! publish_file "$src" "$dst"; then
      say "WARN: не удалось записать $dst, SPA-интерфейс не обновлён"
    fi
  done
  return 0
}

ensure_stats_httpd() {
  # Поднимает (или перезапускает при смене адреса/порта) отдельный веб-сервис
  # для stats.html - раньше страница раздавалась только вместе с zashboard
  # через external-ui mihomo (порт 9090), теперь у неё свой процесс и порт,
  # не зависящий от того, установлен ли zashboard. Самовосстанавливается: при
  # каждом прогоне (раз в HISTORY-интервал через cron) проверяет, жив ли
  # процесс, и поднимает заново, если умер, - отдельного demon/init.d-скрипта
  # для автозапуска после перезагрузки роутера пока нет, см. TODO.md.
  # DIR и ENV экспортируются, чтобы дочерний httpd и порождаемые им CGI-запросы
  # (stats_cgi.sh) видели те же настройки, что и текущий прогон - см.
  # комментарий в начале stats_cgi.sh.
  #
  # Выбор сервера (шаг 5 SPA-миграции, см.
  # docs/plans/2026-09-12-web-spa-migration-design.md - решение по
  # python3-зависимости: вариант 2, деградация, а не жёсткая зависимость) -
  # ниже, перед выбором backend.
  export DIR ENV

  if [ "$STATS_HTTP_ENABLE" != 1 ]; then
    stop_stats_httpd
    return 0
  fi

  if [ ! -d "$STATS_HTTP_DIR/cgi-bin" ] && ! mkdir -p "$STATS_HTTP_DIR/cgi-bin"; then
    say "WARN: не удалось создать $STATS_HTTP_DIR/cgi-bin, веб-сервис статистики не поднят"
    return 0
  fi

  write_stats_httpd_conf
  write_stats_cgi
  write_stats_run
  write_stats_static

  # отпечаток адреса и защиты - смена любого из них требует перезапуска
  # httpd (логин/пароль читает только при старте из -c конфига); md5sum -
  # не для безопасности, а просто чтобы не хранить пароль вторым открытым
  # текстом в .addr-файле (он и так есть в speedtest2.env).
  authsig=$(printf '%s:%s' "$STATS_AUTH_USER" "$STATS_AUTH_PASS" | md5sum 2>/dev/null) || authsig="$STATS_AUTH_USER:$STATS_AUTH_PASS"
  want="$STATS_HTTP_BIND:$STATS_HTTP_PORT:$authsig"
  pid=$(cat "$STATS_HTTP_PIDFILE" 2>/dev/null) || true
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    have=$(cat "$STATS_HTTP_PIDFILE.addr" 2>/dev/null) || true
    if [ "$have" = "$want" ]; then
      return 0
    fi
    say "веб-сервис статистики: адрес или защита изменились, перезапускаю"
    stop_stats_httpd
  fi

  # Основной сервер - stats_httpd.py (python3): только он умеет чистые URL
  # (/, /stats, /settings) и /api/* - см. docs/plans/2026-09-12-web-spa-migration-design.md.
  # Если python3 недоступен (файла нет или сам интерпретатор не найден в
  # PATH) - молча переходим к резервному "busybox httpd" ниже: старые
  # адреса /stats.html и /cgi-bin/* при этом продолжают работать, просто
  # без чистых URL и /api/*.
  py_available=0
  if [ -f "$STATS_HTTPD_PY" ] && command -v "$STATS_HTTPD_PY_CMD" >/dev/null 2>&1; then
    py_available=1
  fi

  backend=""
  if [ "$py_available" = 1 ]; then
    newpid=$(start_stats_httpd_backend "$STATS_HTTPD_PY_CMD $STATS_HTTPD_PY") && backend="$STATS_HTTPD_PY_CMD $STATS_HTTPD_PY"
  fi
  if [ -z "$backend" ]; then
    if [ "$py_available" = 1 ]; then
      say "веб-сервис статистики: $STATS_HTTPD_PY_CMD $STATS_HTTPD_PY не запустился, пробую резервный сервер ($STATS_HTTPD_CMD)"
    else
      say "веб-сервис статистики: $STATS_HTTPD_PY_CMD не найден - используется резервный сервер ($STATS_HTTPD_CMD), доступны только /stats.html и /cgi-bin/*; для чистых URL поставьте python3 (см. README)"
    fi
    newpid=$(start_stats_httpd_backend "$STATS_HTTPD_CMD") && backend=$STATS_HTTPD_CMD
  fi
  if [ -z "$backend" ]; then
    say "WARN: веб-сервис статистики не запустился на $STATS_HTTP_BIND:$STATS_HTTP_PORT ни основным сервером, ни резервным - подробности в $STATS_HTTP_LOG"
    return 0
  fi
  if echo "$newpid" > "$STATS_HTTP_PIDFILE"; then
    echo "$want" > "$STATS_HTTP_PIDFILE.addr" 2>/dev/null || true
    url_host=$(stats_httpd_advertise_host "$STATS_HTTP_BIND")
    [ -n "$url_host" ] || url_host=$STATS_HTTP_BIND
    say "OK: веб-сервис статистики ($backend) на $STATS_HTTP_BIND:$STATS_HTTP_PORT (pid $newpid), раздаёт $STATS_HTTP_DIR - http://$url_host:$STATS_HTTP_PORT/stats.html"
  else
    say "WARN: не удалось записать $STATS_HTTP_PIDFILE, процесс $newpid оставлен запущенным"
  fi
}

start_stats_httpd_backend() {
  # $1 = команда сервера ("busybox httpd" или "$STATS_HTTPD_PY_CMD
  # $STATS_HTTPD_PY") - оба принимают один и тот же набор флагов
  # (-f -p BIND:PORT -h DIR -c CONF), см. шапку stats_httpd.py. При успехе
  # печатает pid в stdout и возвращает 0; при неудаче - WARN в лог через
  # say() и возврат 1. Не трогает $STATS_HTTP_PIDFILE - это решает вызывающий
  # код (ensure_stats_httpd), он же выбирает, пробовать ли запасной вариант.
  cmd=$1
  bin=${cmd%% *}
  if ! command -v "$bin" >/dev/null 2>&1; then
    say "WARN: $bin не найден"
    return 1
  fi
  $cmd -f -p "$STATS_HTTP_BIND:$STATS_HTTP_PORT" -h "$STATS_HTTP_DIR" -c "$STATS_HTTP_CONF" \
    > "$STATS_HTTP_LOG" 2>&1 < /dev/null &
  newpid=$!
  sleep 1
  if ! kill -0 "$newpid" 2>/dev/null; then
    say "WARN: $cmd запустился и сразу завершился (порт занят? см. $STATS_HTTP_LOG)"
    return 1
  fi
  echo "$newpid"
}

stats_httpd_advertise_host() {
  # $1 = STATS_HTTP_BIND. Печатает адрес для строки "OK: веб-сервис
  # статистики ..." в консоли/логе - "0.0.0.0" (слушать все интерфейсы,
  # значение по умолчанию) в браузер не подставишь, оператору нужен
  # реальный IP роутера. Если bind - конкретный адрес, он и есть ответ.
  # Если это "все интерфейсы" - пробуем определить LAN-адрес через
  # STATS_HTTPD_IP_CMD (по умолчанию "ip", есть из коробки в Entware и
  # KeeneticOS): берём все глобальные IPv4 из "ip -4 -o addr show scope
  # global" (формат: "N: iface    inet A.B.C.D/N ..." - $4 после awk,
  # обрезаем маску через cut).
  #
  # На роутере "scope global" адресов может быть НЕСКОЛЬКО сразу - не
  # только LAN-мост (обычно br0), но и WAN, и виртуальные интерфейсы
  # xkeen/mihomo (VPN-туннели подписок), которым провайдер вправе выдать
  # что угодно, вплоть до адреса из зарезервированного диапазона вроде
  # 198.51.100.0/24 (RFC 5737) - на практике встречалось. Раньше брали
  # просто первую строку вывода "ip", что зависело от порядка интерфейсов
  # в ядре и могло показать оператору совсем не тот адрес, по которому он
  # реально заходит в браузере. Теперь среди всех найденных адресов
  # приоритет отдаётся частным диапазонам (RFC 1918: 10.0.0.0/8,
  # 172.16.0.0/12, 192.168.0.0/16) - это и есть обычный домашний LAN;
  # если ни одного частного адреса нет (нетипичная сеть) - как и раньше,
  # берём первый попавшийся, чтобы не остаться совсем без адреса.
  #
  # Если определить не удалось совсем - молча печатаем пусто, вызывающий
  # код (ensure_stats_httpd) сам подставит обратно "$STATS_HTTP_BIND" как
  # раньше, чтобы строка не осталась пустой.
  case "$1" in
    0.0.0.0|"") ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  command -v "$STATS_HTTPD_IP_CMD" >/dev/null 2>&1 || return 0
  "$STATS_HTTPD_IP_CMD" -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | awk '
        function is_private(ip,    o, n) {
          n = split(ip, o, ".")
          if (n != 4) return 0
          if (o[1] == 10) return 1
          if (o[1] == 192 && o[2] == 168) return 1
          if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 1
          return 0
        }
        !got_any { first = $0; got_any = 1 }
        is_private($0) && !got_priv { priv = $0; got_priv = 1 }
        END {
          if (got_priv) print priv
          else if (got_any) print first
        }
      '
}

render_stats() {
  ensure_stats_httpd
  statsdir=${STATS_HTML%/*}
  if [ ! -d "$statsdir" ]; then
    say "WARN: каталог $statsdir не найден, stats.html не записан"
    return 0
  fi
  if [ ! -f "$RENDER_STATS" ]; then
    say "WARN: $RENDER_STATS не найден, stats.html не обновлён"
    return 0
  fi
  generated_ts=$(date '+%Y-%m-%d %H:%M:%S')
  if ! awk -v last="$LAST" -v nodes="$HISTORY_NODES" -v cap="$STATS_NODE_CAP" \
       -v stability="$HISTORY_STABILITY" \
       -v generated="$generated_ts" \
       -f "$RENDER_STATS" "$HISTORY_RUNS" > "$WORK/stats.html" 2> "$WORK/stats.err"; then
    say "WARN: render_stats.awk завершился с ошибкой, stats.html не обновлён"
    [ -s "$WORK/stats.err" ] && sed -n '1,3p' "$WORK/stats.err" >> "$RUN_LOG"
    return 0
  fi
  if [ ! -s "$WORK/stats.html" ]; then
    say "WARN: render_stats.awk вернул пустой файл, stats.html не обновлён"
    return 0
  fi
  publish_file "$WORK/stats.html" "$STATS_HTML" || say "WARN: stats.html не записан"

  # stats.json - те же данные для /api/stats (см. шаг 2 SPA-миграции и
  # маршрут "api/stats" в stats_httpd.py) - тот же вход, та же метка
  # времени, что и у stats.html выше, отдельный awk-прогон с -v format=json.
  # Ошибка/пустой результат здесь - только WARN, как и для stats.html:
  # /api/stats на роутерах без python3-бэкенда всё равно не используется,
  # а на новом бэкенде app.js сам покажет отсутствие данных.
  if ! awk -v last="$LAST" -v nodes="$HISTORY_NODES" -v cap="$STATS_NODE_CAP" \
       -v stability="$HISTORY_STABILITY" \
       -v generated="$generated_ts" \
       -v format=json \
       -f "$RENDER_STATS" "$HISTORY_RUNS" > "$WORK/stats.json" 2> "$WORK/stats.json.err"; then
    say "WARN: render_stats.awk (JSON) завершился с ошибкой, stats.json не обновлён"
    [ -s "$WORK/stats.json.err" ] && sed -n '1,3p' "$WORK/stats.json.err" >> "$RUN_LOG"
    return 0
  fi
  if [ ! -s "$WORK/stats.json" ]; then
    say "WARN: render_stats.awk (JSON) вернул пустой файл, stats.json не обновлён"
    return 0
  fi
  publish_file "$WORK/stats.json" "$STATS_JSON" || say "WARN: stats.json не записан"
}

update_node_stability() {
  # Обновляет агрегат стабильности всех нод пула (node_stability.tsv) -
  # источники данных: групповой delay-check шага 4 (map.txt - весь пул,
  # alive.txt - живые + задержка) и speed-тест шага 5 (res.txt - только
  # ноды, реально прошедшие speed-тест в этом прогоне; тестируются не все
  # живые ноды каждый прогон - см. ENOUGH). Вызывается после обоих шагов,
  # до отбора победителей и публикации fast.yaml - статистика стабильности
  # пишется независимо от исхода остальных шагов прогона. Не критично для
  # работы замерщика - любая ошибка здесь WARN в лог, старый файл не
  # трогаем (та же схема, что и у record_history()).
  if [ ! -f "$NODE_STATS_UPDATE" ]; then
    say "WARN: $NODE_STATS_UPDATE не найден, node_stability.tsv не обновлён"
    return 0
  fi
  statold=$HISTORY_STABILITY
  [ -f "$statold" ] || statold=/dev/null
  if ! awk -v iso="$(date '+%Y-%m-%d %H:%M:%S')" -v window_len="$STABILITY_WINDOW" \
       -v drop_after="$STABILITY_DROP_AFTER" -v mapfile="$WORK/map.txt" \
       -v alivefile="$WORK/alive.txt" -v speedfile="$WORK/res.txt" \
       -f "$NODE_STATS_UPDATE" "$statold" \
       > "$WORK/stability.new" 2> "$WORK/stability.err"; then
    say "WARN: node_stats_update.awk завершился с ошибкой, node_stability.tsv не обновлён"
    [ -s "$WORK/stability.err" ] && sed -n '1,3p' "$WORK/stability.err" >> "$RUN_LOG"
    return 0
  fi
  if [ ! -s "$WORK/stability.new" ]; then
    say "WARN: node_stats_update.awk вернул пустой файл, node_stability.tsv не обновлён"
    return 0
  fi
  publish_file "$WORK/stability.new" "$HISTORY_STABILITY" || say "WARN: node_stability.tsv не записан"
}

record_history() {
  # Дописывает сводку прогона в speedtest_runs.tsv и историю нод-победителей
  # в speedtest_history.tsv, применяет ротацию по HISTORY_KEEP_RUNS/HISTORY_KEEP_DAYS,
  # затем перегенерирует stats.html. Вызывается из main() после успешной
  # публикации fast.yaml — сам по себе не критичен для работы замерщика:
  # любая ошибка здесь — WARN в лог, а не остановка.
  channel=$1; threshold=$2; total=$3; alive=$4; tested=$5; good=$6; winners=$7

  if [ "$HISTORY_KEEP_RUNS" = 0 ] && [ "$HISTORY_KEEP_DAYS" = 0 ]; then
    say "WARN: HISTORY_KEEP_RUNS и HISTORY_KEEP_DAYS оба 0, включаю дефолт HISTORY_KEEP_RUNS=200"
    HISTORY_KEEP_RUNS=200
  fi

  ts=$(date +%s)
  iso=$(date '+%Y-%m-%d %H:%M:%S')

  {
    [ -f "$HISTORY_RUNS" ] && cat "$HISTORY_RUNS"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ts" "$iso" "$channel" "$threshold" "$total" "$alive" "$tested" "$good" "$winners"
  } > "$WORK/runs.new"
  trim_runs "$WORK/runs.new" "$WORK/runs.trimmed" "$HISTORY_KEEP_RUNS" "$HISTORY_KEEP_DAYS" "$ts"
  if ! publish_file "$WORK/runs.trimmed" "$HISTORY_RUNS"; then
    say "WARN: speedtest_runs.tsv не записан, статистика прогона потеряна"
    return 0
  fi

  cutoff=$(awk -F'\t' 'NR==1 { print $1; exit }' "$HISTORY_RUNS")

  : > "$WORK/nodes.append"
  if [ -s "$WORK/win.txt" ]; then
    while read -r SP IDX; do
      NM=$(awk -v k="$IDX" -F'\t' '$1 == k {print $2}' "$WORK/map.txt")
      printf '%s\t%s\t%s\n' "$ts" "$SP" "$NM" >> "$WORK/nodes.append"
    done < "$WORK/win.txt"
  fi
  {
    [ -f "$HISTORY_NODES" ] && cat "$HISTORY_NODES"
    cat "$WORK/nodes.append"
  } > "$WORK/nodes.new"
  trim_nodes_since "$WORK/nodes.new" "$WORK/nodes.trimmed" "$cutoff"
  if ! publish_file "$WORK/nodes.trimmed" "$HISTORY_NODES"; then
    say "WARN: speedtest_history.tsv не записан, история нод потеряна"
  fi

  render_stats
}

looks_like_clash_yaml() {
  grep -Eq '^proxies:[[:space:]]*$' "$1" 2>/dev/null
}

validate_provider() {
  conv_file=$1
  {
    echo "mixed-port: $MIXED_PORT"
    echo "external-controller: $API"
    echo "log-level: silent"
    echo "mode: rule"
    cat "$conv_file"
    echo "proxy-groups:"
    echo "  - name: T"
    echo "    type: select"
    echo "    include-all-proxies: true"
    echo "rules:"
    echo "  - MATCH,T"
  } > "$WORK/provcheck.yaml"
  "$BIN" -t -d "$WORK" -f "$WORK/provcheck.yaml" > "$WORK/provcheck.log" 2>&1
}

convert_source() {
  src=$1
  if looks_like_clash_yaml "$src"; then
    printf '%s\n' "$src"
    return 0
  fi
  base=$(basename "$src")
  decoded="$WORK/subdec-$base.txt"
  if ! base64 -d "$src" > "$decoded" 2>/dev/null || [ ! -s "$decoded" ]; then
    if ! openssl base64 -d -A -in "$src" > "$decoded" 2>/dev/null || [ ! -s "$decoded" ]; then
      say "WARN: источник $src не похож ни на clash-yaml, ни на base64-подписку, пропускаю"
      return 1
    fi
  fi
  first=$(sed -n '1p' "$decoded")
  case "$first" in
    vless://*) ;;
    *) say "WARN: источник $src раскодирован, но не похож на vless-подписку, пропускаю"; return 1 ;;
  esac
  conv="$WORK/subconv-$base.yaml"
  LC_ALL=C awk -f "$SUB_CONVERT" "$decoded" > "$conv" 2> "$WORK/subconv-$base.log"
  n_converted=$(sed -n 's/.*converted=\([0-9]*\).*/\1/p' "$WORK/subconv-$base.log")
  if [ -z "${n_converted:-}" ] || [ "$n_converted" -eq 0 ]; then
    say "WARN: из $src не удалось получить ни одной ноды, пропускаю"
    return 1
  fi
  if ! validate_provider "$conv"; then
    say "WARN: конфиг из $src не прошёл проверку \$BIN -t, пропускаю весь провайдер"
    tail -3 "$WORK/provcheck.log" >> "$RUN_LOG"
    return 1
  fi
  printf '%s\n' "$conv"
  return 0
}

prepare_nodes() {
  conv_sources=""
  for src in $SOURCES; do
    csrc=$(convert_source "$src") || continue
    conv_sources="$conv_sources $csrc"
  done
  if [ -z "$conv_sources" ]; then
    say "WARN: ни один источник не прошёл проверку/конвертацию, пул пуст"
    : > "$WORK/all.yaml"
    echo 0 > "$WORK/cnt.txt"
    return 0
  fi
  awk -v NODEDIR="$WORK/nodes" -v MAPFILE="$WORK/map.txt" \
      -v CNTFILE="$WORK/cnt.txt" -v BLOCK="$BLOCK" -v EXTYPE="$EXTYPE" \
      -f "$PREP" $conv_sources > "$WORK/all.yaml" 2> "$WORK/prep.err"
}

reload_provider() {
  curl -f -s -m 10 -X PUT "http://$API_MAIN/providers/proxies/fast" >/dev/null 2>&1
}

# timeout=20000: при большом пуле (160+ нод, все проверяются одним
# параллельным запросом) роутер не успевает поднять все TLS-соединения
# за 5 секунд - mihomo возвращает 504 "all proxies timeout" на весь
# групповой запрос целиком, а не только для медленных нод. 20 секунд -
# временный запас, подобранный опытным путём под текущий размер пула;
# при дальнейшем росте пула стоит разбивать проверку на батчи вместо
# дальнейшего повышения этого числа.
fetch_delays() {
  curl -f -s -m 60 "http://$API/group/T/delay?url=$DELAY_URL&timeout=20000" \
       -o "$WORK/delay.json" 2>/dev/null
}

select_proxy() {
  idx=$1
  curl -f -s -m 3 -X PUT -H 'Content-Type: application/json' \
       --data-binary "{\"name\":\"$idx\"}" "http://$API/proxies/T" >/dev/null 2>&1
}

normalize_speed() {
  speed=${1%%.*}
  case $speed in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$speed" ;;
  esac
}

accepted_speed() {
  http_status=$1
  raw_speed=$2
  case $http_status in
    2[0-9][0-9]) normalize_speed "$raw_speed" ;;
    *) echo 0 ;;
  esac
}

compute_threshold() {
  channel=$1
  awk -v c="$channel" -v r="$MIN_RATIO" -v f="$MIN_FLOOR" 'BEGIN {
    t = int(c * r)
    print (t > f) ? t : f
  }'
}

measure_direct() {
  METRICS=$(curl -s -m "$DL_TIMEOUT" -o /dev/null -w '%{http_code} %{speed_download}' \
            "$SPEED_URL" 2>/dev/null) || METRICS=""
  HTTP_STATUS=${METRICS%% *}
  SP_RAW=${METRICS#* }
  accepted_speed "$HTTP_STATUS" "$SP_RAW"
}

cleanup() {
  trap - EXIT INT TERM
  if [ -n "$MPID" ]; then
    kill "$MPID" 2>/dev/null || true
    wait "$MPID" 2>/dev/null || true
    MPID=
  fi
  flush_log 2>/dev/null || true
  [ -n "$PUBLISH_TMP" ] && rm -f "$PUBLISH_TMP"
  [ -n "$WORK" ] && rm -rf "$WORK"
  if [ "$LOCK_HELD" = 1 ]; then
    rm -rf "$LOCK"
    LOCK_HELD=0
  fi
}

main() {
if [ -z "$BLOCK" ]; then
  say "WARN: BLOCK не задан; запустите install.sh для создания speedtest2.env"
  return 1
fi
if ! acquire_lock; then
  OLD=$(cat "$LOCK/pid" 2>/dev/null)
  say "WARN: уже выполняется${OLD:+ (pid $OLD)}, выхожу"
  return 0
fi
install_traps

if ! mkdir -p "$WORK/nodes"; then
  say "WARN: не удалось создать временный каталог $WORK"
  return 0
fi
echo "=== $(date) start ===" >> "$RUN_LOG"

# 1. разбор кэшей провайдеров: ноды по файлам + конфиг с техническими именами
if ! prepare_nodes; then
  say "WARN: prep.awk не разобрал входной YAML, fast.yaml не трогаю"
  [ -s "$WORK/prep.err" ] && sed -n '1,3p' "$WORK/prep.err" >> "$RUN_LOG"
  exit 0
fi
TOTAL=$(cat "$WORK/cnt.txt" 2>/dev/null)
[ -z "$TOTAL" ] && TOTAL=0
if [ "$TOTAL" -lt 1 ]; then
  say "WARN: ни одной ноды не разобрано, fast.yaml не трогаю"; exit 0
fi

# 2. конфиг для тестового ядра
{
  echo "mixed-port: $MIXED_PORT"
  echo "external-controller: $API"
  echo "log-level: silent"
  echo "mode: rule"
  echo "proxies:"
  cat "$WORK/all.yaml"
  echo "proxy-groups:"
  echo "  - name: T"
  echo "    type: select"
  echo "    include-all-proxies: true"
  echo "rules:"
  echo "  - MATCH,T"
} > "$WORK/config.yaml"

if ! "$BIN" -t -d "$WORK" -f "$WORK/config.yaml" > "$WORK/test.log" 2>&1; then
  say "WARN: тестовый конфиг не прошёл валидацию, fast.yaml не трогаю"
  tail -3 "$WORK/test.log" >> "$RUN_LOG"; exit 0
fi

# 3. поднять тестовое ядро
"$BIN" -d "$WORK" > "$WORK/run.log" 2>&1 &
MPID=$!
i=0
while [ $i -lt 20 ]; do
  curl -s -m 2 "http://$API/version" > /dev/null 2>&1 && break
  sleep 1; i=$((i+1))
done
if ! curl -s -m 2 "http://$API/version" > /dev/null 2>&1; then
  say "WARN: тестовое ядро не поднялось, fast.yaml не трогаю"; exit 0
fi

# 4. отсев мёртвых одним групповым запросом (ядро проверяет ноды параллельно)
if ! fetch_delays; then
  say "WARN: групповая проверка задержки не выполнена, fast.yaml не трогаю"
  exit 0
fi
tr ',' '\n' < "$WORK/delay.json" | sed -n 's/.*"\(n[0-9]\{4\}\)":\([0-9]*\).*/\2 \1/p' | sort -n > "$WORK/alive.txt"
ALIVE=$(wc -l < "$WORK/alive.txt")
say "нод в пуле: $TOTAL, живых: $ALIVE"
: > "$WORK/res.txt"
if [ "$ALIVE" -lt 1 ]; then
  update_node_stability
  say "WARN: живых нод нет, fast.yaml не трогаю"; exit 0
fi

# 5. замер скорости: живые по возрастанию задержки, пока не наберём ENOUGH выше порога
CHANNEL=$(measure_direct)
if [ "$CHANNEL" -gt 0 ] 2>/dev/null; then
  EFFECTIVE_MIN=$(compute_threshold "$CHANNEL")
  say "канал: $((CHANNEL/1048576)) МБ/с, порог: $((EFFECTIVE_MIN/1048576)) МБ/с"
else
  EFFECTIVE_MIN=$MIN_SPEED
  say "WARN: прямой замер канала не удался, порог из настроек: $((EFFECTIVE_MIN/1048576)) МБ/с"
fi
GOOD=0
: > "$WORK/good_names.txt"
while read -r D IDX; do
  select_proxy "$IDX" || continue
  METRICS=$(curl -s -m "$DL_TIMEOUT" -o /dev/null -w '%{http_code} %{speed_download}' \
            -x "http://127.0.0.1:$MIXED_PORT" "$SPEED_URL" 2>/dev/null)
  HTTP_STATUS=${METRICS%% *}
  SP_RAW=${METRICS#* }
  SP=$(accepted_speed "$HTTP_STATUS" "$SP_RAW")
  echo "$SP $IDX" >> "$WORK/res.txt"
  NM=$(awk -v k="$IDX" -F'	' '$1 == k {print $2}' "$WORK/map.txt")
  echo "$((SP/1048576)).$(( (SP%1048576)*10/1048576 ))	МБ/с	$NM" >> "$WORK/full.txt"
  [ "$FORCE" = 1 ] && say "  $((SP/1048576)).$(( (SP%1048576)*10/1048576 )) МБ/с  $NM"
  if [ "$SP" -ge "$EFFECTIVE_MIN" ] && remember_name "$NM" "$WORK/good_names.txt"; then
    GOOD=$((GOOD+1))
    [ "$GOOD" -ge "$ENOUGH" ] && break
  fi
done < "$WORK/alive.txt"
update_node_stability

# 6. отбор победителей и сборка fast.yaml
select_winners "$WORK/res.txt" "$WORK/map.txt" "$WORK/win.txt" "$EFFECTIVE_MIN" "$TOPN" "$MIN_WINNERS"
WIN=$(wc -l < "$WORK/win.txt")
BELOW_MIN=$(awk -v m="$EFFECTIVE_MIN" '$1 < m { c++ } END { print c + 0 }' "$WORK/win.txt")
if [ "$WIN" -lt 1 ]; then
  say "WARN: порог $((EFFECTIVE_MIN/1048576)) МБ/с не прошёл никто, оставляю прежний fast.yaml"
  best_line=$(sort -rn "$WORK/res.txt" | head -1)
  best_sp=${best_line%% *}
  best_idx=${best_line#* }
  best_nm=$(awk -v k="$best_idx" -F'\t' '$1 == k {print $2}' "$WORK/map.txt")
  say "лучший результат: $((best_sp/1048576)).$(( (best_sp%1048576)*10/1048576 )) МБ/с  $best_nm"
  exit 0
fi

echo "proxies:" > "$WORK/fast.new"
while read -r SP IDX; do
  NAME=$(awk -v k="$IDX" -F'\t' '$1 == k {print $2}' "$WORK/map.txt")
  cat "$WORK/nodes/$IDX.yaml" >> "$WORK/fast.new"
  say "  $((SP/1048576)).$(( (SP%1048576)*10/1048576 )) МБ/с  $NAME"
done < "$WORK/win.txt"

# 7. проверить, что собранное читается
{
  echo "mixed-port: 7893"; echo "mode: rule"
  cat "$WORK/fast.new"
  echo "proxy-groups:"; echo "  - name: C"; echo "    type: select"; echo "    include-all-proxies: true"
  echo "rules:"; echo "  - MATCH,C"
} > "$WORK/check.yaml"
if ! "$BIN" -t -d "$WORK" -f "$WORK/check.yaml" > "$WORK/check.log" 2>&1; then
  say "WARN: собранный fast.yaml не проходит валидацию, оставляю прежний"
  tail -3 "$WORK/check.log" >> "$RUN_LOG"; exit 0
fi

# 8. подменить и перечитать провайдер в боевом ядре
if ! publish_fast "$WORK/fast.new" "$OUT"; then
  say "WARN: fast.yaml не записан, прежний файл сохранён"
  exit 0
fi
sort -rn -k1 "$WORK/full.txt" > "$WORK/last.new" 2>/dev/null
if ! publish_file "$WORK/last.new" "$LAST"; then
  say "WARN: speedtest_last.txt не записан, прежний файл сохранён"
fi
below_note=""
[ "$BELOW_MIN" -gt 0 ] && below_note=" (из них $BELOW_MIN ниже порога скорости - набрано до минимума $MIN_WINNERS)"
if reload_provider; then
  say "OK: $WIN нод -> fast.yaml (проверено $(wc -l < "$WORK/res.txt") из $ALIVE живых, провайдер перечитан)$below_note"
elif [ "$FAST_CHANGED" = 1 ]; then
  say "WARN: fast.yaml обновлён, провайдер не перечитан"
else
  say "WARN: fast.yaml не изменился, провайдер не перечитан"
fi

record_history "$CHANNEL" "$EFFECTIVE_MIN" "$TOTAL" "$ALIVE" "$(wc -l < "$WORK/res.txt" | tr -d ' ')" "$GOOD" "$WIN"
}

update_http_get() {
  # $1 = URL. Печатает тело ответа в stdout при успехе, ничего и код !=0
  # при ошибке (сеть, таймаут, HTTP-ошибка). UPDATE_HTTP_CMD переопределяет
  # инструмент загрузки целиком - для тестов и нестандартных прошивок, где
  # не годится ни curl, ни busybox wget.
  url=$1
  if [ -n "$UPDATE_HTTP_CMD" ]; then
    $UPDATE_HTTP_CMD "$url"
    return $?
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time "$UPDATE_HTTP_TIMEOUT" "$url"
    return $?
  fi
  if command -v busybox >/dev/null 2>&1; then
    busybox wget -q -T "$UPDATE_HTTP_TIMEOUT" -O - "$url"
    return $?
  fi
  return 127
}

fetch_from_source_or_mirror() {
  # $1=путь относительно UPDATE_SOURCE_BASE/UPDATE_MIRROR_BASE (например,
  # "VERSIONS" или "speedtest2.sh"). Основной источник, при неудаче -
  # зеркало. Печатает содержимое в stdout при успехе, иначе ничего и
  # возврат 1 - обе попытки не удались.
  relpath=$1
  body=$(update_http_get "$UPDATE_SOURCE_BASE/$relpath" 2>/dev/null) || body=""
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
    return 0
  fi
  body=$(update_http_get "$UPDATE_MIRROR_BASE/$relpath" 2>/dev/null) || body=""
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
    return 0
  fi
  return 1
}

fetch_versions_manifest() {
  fetch_from_source_or_mirror VERSIONS
}

parse_manifest_version() {
  # $1=содержимое VERSIONS, $2=имя (CORE_VERSION|STATS_VERSION). Строгий
  # разбор одной строки "ИМЯ=число" через sed - никогда не через eval/
  # source, т.к. VERSIONS приходит с внешнего сервера и не должен
  # исполняться как код.
  content=$1; name=$2
  val=$(printf '%s\n' "$content" | sed -n "s/^$name=\\([0-9][0-9]*\\)\$/\\1/p" | head -n 1)
  [ -n "$val" ] || return 1
  printf '%s' "$val"
}

report_update_component() {
  # $1=имя компонента (для сообщения), $2=текущая версия, $3=версия с
  # сервера (пусто, если строка не найдена/битая в VERSIONS).
  label=$1; cur=$2; remote=$3
  if [ -z "$remote" ]; then
    say "WARN: $label - версия на сервере не распознана в VERSIONS, сравнение пропущено"
    return 0
  fi
  if [ "$remote" -gt "$cur" ] 2>/dev/null; then
    say "$label: установлена версия $cur, доступна $remote"
  else
    say "$label: установлена версия $cur, это актуально (на сервере: $remote)"
  fi
}

check_update() {
  # Точка входа для --check-update: ничего не меняет на диске, только
  # печатает/логирует, что core/stats устарели относительно VERSIONS из
  # репозитория. По расписанию (cron) не вызывается - только руками.
  manifest=$(fetch_versions_manifest) || manifest=""
  if [ -z "$manifest" ]; then
    say "WARN: не удалось получить VERSIONS ни с $UPDATE_SOURCE_BASE, ни с зеркала $UPDATE_MIRROR_BASE - проверьте сеть роутера"
    return 1
  fi
  remote_core=$(parse_manifest_version "$manifest" CORE_VERSION) || remote_core=""
  remote_stats=$(parse_manifest_version "$manifest" STATS_VERSION) || remote_stats=""
  if [ -z "$remote_core" ] && [ -z "$remote_stats" ]; then
    say "WARN: файл VERSIONS получен, но не содержит распознаваемых строк CORE_VERSION=/STATS_VERSION="
    return 1
  fi
  report_update_component core "$CORE_VERSION" "$remote_core"
  report_update_component stats "$STATS_VERSION" "$remote_stats"
}

update_component_files() {
  # $1=метка компонента (для сообщений в лог), далее пары вида
  # "относительный_путь_на_сервере:локальный_путь_назначения". Всё-или-
  # ничего: сначала скачивает и проверяет КАЖДЫЙ файл во временный
  # каталог, и только если все прошли - переносит их на место (с бэкапом
  # прежних версий рядом, "*.bak-ГГГГММДДЧЧММСС"). Любая неудача на этапе
  # скачивания/проверки прерывает всё обновление до единой записи на диск.
  # Проверка синтаксиса - не проверка подлинности (подписи нет, см.
  # TODO.md): просто защита от случайно битого/усечённого файла.
  label=$1; shift
  update_tmp=$(mktemp -d "${TMPROOT:-/tmp}/mst-update.XXXXXX" 2>/dev/null) || {
    say "WARN: $label - не удалось создать временный каталог, обновление не выполнено"
    return 1
  }
  ok=1
  for pair in "$@"; do
    remote=${pair%%:*}
    if ! body=$(fetch_from_source_or_mirror "$remote"); then
      say "WARN: $label - не удалось скачать $remote ни с $UPDATE_SOURCE_BASE, ни с зеркала $UPDATE_MIRROR_BASE - обновление не выполнено"
      ok=0
      break
    fi
    if ! printf '%s\n' "$body" > "$update_tmp/$remote" 2>/dev/null; then
      say "WARN: $label - не удалось записать $remote во временный каталог - обновление не выполнено"
      ok=0
      break
    fi
    case $remote in
      *.sh)
        if ! sh -n "$update_tmp/$remote" 2>/dev/null; then
          say "WARN: $label - $remote не прошёл проверку синтаксиса (sh -n) - обновление не выполнено"
          ok=0
          break
        fi
        ;;
      *.awk)
        if ! awk -f "$update_tmp/$remote" /dev/null >/dev/null 2>&1; then
          say "WARN: $label - $remote не прошёл проверку синтаксиса (awk) - обновление не выполнено"
          ok=0
          break
        fi
        ;;
      *.py)
        # Только если python3 вообще есть - на роутере он опционален (см.
        # STATS_HTTPD_PY выше, резервный busybox httpd без него), отсутствие
        # интерпретатора само по себе не повод браковать обновление.
        if command -v python3 >/dev/null 2>&1 && ! python3 -m py_compile "$update_tmp/$remote" 2>/dev/null; then
          say "WARN: $label - $remote не прошёл проверку синтаксиса (python3 -m py_compile) - обновление не выполнено"
          ok=0
          break
        fi
        ;;
    esac
  done
  if [ "$ok" != 1 ]; then
    rm -rf "$update_tmp"
    return 1
  fi
  stamp=$(date '+%Y%m%d%H%M%S')
  for pair in "$@"; do
    remote=${pair%%:*}
    dest=${pair#*:}
    if [ -f "$dest" ]; then
      cp "$dest" "$dest.bak-$stamp" 2>/dev/null \
        || say "WARN: $label - не удалось сохранить резервную копию $dest (обновление продолжается)"
    fi
    if mv "$update_tmp/$remote" "$dest"; then
      case $dest in
        *.sh) chmod +x "$dest" 2>/dev/null || true ;;
      esac
    else
      say "WARN: $label - не удалось заменить $dest - часть файлов уже могла обновиться, проверьте вручную"
      ok=0
    fi
  done
  rm -rf "$update_tmp"
  if [ "$ok" = 1 ]; then
    say "OK: $label обновлён (резервные копии - рядом с исходными файлами, *.bak-$stamp)"
    return 0
  fi
  return 1
}

update_core() {
  # Точка входа для --update-core. Обновляет весь набор целиком (см.
  # README) - speedtest2.sh, install.sh, setup.sh и весь их
  # вспомогательный инструментарий (version_check.sh, detect_ua.sh,
  # render_config.awk, existing_config.awk, config.example.yaml),
  # prep.awk, providers.awk, node_stats_update.awk, sub_convert.awk. Ни
  # один из этих файлов не запускается как постоянный сервис - для них
  # не нужен перезапуск (в отличие от update_stats(), см.
  # apply_stats_update()), т.к. каждый вызывается заново с диска при
  # следующем запуске (cron/--force для speedtest2.sh, руками для
  # install.sh/setup.sh). Изменения вступают в силу со следующего
  # запуска - текущий процесс (если что-то его всё же вызвало) доработает
  # со старым кодом.
  update_component_files core \
    "speedtest2.sh:$UPDATE_SELF_SCRIPT" \
    "install.sh:$UPDATE_INSTALL_SH" \
    "setup.sh:$UPDATE_SETUP_SH" \
    "version_check.sh:$UPDATE_VERSION_CHECK_SH" \
    "detect_ua.sh:$UPDATE_DETECT_UA_SH" \
    "render_config.awk:$UPDATE_RENDER_CONFIG_AWK" \
    "existing_config.awk:$UPDATE_EXISTING_CONFIG_AWK" \
    "config.example.yaml:$UPDATE_CONFIG_EXAMPLE_YAML" \
    "prep.awk:$PREP" \
    "providers.awk:$UPDATE_PROVIDERS_AWK" \
    "node_stats_update.awk:$NODE_STATS_UPDATE" \
    "sub_convert.awk:$SUB_CONVERT"
  rc=$?
  if [ "$rc" = 0 ]; then
    say "core: изменения вступят в силу со следующего запуска (cron или speedtest2.sh --force)"
  fi
  return $rc
}

apply_stats_update() {
  # После успешного обновления stats-файлов - перегенерировать stats.html
  # и переподнять веб-сервис немедленно, не дожидаясь cron. Тот же приём,
  # что stats_cgi.sh использует после сохранения формы настройки.
  # stop_stats_httpd() перед ensure_stats_httpd() - обязательно: сама
  # ensure_stats_httpd() перезапускает процесс только при смене
  # адреса/порта/пароля (см. её же комментарий), а не при изменении кода -
  # без явной остановки здесь обновлённый stats_httpd.py просто продолжит
  # молча работать под старым, уже запущенным процессом до следующего
  # ручного вмешательства (ровно так и вышло один раз вручную в этом
  # проекте - см. CHANGELOG.md).
  WORK=$(mktemp -d "${TMPROOT:-/tmp}/mst-apply.XXXXXX" 2>/dev/null) || WORK=${TMPROOT:-/tmp}/mst-apply.$$
  mkdir -p "$WORK" 2>/dev/null
  render_stats
  stop_stats_httpd
  ensure_stats_httpd
  rm -rf "$WORK"
}

update_stats() {
  # Точка входа для --update-stats. Все файлы веб-сервиса статистики
  # обновляются вместе одним "всё-или-ничего" набором (см.
  # update_component_files()) - и старый server-rendered путь
  # (render_stats.awk/stats_cgi.sh), и SPA-shell (stats_index.html/
  # stats_style.css/stats_app.js/stats_chart.js), и сам веб-сервер
  # (stats_httpd.py/stats_run.sh) - разносить их по отдельным командам
  # смысла нет, все меняются вместе при доработке раздела "Статистика".
  if ! update_component_files stats \
      "render_stats.awk:$RENDER_STATS" \
      "stats_cgi.sh:$STATS_CGI_SOURCE" \
      "stats_run.sh:$STATS_RUN_SOURCE" \
      "stats_httpd.py:$STATS_HTTPD_PY" \
      "stats_index.html:$STATS_INDEX_SOURCE" \
      "stats_style.css:$STATS_STYLE_SOURCE" \
      "stats_app.js:$STATS_APP_SOURCE" \
      "stats_chart.js:$STATS_CHARTJS_SOURCE"; then
    return 1
  fi
  apply_stats_update
}

parse_args() {
  for _arg in "$@"; do
    case $_arg in
      --force) FORCE=1 ;;
      --check-update) CHECK_UPDATE=1 ;;
      --update-core) UPDATE_CORE=1 ;;
      --update-stats) UPDATE_STATS=1 ;;
    esac
  done
}

if [ "${MST_LIB_ONLY:-0}" != 1 ]; then
  parse_args "$@"
  if [ "$CHECK_UPDATE" = 1 ] || [ "$UPDATE_CORE" = 1 ] || [ "$UPDATE_STATS" = 1 ]; then
    FORCE=1
  fi
  if [ "$CHECK_UPDATE" = 1 ]; then
    check_update
  elif [ "$UPDATE_CORE" = 1 ]; then
    update_core
  elif [ "$UPDATE_STATS" = 1 ]; then
    update_stats
  else
    main "$@"
  fi
fi
