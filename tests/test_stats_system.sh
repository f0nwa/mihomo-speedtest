#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/web/stats_system.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { case "$2" in *"$1"*) ;; *) fail "expected to find: $1 in: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$1"*) fail "expected NOT to find: $1 in: $2" ;; esac; }

# Пункт 5 фидбека по макету "Панель управления": футер с версией релиза,
# аптаймом, загрузкой CPU/памяти и статусом ядра mihomo. Ни один из этих
# показателей раньше не собирался нигде в проекте - новый CGI-скрипт
# web/stats_system.sh (тот же приём, что stats_run.sh/stats_update.sh).

printf 'FORMAT_VERSION=2\nRELEASE_VERSION=9\n' > "$TMP/installed-manifest.txt"
printf '1234.5 111.1\n' > "$TMP/uptime"
cat > "$TMP/meminfo" <<'EOF'
MemTotal:        100000 kB
MemFree:           50000 kB
MemAvailable:      62000 kB
EOF

# /proc/stat реально живой (перечитывается ядром на каждое обращение) -
# фикстура заменяет его счётчиком вызовов: 1-е обращение отдаёт "старый"
# снимок, 2-е и далее - "новый" (idle подросло меньше total => 12% занятости
# между двумя замерами cpu_percent()).
COUNTER=$TMP/stat-counter
: > "$COUNTER"
cat > "$TMP/statcmd" <<EOF
#!/bin/sh
n=\$(cat "$COUNTER" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "$COUNTER"
if [ "\$n" = 1 ]; then
  echo 'cpu  100 0 0 800 0 0 0 0 0 0'
else
  echo 'cpu  112 0 0 888 0 0 0 0 0 0'
fi
EOF
chmod +x "$TMP/statcmd"

cat > "$TMP/pidof-yes" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP/pidof-no" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$TMP/pidof-yes" "$TMP/pidof-no"

run() {
  INSTALLED_MANIFEST_PATH="$TMP/installed-manifest.txt" \
  PROC_UPTIME="$TMP/uptime" PROC_MEMINFO="$TMP/meminfo" \
  STAT_CMD="$TMP/statcmd" CPU_SAMPLE_DELAY=0 \
  PIDOF_CMD="${PIDOF_OVERRIDE:-$TMP/pidof-yes}" \
  REQUEST_METHOD="${METHOD_OVERRIDE:-GET}" sh "$SCRIPT"
}

: > "$COUNTER"
OUT=$(run)
assert_contains 'Content-Type: application/json' "$OUT" "заголовок ответа"
BODY=$(printf '%s\n' "$OUT" | tail -1)
assert_contains '"release_version":"9"' "$BODY" "версия релиза"
assert_contains '"uptime_seconds":1234' "$BODY" "аптайм (целые секунды)"
assert_contains '"cpu_percent":12' "$BODY" "загрузка CPU (12%)"
assert_contains '"mem_percent":38' "$BODY" "занятая память (38%)"
assert_contains '"mihomo_active":true' "$BODY" "mihomo работает"

# --- mihomo не запущен ---
: > "$COUNTER"
PIDOF_OVERRIDE=$TMP/pidof-no
OUT2=$(run)
assert_contains '"mihomo_active":false' "$OUT2" "mihomo не работает"
unset PIDOF_OVERRIDE

# --- pidof недоступен вовсе - неизвестно, а не "не работает" ---
: > "$COUNTER"
PIDOF_OVERRIDE=$TMP/no-such-binary
OUT3=$(run)
assert_contains '"mihomo_active":null' "$OUT3" "pidof недоступен - статус неизвестен"
unset PIDOF_OVERRIDE

# --- нет installed-manifest.txt - версия неизвестна, не ошибка ---
: > "$COUNTER"
OUT4=$(INSTALLED_MANIFEST_PATH="$TMP/no-such-manifest.txt" \
  PROC_UPTIME="$TMP/uptime" PROC_MEMINFO="$TMP/meminfo" \
  STAT_CMD="$TMP/statcmd" CPU_SAMPLE_DELAY=0 PIDOF_CMD="$TMP/pidof-yes" \
  REQUEST_METHOD=GET sh "$SCRIPT")
assert_contains '"release_version":null' "$OUT4" "версия релиза неизвестна без манифеста"

# --- неподходящий метод ---
: > "$COUNTER"
METHOD_OVERRIDE=POST
OUT5=$(run)
assert_contains 'method_not_allowed' "$OUT5" "POST не поддерживается"
unset METHOD_OVERRIDE

echo "test_stats_system.sh: OK"
