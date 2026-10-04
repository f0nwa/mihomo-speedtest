#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-cgi-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  case "$2" in
    *"$1"*) ;;
    *) fail "expected to find: $1 (context: $3)" ;;
  esac
}

assert_not_contains() {
  case "$2" in
    *"$1"*) fail "expected NOT to find: $1 (context: $3)" ;;
  esac
}

# --- фикстура: DIR со своей копией speedtest2.sh/render_stats.awk/stats_cgi.sh
#     и пустой историей - как после свежего install.sh, но в tmp ---
W=$TEST_ROOT/w
mkdir -p "$W/stats_www"
cp "$ROOT/speedtest-runtime/speedtest2.sh" "$W/speedtest2.sh"
cp "$ROOT/web/render_stats.awk" "$W/render_stats.awk"
cp "$ROOT/web/stats_cgi.sh" "$W/stats_cgi.sh"
chmod +x "$W/speedtest2.sh" "$W/stats_cgi.sh"
cat > "$W/speedtest2.env" <<'EOF'
BLOCK='test'
EOF
: > "$W/speedtest_runs.tsv"
: > "$W/speedtest_history.tsv"

# Порция 3 (независимая служба): вместо ensure_stats_httpd() форма теперь
# вызывает "$STATS_INIT_SCRIPT reconfigure" только если поменялись
# логин/пароль (design, сценарий 12). Настоящий stats_init.sh здесь не
# нужен - подставляем фиктивный, который просто пишет свой аргумент в
# журнал, чтобы посчитать вызовы; переключается на "не найден"/"падает"
# отдельными сценариями ниже через сам STATS_INIT_SCRIPT.
FAKE_INITD=$W/fake_initd.sh
FAKE_INITD_LOG=$W/fake_initd.log
: > "$FAKE_INITD_LOG"
cat > "$FAKE_INITD" <<EOF2
#!/bin/sh
echo "\$1" >> "$FAKE_INITD_LOG"
exit 0
EOF2
chmod +x "$FAKE_INITD"

# Валидные значения новых полей (порция 2 - "параметры замера скорости"),
# отличные от дефолтов speedtest2.sh - чтобы отличать "сохранилось" от
# "совпало с дефолтом по случайности".
OK_TUNING="extype=custom&size_mb=20&dl_timeout=30&min_speed_mb=2&min_ratio=0.3&min_floor_mb=1&topn=15&enough=18&min_winners=2&stability_window=100&stability_drop_after=50&stable_min_uptime=70&stable_lookback=16&stable_min_runs=6"

