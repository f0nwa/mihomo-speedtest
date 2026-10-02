#!/bin/sh
# Замер скорости нод на собственном ядре mihomo -> fast.yaml. Запуск по cron.
# В отличие от clash-speedtest тестирует ВСЕ транспорты, которые понимает установленный mihomo
# (xhttp, hysteria2, AmneziaWG и прочее): поднимает второй экземпляр на своих портах,
# переключает селектор через API и качает файл через локальный прокси.

DIR=${DIR:-/opt/etc/mihomo-speedtest}
MIHOMO_DIR=${MIHOMO_DIR:-/opt/etc/mihomo}
PROV=${PROV:-$MIHOMO_DIR/proxy-providers}
SOURCES=${SOURCES:-"$MIHOMO_DIR/config.yaml"}   # установщик добавляет кэши провайдеров через speedtest2.env
OUT=${OUT:-$MIHOMO_DIR/fast.yaml}
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
MPID=
PUBLISH_TMP=
PROGRESS_ACTIVE=0   # 1, когда цикл шага 5 (write_progress) начат в этом прогоне - см. cleanup()
RUN_LOG=${RUN_LOG:-$WORK/speedtest.log}
LOG_LIMIT=${LOG_LIMIT:-102400}
LOG_FLUSHED=0
# Живой журнал для вкладки «Журнал» веб-интерфейса. Пока страница открыта,
# stats_httpd.py держит в LIVE_LOG_DIR свежий файл-маркер viewer, и say()
# дублирует каждую строку в live.log. Без маркера say() в каталог не пишет
# вовсе. Всё живёт только в /tmp (tmpfs), в /opt ничего не пишется; размер
# ограничивает и удаляет файлы после ухода зрителя сам stats_httpd.py.
# LOG_TAG - метка источника строки в живом журнале; скрипты, подключающие
# этот файл как библиотеку (stats_service.sh, stats_cgi.sh), переопределяют
# её после подключения, не экспортируя.
LIVE_LOG_DIR=${LIVE_LOG_DIR:-$TMPROOT/mihomo-speedtest-live}
LIVE_LOG=$LIVE_LOG_DIR/live.log
LIVE_LOG_VIEWER=$LIVE_LOG_DIR/viewer
LOG_TAG=speedtest

MIXED_PORT=7899
API=127.0.0.1:9099
API_MAIN=127.0.0.1:9090   # уточняется по external-controller рабочего конфига, см. main_api_init()
# WireGuard/AmneziaWG (один ключ - один клиент) проверяются не во втором ядре,
# а на уже работающем экземпляре ноды в основном: служебная группа и вход
# из config.example.yaml (порция 1 плана 2026-09-28-wg-main-core-speedtest).
WG_GROUP=MST-SPEEDTEST
WG_FAST_GROUP=MST-FAST-WG   # победитель среди WG/AWG - участник '⚡ Быстрый пул'
WG_LISTENER=mst-speedtest
WG_PORT=7896
MAIN_CONFIG=${MAIN_CONFIG:-$MIHOMO_DIR/config.yaml}
MAIN_CURL_CFG=
MAIN_API_OK=0

SIZE=10485760         # сколько качать с каждой ноды, байт. Меньше 10 МБ занижает: на 3 МБ
                      # треть времени уходит на TTFB и та же нода показывает 4.5 вместо 12 МБ/с
DL_TIMEOUT=15         # потолок на одну закачку, секунд
MIN_SPEED=1048576     # порог отбора, байт/с (1 МБ/с для текущего канала)
MIN_RATIO=0.25         # динамический порог = доля от прямого канала
MIN_FLOOR=524288       # абсолютный минимум порога, байт/с (0.5 МиБ/с)
TOPN=15               # сколько нод класть в fast.yaml
ENOUGH=20             # набрали столько выше порога - дальше не меряем
MAX_TESTED=40         # максимум кандидатов на загрузку; 0 = без ограничения
MIN_WINNERS=3         # минимум нод в fast.yaml, если есть из кого выбрать - см. select_winners()
DELAY_BATCH_SIZE=10   # сколько нод одновременно проверяет второе ядро
DELAY_TIMEOUT_MS=5000 # таймаут одной ноды внутри небольшой пакетной группы
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

STATS_JSON=${STATS_JSON:-$DIR/stats_www/stats.json}   # данные статистики (render_stats.awk) - раздаётся веб-сервисом как /api/stats
STATS_HTML=${STATS_HTML:-$DIR/stats_www/stats.html}   # устаревшая HTML-страница (удалена 2026-09-28): больше не пишется, render_stats() удаляет оставшуюся от старых версий
RENDER_STATS=${RENDER_STATS:-$DIR/render_stats.awk}
STATS_PROGRESS=${STATS_PROGRESS:-$DIR/stats_www/progress.json}   # прогресс скоростного теста по нодам текущего прогона (см. write_progress() ниже) - шаг 1 задачи "видно по нодам при прогоне", пока без раздачи через веб-сервис (см. TODO.md)
RENDER_PROGRESS=${RENDER_PROGRESS:-$DIR/render_progress.awk}
STATS_HTTP_ENABLE=${STATS_HTTP_ENABLE:-1}          # 1 = поднимать отдельный веб-сервис со статистикой, 0 = только писать файл
STATS_HTTP_BIND=${STATS_HTTP_BIND:-0.0.0.0}        # адрес привязки (0.0.0.0 = вся локальная сеть, как и 9090)
STATS_HTTP_PORT=${STATS_HTTP_PORT:-8899}           # порт веб-сервиса статистики; должен быть свободен (не 5000/5001/9090)
STATS_HTTP_DIR=${STATS_HTTP_DIR:-$DIR/stats_www}   # данные веб-интерфейса (stats.json, progress.json); создаётся сам
STATS_HTTP_PIDFILE=${STATS_HTTP_PIDFILE:-$DIR/stats_httpd.pid}
STATS_HTTP_LOG=${STATS_HTTP_LOG:-$DIR/stats_httpd.log}
STATS_HTTPD_PY=${STATS_HTTPD_PY:-$DIR/stats_httpd.py}   # обязательный сервер на Python 3: чистые URL, API и общая авторизация
STATS_HTTPD_PY_CMD=${STATS_HTTPD_PY_CMD:-python3}       # интерпретатор для основного сервера
STATS_NODE_CAP=${STATS_NODE_CAP:-8}                 # сколько нод графика по нодам показывать сразу, 1..50 (см. render_stats.awk)
STATS_SERVICE=${STATS_SERVICE:-$DIR/stats_service.sh}               # порция 3: независимый supervisor (см. design), ставится install.sh
STATS_INIT_SCRIPT=${STATS_INIT_SCRIPT:-/opt/etc/init.d/S80speedtest-stats}  # порция 3: Entware init-скрипт независимой службы, ставится install.sh

