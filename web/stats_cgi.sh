#!/bin/sh
# CGI-скрипт настроек веб-интерфейса (JSON для /api/settings, см.
# API_ALIASES в stats_httpd.py и renderSettings() в stats_app.js). Ставится install.sh в $DIR/stats_cgi.sh;
# в раздаваемый каталог (STATS_CGI_SCRIPT, обычно $DIR/stats_www/cgi-bin/config)
# его копирует write_stats_cgi() из speedtest2.sh при каждом запуске/
# перезапуске независимой службы (prepare() в stats_service.sh, порция 3 -
# см. docs/superpowers/specs/2026-09-15-independent-stats-service-design.md) -
# править нужно этот файл, копия перезаписывается автоматически и правки в
# ней не сохранятся.
#
# Полагается на то, что busybox httpd передаёт CGI-процессу окружение
# родителя: stats_service.sh экспортирует DIR и ENV перед запуском веб-
# сервиса, поэтому сорс "$DIR/speedtest2.sh" ниже подхватывает те же
# настройки (включая текущий speedtest2.env), что и обычный прогон по cron -
# в т.ч. пересчитывает все зависящие от DIR пути (HISTORY_RUNS, STATS_JSON
# и т.д.), а не только те, что перечислены тут.

export MST_LIB_ONLY=1
[ -n "$DIR" ] && [ -f "$DIR/speedtest2.sh" ] && . "$DIR/speedtest2.sh"
LOG_TAG=settings   # метка строк формы настроек в живом журнале (см. say() в speedtest2.sh)
MAX_TESTED=${MAX_TESTED:-40}

if [ -z "$DIR" ] || ! command -v render_stats >/dev/null 2>&1; then
  echo "Content-Type: text/plain; charset=utf-8"
  echo
  echo "Ошибка конфигурации: не удалось подключить speedtest2.sh (DIR=[$DIR])."
  echo "Обычно это значит, что CGI запущен не через busybox httpd, поднятый stats_service.sh."
  exit 0
fi

urldecode() {
  # Раньше: busybox httpd -d "$1" - на сборке Entware BusyBox без апплета
  # httpd (busybox httpd -d "2" -> "httpd: applet not found", код 127,
  # пустой stdout) любое поле формы декодировалось в пустую строку
  # независимо от длины и содержимого - веб-форма при этом отдаётся,
  # потому что сам httpd-сервер запускается другим путём/бинарником, а
  # внутри CGI-скрипта голое имя "busybox" резолвится через PATH именно
  # в этот урезанный busybox. Декодирование сделано чистым awk - не
  # зависит от того, какой busybox и с какими апплетами найдётся в PATH.
  printf '%s' "$1" | awk '
    BEGIN {
      for (i = 0; i <= 255; i++) {
        h = sprintf("%02x", i); H = sprintf("%02X", i)
        byte[h] = sprintf("%c", i); byte[H] = sprintf("%c", i)
      }
    }
    {
      s = $0; out = ""; n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "+") { out = out " "; i += 1 }
        else if (c == "%" && i + 2 <= n && substr(s, i + 1, 2) in byte) {
          out = out byte[substr(s, i + 1, 2)]; i += 3
        } else { out = out c; i += 1 }
      }
      printf "%s", out
    }'
}

is_uint() {
  case $1 in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_decimal_in_range() {
  # $1=значение, $2=нижняя граница, $3="incl"|"excl" (входит ли сама
  # граница), $4=верхняя граница ("" = без ограничения сверху, всегда
  # включительно). Один awk-вызов вместо двух (было: отдельно формат,
  # отдельно диапазон) - на форме с полутора десятками числовых полей
  # лишние fork/exec на каждое поле складываются в заметную нагрузку на
  # слабом роутере (см. CHANGELOG про фикс тайм-аута CGI).
  awk -v v="$1" -v lo="$2" -v loType="$3" -v hi="$4" 'BEGIN {
    ok = (v ~ /^[0-9]+(\.[0-9]+)?$/)
    if (ok) {
      n = v + 0
      if (loType == "excl") { if (!(n > lo)) ok = 0 } else { if (!(n >= lo)) ok = 0 }
      if (ok && hi != "" && !(n <= hi)) ok = 0
    }
    exit !ok
  }'
}

mb_to_bytes() {
  # Округление до целого байта - SIZE/MIN_SPEED/MIN_FLOOR в speedtest2.env
  # всегда целые (сравниваются в awk/curl как обычные числа).
  awk -v mb="$1" 'BEGIN { printf "%.0f", mb * 1048576 }'
}

