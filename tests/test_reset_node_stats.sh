#!/bin/sh
# Кнопка «Сбросить статистику»: POST /api/settings action=reset_node_stats
# (reset_node_stats() в stats_cgi.sh) очищает speedtest_runs.tsv,
# speedtest_history.tsv и node_stability.tsv, не трогает speedtest2.env,
# во время прогона (занята блокировка) отказывает.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/reset-stats-test.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

W=$T/w
mkdir -p "$W"
cp "$ROOT/speedtest-runtime/speedtest2.sh" "$W/speedtest2.sh"
cp "$ROOT/web/render_stats.awk" "$W/render_stats.awk"
cp "$ROOT/web/stats_cgi.sh" "$W/stats_cgi.sh"
echo "BLOCK='test'" > "$W/speedtest2.env"
printf '1700000000\t2023-11-14 22:13:20\t1000000\t500000\t10\t8\t5\t3\t2\n' > "$W/speedtest_runs.tsv"
printf '1700000000\t900000\tnode-a\n' > "$W/speedtest_history.tsv"
printf 'node-a\tsomething\n' > "$W/node_stability.tsv"
cp "$W/speedtest2.env" "$T/env.before"

post() {
  printf '%s' "$1" | DIR="$W" ENV="$W/speedtest2.env" TMPROOT="$T" LOCK="$T/mst.lock" \
    REQUEST_METHOD=POST CONTENT_LENGTH=${#1} sh "$W/stats_cgi.sh"
}

# 1. Во время прогона - отказ, файлы целы.
mkdir "$T/mst.lock"
out=$(post "action=reset_node_stats")
case $out in *'"ok":false'*'"reset"'*) ;; *) fail "1: нет отказа при занятой блокировке: $out" ;; esac
[ -s "$W/speedtest_history.tsv" ] || fail "1: история очищена во время прогона"
[ -s "$W/speedtest_runs.tsv" ] || fail "1: прогоны очищены во время прогона"
rmdir "$T/mst.lock"

# 2. Сброс: прогоны и обе статистики пусты, настройки на месте, блокировка снята.
out=$(post "action=reset_node_stats")
case $out in *'{"ok":true}'*) ;; *) fail "2: $out" ;; esac
[ -f "$W/speedtest_history.tsv" ] && [ ! -s "$W/speedtest_history.tsv" ] || fail "2: speedtest_history.tsv не пуст"
[ -f "$W/node_stability.tsv" ] && [ ! -s "$W/node_stability.tsv" ] || fail "2: node_stability.tsv не пуст"
[ -f "$W/speedtest_runs.tsv" ] && [ ! -s "$W/speedtest_runs.tsv" ] || fail "2: speedtest_runs.tsv не пуст"
cmp -s "$W/speedtest2.env" "$T/env.before" || fail "2: speedtest2.env изменён"
[ ! -e "$T/mst.lock" ] || fail "2: блокировка не снята"

echo "OK: test_reset_node_stats.sh"
