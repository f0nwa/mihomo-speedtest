#!/bin/sh
# CGI-скрипт формы настройки статистики speedtest2 (см. README.md, раздел
# про stats_www/cgi-bin/config). Ставится install.sh в $DIR/stats_cgi.sh;
# в раздаваемый каталог (STATS_CGI_SCRIPT, обычно $DIR/stats_www/cgi-bin/config)
# его копирует write_stats_cgi() из speedtest2.sh при каждом прогоне
# ensure_stats_httpd() - править нужно этот файл, копия перезаписывается
# автоматически и правки в ней не сохранятся.
#
# Полагается на то, что busybox httpd передаёт CGI-процессу окружение
# родителя: ensure_stats_httpd() в speedtest2.sh экспортирует DIR и ENV
# перед запуском веб-сервиса, поэтому сорс "$DIR/speedtest2.sh" ниже
# подхватывает те же настройки (включая текущий speedtest2.env), что и
# обычный прогон по cron - в т.ч. пересчитывает все зависящие от DIR пути
# (HISTORY_RUNS, STATS_HTML и т.д.), а не только те, что перечислены тут.

export MST_LIB_ONLY=1
[ -n "$DIR" ] && [ -f "$DIR/speedtest2.sh" ] && . "$DIR/speedtest2.sh"
MAX_PING_MS=${MAX_PING_MS:-500}
MAX_TESTED=${MAX_TESTED:-40}

if [ -z "$DIR" ] || ! command -v render_stats >/dev/null 2>&1; then
  echo "Content-Type: text/plain; charset=utf-8"
  echo
  echo "Ошибка конфигурации: не удалось подключить speedtest2.sh (DIR=[$DIR])."
  echo "Обычно это значит, что CGI запущен не через busybox httpd, поднятый ensure_stats_httpd()."
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

html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
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
  # $1=условное имя поля (для err_fields - задел под будущий JSON-путь
  # /api/settings, шаг 4), $2=текст сообщения без HTML-разметки. Пишет
  # сразу в обе глобальные переменные - err (HTML, с <br> между
  # сообщениями, как было раньше) и err_fields (по строке
  # "поле|сообщение" на ошибку, без HTML-разметки) - у обеих один и тот
  # же вызов validate_settings_fields() ниже как единственный источник
  # правил.
  err="${err}$2<br>"
  err_fields="${err_fields}$1|$2
"
}

validate_settings_fields() {
  # Проверяет уже раскодированные значения полей формы настройки (18
  # штук: node_cap, keep_runs, keep_days, geo_filter, extype, size_mb,
  # dl_timeout, min_speed_mb, min_ratio, min_floor_mb, topn, enough,
  # min_winners, stability_window, stability_drop_after, no_auth,
  # auth_user, auth_pass - берутся из одноимённых shell-переменных,
  # устанавливаемых ДО вызова этой функции: сегодня - urldecode() из тела
  # POST HTML-формы ниже, в будущем (шаг 4, см.
  # docs/plans/2026-09-12-web-spa-migration-design.md) - разбором
  # JSON-тела POST /api/settings). Ни $ENV, ни другие файлы не трогает -
  # только заполняет err/err_fields (см. _add_err()) и возвращает 0, если
  # ошибок нет, иначе 1. Один набор правил на оба вызывающих пути - при
  # подключении JSON API в шаге 4 их не дублировать, а звать эту же
  # функцию.
  err=""
  err_fields=""

  if ! is_uint "$max_ping_ms"; then
    _add_err max_ping_ms "Предел задержки должен быть целым числом от 0 мс (0 = без ограничения)."
  fi
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
  fi
  if ! is_decimal_in_range "$size_mb" 1 incl 100; then
    _add_err size_mb "Размер файла для замера должен быть числом от 1 до 100 МБ."
  fi
  if ! is_uint "$dl_timeout" || [ "$dl_timeout" -lt 1 ] || [ "$dl_timeout" -gt 120 ]; then
    _add_err dl_timeout "Таймаут закачки должен быть целым числом от 1 до 120 секунд."
  fi
  if ! is_decimal_in_range "$min_speed_mb" 0 excl 1000; then
    _add_err min_speed_mb "Порог скорости должен быть числом больше 0 и не больше 1000 МБ/с."
  fi
  if ! is_decimal_in_range "$min_ratio" 0 excl 1; then
    _add_err min_ratio "Доля канала должна быть числом больше 0 и не больше 1 (например 0.25)."
  fi
  if ! is_decimal_in_range "$min_floor_mb" 0 incl ""; then
    _add_err min_floor_mb "Абсолютный минимум порога должен быть числом от 0 МБ/с (0 = без минимума)."
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
  if [ -z "$no_auth" ]; then
    if [ -n "$auth_user" ] && [ -z "$auth_pass" ]; then
      _add_err auth_pass "Для смены пароля укажите и логин, и пароль."
    elif [ -z "$auth_user" ] && [ -n "$auth_pass" ]; then
      _add_err auth_user "Для смены пароля укажите и логин, и пароль."
    fi
  fi

  [ -z "$err" ]
}