# providers.awk - разбор блоков подписок из config.yaml. Имя переменной
# историческое (осталось от удалённого самообновления --update-core); её
# читает stats_cgi.sh после подключения этого файла (кандидаты для
# гео-фильтра спидтеста), поэтому имя не меняется.
UPDATE_PROVIDERS_AWK=${UPDATE_PROVIDERS_AWK:-$DIR/providers.awk}

ENV=${ENV:-$DIR/speedtest2.env}
[ -f "$ENV" ] && . "$ENV"
SPEED_URL="https://speed.cloudflare.com/__down?bytes=$SIZE"  # см. комментарий у DELAY_URL выше

# Скорости curl и история хранятся в байтах/с; журнал показывает Мбит/с.
# Расчёт в awk без умножения в shell исключает переполнение на 32-битных роутерах.
format_mbit() {
  LC_ALL=C awk -v speed="$1" 'BEGIN { printf "%.1f", speed / 125000 }'
}

say() {
  log_line="$(date '+%H:%M:%S') $*"
  [ "$FORCE" = 1 ] && echo "$log_line"
  run_dir=${RUN_LOG%/*}
  if [ -d "$run_dir" ]; then
    echo "$log_line" >> "$RUN_LOG"
  else
    echo "$log_line" >> "$LOG" 2>/dev/null || echo "$log_line" >&2
  fi
  if [ -f "$LIVE_LOG_VIEWER" ]; then
    echo "${log_line%% *} [$LOG_TAG] $*" >> "$LIVE_LOG" 2>/dev/null || :
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
        say "force: Забираю зависшую блокировку (pid $old_pid не отвечает)"
        rm -rf "$LOCK"
        continue
      fi
      if [ "$waited" -ge "$FORCE_WAIT" ]; then
        say "WARN: force -- блокировка занята${old_pid:+ (pid $old_pid)} дольше ${FORCE_WAIT}с, выхожу"
        return 1
      fi
      [ "$waited" -eq 0 ] && say "force: Блокировка занята${old_pid:+ (pid $old_pid)}, жду освобождения..."
      sleep 2
      waited=$((waited + 2))
    done
  else
    if ! mkdir "$LOCK" 2>/dev/null; then
      # Блокировку от убитого kill -9/OOM прогона забираем, иначе все
      # следующие прогоны по cron выходили бы до перезагрузки роутера.
      old_pid=$(cat "$LOCK/pid" 2>/dev/null)
      [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null || return 1
      say "Забираю зависшую блокировку (pid $old_pid не отвечает)"
      rm -rf "$LOCK"
      mkdir "$LOCK" 2>/dev/null || return 1
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

write_progress() {
  # Прогресс скоростного теста по нодам ТЕКУЩЕГО прогона - шаг 1 задачи
  # "видно по нодам при прогоне" (пока только пишет файл, без раздачи
  # через веб-сервис и без страницы - следующие шаги отдельными
  # коммитами). Источник - $WORK/progress.tsv, накапливается построчно в
  # цикле шага 5 ниже (по одной строке на протестированную ноду). $1 - 1,
  # пока цикл ещё идёт (вызов после каждой ноды и один раз перед циклом с
  # пустым progress.tsv), 0 - финальный вызов (сразу после цикла и
  # повторно, для надёжности, из cleanup() перед удалением $WORK - см. её
  # комментарий про early-exit/INT/TERM). Не критично для работы
  # замерщика - любая ошибка здесь WARN, publish_fast/fast.yaml не
  # трогает - та же схема, что и у update_node_stability()/render_stats().
  # kill -9 (в отличие от INT/TERM) обычным trap не перехватить - тогда
  # файл так и останется running:true до следующего прогона, то же
  # ограничение, что и у lock-файла в acquire_lock().
  progress_running=$1
  if [ ! -f "$RENDER_PROGRESS" ]; then
    say "WARN: $RENDER_PROGRESS не найден, progress.json не обновлён"
    return 0
  fi
  progressdir=${STATS_PROGRESS%/*}
  if [ ! -d "$progressdir" ] && ! mkdir -p "$progressdir" 2>/dev/null; then
    say "WARN: Не удалось создать $progressdir, progress.json не обновлён"
    return 0
  fi
  if ! awk -v running="$progress_running" -v total="${PROGRESS_TOTAL:-0}" \
       -v started_iso="${PROGRESS_STARTED_ISO:-}" -v updated_iso="$(date '+%Y-%m-%d %H:%M:%S')" \
       -f "$RENDER_PROGRESS" "$WORK/progress.tsv" \
       > "$WORK/progress.new" 2> "$WORK/progress.err"; then
    say "WARN: render_progress.awk завершился с ошибкой, progress.json не обновлён"
    [ -s "$WORK/progress.err" ] && sed -n '1,3p' "$WORK/progress.err" >> "$RUN_LOG"
    return 0
  fi
  publish_file "$WORK/progress.new" "$STATS_PROGRESS" || say "WARN: progress.json не записан"
}

remember_name() {
  name=$1
  seen_file=$2
  if grep -qxF "$name" "$seen_file" 2>/dev/null; then
    return 1
  fi
  echo "$name" >> "$seen_file"
}

select_candidates() {
  # Вход: техническое время ответа и имя. Число приходит от второго,
  # только что запущенного ядра под массовой нагрузкой и не сопоставимо с
  # пингом рабочего Mihomo, поэтому служит только для сортировки. Перед
  # последовательными загрузками применяется лишь лимит количества.
  sort -n "$1" | awk -v cap="$MAX_TESTED" '
    $1 > 0 {
      if (cap == 0 || n < cap) { print; n++ }
    }' > "$2"
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

zash_ui_dir() {
  # Каталог external-ui из config.yaml (обычно "./zash", относительно
  # $DIR - именно так mihomo распаковывает туда zashboard при первом
  # запуске, см. external-ui-url в config.yaml/config.example.yaml).
  # Используется только cleanup_old_zash_stats() ниже. Разбор нарочно
  # минимальный - одна строка верхнего уровня "external-ui: <путь>" без
  # общего YAML-парсера, ровно то, что кладёт туда сама установка (см.
  # config.example.yaml). Пусто, если config.yaml отсутствует, строки
  # нет или значение после разбора пустое.
  [ -f "$SOURCES" ] || return 0
  raw=$(sed -n 's/^external-ui:[[:space:]]*//p' "$SOURCES" | head -n 1)
  raw=${raw%%#*}
  raw=$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/')
  raw=${raw#./}   # "./zash" -> "zash" - косметика, чтобы не собирать путь вида "$DIR/./zash"
  [ -n "$raw" ] || return 0
  case "$raw" in
    /*) printf '%s' "$raw" ;;
    *) printf '%s/%s' "$DIR" "$raw" ;;
  esac
}

cleanup_old_zash_stats() {
  # Убирает хвост старой схемы (см. TODO.md - "убрать старую страницу
  # статистики из встроенного веб-UI mihomo"): до появления отдельного
  # веб-сервиса статистики (см. комментарий в начале prepare() в stats_service.sh)
  # stats.html лежал прямо в каталоге external-ui и раздавался вместе с
  # zashboard на порту API_MAIN (обычно 9090, например
  # http://<роутер>:9090/ui/stats.html). Текущий код туда больше ничего
  # не пишет (render_stats() работает только с
  # $STATS_HTTP_DIR, не связанным с zashboard) - оставшийся там файл
  # только дублирует новый сервис и путает читателя двумя разными
  # адресами с похожим содержимым.
  #
  # Вызывается из prepare() в stats_service.sh при каждом прогоне (включая
  # --force), поэтому самовосстанавливается так же, как остальной код
  # этого файла: если zashboard когда-нибудь переустановят и туда снова
  # вручную скопируют stats.html - следующий прогон уберёт его опять.
  # Удаляется только файл с нашей подписью (проверка заголовка ниже) -
  # чтобы случайно не стереть чужой файл с тем же именем, если он когда-
  # нибудь там окажется.
  zdir=$(zash_ui_dir)
  [ -n "$zdir" ] || return 0
  target=$zdir/stats.html
  [ -f "$target" ] || return 0
  grep -q '<title>speedtest2 - статистика</title>' "$target" 2>/dev/null || return 0
  if rm -f "$target"; then
    say "OK: Убран устаревший $target (дублировал новый веб-сервис статистики, см. TODO.md)"
  else
    say "WARN: Не удалось убрать устаревший $target - уберите вручную"
  fi
}

render_stats() {
  # Атомарно публикует stats.json. HTTP-бэкенд запускает и перезапускает
  # stats_service.sh, прогоны speedtest2.sh его не трогают.
  statsdir=${STATS_JSON%/*}
  if [ ! -d "$statsdir" ]; then
    say "WARN: Каталог $statsdir не найден, stats.json не записан"
    return 0
  fi
  # Старый HTML-интерфейс (stats.html) удалён 2026-09-28 - убираем файл,
  # оставшийся от прежних версий, чтобы по /stats.html не открывалась
  # навсегда застывшая статистика. Одна запись в /opt и только если файл есть.
  if [ -f "$STATS_HTML" ]; then
    rm -f "$STATS_HTML" 2>/dev/null || say "WARN: Не удалось удалить устаревший $STATS_HTML"
  fi
  if [ ! -f "$RENDER_STATS" ]; then
    say "WARN: $RENDER_STATS не найден, stats.json не обновлён"
    return 0
  fi
  generated_ts=$(date '+%Y-%m-%d %H:%M:%S')
  # stats.json - данные для /api/stats (маршрут "api/stats" в
  # stats_httpd.py). Ошибка/пустой результат - только WARN: app.js сам
  # покажет отсутствие данных, а прогон спидтеста от этого не страдает.
  # Явный формат нужен старому web-компоненту при обновлении только runtime.
  if ! awk -v last="$LAST" -v nodes="$HISTORY_NODES" -v cap="$STATS_NODE_CAP" \
       -v stability="$HISTORY_STABILITY" \
       -v generated="$generated_ts" \
       -v format=json \
       -f "$RENDER_STATS" "$HISTORY_RUNS" > "$WORK/stats.json" 2> "$WORK/stats.json.err"; then
    say "WARN: render_stats.awk завершился с ошибкой, stats.json не обновлён"
    [ -s "$WORK/stats.json.err" ] && sed -n '1,3p' "$WORK/stats.json.err" >> "$RUN_LOG"
    return 0
  fi
  if [ ! -s "$WORK/stats.json" ]; then
    say "WARN: render_stats.awk вернул пустой файл, stats.json не обновлён"
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
       -v alivefile="$WORK/alive.txt" -v speedfile="$WORK/res.txt" -v skipfile="$WORK/wg_skip.txt" \
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
  # затем перегенерирует stats.json. Вызывается из main() после успешной
  # публикации fast.yaml - сам по себе не критичен для работы замерщика:
  # любая ошибка здесь - WARN в лог, а не остановка.
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
      say "WARN: Источник $src не похож ни на clash-yaml, ни на base64-подписку, пропускаю"
      return 1
    fi
  fi
  first=$(sed -n '1p' "$decoded")
  case "$first" in
    vless://*) ;;
    *) say "WARN: Источник $src раскодирован, но не похож на vless-подписку, пропускаю"; return 1 ;;
  esac
  conv="$WORK/subconv-$base.yaml"
  LC_ALL=C awk -f "$SUB_CONVERT" "$decoded" > "$conv" 2> "$WORK/subconv-$base.log"
  n_converted=$(sed -n 's/.*converted=\([0-9]*\).*/\1/p' "$WORK/subconv-$base.log")
  if [ -z "${n_converted:-}" ] || [ "$n_converted" -eq 0 ]; then
    say "WARN: Из $src не удалось получить ни одной ноды, пропускаю"
    return 1
  fi
  if ! validate_provider "$conv"; then
    say "WARN: Конфиг из $src не прошёл проверку \$BIN -t, пропускаю весь провайдер"
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
    say "WARN: Ни один источник не прошёл проверку/конвертацию, пул пуст"
    : > "$WORK/all.yaml"
    echo 0 > "$WORK/cnt.txt"
    return 0
  fi
  : > "$WORK/wg.txt"
  awk -v NODEDIR="$WORK/nodes" -v MAPFILE="$WORK/map.txt" -v WGFILE="$WORK/wg.txt" \
      -v CNTFILE="$WORK/cnt.txt" -v BLOCK="$BLOCK" -v EXTYPE="$EXTYPE" \
      -f "$PREP" $conv_sources > "$WORK/all.yaml" 2> "$WORK/prep.err"
}

reload_provider() {
  main_curl -f -s -m 10 -X PUT "http://$API_MAIN/providers/proxies/fast" >/dev/null 2>&1
}

# --- API основного ядра и WireGuard/AmneziaWG через него ---

# main_api_init - адрес и secret API основного ядра из рабочего конфига
# (external-controller/secret - только однострочные значения верхнего
# уровня). secret уходит в заголовок через файл настроек curl (-K) с правами
# 0600, а не в аргументы (их видно в ps). MAIN_API_OK=1, если адрес
# определён; без external-controller остаётся API_MAIN по умолчанию.
main_api_init() {
  MAIN_API_OK=0
  MAIN_CURL_CFG=$WORK/main-api.curl
  ( umask 077; : > "$MAIN_CURL_CFG" ) || { MAIN_CURL_CFG=; return 1; }
  [ -f "$MAIN_CONFIG" ] || return 1
  main_vals=$(awk '
    function val(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); sub(/[ \t\r]+$/, "", s)
      if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2); return s }
    /^external-controller:/ { c = val($0) }
    /^secret:/ { k = val($0) }
    END { printf "%s\t%s", c, k }' "$MAIN_CONFIG") || return 1
  main_ctl=${main_vals%%"$(printf '\t')"*}
  main_secret=${main_vals#*"$(printf '\t')"}
  [ -n "$main_ctl" ] || return 1
  main_port=${main_ctl##*:}
  case $main_port in ''|*[!0-9]*) return 1 ;; esac
  case $main_ctl in
    :*|0.0.0.0:*|'[::]:'*|'::':*) main_host=127.0.0.1 ;;
    *) main_host=${main_ctl%:*} ;;
  esac
  case $main_host in ''|*[!A-Za-z0-9.:\[\]-]*) return 1 ;; esac
  if [ -n "$main_secret" ]; then
    case $main_secret in *'"'*|*'\'*) return 1 ;; esac
    printf 'header = "Authorization: Bearer %s"\n' "$main_secret" > "$MAIN_CURL_CFG" || return 1
  fi
  API_MAIN=$main_host:$main_port
  MAIN_API_OK=1
}

