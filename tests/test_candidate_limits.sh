#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
MST_LIB_ONLY=1 . "$ROOT/speedtest-runtime/speedtest2.sh"
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
printf '800 n0001\n500 n0002\n30 n0003\n100 n0004\n0 n0005\n' > "$task_tmp/alive"
MAX_TESTED=2
select_candidates "$task_tmp/alive" "$task_tmp/out"
[ "$(cat "$task_tmp/out")" = "$(printf '30 n0003\n100 n0004')" ]
MAX_TESTED=0
select_candidates "$task_tmp/alive" "$task_tmp/out"
[ "$(wc -l < "$task_tmp/out" | tr -d ' ')" = 4 ]
# Установка сохраняет лимит количества, но удаляет старый порог задержки.
SELFDIR=$ROOT/installer
INSTALL_LIB_ONLY=1 . "$ROOT/install.sh"
SOURCES=/test.yaml
BLOCK=RU
BLOCK_SOURCE=test
MIN_SPEED=100
printf "MAX_PING_MS='250'\nMAX_TESTED='0'\nTOPN='7'\n" > "$task_tmp/env"
write_env "$task_tmp/env"
grep -qx "MAX_TESTED='0'" "$task_tmp/env"
! grep -q '^MAX_PING_MS=' "$task_tmp/env"
grep -qx "TOPN='7'" "$task_tmp/env"
grep -qx "ENOUGH='20'" "$task_tmp/env"
# Переустановка сохраняет остальные поля веб-настроек, EXTYPE и частоту
# проверки обновлений; порог MIN_SPEED считается по долям пользователя.
printf "SIZE='20971520'\nDL_TIMEOUT='30'\nMIN_RATIO='0.5'\nMIN_FLOOR='100'\nSTABILITY_WINDOW='50'\nSTABILITY_DROP_AFTER='7'\nHISTORY_KEEP_RUNS='99'\nHISTORY_KEEP_DAYS='9'\nSTATS_NODE_CAP='12'\nUPDATE_CHECK_HOURS='6'\nEXTYPE='vless'\n" > "$task_tmp/env"
EXTYPE= write_env "$task_tmp/env"
for kv in "SIZE='20971520'" "DL_TIMEOUT='30'" "MIN_RATIO='0.5'" "MIN_FLOOR='100'" "STABILITY_WINDOW='50'" "STABILITY_DROP_AFTER='7'" "HISTORY_KEEP_RUNS='99'" "HISTORY_KEEP_DAYS='9'" "STATS_NODE_CAP='12'" "UPDATE_CHECK_HOURS='6'" "EXTYPE='vless'"; do
  grep -qxF "$kv" "$task_tmp/env" || { echo "FAIL: переустановка потеряла $kv" >&2; exit 1; }
done
[ "$(ENVFILE="$task_tmp/env" compute_min_speed 1000)" = 500 ] || { echo "FAIL: compute_min_speed не взял MIN_RATIO из env" >&2; exit 1; }
EXTYPE=trojan write_env "$task_tmp/env"
grep -qxF "EXTYPE='trojan'" "$task_tmp/env" && [ "$(grep -c '^EXTYPE=' "$task_tmp/env")" = 1 ] || { echo "FAIL: EXTYPE из окружения" >&2; exit 1; }
echo 'test_candidate_limits: OK'