print_settings_json() {
  # JSON-ответ для /api/settings (шаг 4, см.
  # docs/plans/2026-09-12-web-spa-migration-design.md) - включается
  # переменной окружения API_JSON=1, которую stats_httpd.py добавляет
  # только для алиаса "/api/settings" (см. API_ALIASES в stats_httpd.py) -
  # обычный "/cgi-bin/config" её не получает и продолжает отдавать HTML
  # форму как раньше. GET - текущие значения полей (те же переменные,
  # что подставляются в HTML-форму ниже - $STATS_NODE_CAP/$BLOCK/...).
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

  # geo_filter/extype/auth_user - через окружение процесса (ENVIRON[] в
  # awk), а не "-v": awk сам разбирает escape-последовательности внутри
  # значений "-v" (POSIX) - буквальный "\\" в регулярном выражении
  # гео-фильтра мог бы незаметно потеряться. Числовые поля ниже такому
  # риску не подвержены (уже провалидированы как целые/десятичные) -
  # для них "-v" как и везде в проекте.
  MST_API_GEO="$BLOCK" MST_API_EXTYPE="$EXTYPE" MST_API_AUTHUSER="$STATS_AUTH_USER" \
  awk -v node_cap="$STATS_NODE_CAP" -v keep_runs="$HISTORY_KEEP_RUNS" \
      -v keep_days="$HISTORY_KEEP_DAYS" \
      -v max_ping_ms="$MAX_PING_MS" -v max_tested="$MAX_TESTED" \
      -v size_mb="$(bytes_to_mb "$SIZE")" -v dl_timeout="$DL_TIMEOUT" \
      -v min_speed_mb="$(bytes_to_mb "$MIN_SPEED")" -v min_ratio="$MIN_RATIO" \
      -v min_floor_mb="$(bytes_to_mb "$MIN_FLOOR")" -v topn="$TOPN" -v enough="$ENOUGH" \
      -v min_winners="$MIN_WINNERS" -v stability_window="$STABILITY_WINDOW" \
      -v stability_drop_after="$STABILITY_DROP_AFTER" '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    BEGIN {
      geo_filter = ENVIRON["MST_API_GEO"]
      extype = ENVIRON["MST_API_EXTYPE"]
      auth_user = ENVIRON["MST_API_AUTHUSER"]
      printf "{\"ok\":true,\"values\":{"
      printf "\"max_ping_ms\":%d,\"max_tested\":%d,", max_ping_ms + 0, max_tested + 0
      printf "\"node_cap\":%d,\"keep_runs\":%d,\"keep_days\":%d,", node_cap + 0, keep_runs + 0, keep_days + 0
      printf "\"geo_filter\":\"%s\",\"extype\":\"%s\",", esc(geo_filter), esc(extype)
      printf "\"size_mb\":%s,\"dl_timeout\":%d,", size_mb + 0, dl_timeout + 0
      printf "\"min_speed_mb\":%s,\"min_ratio\":%s,\"min_floor_mb\":%s,", min_speed_mb + 0, min_ratio + 0, min_floor_mb + 0
      printf "\"topn\":%d,\"enough\":%d,\"min_winners\":%d,", topn + 0, enough + 0, min_winners + 0
      printf "\"stability_window\":%d,\"stability_drop_after\":%d,", stability_window + 0, stability_drop_after + 0
      printf "\"has_auth\":%s,\"auth_user\":\"%s\",", (auth_user == "" ? "false" : "true"), esc(auth_user)
      printf "\"geo_filter_candidates\":["
      gf_first = 1
    }
    { if ($0 == "") next; if (!gf_first) printf ","; gf_first = 0; printf "\"%s\"", esc($0) }
    END { printf "]}}" }' <<GEOFILTER_CANDIDATES