main_curl() {
  if [ -n "$MAIN_CURL_CFG" ]; then curl -K "$MAIN_CURL_CFG" "$@"; else curl "$@"; fi
}

# urlencode - процентное кодирование всего, кроме [A-Za-z0-9._~-] (имена нод
# бывают с пробелами, эмодзи и скобками). Только awk в побайтовом режиме
# (LC_ALL=C): минимальный BusyBox od на Keenetic не знает -t/-A, и прежняя
# версия через od давала пустую строку - запросы уходили на /proxies/.
urlencode() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i }
    NR > 1 { printf "%%0A" }
    { for (i = 1; i <= length($0); i++) { c = substr($0, i, 1)
        if (c ~ /[A-Za-z0-9._~-]/) printf "%s", c; else printf "%%%02X", ord[c] } }'
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# wg_group_members - имена из поля "all" группы WG_GROUP основного ядра, по
# одному в строке. \u-экранирование Go (<, >, &) раскрывается, прочие
# экранированные символы дают заведомо несовпадающее имя.
wg_group_members() {
  main_curl -f -s -m 5 "http://$API_MAIN/proxies/$(urlencode "$WG_GROUP")" > "$WORK/wg-group.json" 2>/dev/null || return 1
  # Ответ списка всех прокси (/proxies/ при пустом имени) - не наша группа.
  grep -q '"proxies":{' "$WORK/wg-group.json" && return 1
  awk 'BEGIN { RS = "\001" }
  {
    s = $0; i = index(s, "\"all\":[")
    if (!i) exit 1
    i += 7; n = length(s); q = 0
    while (i <= n) {
      c = substr(s, i, 1)
      if (!q) {
        if (c == "]") { found = 1; break }
        if (c == "\"") { q = 1; out = "" }
        i++; continue
      }
      if (c == "\\") {
        d = substr(s, i + 1, 1)
        if (d == "u") {
          h = tolower(substr(s, i + 2, 4))
          ch = (h == "003c") ? "<" : (h == "003e") ? ">" : (h == "0026") ? "&" : "\001"
          out = out ch
          i += 6; continue
        }
        # BusyBox awk читает "out ((...))" как вызов функции out - через переменную.
        ch = (d == "n" || d == "t" || d == "r") ? "\001" : d
        out = out ch; i += 2; continue
      }
      if (c == "\"") { print out; q = 0; i++; continue }
      out = out c; i++
    }
  }
  END { exit !found }' "$WORK/wg-group.json"
}