bytes_to_mb() {
  # %g сам обрезает лишние нули (10485760 -> "10", 524288 -> "0.5").
  awk -v b="$1" 'BEGIN { printf "%g", b / 1048576 }'
}

# Скорости (MIN_SPEED/MIN_FLOOR) в веб-интерфейсе - в Мбит/с (x8 /
# 1 000 000, как в спидтестах), в speedtest2.env - по-прежнему байты/с.
mbit_to_bytes() {
  awk -v m="$1" 'BEGIN { printf "%.0f", m * 1000000 / 8 }'
}

bytes_to_mbit() {
  # Два знака после точки, %g обрезает лишние нули (1048576 -> "8.39",
  # 1250000 -> "10").
  awk -v b="$1" 'BEGIN { printf "%g", int(b * 8 / 10000 + 0.5) / 100 }'
}

parse_body_fields() {
  # Разбирает $body (application/x-www-form-urlencoded) ОДНИМ проходом
  # awk вместо отдельного sed на каждое из 16 полей формы (было: sed
  # заново пересканировал всю строку на каждое имя поля - O(число полей)
  # forkнутых процессов на один запрос). Печатает shell-присваивания
  # RAW_<имя>='<ещё закодированное значение>' для eval - urldecode()
  # по-прежнему делается отдельно на каждое значение (нельзя раскодировать
  # $body целиком разом: закодированный литеральный '&' внутри значения
  # после этого было бы не отличить от настоящего разделителя полей).
  printf '%s' "$body" | awk -F '&' '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "") continue
        eq = index($i, "=")
        if (eq == 0) { name = $i; val = "" } else { name = substr($i, 1, eq - 1); val = substr($i, eq + 1) }
        if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) continue
        gsub(/'"'"'/, "'"'"'\\'"'"''"'"'", val)
        printf "RAW_%s='"'"'%s'"'"'\n", name, val
      }
    }'
}

set_env_var() {
  # $1=имя (без спецсимволов регулярных выражений - все имена ниже фиксированы),
  # $2=значение. Атомарно заменяет/добавляет строку NAME='значение' в $ENV -
  # в кавычках, как install.sh пишет write_env(). Остальные строки (BLOCK,
  # SOURCES, комментарии...) не трогает.
  name=$1; val=$2
  esc=$(printf '%s' "$val" | sed "s/'/'\\\\''/g")
  tmp="$ENV.cgi.$$"
  { [ -f "$ENV" ] && grep -v "^$name=" "$ENV"; printf "%s='%s'\\n" "$name" "$esc"; } > "$tmp" 2>/dev/null
  mv "$tmp" "$ENV"
}

_add_err() {
  # $1=условное имя поля для JSON-ответа /api/settings, $2=текст сообщения.
  # err - признак «есть ошибки» (непустой) и сводный текст, err_fields -
  # по строке "поле|сообщение" на ошибку для JSON (print_settings_json()).
  err="${err}$2
"
  err_fields="${err_fields}$1|$2
"
}

normalize_block() {
  # BLOCK - список подстрок через | (см. prep.awk), не regex: убираем
  # пробелы вокруг | и по краям и префикс "(?i)" у кусков (след копирования
  # exclude-filter из config.yaml). Та же функция есть в web/stats_cgi.sh.
  printf '%s\n' "$1" | sed -e 's/[[:space:]]*|[[:space:]]*/|/g' \
    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e 's/^(?i)//' -e 's/|(?i)/|/g'
}

