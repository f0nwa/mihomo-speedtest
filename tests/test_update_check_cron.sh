#!/bin/sh
# Частота фоновой проверки обновлений: cmd_cron_sync() в stats_update.sh
# (UPDATE_CHECK_HOURS -> cron-строка) и поле update_check_hours в
# /api/settings (stats_cgi.sh). crontab подменён через PATH.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/update-cron-test.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

W=$T/w
mkdir -p "$W" "$T/bin"
cp "$ROOT/web/stats_update.sh" "$W/stats_update.sh"
CRON=$T/crontab.txt
cat > "$T/bin/crontab" <<EOF2
#!/bin/sh
if [ "\$1" = "-l" ]; then cat "$CRON" 2>/dev/null; exit 0; fi
if [ "\$1" = "-" ]; then cat > "$CRON"; exit 0; fi
exit 1
EOF2
chmod +x "$T/bin/crontab"
export PATH="$T/bin:$PATH"
SU="$W/stats_update.sh"
run() { env -u REQUEST_METHOD -u MST_UPDATE_ACTION DIR="$W" ENV="$W/speedtest2.env" STATS_UPDATE_RUNTIME_DIR="$T/rt" sh "$SU" "$@"; }

# 1. Без строки и без "add" - crontab не трогается (cron-вызов check на
#    чужой машине не должен добавлять расписание).
printf '0 */3 * * * %s/speedtest2.sh\n' "$W" > "$CRON"
: > "$W/speedtest2.env"
run cron-sync
[ "$(cat "$CRON")" = "0 */3 * * * $W/speedtest2.sh" ] || fail "1: crontab изменён без add"

# 2. add, настройки нет -> по умолчанию раз в 12 часов, чужая строка цела.
run cron-sync add
grep -qxF "17 */12 * * * $SU check" "$CRON" || fail "2: нет строки раз в 12 часов: $(cat "$CRON")"
grep -qxF "0 */3 * * * $W/speedtest2.sh" "$CRON" || fail "2: потеряна строка speedtest2.sh"

# 3. Старая ежедневная строка мигрирует без add; дубликатов нет.
printf '0 */3 * * * %s/speedtest2.sh\n17 5 * * * %s check\n' "$W" "$SU" > "$CRON"
run cron-sync
[ "$(grep -cF "$SU" "$CRON")" = 1 ] || fail "3: дубликат строки"
grep -qxF "17 */12 * * * $SU check" "$CRON" || fail "3: не мигрировала: $(cat "$CRON")"

# 4. Значения из env (в кавычках, как пишет set_env_var).
echo "UPDATE_CHECK_HOURS='6'" > "$W/speedtest2.env"; run cron-sync
grep -qxF "17 */6 * * * $SU check" "$CRON" || fail "4: 6 часов"
echo "UPDATE_CHECK_HOURS='24'" > "$W/speedtest2.env"; run cron-sync
grep -qxF "17 5 * * * $SU check" "$CRON" || fail "4: 24 часа"
echo "UPDATE_CHECK_HOURS='1'" > "$W/speedtest2.env"; run cron-sync
grep -qxF "17 * * * * $SU check" "$CRON" || fail "4: 1 час"
echo "UPDATE_CHECK_HOURS='5'" > "$W/speedtest2.env"; run cron-sync
grep -qxF "17 */12 * * * $SU check" "$CRON" || fail "4: недопустимое значение -> 12"

# 5. /api/settings: GET отдаёт 12 по умолчанию, POST сохраняет и
#    переписывает crontab, недопустимое значение - ошибка поля.
cp "$ROOT/speedtest-runtime/speedtest2.sh" "$W/speedtest2.sh"
cp "$ROOT/web/render_stats.awk" "$W/render_stats.awk"
cp "$ROOT/web/stats_cgi.sh" "$W/stats_cgi.sh"
echo "BLOCK='test'" > "$W/speedtest2.env"
: > "$W/speedtest_runs.tsv"; : > "$W/speedtest_history.tsv"
cgi() { DIR="$W" ENV="$W/speedtest2.env" STATS_INIT_SCRIPT=/bin/true "$@" sh "$W/stats_cgi.sh"; }
out=$(REQUEST_METHOD=GET cgi env)
case $out in *'"update_check_hours":12'*) ;; *) fail "5: GET без 12: $out" ;; esac
BODY="node_cap=4&keep_runs=10&keep_days=0&geo_filter=test&extype=&size_mb=10&dl_timeout=20&min_speed_mb=1&min_ratio=0.25&min_floor_mb=0&topn=10&enough=10&min_winners=1&stability_window=200&stability_drop_after=0&update_check_hours=4"
out=$(printf '%s' "$BODY" | REQUEST_METHOD=POST CONTENT_LENGTH=${#BODY} cgi env)
case $out in *'{"ok":true}'*) ;; *) fail "5: POST: $out" ;; esac
grep -qxF "UPDATE_CHECK_HOURS='4'" "$W/speedtest2.env" || fail "5: не сохранено в env"
grep -qxF "17 */4 * * * $SU check" "$CRON" || fail "5: crontab не обновлён: $(cat "$CRON")"
BODY2=$(printf '%s' "$BODY" | sed 's/update_check_hours=4/update_check_hours=5/')
out=$(printf '%s' "$BODY2" | REQUEST_METHOD=POST CONTENT_LENGTH=${#BODY2} cgi env)
case $out in *'"update_check_hours":'*) ;; *) fail "5: нет ошибки для 5 часов: $out" ;; esac

echo "OK: test_update_check_cron.sh"