# wg_prepare - из $WORK/wg.txt (idx<TAB>имя, prep.awk) отбирает ноды, которые
# можно проверить через основное ядро ($WORK/wg_ok.txt), остальные - в
# $WORK/wg_skip.txt (idx) с причиной в логе. Второе ядро такие ноды не
# получает никогда - второй клиент с тем же ключом ломает соединение.
wg_prepare() {
  : > "$WORK/wg_ok.txt"; : > "$WORK/wg_skip.txt"
  [ -s "$WORK/wg.txt" ] || return 0
  wg_reason=
  if ! grep -q "^  - name: $WG_LISTENER\$" "$MAIN_CONFIG" 2>/dev/null; then
    wg_reason="в рабочем конфиге нет входа $WG_LISTENER (нужна миграция конфига через обновление)"
  elif [ "$MAIN_API_OK" != 1 ]; then
    wg_reason="не удалось определить адрес или secret API основного ядра"
  elif command -v netstat >/dev/null 2>&1 && ! netstat -ltn 2>/dev/null | awk -v p=":$WG_PORT" 'substr($4, length($4) - length(p) + 1) == p { f = 1 } END { exit !f }'; then
    wg_reason="вход 127.0.0.1:$WG_PORT не слушает (основное ядро не перезапущено после миграции?)"
  elif ! wg_group_members > "$WORK/wg-members.txt"; then
    wg_reason="группа $WG_GROUP недоступна через API основного ядра"
  fi
  if [ -n "$wg_reason" ]; then
    cut -f1 "$WORK/wg.txt" > "$WORK/wg_skip.txt"
    say "WARN: WireGuard/AmneziaWG-ноды ($(wc -l < "$WORK/wg.txt" | tr -d ' ')) не проверяются: $wg_reason"
    return 0
  fi
  while IFS="$(printf '\t')" read -r wg_idx wg_name; do
    [ -n "$wg_idx" ] || continue
    wg_dups=$(awk -F '\t' -v n="$wg_name" '$2 == n { c++ } END { print c + 0 }' "$WORK/map.txt")
    wg_members=$(grep -cxF -- "$wg_name" "$WORK/wg-members.txt" 2>/dev/null) || wg_members=0
    if [ "$wg_dups" -gt 1 ]; then
      wg_why="имя встречается в пуле несколько раз"
    elif [ "$wg_members" != 1 ]; then
      wg_why="нет в группе $WG_GROUP основного ядра (другое имя, например префикс провайдера?)"
    else
      printf '%s\t%s\n' "$wg_idx" "$wg_name" >> "$WORK/wg_ok.txt"
      continue
    fi
    echo "$wg_idx" >> "$WORK/wg_skip.txt"
    say "WARN: WG-нода не проверяется: $wg_name - $wg_why"
  done < "$WORK/wg.txt"
}