run_cgi() {
  # $1=METHOD, $2=тело (для POST) или "" для GET. Печатает вывод CGI в stdout.
  # STATS_INIT_SCRIPT по умолчанию - фиктивный (см. FAKE_INITD выше);
  # отдельные сценарии переопределяют его через $3, если он задан.
  method=$1
  body=${2:-}
  initd=${3:-$FAKE_INITD}
  if [ "$method" = POST ]; then
    printf '%s' "$body" | DIR="$W" MIHOMO_DIR="$W" ENV="$W/speedtest2.env" STATS_INIT_SCRIPT="$initd" \
      REQUEST_METHOD=POST CONTENT_LENGTH=${#body} "$W/stats_cgi.sh"
  else
    DIR="$W" MIHOMO_DIR="$W" ENV="$W/speedtest2.env" STATS_INIT_SCRIPT="$initd" REQUEST_METHOD=GET "$W/stats_cgi.sh"
  fi
}

run_cgi_json() {
  # То же самое, что run_cgi(), но с API_JSON=1 - проверяет
  # print_settings_json() (шаг 4, /api/settings), а не HTML-форму.
  method=$1
  body=${2:-}
  initd=${3:-$FAKE_INITD}
  if [ "$method" = POST ]; then
    printf '%s' "$body" | DIR="$W" MIHOMO_DIR="$W" ENV="$W/speedtest2.env" API_JSON=1 STATS_INIT_SCRIPT="$initd" \
      REQUEST_METHOD=POST CONTENT_LENGTH=${#body} "$W/stats_cgi.sh"
  else
    DIR="$W" MIHOMO_DIR="$W" ENV="$W/speedtest2.env" API_JSON=1 STATS_INIT_SCRIPT="$initd" REQUEST_METHOD=GET "$W/stats_cgi.sh"
  fi
}

# --- GET без DIR: скрипт не должен падать, а вернуть понятную ошибку ---
OUT_NODIR=$(REQUEST_METHOD=GET "$W/stats_cgi.sh")
assert_contains "Content-Type: text/plain" "$OUT_NODIR" "no-DIR content-type"
assert_contains "Ошибка конфигурации" "$OUT_NODIR" "no-DIR error message"

# --- GET: значения по умолчанию (свежий speedtest2.env). HTML-формы нет с 2026-09-28 - всегда JSON ---
OUT_GET=$(run_cgi GET)
assert_contains 'Content-Type: application/json' "$OUT_GET" "GET content-type (HTML-формы больше нет, всегда JSON)"
assert_contains '"node_cap":8' "$OUT_GET" "GET default node_cap"
assert_contains '"keep_runs":200' "$OUT_GET" "GET default keep_runs"
assert_contains '"keep_days":30' "$OUT_GET" "GET default keep_days"
assert_not_contains '"auth_user"' "$OUT_GET" "GET has no legacy auth_user"
assert_not_contains '"auth_pass"' "$OUT_GET" "GET has no legacy auth_pass"
assert_not_contains '"no_auth"' "$OUT_GET" "GET has no auth disable switch"
assert_contains '"geo_filter":"test"' "$OUT_GET" "GET default geo_filter from fixture"
assert_contains '"extype":"trojan|ss"' "$OUT_GET" "GET default extype"
assert_contains '"size_mb":10' "$OUT_GET" "GET default size_mb (10485760 baytes)"
assert_contains '"dl_timeout":15' "$OUT_GET" "GET default dl_timeout"
assert_contains '"min_speed_mb":8.39' "$OUT_GET" "GET default min_speed_mb (1048576 baytes = 8.39 Mbit/s)"
assert_contains '"min_ratio":0.25' "$OUT_GET" "GET default min_ratio"
assert_contains '"min_floor_mb":4.19' "$OUT_GET" "GET default min_floor_mb (524288 baytes = 4.19 Mbit/s)"
assert_contains '"topn":15' "$OUT_GET" "GET default topn"
assert_contains '"enough":20' "$OUT_GET" "GET default enough"
assert_not_contains '"max_ping_ms"' "$OUT_GET" "GET has no misleading ping limit"
assert_contains '"max_tested":40' "$OUT_GET" "GET default candidate limit"
assert_contains '"min_winners":3' "$OUT_GET" "GET default min_winners"
assert_contains '"stability_window":200' "$OUT_GET" "GET default stability_window"
assert_contains '"stable_min_uptime":80' "$OUT_GET" "GET default stable_min_uptime"
assert_contains '"stable_lookback":24' "$OUT_GET" "GET default stable_lookback"
assert_contains '"stable_min_runs":8' "$OUT_GET" "GET default stable_min_runs"
assert_contains '"stability_drop_after":200' "$OUT_GET" "GET default stability_drop_after (= HISTORY_KEEP_RUNS)"
assert_contains '"update_channel":"stable"' "$OUT_GET" "GET default update_channel (stable)"

# --- POST валидный: сохраняет, перегенерирует stats.json, отвечает {"ok":true} ---
OUT_POST=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10&geo_filter=ru-block&$OK_TUNING&max_tested=12")
grep -qF "MAX_TESTED='12'" "$W/speedtest2.env" || fail "candidate limit not saved"
assert_contains '{"ok":true}' "$OUT_POST" "valid POST message"
grep -qF "STATS_NODE_CAP='3'" "$W/speedtest2.env" || fail "STATS_NODE_CAP not saved"
grep -qF "HISTORY_KEEP_RUNS='50'" "$W/speedtest2.env" || fail "HISTORY_KEEP_RUNS not saved"
grep -qF "HISTORY_KEEP_DAYS='10'" "$W/speedtest2.env" || fail "HISTORY_KEEP_DAYS not saved"
! grep -q '^STATS_AUTH_' "$W/speedtest2.env" || fail "settings must not write legacy auth variables"
grep -qF "BLOCK='ru-block'" "$W/speedtest2.env" || fail "geo_filter (BLOCK) not saved"
grep -qF "EXTYPE='custom'" "$W/speedtest2.env" || fail "EXTYPE not saved"
grep -qF "SIZE='20971520'" "$W/speedtest2.env" || fail "size_mb (SIZE) not converted/saved"
grep -qF "DL_TIMEOUT='30'" "$W/speedtest2.env" || fail "DL_TIMEOUT not saved"
grep -qF "MIN_SPEED='250000'" "$W/speedtest2.env" || fail "min_speed_mb (MIN_SPEED) not converted/saved"
grep -qF "MIN_RATIO='0.3'" "$W/speedtest2.env" || fail "MIN_RATIO not saved"
grep -qF "MIN_FLOOR='125000'" "$W/speedtest2.env" || fail "min_floor_mb (MIN_FLOOR) not converted/saved"
grep -qF "TOPN='15'" "$W/speedtest2.env" || fail "TOPN not saved"
grep -qF "ENOUGH='18'" "$W/speedtest2.env" || fail "ENOUGH not saved"
grep -qF "MIN_WINNERS='2'" "$W/speedtest2.env" || fail "MIN_WINNERS not saved"
grep -qF "STABILITY_WINDOW='100'" "$W/speedtest2.env" || fail "STABILITY_WINDOW not saved"
grep -qF "STABLE_MIN_UPTIME='70'" "$W/speedtest2.env" || fail "STABLE_MIN_UPTIME not saved"
grep -qF "STABLE_LOOKBACK='16'" "$W/speedtest2.env" || fail "STABLE_LOOKBACK not saved"
grep -qF "STABLE_MIN_RUNS='6'" "$W/speedtest2.env" || fail "STABLE_MIN_RUNS not saved"
grep -qF "STABILITY_DROP_AFTER='50'" "$W/speedtest2.env" || fail "STABILITY_DROP_AFTER not saved"
[ ! -e "$W/stats_www/stats.html" ] || fail "устаревший stats.html не должен появляться после сохранения настроек"
[ -s "$W/stats_www/stats.json" ] || fail "stats.json (JSON-режим render_stats.awk, шаг 4) was not (re)generated after valid POST"

# Настройки speedtest не меняют жизненный цикл веб-сервиса.
[ "$(wc -l < "$FAKE_INITD_LOG")" -eq 0 ] || fail "settings must not call reconfigure"

# --- GET снова: отдаются уже сохранённые значения ---
OUT_GET2=$(run_cgi GET)
assert_contains '"node_cap":3' "$OUT_GET2" "GET reflects saved node_cap"
assert_contains '"geo_filter":"ru-block"' "$OUT_GET2" "GET reflects saved geo_filter"
assert_contains '"size_mb":20' "$OUT_GET2" "GET reflects saved size_mb"
assert_contains '"min_floor_mb":1' "$OUT_GET2" "GET reflects saved min_floor_mb"
assert_contains '"stability_window":100' "$OUT_GET2" "GET reflects saved stability_window"

# --- POST невалидные значения не должны менять speedtest2.env ---
ENV_BEFORE=$(cat "$W/speedtest2.env")
OUT_LIMIT_BAD=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10&geo_filter=ru-block&$OK_TUNING&max_tested=no")
assert_contains 'Сколько нод проверять на скорость' "$OUT_LIMIT_BAD" "invalid candidate limit rejected"
[ "$(cat "$W/speedtest2.env")" = "$ENV_BEFORE" ] || fail "invalid limits changed settings"

OUT_BAD1=$(run_cgi POST "node_cap=51&keep_runs=50&keep_days=10&geo_filter=x&$OK_TUNING")
assert_contains "от 1 до 50" "$OUT_BAD1" "node_cap out of range"

OUT_BAD2=$(run_cgi POST "node_cap=3&keep_runs=abc&keep_days=10&geo_filter=x&$OK_TUNING")
assert_contains "целым числом" "$OUT_BAD2" "keep_runs not a number"

OUT_BAD3=$(run_cgi POST "node_cap=3&keep_runs=0&keep_days=0&geo_filter=x&$OK_TUNING")
assert_contains "занулить оба лимита" "$OUT_BAD3" "both retention limits zero"

OUT_BAD6=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10")
assert_contains "Гео-фильтр обязателен" "$OUT_BAD6" "empty geo_filter rejected"

OUT_BAD7=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10&geo_filter=x&extype=custom&size_mb=0&dl_timeout=30&min_speed_mb=2&min_ratio=0.3&min_floor_mb=1&topn=15&enough=18&min_winners=2")
assert_contains "от 1 до 100 МБ" "$OUT_BAD7" "size_mb out of range"

OUT_BAD8=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10&geo_filter=x&extype=custom&size_mb=20&dl_timeout=30&min_speed_mb=2&min_ratio=1.5&min_floor_mb=1&topn=15&enough=18&min_winners=2")
assert_contains "не больше 1" "$OUT_BAD8" "min_ratio out of range"

OUT_BAD9=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10&geo_filter=x&extype=custom&size_mb=20&dl_timeout=30&min_speed_mb=2&min_ratio=0.3&min_floor_mb=1&topn=0&enough=18&min_winners=2")
assert_contains "TOPN" "$OUT_BAD9" "topn out of range"

OUT_BAD10=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10&geo_filter=x&extype=custom&size_mb=20&dl_timeout=30&min_speed_mb=2&min_ratio=0.3&min_floor_mb=1&topn=15&enough=18&min_winners=2&stability_window=0&stability_drop_after=50")
assert_contains "окна стабильности" "$OUT_BAD10" "stability_window out of range"
OUT_BAD11=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10&geo_filter=x&extype=custom&size_mb=20&dl_timeout=30&min_speed_mb=2&min_ratio=0.3&min_floor_mb=1&topn=15&enough=18&min_winners=2&stability_window=100&stability_drop_after=50&stable_min_uptime=101")
assert_contains "Минимальный Uptime" "$OUT_BAD11" "stable_min_uptime out of range"

OUT_BAD11=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10&geo_filter=Russia%7C%7CRU-&$OK_TUNING")
assert_contains "пустые куски" "$OUT_BAD11" "geo_filter with empty segment rejected"
OUT_BAD12=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10&geo_filter=Russia%7C&$OK_TUNING")
assert_contains "пустые куски" "$OUT_BAD12" "geo_filter with trailing | rejected"
OUT_BAD13=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10&geo_filter=Russia%0ARU-&$OK_TUNING")
assert_contains "перевод строки" "$OUT_BAD13" "geo_filter with newline rejected"
HUGE_GEO=$(awk 'BEGIN{for(i=0;i<4100;i++) printf "a"}')
OUT_BAD14=$(run_cgi POST "node_cap=3&keep_runs=50&keep_days=10&geo_filter=$HUGE_GEO&$OK_TUNING")
assert_contains "4000" "$OUT_BAD14" "too long geo_filter rejected"

[ "$(cat "$W/speedtest2.env")" = "$ENV_BEFORE" ] || fail "invalid POST changed speedtest2.env"

# Устаревшие поля авторизации игнорируются и не могут изменить env.
printf "STATS_AUTH_USER='baseline'\nSTATS_AUTH_PASS='baselinepass'\n" >> "$W/speedtest2.env"
run_cgi POST "node_cap=5&keep_runs=50&keep_days=10&no_auth=1&auth_user=attacker&auth_pass=changed&geo_filter=ru-block&$OK_TUNING" >/dev/null
grep -qF "STATS_AUTH_USER='baseline'" "$W/speedtest2.env" || fail "legacy auth_user changed env"
grep -qF "STATS_AUTH_PASS='baselinepass'" "$W/speedtest2.env" || fail "legacy auth_pass changed env"

# --- кандидаты гео-фильтра: providers.awk разбирает config.yaml так же,
#     как install.sh, и найденные exclude-filter попадают в geo_filter_candidates. ---
cp "$ROOT/speedtest-runtime/providers.awk" "$W/providers.awk"
cat > "$W/config.yaml" <<'YAML'
proxy-providers:
  ru:
    type: http
    url: "https://example.com/ru"
    path: ./proxy-providers/ru.yaml
    exclude-filter: 'RU|Russia'
  eu:
    type: http
    url: "https://example.com/eu"
    path: ./proxy-providers/eu.yaml
    exclude-filter: 'EU|Europe'
YAML

OUT_CANDIDATES=$(run_cgi GET)
assert_contains '"geo_filter_candidates":["RU|Russia","EU|Europe"]' "$OUT_CANDIDATES" "geo_filter candidates from config.yaml"

# --- регресс: длинный гео-фильтр (эмодзи-флаги + кириллица, как в
#     реальном использовании) не должен ломать разбор ОСТАЛЬНЫХ полей -
#     раньше (get_field на sed, по одному пересканированию body на
#     каждое из полутора десятков полей формы) на реальном роутере это
#     иногда приводило к тому, что все поля выглядели пустыми ---
LONG_GEO='(?i)Russia|RU|whitelist|%D0%9C%D0%BE%D1%81%D0%BA%D0%B2%D0%B0|%D0%A0%D0%BE%D1%81%D1%81%D0%B8%D1%8F|SPB|MSK|%F0%9F%87%B7%F0%9F%87%BA|%F0%9F%87%B2%F0%9F%87%BD|%F0%9F%87%BB%F0%9F%87%AA|%F0%9F%87%A6%F0%9F%87%B7|%F0%9F%87%AE%F0%9F%87%B9|%F0%9F%87%A7%F0%9F%87%B7|%F0%9F%87%AE%F0%9F%87%B3'
OUT_LONGGEO=$(run_cgi POST "node_cap=8&keep_runs=200&keep_days=30&geo_filter=$LONG_GEO&$OK_TUNING")
assert_contains '{"ok":true}' "$OUT_LONGGEO" "long geo_filter does not break other fields"
grep -qF "MIN_SPEED='250000'" "$W/speedtest2.env" || fail "min_speed_mb lost when geo_filter is long"
grep -qF "TOPN='15'" "$W/speedtest2.env" || fail "topn lost when geo_filter is long"
grep -q "^BLOCK='Russia|RU|whitelist|" "$W/speedtest2.env" || fail "(?i) prefix not stripped from saved BLOCK"
OUT_NORM=$(run_cgi POST "node_cap=8&keep_runs=200&keep_days=30&geo_filter=%20Russia%20%7C%20(%3Fi)RU-%20&$OK_TUNING")
assert_contains '{"ok":true}' "$OUT_NORM" "spaces around | accepted"
grep -qF "BLOCK='Russia|RU-'" "$W/speedtest2.env" || fail "BLOCK not normalized (spaces/(?i))"


# --- Регрессия: "все поля пустые" из-за отсутствия апплета httpd в
#     busybox (реальный корень бага, найденный на роутере 12.09.2026) -
#     urldecode() раньше звала `busybox httpd -d "$1"`; на сборке Entware
#     BusyBox без httpd-апплета это даёт "httpd: applet not found", код
#     возврата 127 и пустой stdout - ЛЮБОЕ поле формы (даже простую
#     цифру без единого спецсимвола вроде min_speed_mb=3) декодировалось
#     в пустую строку. Длинный гео-фильтр тут ни при чём - совпадение по
#     времени с тем тестом выше. Симулируем такой busybox фальшивым
#     бинарником в PATH, который всегда "без httpd-апплета". ---
cat > "$W/speedtest2.env" <<'EOF'
BLOCK='test'
EOF
FAKEBIN=$TEST_ROOT/fakebin
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/busybox" <<'FAKEEOF'
#!/bin/sh
echo "httpd: applet not found" >&2
exit 127
FAKEEOF
chmod +x "$FAKEBIN/busybox"

BODY_NOHTTPD="node_cap=8&keep_runs=200&keep_days=30&geo_filter=RU&extype=custom&size_mb=20&dl_timeout=30&min_speed_mb=3&min_ratio=0.3&min_floor_mb=1&topn=15&enough=18&min_winners=2&stability_window=100&stability_drop_after=50"
OUT_NOHTTPD=$(printf '%s' "$BODY_NOHTTPD" | PATH="$FAKEBIN:$PATH" DIR="$W" MIHOMO_DIR="$W" ENV="$W/speedtest2.env" \
  REQUEST_METHOD=POST CONTENT_LENGTH=${#BODY_NOHTTPD} "$W/stats_cgi.sh")
assert_contains '{"ok":true}' "$OUT_NOHTTPD" "form works when busybox has no httpd applet"
grep -qF "MIN_SPEED='375000'" "$W/speedtest2.env" || fail "min_speed_mb lost when busybox has no httpd applet"
grep -qF "BLOCK='RU'" "$W/speedtest2.env" || fail "geo_filter lost when busybox has no httpd applet"

# =========================================================================
# JSON-режим /api/settings (шаг 4 SPA-миграции, переменная окружения
# API_JSON=1 - см. print_settings_json() в stats_cgi.sh и API_ALIASES в
# stats_httpd.py, tests/test_stats_httpd_py.sh проверяет саму проводку
# алиаса, здесь - сам JSON-вывод stats_cgi.sh).
# =========================================================================
cat > "$W/speedtest2.env" <<'EOF'
BLOCK='ru-block'
EOF

OUT_JSON_GET=$(run_cgi_json GET)
assert_contains 'Content-Type: application/json' "$OUT_JSON_GET" "JSON GET content-type"
assert_contains '"ok":true' "$OUT_JSON_GET" "JSON GET ok"
assert_contains '"geo_filter":"ru-block"' "$OUT_JSON_GET" "JSON GET reflects geo_filter"
assert_contains '"node_cap":8' "$OUT_JSON_GET" "JSON GET default node_cap"
assert_not_contains '"max_ping_ms"' "$OUT_JSON_GET" "JSON GET has no misleading ping limit"
assert_contains '"geo_filter_candidates":["RU|Russia","EU|Europe"]' "$OUT_JSON_GET" "JSON GET geo_filter_candidates from config.yaml (see providers.awk fixture above)"
assert_not_contains '<' "$OUT_JSON_GET" "JSON GET must not contain HTML"

OUT_JSON_BAD=$(run_cgi_json POST "node_cap=99&keep_runs=50&keep_days=10&geo_filter=x&$OK_TUNING")
assert_contains '"ok":false' "$OUT_JSON_BAD" "JSON POST invalid ok=false"
assert_contains '"node_cap":"' "$OUT_JSON_BAD" "JSON POST invalid errors has node_cap key"
assert_contains 'от 1 до 50' "$OUT_JSON_BAD" "JSON POST invalid error text"
grep -qF "BLOCK='ru-block'" "$W/speedtest2.env" || fail "JSON invalid POST must not save"

OUT_JSON_OK=$(run_cgi_json POST "node_cap=4&keep_runs=50&keep_days=10&geo_filter=ru-block2&$OK_TUNING")
BODY_JSON_OK=$(printf '%s' "$OUT_JSON_OK" | tail -n +3)
[ "$BODY_JSON_OK" = '{"ok":true}' ] || fail "JSON valid POST must reply exactly {\"ok\":true} (got: $BODY_JSON_OK)"
grep -qF "STATS_NODE_CAP='4'" "$W/speedtest2.env" || fail "JSON valid POST did not save node_cap"
grep -qF "BLOCK='ru-block2'" "$W/speedtest2.env" || fail "JSON valid POST did not save geo_filter"

OUT_JSON_GET2=$(run_cgi_json GET)
assert_contains '"node_cap":4' "$OUT_JSON_GET2" "JSON GET reflects saved node_cap"
assert_contains '"geo_filter":"ru-block2"' "$OUT_JSON_GET2" "JSON GET reflects saved geo_filter"

# --- канал обновлений: stable/dev, строка UPDATE_CHANNEL в env ---
OUT_CH=$(run_cgi_json POST "node_cap=4&keep_runs=50&keep_days=10&geo_filter=ru-block2&$OK_TUNING&update_channel=dev")
assert_contains '{"ok":true}' "$OUT_CH" "POST update_channel=dev ok"
grep -qF "UPDATE_CHANNEL='dev'" "$W/speedtest2.env" || fail "UPDATE_CHANNEL='dev' not saved"
assert_contains '"update_channel":"dev"' "$(run_cgi_json GET)" "JSON GET reflects update_channel=dev"
OUT_CH_BAD=$(run_cgi_json POST "node_cap=4&keep_runs=50&keep_days=10&geo_filter=ru-block2&$OK_TUNING&update_channel=beta")
assert_contains '"ok":false' "$OUT_CH_BAD" "POST update_channel=beta rejected"
assert_contains '"update_channel":"' "$OUT_CH_BAD" "error keyed by update_channel"
assert_contains 'Канал обновлений: stable или dev.' "$OUT_CH_BAD" "update_channel error text"
grep -qF "UPDATE_CHANNEL='dev'" "$W/speedtest2.env" || fail "invalid update_channel changed env"
# без поля в теле канал остаётся прежним
run_cgi_json POST "node_cap=4&keep_runs=50&keep_days=10&geo_filter=ru-block2&$OK_TUNING" >/dev/null
grep -qF "UPDATE_CHANNEL='dev'" "$W/speedtest2.env" || fail "omitted update_channel must keep current value"

# --- action=save_updates (карточка на вкладке «Обновления»): только канал и частота ---
NODE_CAP_BEFORE=$(grep "^STATS_NODE_CAP=" "$W/speedtest2.env")
BLOCK_BEFORE=$(grep "^BLOCK=" "$W/speedtest2.env")
OUT_SU=$(run_cgi_json POST "action=save_updates&update_channel=stable&update_check_hours=6")
assert_contains '{"ok":true}' "$OUT_SU" "save_updates ok"
grep -qF "UPDATE_CHANNEL='stable'" "$W/speedtest2.env" || fail "save_updates: канал не сохранён"
grep -qF "UPDATE_CHECK_HOURS='6'" "$W/speedtest2.env" || fail "save_updates: частота не сохранена"
[ "$(grep "^STATS_NODE_CAP=" "$W/speedtest2.env")" = "$NODE_CAP_BEFORE" ] || fail "save_updates не должен трогать node_cap"
[ "$(grep "^BLOCK=" "$W/speedtest2.env")" = "$BLOCK_BEFORE" ] || fail "save_updates не должен трогать гео-фильтр"
OUT_SU_BAD=$(run_cgi_json POST "action=save_updates&update_channel=beta&update_check_hours=6")
assert_contains '"ok":false' "$OUT_SU_BAD" "save_updates: неверный канал отклонён"
assert_contains '"update_channel":"' "$OUT_SU_BAD" "save_updates: ошибка по полю update_channel"
OUT_SU_BAD2=$(run_cgi_json POST "action=save_updates&update_channel=dev&update_check_hours=5")
assert_contains '"update_check_hours":"' "$OUT_SU_BAD2" "save_updates: неверная частота отклонена"
grep -qF "UPDATE_CHANNEL='stable'" "$W/speedtest2.env" || fail "save_updates с ошибкой не должен менять канал"

if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$OUT_JSON_GET2" | tail -n +3 > "$TEST_ROOT/api_settings_get.json"
  python3 - "$TEST_ROOT/api_settings_get.json" <<'PYCHECK' || fail "JSON GET /api/settings не распарсился"
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
assert d["ok"] is True
assert d["values"]["node_cap"] == 4
assert d["values"]["geo_filter"] == "ru-block2"
PYCHECK
fi

# Устаревшие поля авторизации отсутствуют и в JSON-настройках.
assert_not_contains '"has_auth"' "$OUT_JSON_GET2" "JSON has no legacy has_auth"
assert_not_contains '"auth_user"' "$OUT_JSON_GET2" "JSON has no legacy auth_user"

echo "test_stats_cgi.sh: OK"