$geo_filter_candidates_raw
GEOFILTER_CANDIDATES
}

method=${REQUEST_METHOD:-GET}
msg=""
err=""

if [ "$method" = "POST" ]; then
  len=${CONTENT_LENGTH:-0}
  is_uint "$len" || len=0
  if [ "$len" -gt 0 ]; then
    body=$(dd bs=1 count="$len" 2>/dev/null)
  else
    body=""
  fi

  RAW_node_cap=""; RAW_keep_runs=""; RAW_keep_days=""; RAW_auth_user=""
  RAW_auth_pass=""; RAW_no_auth=""; RAW_geo_filter=""; RAW_extype=""
  RAW_size_mb=""; RAW_dl_timeout=""; RAW_min_speed_mb=""; RAW_min_ratio=""
  RAW_min_floor_mb=""; RAW_topn=""; RAW_enough=""; RAW_min_winners=""
  RAW_stability_window=""; RAW_stability_drop_after=""
  RAW_max_ping_ms="$MAX_PING_MS"; RAW_max_tested="$MAX_TESTED"
  eval "$(parse_body_fields)"

  node_cap=$(urldecode "$RAW_node_cap")
  max_ping_ms=$(urldecode "$RAW_max_ping_ms")
  max_tested=$(urldecode "$RAW_max_tested")
  keep_runs=$(urldecode "$RAW_keep_runs")
  keep_days=$(urldecode "$RAW_keep_days")
  auth_user=$(urldecode "$RAW_auth_user")
  auth_pass=$(urldecode "$RAW_auth_pass")
  no_auth=$(urldecode "$RAW_no_auth")
  geo_filter=$(urldecode "$RAW_geo_filter")
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
    set_env_var MAX_PING_MS "$max_ping_ms"
    set_env_var MAX_TESTED "$max_tested"
    set_env_var STATS_NODE_CAP "$node_cap"
    set_env_var HISTORY_KEEP_RUNS "$keep_runs"
    set_env_var HISTORY_KEEP_DAYS "$keep_days"
    set_env_var BLOCK "$geo_filter"
    set_env_var EXTYPE "$extype"
    set_env_var SIZE "$(mb_to_bytes "$size_mb")"
    set_env_var DL_TIMEOUT "$dl_timeout"
    set_env_var MIN_SPEED "$(mb_to_bytes "$min_speed_mb")"
    set_env_var MIN_RATIO "$min_ratio"
    set_env_var MIN_FLOOR "$(mb_to_bytes "$min_floor_mb")"
    set_env_var TOPN "$topn"
    set_env_var ENOUGH "$enough"
    set_env_var MIN_WINNERS "$min_winners"
    set_env_var STABILITY_WINDOW "$stability_window"
    set_env_var STABILITY_DROP_AFTER "$stability_drop_after"
    if [ -n "$no_auth" ]; then
      set_env_var STATS_AUTH_USER ""
      set_env_var STATS_AUTH_PASS ""
    elif [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then
      set_env_var STATS_AUTH_USER "$auth_user"
      set_env_var STATS_AUTH_PASS "$auth_pass"
    fi

    # перечитываем свежесохранённые значения и применяем сразу, не дожидаясь
    # следующего прогона по cron: перегенерируем stats.html (новый NODE_CAP)
    # и переподнимаем веб-сервис (новые логин/пароль/защита cgi-bin).
    [ -f "$ENV" ] && . "$ENV"
    WORK=$(mktemp -d "${TMPROOT:-/tmp}/mst-cgi.XXXXXX" 2>/dev/null) || WORK=${TMPROOT:-/tmp}/mst-cgi.$$
    mkdir -p "$WORK" 2>/dev/null
    RUN_LOG=$WORK/cgi.log
    render_stats
    ensure_stats_httpd
    rm -rf "$WORK"
    msg="Настройки сохранены."
  fi
fi

# Кандидаты гео-фильтра из текущего config.yaml - те же, что install.sh
# предложил бы при переустановке (providers.awk ищет exclude-filter у
# proxy-providers). Файла может не быть или providers.awk не найти в нём
# провайдеров - тогда просто нет подсказок (пустой geo_filter_options /
# geo_filter_candidates_raw), поле в форме/API остаётся обычным текстовым.
# Нужно и HTML-пути (datalist ниже), и JSON-пути (print_settings_json) -
# посчитано один раз здесь, до ветвления по API_JSON.
BLOCK_COUNT=0
CONFIG_YAML=$DIR/config.yaml
if [ -f "$CONFIG_YAML" ] && [ -n "${UPDATE_PROVIDERS_AWK:-}" ] && [ -f "$UPDATE_PROVIDERS_AWK" ]; then
  block_candidates=$(awk -v CONFIG="$CONFIG_YAML" -v CONFDIR="$DIR" -f "$UPDATE_PROVIDERS_AWK" "$CONFIG_YAML" 2>/dev/null | grep -E '^BLOCK_(COUNT|[0-9]+)=')
  [ -n "$block_candidates" ] && eval "$block_candidates"
fi
geo_filter_options=""
geo_filter_candidates_raw=""
i=1
while [ "$i" -le "$BLOCK_COUNT" ]; do
  eval "cand=\$BLOCK_$i"
  geo_filter_options="$geo_filter_options<option value=\"$(html_escape "$cand")\">
"
  geo_filter_candidates_raw="${geo_filter_candidates_raw}${cand}
"
  i=$((i + 1))
done

if [ -n "${API_JSON:-}" ]; then
  print_settings_json
  exit 0
fi

echo "Content-Type: text/html; charset=utf-8"
echo

cat <<HTML
<!doctype html><meta charset="utf-8">
<title>speedtest2 - настройка статистики</title>
<style>
:root{--bg:#f5f6f8;--card:#ffffff;--card-border:#e2e2e2;--text:#1b1f24;--muted:#666666;--border:#e2e2e2;--shadow:0 1px 2px rgba(15,17,21,.06);--accent:#2a78d6}
@media (prefers-color-scheme: dark){:root{--bg:#0b0d12;--card:#161a21;--card-border:#262b33;--text:#e7e9ec;--muted:#9aa0a6;--border:#262b33;--shadow:0 1px 3px rgba(0,0,0,.4);--accent:#2a78d6}}
:root[data-theme="light"]{--bg:#f5f6f8;--card:#ffffff;--card-border:#e2e2e2;--text:#1b1f24;--muted:#666666;--border:#e2e2e2;--shadow:0 1px 2px rgba(15,17,21,.06);--accent:#2a78d6}
:root[data-theme="dark"]{--bg:#0b0d12;--card:#161a21;--card-border:#262b33;--text:#e7e9ec;--muted:#9aa0a6;--border:#262b33;--shadow:0 1px 3px rgba(0,0,0,.4);--accent:#2a78d6}
*{box-sizing:border-box}
body{font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;margin:0;background:var(--bg);color:var(--text)}
.wrap{max-width:520px;margin:0 auto;padding:20px 16px 40px}
header{display:flex;align-items:flex-start;justify-content:space-between;gap:12px;margin-bottom:16px}
h1{font-size:19px;margin:0}
.meta{color:var(--muted);font-size:12.5px;margin:2px 0 0}
.theme-btn{border:1px solid var(--card-border);background:var(--card);color:var(--text);border-radius:8px;padding:6px 10px;font-size:13px;cursor:pointer;text-decoration:none;display:inline-block;flex:0 0 auto}
.card{background:var(--card);border:1px solid var(--card-border);border-radius:14px;padding:16px 18px;margin-bottom:16px;box-shadow:var(--shadow)}
h2{font-size:14.5px;margin:0 0 8px;font-weight:600}
label{display:block;font-size:13px;color:var(--muted);margin:12px 0 4px}
label:first-child{margin-top:0}
input[type=text],input[type=password],input[type=number]{width:100%;padding:7px 9px;border:1px solid var(--card-border);border-radius:6px;background:var(--bg);color:var(--text);font-size:14px}
.hint{color:var(--muted);font-size:12px;margin:4px 0 0}
.row-checkbox{display:flex;align-items:center;gap:6px;margin-top:12px}
.row-checkbox label{margin:0}
button.submit{margin-top:16px;padding:8px 16px;border:0;border-radius:8px;background:var(--accent);color:#fff;font-size:14px;cursor:pointer;box-shadow:var(--shadow)}
.msg-ok{background:#16a34a22;border:1px solid #16a34a;border-radius:8px;padding:8px 12px;margin-bottom:16px;font-size:13px}
.msg-err{background:#dc262622;border:1px solid #dc2626;border-radius:8px;padding:8px 12px;margin-bottom:16px;font-size:13px}
</style>
<div class="wrap">
<header>
<div><h1>Настройка статистики</h1><p class="meta">speedtest2</p></div>
<div style="display:flex;gap:8px;flex:0 0 auto">
<a class="theme-btn" href="../stats.html">К статистике</a>
<button class="theme-btn" id="themeBtn" type="button">Тема</button>
</div>
</header>
HTML

[ -n "$msg" ] && printf '<p class="msg-ok">%s</p>\n' "$(html_escape "$msg")"
[ -n "$err" ] && printf '<p class="msg-err">%s</p>\n' "$err"

cur_auth_user=$(html_escape "$STATS_AUTH_USER")

cat <<HTML
<form method="post">
<div class="card">
<h2>Гео-фильтр (BLOCK)</h2>
<label for="geo_filter">Регулярное выражение для исключения нод</label>
<input type="text" id="geo_filter" name="geo_filter" list="geo_filter_options" value="$(html_escape "$BLOCK")" autocomplete="off">
<datalist id="geo_filter_options">
$geo_filter_options</datalist>
<p class="hint">Обязательное поле - без него подписка может подставить российскую ноду, которая выиграет замер по пингу. Подсказки в списке - варианты exclude-filter, найденные в текущем config.yaml.</p>
</div>
<div class="card">
<h2>Как тестируем ноды</h2>
<label for="extype">Исключить типы нод целиком (через |)</label>
<input type="text" id="extype" name="extype" value="$(html_escape "$EXTYPE")" placeholder="например trojan|ss" autocomplete="off">
<p class="hint">Пусто = тестировать все типы, которые понимает mihomo.</p>
<label for="size_mb">Размер файла для замера, МБ</label>
<input type="number" min="1" max="100" step="any" id="size_mb" name="size_mb" value="$(html_escape "$(bytes_to_mb "$SIZE")")">
<p class="hint">Меньше 10 МБ занижает результат - треть времени уходит на TTFB.</p>
<label for="dl_timeout">Таймаут закачки, сек</label>
<input type="number" min="1" max="120" id="dl_timeout" name="dl_timeout" value="$(html_escape "$DL_TIMEOUT")">
</div>
<div class="card">
<h2>Порог и число нод в fast.yaml</h2>
<label for="min_speed_mb">Порог отбора (для текущего канала), МБ/с</label>
<input type="number" min="0.1" max="1000" step="any" id="min_speed_mb" name="min_speed_mb" value="$(html_escape "$(bytes_to_mb "$MIN_SPEED")")">
<p class="hint">Пересчитывается install.sh при переустановке от прямого замера канала - здесь можно поправить вручную.</p>
<label for="min_ratio">Динамический порог, доля от прямого канала</label>
<input type="number" min="0.01" max="1" step="any" id="min_ratio" name="min_ratio" value="$(html_escape "$MIN_RATIO")">
<label for="min_floor_mb">Абсолютный минимум порога, МБ/с (0 = без минимума)</label>
<input type="number" min="0" step="any" id="min_floor_mb" name="min_floor_mb" value="$(html_escape "$(bytes_to_mb "$MIN_FLOOR")")">
<label for="max_ping_ms">Максимальная задержка кандидата, мс (0 = без ограничения)</label>
<input type="number" min="0" id="max_ping_ms" name="max_ping_ms" value="$(html_escape "$MAX_PING_MS")">
<label for="max_tested">Максимум кандидатов на скоростной тест (0 = без ограничения)</label>
<input type="number" min="0" id="max_tested" name="max_tested" value="$(html_escape "$MAX_TESTED")">
<label for="topn">Сколько нод класть в fast.yaml (TOPN)</label>
<input type="number" min="1" max="50" id="topn" name="topn" value="$(html_escape "$TOPN")">
<label for="enough">Хватит нод выше порога - дальше не мерить</label>
<input type="number" min="1" max="100" id="enough" name="enough" value="$(html_escape "$ENOUGH")">
<label for="min_winners">Минимум нод в fast.yaml, даже ниже порога</label>
<input type="number" min="0" max="50" id="min_winners" name="min_winners" value="$(html_escape "$MIN_WINNERS")">
<p class="hint">Если рабочих нод меньше TOPN - добор идёт по убыванию скорости, пока не наберётся этот минимум.</p>
</div>
<div class="card">
<h2>Стабильность нод</h2>
<label for="stability_window">Длина окна "недавних" прогонов</label>
<input type="number" min="1" max="5000" id="stability_window" name="stability_window" value="$(html_escape "$STABILITY_WINDOW")">
<p class="hint">В прогонах, не в днях - 200 при прогоне раз в 3 часа - это около месяца. Влияет только на таблицу "Доступность нод пула" на stats.html.</p>
<label for="stability_drop_after">Удалять ноду после стольких прогонов подряд без неё в пуле (0 = не удалять)</label>
<input type="number" min="0" id="stability_drop_after" name="stability_drop_after" value="$(html_escape "$STABILITY_DROP_AFTER")">
</div>
<div class="card">
<h2>График по нодам</h2>
<label for="node_cap">Число нод на графике (1-8)</label>
<input type="number" min="1" max="8" id="node_cap" name="node_cap" value="$(html_escape "$STATS_NODE_CAP")">
<p class="hint">Больше 8 не поддерживается - столько цветов в палитре легенды.</p>
</div>
<div class="card">
<h2>Хранение истории</h2>
<label for="keep_runs">Хранить прогонов (0 = не ограничивать)</label>
<input type="number" min="0" id="keep_runs" name="keep_runs" value="$(html_escape "$HISTORY_KEEP_RUNS")">
<label for="keep_days">Хранить дней (0 = не ограничивать)</label>
<input type="number" min="0" id="keep_days" name="keep_days" value="$(html_escape "$HISTORY_KEEP_DAYS")">
<p class="hint">Нельзя занулить оба сразу.</p>
</div>
<div class="card">
<h2>Защита формы настройки</h2>
<p class="hint">Страница статистики (stats.html) всегда открыта без пароля. Этой формой можно закрыть только саму настройку.</p>
<label for="auth_user">Логин</label>
<input type="text" id="auth_user" name="auth_user" placeholder="$([ -n "$cur_auth_user" ] && echo "текущий: $cur_auth_user" || echo "не задан")" autocomplete="off">
<label for="auth_pass">Новый пароль</label>
<input type="password" id="auth_pass" name="auth_pass" placeholder="оставьте пустым, если не меняете" autocomplete="new-password">
<div class="row-checkbox">
<input type="checkbox" id="no_auth" name="no_auth" value="1">
<label for="no_auth">Отключить защиту (доступ без пароля)</label>
</div>
</div>
<button class="submit" type="submit">Сохранить</button>
</form>
</div>
<script>
(function(){
var KEY='speedtest2-theme';
var root=document.documentElement;
var btn=document.getElementById('themeBtn');
function label(){var cur=root.getAttribute('data-theme');btn.textContent=cur==='dark'?'Светлая тема':cur==='light'?'Тёмная тема':'Тема: авто';}
function apply(t){if(t){root.setAttribute('data-theme',t);}else{root.removeAttribute('data-theme');}label();}
var saved=null;
try{saved=localStorage.getItem(KEY);}catch(e){}
apply(saved);
btn.addEventListener('click',function(){
var cur=root.getAttribute('data-theme');
var next=cur==='dark'?'light':cur==='light'?null:'dark';
apply(next);
try{if(next){localStorage.setItem(KEY,next);}else{localStorage.removeItem(KEY);}}catch(e){}
});
})();
</script>
HTML