wg_delay_one() {
  main_curl -s -m $((DELAY_TIMEOUT_MS / 1000 + 3)) \
    "http://$API_MAIN/proxies/$(urlencode "$1")/delay?url=$DELAY_URL&timeout=$DELAY_TIMEOUT_MS" 2>/dev/null \
    | sed -n 's/.*"delay":\([0-9][0-9]*\).*/\1/p'
}

# wg_delays - задержка WG-нод через основное ядро; первый запрос прогревает
# туннель (рукопожатие), в зачёт идёт второй. Дописывает "delay idx" в
# $WORK/alive.raw, как fetch_delays() для второго ядра.
wg_delays() {
  while IFS="$(printf '\t')" read -r wg_idx wg_name; do
    [ -n "$wg_idx" ] || continue
    wg_delay_one "$wg_name" > /dev/null
    wg_d=$(wg_delay_one "$wg_name")
    [ "${wg_d:-0}" -gt 0 ] 2>/dev/null && echo "$wg_d $wg_idx" >> "$WORK/alive.raw"
  done < "$WORK/wg_ok.txt"
  return 0
}

# wg_group_now - поле "now" (текущий выбор) группы $1 основного ядра.
wg_group_now() {
  main_curl -f -s -m 5 "http://$API_MAIN/proxies/$(urlencode "$1")" 2>/dev/null | awk 'BEGIN { RS = "\001" }
  {
    i = index($0, "\"now\":\"")
    if (!i) exit 1
    s = substr($0, i + 7); out = ""
    for (j = 1; j <= length(s); j++) {
      c = substr(s, j, 1)
      if (c == "\\") { out = out substr(s, j + 1, 1); j++; continue }
      if (c == "\"") { print out; found = 1; exit }
      out = out c
    }
  }
  END { exit !found }'
}

