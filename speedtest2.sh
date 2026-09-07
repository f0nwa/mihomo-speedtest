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
TMPROOT=${TMPROOT:-/tmp}
WORK=${WORK:-$TMPROOT/mst.$$}
LOCK=${LOCK:-$TMPROOT/mst.lock}
LOCK_HELD=0
FORCE=${FORCE:-0}             # 1 -- ручной внеочередной запуск: живой вывод в терминал,
                              # ожидание/захват чужой блокировки вместо немедленного выхода
FORCE_WAIT=${FORCE_WAIT:-180} # force: сколько ждать (сек) чужую блокировку, прежде чем сдаться
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
DELAY_URL='https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204'
SPEED_URL="https://speed.cloudflare.com/__down?bytes=$SIZE"
# гео-стоп-лист: ноды с такими кусками в имени не тестируются вовсе
EXTYPE='trojan|ss'      # типы нод, которые вообще не тестируем
BLOCK=${BLOCK:-}       # обязательный фильтр загружает install.sh через speedtest2.env

HISTORY_RUNS=${HISTORY_RUNS:-$DIR/speedtest_runs.tsv}       # сводка по прогонам: канал, порог, счётчики
HISTORY_NODES=${HISTORY_NODES:-$DIR/speedtest_history.tsv}  # история нод-победителей по прогонам
HISTORY_KEEP_RUNS=${HISTORY_KEEP_RUNS:-200}   # хранить не больше стольких последних прогонов (0 = не ограничивать)
HISTORY_KEEP_DAYS=${HISTORY_KEEP_DAYS:-30}    # и не старше стольких дней (0 = не ограничивать)
STATS_HTML=${STATS_HTML:-$DIR/zash/stats.html}   # страница статистики в каталоге external-ui (:9090/ui/stats.html)
RENDER_STATS=${RENDER_STATS:-$DIR/render_stats.awk}

ENV=${ENV:-$DIR/speedtest2.env}
[ -f "$ENV" ] && . "$ENV"

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
  results=$1
  mapfile=$2
  output=$3
  minimum=$4
  top=$5

  sort -rn "$results" | awk -F ' ' -v mapfile="$mapfile" -v minimum="$minimum" -v top="$top" '
    BEGIN {
      while ((getline line < mapfile) > 0) {
        tab = index(line, "\t")
        if (tab > 0) names[substr(line, 1, tab - 1)] = substr(line, tab + 1)
      }
      close(mapfile)
    }
    $1 >= minimum {
      name = names[$2]
      if (name == "" || seen[name]++) next
      print $1, $2
      if (++count >= top) exit
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

render_stats() {
  statsdir=${STATS_HTML%/*}
  if [ ! -d "$statsdir" ]; then
    say "WARN: каталог $statsdir не найден (zashboard/external-ui ещё не установлен?), stats.html не записан"
    return 0
  fi
  if [ ! -f "$RENDER_STATS" ]; then
    say "WARN: $RENDER_STATS не найден, stats.html не обновлён"
    return 0
  fi
  if ! awk -v last="$LAST" -v nodes="$HISTORY_NODES" -v generated="$(date '+%Y-%m-%d %H:%M:%S')" \
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

prepare_nodes() {
  awk -v NODEDIR="$WORK/nodes" -v MAPFILE="$WORK/map.txt" \
      -v CNTFILE="$WORK/cnt.txt" -v BLOCK="$BLOCK" -v EXTYPE="$EXTYPE" \
      -f "$PREP" $SOURCES > "$WORK/all.yaml" 2> "$WORK/prep.err"
}

reload_provider() {
  curl -f -s -m 10 -X PUT "http://$API_MAIN/providers/proxies/fast" >/dev/null 2>&1
}

fetch_delays() {
  curl -f -s -m 60 "http://$API/group/T/delay?url=$DELAY_URL&timeout=5000" \
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
if [ "$ALIVE" -lt 1 ]; then
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
: > "$WORK/res.txt"
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

# 6. отбор победителей и сборка fast.yaml
select_winners "$WORK/res.txt" "$WORK/map.txt" "$WORK/win.txt" "$EFFECTIVE_MIN" "$TOPN"
WIN=$(wc -l < "$WORK/win.txt")
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
if reload_provider; then
  say "OK: $WIN нод -> fast.yaml (проверено $(wc -l < "$WORK/res.txt") из $ALIVE живых, провайдер перечитан)"
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
    esac
  done
}

if [ "${MST_LIB_ONLY:-0}" != 1 ]; then
  parse_args "$@"
  main "$@"
fi