validate_settings_fields() {
  # Проверяет уже раскодированные значения полей формы настройки (16
  # штук: node_cap, keep_runs, keep_days, geo_filter, extype, size_mb,
  # dl_timeout, min_speed_mb, min_ratio, min_floor_mb, topn, enough,
  # min_winners, stability_window, stability_drop_after и max_tested -
  # берутся из одноимённых shell-переменных,
  # устанавливаемых ДО вызова этой функции - urldecode() из тела POST
  # /api/settings). Ни $ENV, ни другие файлы не трогает - только заполняет
  # err/err_fields (см. _add_err()) и возвращает 0, если ошибок нет, иначе 1.
  err=""
  err_fields=""

  if ! is_uint "$max_tested"; then
    _add_err max_tested "Лимит кандидатов должен быть целым числом от 0 (0 = без ограничения)."
  fi

  if ! is_uint "$node_cap" || [ "$node_cap" -lt 1 ] || [ "$node_cap" -gt 8 ]; then
    _add_err node_cap "Число нод на графике должно быть от 1 до 8."
  fi
  if ! is_uint "$keep_runs"; then
    _add_err keep_runs "«Хранить прогонов» должно быть целым числом (0 = не ограничивать)."
  fi
  if ! is_uint "$keep_days"; then
    _add_err keep_days "«Хранить дней» должно быть целым числом (0 = не ограничивать)."
  fi
  if [ -z "$err" ] && [ "$keep_runs" = 0 ] && [ "$keep_days" = 0 ]; then
    _add_err keep_days "Нельзя одновременно занулить оба лимита хранения истории."
  fi
  if [ -z "$geo_filter" ]; then
    _add_err geo_filter "Гео-фильтр обязателен - без него подписка может подставить российскую ноду."
  else
    case $geo_filter in
      *"
"*) _add_err geo_filter "Гео-фильтр не должен содержать перевод строки." ;;
      '|'*|*'|'|*'||'*) _add_err geo_filter "В гео-фильтре есть пустые куски: лишний | в начале, в конце или два подряд." ;;
    esac
    if [ "${#geo_filter}" -gt 4000 ]; then
      _add_err geo_filter "Гео-фильтр должен быть не длиннее 4000 символов."
    fi
  fi
  if ! is_decimal_in_range "$size_mb" 1 incl 100; then
    _add_err size_mb "Размер файла для замера должен быть числом от 1 до 100 МБ."
  fi
  if ! is_uint "$dl_timeout" || [ "$dl_timeout" -lt 1 ] || [ "$dl_timeout" -gt 120 ]; then
    _add_err dl_timeout "Таймаут закачки должен быть целым числом от 1 до 120 секунд."
  fi
  if ! is_decimal_in_range "$min_speed_mb" 0 excl 10000; then
    _add_err min_speed_mb "Порог скорости должен быть числом больше 0 и не больше 10000 Мбит/с."
  fi
  if ! is_decimal_in_range "$min_ratio" 0 excl 1; then
    _add_err min_ratio "Доля канала должна быть числом больше 0 и не больше 1 (например 0.25)."
  fi
  if ! is_decimal_in_range "$min_floor_mb" 0 incl ""; then
    _add_err min_floor_mb "Абсолютный минимум порога должен быть числом от 0 Мбит/с (0 = без минимума)."
  fi
  if ! is_uint "$topn" || [ "$topn" -lt 1 ] || [ "$topn" -gt 50 ]; then
    _add_err topn "Число нод в fast.yaml (TOPN) должно быть целым от 1 до 50."
  fi
  if ! is_uint "$enough" || [ "$enough" -lt 1 ] || [ "$enough" -gt 100 ]; then
    _add_err enough "«Хватит нод выше порога» должно быть целым от 1 до 100."
  fi
  if ! is_uint "$min_winners" || [ "$min_winners" -gt 50 ]; then
    _add_err min_winners "Минимум нод-победителей должен быть целым от 0 до 50."
  fi
  if ! is_uint "$stability_window" || [ "$stability_window" -lt 1 ] || [ "$stability_window" -gt 5000 ]; then
    _add_err stability_window "Длина окна стабильности должна быть целым от 1 до 5000 прогонов."
  fi
  if ! is_uint "$stability_drop_after"; then
    _add_err stability_drop_after "«Удалять ноду после» должно быть целым числом (0 = не удалять)."
  fi
  [ -z "$err" ]
}