# wg_publish_fast - WG/AWG-ноды не пишутся в fast.yaml (второй клиент с тем
# же ключом), вместо этого лучшая из прошедших порог $1 выбирается в группе
# WG_FAST_GROUP, которая входит в '⚡ Быстрый пул'. Нет прошедших порог:
# REJECT, если текущий выбор проверялся в этом прогоне и не прошёл (не
# ответил или ниже порога); не дошедший до замера выбор не трогаем.
wg_publish_fast() {
  [ -s "$WORK/wg_ok.txt" ] || return 0
  if ! wg_now=$(wg_group_now "$WG_FAST_GROUP"); then
    say "WARN: Группы $WG_FAST_GROUP нет в основном ядре - WG-ноды в '⚡ Быстрый пул' не попадают (нужна миграция конфига)"
    return 0
  fi
  wg_best=$(awk -v min="$1" -v okfile="$WORK/wg_ok.txt" '
    BEGIN { FS = "\t"; while ((getline l < okfile) > 0) { split(l, f, "\t"); nm[f[1]] = f[2] } FS = " " }
    ($2 in nm) && $1 >= min && $1 > best { best = $1; name = nm[$2] }
    END { if (name != "") print name }' "$WORK/res.txt")
  if [ -n "$wg_best" ]; then
    if [ "$wg_now" = "$wg_best" ] || wg_select_in "$WG_FAST_GROUP" "$wg_best"; then
      say "WG: $wg_best -> '⚡ Быстрый пул' (группа $WG_FAST_GROUP)"
    else
      say "WARN: Не удалось выбрать $wg_best в группе $WG_FAST_GROUP"
    fi
    return 0
  fi
  [ "$wg_now" != REJECT ] || return 0
  wg_now_idx=$(awk -F '\t' -v n="$wg_now" '$2 == n { print $1; exit }' "$WORK/wg_ok.txt")
  [ -n "$wg_now_idx" ] || return 0
  wg_now_state=$(awk -v k="$wg_now_idx" -v min="$1" -v alive="$WORK/alive.txt" '
    BEGIN { while ((getline l < alive) > 0) { split(l, a, " "); if (a[2] == k) up = 1 } }
    $2 == k { tested = 1; if ($1 < min) slow = 1 }
    END { print (!up || (tested && slow)) ? "fail" : "keep" }' "$WORK/res.txt")
  if [ "$wg_now_state" = fail ]; then
    wg_select_in "$WG_FAST_GROUP" REJECT && say "WG: $wg_now не прошёл замер - убран из '⚡ Быстрый пул'"
  fi
  return 0
}

wg_select_in() {
  main_curl -f -s -m 3 -X PUT -H 'Content-Type: application/json' \
    --data-binary "{\"name\":\"$(json_escape "$2")\"}" \
    "http://$API_MAIN/proxies/$(urlencode "$1")" >/dev/null 2>&1
}

wg_select() {
  main_curl -f -s -m 3 -X PUT -H 'Content-Type: application/json' \
    --data-binary "{\"name\":\"$(json_escape "$1")\"}" \
    "http://$API_MAIN/proxies/$(urlencode "$WG_GROUP")" >/dev/null 2>&1
}

write_test_config() {
  # Пул второго ядра - map2.txt (без WireGuard/AmneziaWG, см. main()); без
  # него (вызов вне main) - весь map.txt.
  pool2=$WORK/map2.txt
  [ -f "$pool2" ] || pool2=$WORK/map.txt
  # T содержит весь пул, но используется только для последовательного
  # переключения нод во время замера скорости. Группы D0001... разбивают
  # массовый delay-check на небольшие последовательные партии: внутри
  # каждой Mihomo проверяет ноды параллельно, между партиями - нет.
  awk -F '\t' -v size="$DELAY_BATCH_SIZE" '
    (NR - 1) % size == 0 {
      group++
      printf "  - name: D%04d\n", group
      print "    type: select"
      print "    proxies:"
    }
    { print "      - " $1 }
  ' "$pool2" > "$WORK/delay_groups.yaml"

  awk -v size="$DELAY_BATCH_SIZE" '
    (NR - 1) % size == 0 { printf "D%04d\n", ++group }
  ' "$pool2" > "$WORK/delay_groups.txt"

  {
    echo "mixed-port: $MIXED_PORT"
    echo "external-controller: $API"
    echo "log-level: silent"
    echo "mode: rule"
    # Метка исключает соединения второго ядра из перехвата OUTPUT в XKeen.
    echo "routing-mark: 255"
    echo "proxies:"
    cat "$WORK/all.yaml"
    echo "proxy-groups:"
    echo "  - name: T"
    echo "    type: select"
    echo "    include-all-proxies: true"
    cat "$WORK/delay_groups.yaml"
    echo "rules:"
    echo "  - MATCH,T"
  } > "$WORK/config.yaml"
}

fetch_delays() {
  : > "$WORK/alive.raw"
  delay_batches_ok=0
  while IFS= read -r delay_group; do
    [ -n "$delay_group" ] || continue
    delay_json=$WORK/delay-$delay_group.json
    if curl -f -s -m 10 \
         "http://$API/group/$delay_group/delay?url=$DELAY_URL&timeout=$DELAY_TIMEOUT_MS" \
         -o "$delay_json" 2>/dev/null; then
      delay_batches_ok=$((delay_batches_ok + 1))
      tr ',' '\n' < "$delay_json" \
        | sed -n 's/.*"\(n[0-9]\{4\}\)":\([0-9]*\).*/\2 \1/p' \
        >> "$WORK/alive.raw"
    else
      say "WARN: Пакетная проверка задержки $delay_group не выполнена, продолжаю с остальными"
    fi
  done < "$WORK/delay_groups.txt"

  sort -n "$WORK/alive.raw" > "$WORK/alive.txt"
  [ "$delay_batches_ok" -gt 0 ]
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
  [ -n "$PUBLISH_TMP" ] && rm -f "$PUBLISH_TMP"
  # Страховка на случай, если цикл шага 5 (write_progress 0 после него,
  # см. main()) не был достигнут - ранний return/exit по ходу самого
  # цикла, INT/TERM и т.п.: без этого progress.json мог бы остаться
  # running:true до следующего прогона. Порядок важен - до rm -rf "$WORK"
  # (write_progress читает "$WORK/progress.tsv").
  [ "$PROGRESS_ACTIVE" = 1 ] && write_progress 0
  # Журнал - после write_progress: её WARN тоже должны попасть в speedtest.log.
  flush_log 2>/dev/null || true
  [ -n "$WORK" ] && rm -rf "$WORK"
  if [ "$LOCK_HELD" = 1 ]; then
    rm -rf "$LOCK"
    LOCK_HELD=0
  fi
}

main() {
case $MAX_TESTED in
  ''|*[!0-9]*) say "WARN: MAX_TESTED должен быть целым неотрицательным числом"; return 1 ;;
esac
if [ -z "$BLOCK" ]; then
  say "WARN: BLOCK не задан; запустите install.sh для создания speedtest2.env"
  return 1
fi
if ! acquire_lock; then
  OLD=$(cat "$LOCK/pid" 2>/dev/null)
  say "WARN: Уже выполняется${OLD:+ (pid $OLD)}, выхожу"
  return 0
fi
install_traps

if ! mkdir -p "$WORK/nodes"; then
  say "WARN: Не удалось создать временный каталог $WORK"
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
  say "WARN: Ни одной ноды не разобрано, fast.yaml не трогаю"; exit 0
fi

# WireGuard/AmneziaWG (wg.txt) во второе ядро не попадают вовсе: пул второго
# ядра - map2.txt; их проверяет основное ядро (wg_prepare/wg_delays ниже).
main_api_init || true
awk -F '\t' -v wgfile="$WORK/wg.txt" '
  BEGIN { while ((getline l < wgfile) > 0) { split(l, f, "\t"); wg[f[1]] = 1 } }
  !($1 in wg)' "$WORK/map.txt" > "$WORK/map2.txt"
WG_TOTAL=$(wc -l < "$WORK/wg.txt" | tr -d ' ')
POOL2=$(wc -l < "$WORK/map2.txt" | tr -d ' ')
: > "$WORK/alive.raw"

if [ "$POOL2" -gt 0 ]; then
# 2. конфиг для тестового ядра
write_test_config

if ! "$BIN" -t -d "$WORK" -f "$WORK/config.yaml" > "$WORK/test.log" 2>&1; then
  say "WARN: Тестовый конфиг не прошёл валидацию, fast.yaml не трогаю"
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
  say "WARN: Тестовое ядро не поднялось, fast.yaml не трогаю"; exit 0
fi

# 4. отсев мёртвых последовательными пакетами (внутри пакета - параллельно)
if ! fetch_delays; then
  say "WARN: Групповая проверка задержки не выполнена, fast.yaml не трогаю"
  exit 0
fi
else
  say "Второе ядро не запускается: в пуле только WireGuard/AmneziaWG-ноды"
fi

# 4a. WireGuard/AmneziaWG - через основное ядро (вход $WG_LISTENER, группа $WG_GROUP)
if [ "$WG_TOTAL" -gt 0 ]; then
  wg_prepare
  wg_delays
  say "WireGuard/AmneziaWG: $WG_TOTAL в пуле, проверяются через основное ядро: $(wc -l < "$WORK/wg_ok.txt" | tr -d ' ')"
else
  : > "$WORK/wg_ok.txt"; : > "$WORK/wg_skip.txt"
fi
sort -n "$WORK/alive.raw" > "$WORK/alive.txt"
ALIVE=$(wc -l < "$WORK/alive.txt")
say "Нод в пуле: $TOTAL, живых: $ALIVE"
: > "$WORK/res.txt"
if [ "$ALIVE" -lt 1 ]; then
  update_node_stability
  say "WARN: Живых нод нет, fast.yaml не трогаю"; exit 0
fi

# 5. отбор по задержке и количеству до последовательных загрузок
select_candidates "$WORK/alive.txt" "$WORK/candidates.txt"
CANDIDATES=$(wc -l < "$WORK/candidates.txt")
say "Кандидатов на скорость: $CANDIDATES из $ALIVE живых; MAX_TESTED=$MAX_TESTED"
if [ "$CANDIDATES" -lt 1 ]; then
  update_node_stability
  say "WARN: Нет кандидатов в пределах лимитов, сохраняю прежний fast.yaml"
  exit 0
fi
CHANNEL=$(measure_direct)
if [ "$CHANNEL" -gt 0 ] 2>/dev/null; then
  EFFECTIVE_MIN=$(compute_threshold "$CHANNEL")
  say "Канал: $(format_mbit "$CHANNEL") Мбит/с, порог: $(format_mbit "$EFFECTIVE_MIN") Мбит/с"
else
  EFFECTIVE_MIN=$MIN_SPEED
  say "WARN: Прямой замер канала не удался, порог из настроек: $(format_mbit "$EFFECTIVE_MIN") Мбит/с"
fi
PROGRESS_TOTAL=$CANDIDATES
PROGRESS_STARTED_ISO=$(date '+%Y-%m-%d %H:%M:%S')
PROGRESS_ACTIVE=1
: > "$WORK/progress.tsv"
write_progress 1
GOOD=0
: > "$WORK/good_names.txt"
while read -r D IDX; do
  WG_NAME=$(awk -F '\t' -v k="$IDX" '$1 == k { print $2 }' "$WORK/wg_ok.txt")
  if [ -n "$WG_NAME" ]; then
    wg_select "$WG_NAME" || { say "WARN: Не удалось выбрать $WG_NAME в группе $WG_GROUP основного ядра"; continue; }
    SPEED_PORT=$WG_PORT
  else
    select_proxy "$IDX" || continue
    SPEED_PORT=$MIXED_PORT
  fi
  METRICS=$(curl -s -m "$DL_TIMEOUT" -o /dev/null -w '%{http_code} %{speed_download}' \
            -x "http://127.0.0.1:$SPEED_PORT" "$SPEED_URL" 2>/dev/null)
  HTTP_STATUS=${METRICS%% *}
  SP_RAW=${METRICS#* }
  SP=$(accepted_speed "$HTTP_STATUS" "$SP_RAW")
  echo "$SP $IDX" >> "$WORK/res.txt"
  NM=$(awk -v k="$IDX" -F'	' '$1 == k {print $2}' "$WORK/map.txt")
  echo "$((SP/1048576)).$(( (SP%1048576)*10/1048576 ))	МБ/с	$NM" >> "$WORK/full.txt"
  [ "$FORCE" = 1 ] && say "  $(format_mbit "$SP") Мбит/с  $NM"
  PROGRESS_STATUS=slow
  [ "$SP" -ge "$EFFECTIVE_MIN" ] && PROGRESS_STATUS=ok
  printf '%s\t%s\t%s\n' "$NM" "$SP" "$PROGRESS_STATUS" >> "$WORK/progress.tsv"
  write_progress 1
  if [ "$SP" -ge "$EFFECTIVE_MIN" ] && remember_name "$NM" "$WORK/good_names.txt"; then
    GOOD=$((GOOD+1))
    [ "$GOOD" -ge "$ENOUGH" ] && break
  fi
done < "$WORK/candidates.txt"
write_progress 0
update_node_stability

# 6. отбор победителей и сборка fast.yaml
# WG/AWG-ноды в fast.yaml не пишутся: полное определение подняло бы в
# основном ядре второго клиента с тем же ключом, а псевдоним direct +
# dialer-proxy на роутере шёл мимо туннеля (задержка 33 мс против 126 мс).
# Победитель среди них попадает в пул через группу WG_FAST_GROUP (wg_publish_fast).
awk -v wgfile="$WORK/wg.txt" '
  BEGIN { while ((getline l < wgfile) > 0) { split(l, f, "\t"); wg[f[1]] = 1 } }
  !($2 in wg)' "$WORK/res.txt" > "$WORK/res_fast.txt"
if [ -s "$WORK/wg_ok.txt" ]; then
  while read -r WSP WIDX; do
    WNM=$(awk -F '\t' -v k="$WIDX" '$1 == k { print $2 }' "$WORK/wg_ok.txt")
    [ -n "$WNM" ] && say "WG: $(format_mbit "$WSP") Мбит/с  $WNM"
  done < "$WORK/res.txt"
fi
wg_publish_fast "$EFFECTIVE_MIN"
select_winners "$WORK/res_fast.txt" "$WORK/map.txt" "$WORK/win.txt" "$EFFECTIVE_MIN" "$TOPN" "$MIN_WINNERS"
WIN=$(wc -l < "$WORK/win.txt")
BELOW_MIN=$(awk -v m="$EFFECTIVE_MIN" '$1 < m { c++ } END { print c + 0 }' "$WORK/win.txt")
if [ "$WIN" -lt 1 ]; then
  say "WARN: Порог $(format_mbit "$EFFECTIVE_MIN") Мбит/с не прошла ни одна нода для fast.yaml (WG/AWG - отдельно, см. выше), оставляю прежний fast.yaml"
  best_line=$(sort -rn "$WORK/res.txt" | head -1)
  best_sp=${best_line%% *}
  best_idx=${best_line#* }
  best_nm=$(awk -v k="$best_idx" -F'\t' '$1 == k {print $2}' "$WORK/map.txt")
  say "Лучший результат: $(format_mbit "$best_sp") Мбит/с  $best_nm"
  exit 0
fi

echo "proxies:" > "$WORK/fast.new"
while read -r SP IDX; do
  NAME=$(awk -v k="$IDX" -F'\t' '$1 == k {print $2}' "$WORK/map.txt")
  cat "$WORK/nodes/$IDX.yaml" >> "$WORK/fast.new"
  say "  $(format_mbit "$SP") Мбит/с  $NAME"
done < "$WORK/win.txt"

# 7. проверить, что собранное читается
{
  echo "mixed-port: 7893"; echo "mode: rule"
  cat "$WORK/fast.new"
  echo "proxy-groups:"; echo "  - name: C"; echo "    type: select"; echo "    include-all-proxies: true"
  echo "rules:"; echo "  - MATCH,C"
} > "$WORK/check.yaml"
if ! "$BIN" -t -d "$WORK" -f "$WORK/check.yaml" > "$WORK/check.log" 2>&1; then
  say "WARN: Собранный fast.yaml не проходит валидацию, оставляю прежний"
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

parse_args() {
  for _arg in "$@"; do
    case $_arg in
      --force) FORCE=1 ;;
      # Старое самообновление с ветки main (VERSIONS, без SHA256) удалено:
      # обновления ставятся только управляемым обновлятором update.sh.
      # Флаги распознаются, чтобы по старой привычке не запустить вместо
      # них полный прогон спидтеста.
      --check-update | --update-core | --update-stats) REMOVED_UPDATE_FLAG=$_arg ;;
    esac
  done
}

if [ "${MST_LIB_ONLY:-0}" != 1 ]; then
  REMOVED_UPDATE_FLAG=
  parse_args "$@"
  if [ -n "$REMOVED_UPDATE_FLAG" ]; then
    echo "speedtest2.sh: $REMOVED_UPDATE_FLAG больше не поддерживается - используйте раздел «Обновления» веб-интерфейса или mihomo-speedtest update --check" >&2
    exit 2
  fi
  main "$@"
fi