print_settings_json() {
  # JSON-ответ для /api/settings (шаг 4, см.
  # docs/plans/2026-09-12-web-spa-migration-design.md) - включается
  # переменной окружения API_JSON=1, которую stats_httpd.py добавляет
  # только для алиаса "/api/settings" (см. API_ALIASES в stats_httpd.py).
  # С 2026-09-28 HTML-формы нет, и JSON отдаётся всегда, независимо от
  # API_JSON. GET - текущие значения полей ($STATS_NODE_CAP/$BLOCK/...).
  # POST - результат validate_settings_fields()/сохранения выше:
  # {"ok":true} либо {"ok":false,"errors":{"поле":"сообщение",...}}
  # (errors собран из err_fields - см. _add_err()).
  echo "Content-Type: application/json; charset=utf-8"
  echo

  if [ "$method" = "POST" ]; then
    if [ -n "$err" ]; then
      printf '%s\n' "$err_fields" | awk -F'|' '
        function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
        BEGIN { printf "{\"ok\":false,\"errors\":{"; first = 1 }
        NF >= 2 {
          field = $1
          msg = $0
          sub(/^[^|]*\|/, "", msg)
          if (!first) printf ","
          first = 0
          printf "\"%s\":\"%s\"", esc(field), esc(msg)
        }
        END { printf "}}" }'
    else
      printf '{"ok":true}'
    fi
    return 0
  fi

  # geo_filter/extype - через окружение процесса (ENVIRON[] в
  # awk), а не "-v": awk сам разбирает escape-последовательности внутри
  # значений "-v" (POSIX) - буквальный "\\" в регулярном выражении
  # гео-фильтра мог бы незаметно потеряться. Числовые поля ниже такому
  # риску не подвержены (уже провалидированы как целые/десятичные) -
  # для них "-v" как и везде в проекте.
  MST_API_GEO="$BLOCK" MST_API_EXTYPE="$EXTYPE" \
  awk -v node_cap="$STATS_NODE_CAP" -v keep_runs="$HISTORY_KEEP_RUNS" \
      -v keep_days="$HISTORY_KEEP_DAYS" \
      -v max_tested="$MAX_TESTED" \
      -v size_mb="$(bytes_to_mb "$SIZE")" -v dl_timeout="$DL_TIMEOUT" \
      -v min_speed_mb="$(bytes_to_mbit "$MIN_SPEED")" -v min_ratio="$MIN_RATIO" \
      -v min_floor_mb="$(bytes_to_mbit "$MIN_FLOOR")" -v topn="$TOPN" -v enough="$ENOUGH" \
      -v min_winners="$MIN_WINNERS" -v stability_window="$STABILITY_WINDOW" \
      -v stability_drop_after="$STABILITY_DROP_AFTER" '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    BEGIN {
      geo_filter = ENVIRON["MST_API_GEO"]
      extype = ENVIRON["MST_API_EXTYPE"]
      printf "{\"ok\":true,\"values\":{"
      printf "\"max_tested\":%d,", max_tested + 0
      printf "\"node_cap\":%d,\"keep_runs\":%d,\"keep_days\":%d,", node_cap + 0, keep_runs + 0, keep_days + 0
      printf "\"geo_filter\":\"%s\",\"extype\":\"%s\",", esc(geo_filter), esc(extype)
      printf "\"size_mb\":%s,\"dl_timeout\":%d,", size_mb + 0, dl_timeout + 0
      printf "\"min_speed_mb\":%s,\"min_ratio\":%s,\"min_floor_mb\":%s,", min_speed_mb + 0, min_ratio + 0, min_floor_mb + 0
      printf "\"topn\":%d,\"enough\":%d,\"min_winners\":%d,", topn + 0, enough + 0, min_winners + 0
      printf "\"stability_window\":%d,\"stability_drop_after\":%d,", stability_window + 0, stability_drop_after + 0
      printf "\"geo_filter_candidates\":["
      gf_first = 1
    }
    { if ($0 == "") next; if (!gf_first) printf ","; gf_first = 0; printf "\"%s\"", esc($0) }
    END { printf "]}}" }' <<GEOFILTER_CANDIDATES
$geo_filter_candidates_raw
GEOFILTER_CANDIDATES
}

method=${REQUEST_METHOD:-GET}
err=""

if [ "$method" = "POST" ]; then
  len=${CONTENT_LENGTH:-0}
  is_uint "$len" || len=0
  if [ "$len" -gt 0 ]; then
    body=$(dd bs=1 count="$len" 2>/dev/null)
  else
    body=""
  fi

  RAW_node_cap=""; RAW_keep_runs=""; RAW_keep_days=""; RAW_geo_filter=""; RAW_extype=""
  RAW_size_mb=""; RAW_dl_timeout=""; RAW_min_speed_mb=""; RAW_min_ratio=""
  RAW_min_floor_mb=""; RAW_topn=""; RAW_enough=""; RAW_min_winners=""
  RAW_stability_window=""; RAW_stability_drop_after=""
  RAW_max_tested="$MAX_TESTED"
  eval "$(parse_body_fields)"

  node_cap=$(urldecode "$RAW_node_cap")
  max_tested=$(urldecode "$RAW_max_tested")
  keep_runs=$(urldecode "$RAW_keep_runs")
  keep_days=$(urldecode "$RAW_keep_days")
  geo_filter=$(normalize_block "$(urldecode "$RAW_geo_filter")")
  extype=$(urldecode "$RAW_extype")
  size_mb=$(urldecode "$RAW_size_mb")
  dl_timeout=$(urldecode "$RAW_dl_timeout")
  min_speed_mb=$(urldecode "$RAW_min_speed_mb")
  min_ratio=$(urldecode "$RAW_min_ratio")
  min_floor_mb=$(urldecode "$RAW_min_floor_mb")
  topn=$(urldecode "$RAW_topn")
  enough=$(urldecode "$RAW_enough")
  min_winners=$(urldecode "$RAW_min_winners")
  stability_window=$(urldecode "$RAW_stability_window")
  stability_drop_after=$(urldecode "$RAW_stability_drop_after")

  validate_settings_fields

  if [ -z "$err" ]; then
    set_env_var MAX_TESTED "$max_tested"
    set_env_var STATS_NODE_CAP "$node_cap"
    set_env_var HISTORY_KEEP_RUNS "$keep_runs"
    set_env_var HISTORY_KEEP_DAYS "$keep_days"
    set_env_var BLOCK "$geo_filter"
    set_env_var EXTYPE "$extype"
    set_env_var SIZE "$(mb_to_bytes "$size_mb")"
    set_env_var DL_TIMEOUT "$dl_timeout"
    set_env_var MIN_SPEED "$(mbit_to_bytes "$min_speed_mb")"
    set_env_var MIN_RATIO "$min_ratio"
    set_env_var MIN_FLOOR "$(mbit_to_bytes "$min_floor_mb")"
    set_env_var TOPN "$topn"
    set_env_var ENOUGH "$enough"
    set_env_var MIN_WINNERS "$min_winners"
    set_env_var STABILITY_WINDOW "$stability_window"
    set_env_var STABILITY_DROP_AFTER "$stability_drop_after"
    # перечитываем свежесохранённые значения и применяем сразу, не дожидаясь
    # следующего прогона по cron: перегенерируем stats.json (новый NODE_CAP)
    # немедленно. render_stats() с порции 2 сама больше не трогает
    # HTTP-процесс - если поменялись логин/пароль, веб-сервис перезапускает
    # независимая служба через явный reconfigure (порция 3), а не эта форма
    # напрямую.
    [ -f "$ENV" ] && . "$ENV"
    WORK=$(mktemp -d "${TMPROOT:-/tmp}/mst-cgi.XXXXXX" 2>/dev/null) || WORK=${TMPROOT:-/tmp}/mst-cgi.$$
    mkdir -p "$WORK" 2>/dev/null
    RUN_LOG=$WORK/cgi.log
    render_stats
    rm -rf "$WORK"

  fi
fi

# Кандидаты гео-фильтра из текущего config.yaml - те же, что install.sh
# предложил бы при переустановке (providers.awk ищет exclude-filter у
# proxy-providers). Файла может не быть или providers.awk не найти в нём
# провайдеров - тогда просто нет подсказок (пустой
# geo_filter_candidates_raw), список кандидатов в JSON пуст.
BLOCK_COUNT=0
MIHOMO_DIR=${MIHOMO_DIR:-/opt/etc/mihomo}
CONFIG_YAML=$MIHOMO_DIR/config.yaml
if [ -f "$CONFIG_YAML" ] && [ -n "${UPDATE_PROVIDERS_AWK:-}" ] && [ -f "$UPDATE_PROVIDERS_AWK" ]; then
  block_candidates=$(awk -v CONFIG="$CONFIG_YAML" -v CONFDIR="$MIHOMO_DIR" -f "$UPDATE_PROVIDERS_AWK" "$CONFIG_YAML" 2>/dev/null | grep -E '^BLOCK_(COUNT|[0-9]+)=')
  [ -n "$block_candidates" ] && eval "$block_candidates"
fi
geo_filter_candidates_raw=""
i=1
while [ "$i" -le "$BLOCK_COUNT" ]; do
  eval "cand=\$BLOCK_$i"
  geo_filter_candidates_raw="${geo_filter_candidates_raw}${cand}
"
  i=$((i + 1))
done

# Ответ всегда JSON (GET - текущие значения, POST - итог сохранения).
# HTML-форма настроек удалена 2026-09-28 вместе с остальным старым
# HTML-интерфейсом: stats_httpd.py и так перенаправлял GET /cgi-bin/config
# на /settings и отвечал 410 на POST туда, так что форма была недостижима.
print_settings_json
