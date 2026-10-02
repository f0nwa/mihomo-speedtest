#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/speedtest-runtime/node_stats_update.awk"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/node-stats-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected [$2], got [$1] ($3)"
}

field() {
  # field FILE NAME N -- N-е поле (1-based) строки с этим именем ноды;
  # пусто, если строки с таким именем нет вовсе.
  awk -F'\t' -v n="$2" -v i="$3" '$1 == n { print $i; found=1 } END { if (!found) print "" }' "$1"
}

row_exists() {
  awk -F'\t' -v n="$2" '$1 == n { f=1 } END { exit f ? 0 : 1 }' "$1"
}

run_update() {
  # run_update OLD_TSV MAP ALIVE ISO WINDOW DROP [SPEED] -- печатает новый
  # TSV; SPEED (res.txt-формат "байт/с idx") опционален - без него
  # speedfile указывает на /dev/null, как если бы этот прогон не дошёл до
  # speed-теста ни для одной ноды.
  old=$1; map=$2; alive=$3; iso=$4; win=$5; drop=$6; speed=${7:-/dev/null}
  awk -v iso="$iso" -v window_len="$win" -v drop_after="$drop" \
      -v mapfile="$map" -v alivefile="$alive" -v speedfile="$speed" \
      -f "$SCRIPT" "$old"
}

# --- первый прогон: одна нода жива, одна мертва ---
printf 'n0001\tnode-a\nn0002\tnode-b\n' > "$WORK/map1.txt"
printf '120 n0001\n' > "$WORK/alive1.txt"
: > "$WORK/empty.tsv"
run_update "$WORK/empty.tsv" "$WORK/map1.txt" "$WORK/alive1.txt" "2026-09-10 09:00:00" 200 0 > "$WORK/out1.tsv"

assert_eq "$(field "$WORK/out1.tsv" node-a 5)" "1" "node-a runs_seen после первого прогона"
assert_eq "$(field "$WORK/out1.tsv" node-a 6)" "1" "node-a runs_alive после первого прогона"
assert_eq "$(field "$WORK/out1.tsv" node-a 2)" "2026-09-10 09:00:00" "node-a first_seen = дата первого прогона"
assert_eq "$(field "$WORK/out1.tsv" node-a 3)" "2026-09-10 09:00:00" "node-a last_seen = дата первого прогона (жива)"
assert_eq "$(field "$WORK/out1.tsv" node-a 10)" "A" "node-a окно после первого прогона"
assert_eq "$(field "$WORK/out1.tsv" node-b 6)" "0" "node-b (мертва) runs_alive"
assert_eq "$(field "$WORK/out1.tsv" node-b 3)" "" "node-b last_seen пусто - ни разу не отвечала"
assert_eq "$(field "$WORK/out1.tsv" node-b 10)" "D" "node-b окно"
assert_eq "$(field "$WORK/out1.tsv" node-b 9)" "0" "node-b consec_absent (в пуле, просто не ответила)"

# --- второй прогон: node-a снова жива, node-b пропала из пула целиком ---
printf 'n0001\tnode-a\n' > "$WORK/map2.txt"
printf '110 n0001\n' > "$WORK/alive2.txt"
run_update "$WORK/out1.tsv" "$WORK/map2.txt" "$WORK/alive2.txt" "2026-09-10 12:00:00" 200 0 > "$WORK/out2.tsv"

assert_eq "$(field "$WORK/out2.tsv" node-a 5)" "2" "node-a runs_seen после второго прогона"
assert_eq "$(field "$WORK/out2.tsv" node-a 6)" "2" "node-a runs_alive после второго прогона"
assert_eq "$(field "$WORK/out2.tsv" node-a 7)" "230" "node-a delay_sum_ms = 120+110"
assert_eq "$(field "$WORK/out2.tsv" node-a 2)" "2026-09-10 09:00:00" "node-a first_seen не меняется на втором прогоне"
assert_eq "$(field "$WORK/out2.tsv" node-a 10)" "AA" "node-a окно после второго прогона"
assert_eq "$(field "$WORK/out2.tsv" node-b 5)" "1" "node-b runs_seen не растёт, когда её нет в пуле"
assert_eq "$(field "$WORK/out2.tsv" node-b 9)" "1" "node-b consec_absent после исчезновения из пула"
assert_eq "$(field "$WORK/out2.tsv" node-b 10)" "D." "node-b окно с точкой отсутствия"

# --- удаление ноды из агрегата по STABILITY_DROP_AFTER ---
: > "$WORK/mapempty.txt"
: > "$WORK/aliveempty.txt"
run_update "$WORK/out2.tsv" "$WORK/mapempty.txt" "$WORK/aliveempty.txt" "2026-09-10 15:00:00" 200 2 > "$WORK/out3.tsv"
row_exists "$WORK/out3.tsv" node-b && fail "node-b должна быть удалена из агрегата при consec_absent >= drop_after(2)"

# --- обрезка окна по window_len ---
printf 'n0001\tnode-c\n' > "$WORK/mapc.txt"
printf '50 n0001\n' > "$WORK/alivec.txt"
: > "$WORK/emptyc.tsv"
run_update "$WORK/emptyc.tsv" "$WORK/mapc.txt" "$WORK/alivec.txt" "2026-09-10 01:00:00" 3 0 > "$WORK/c1.tsv"
run_update "$WORK/c1.tsv"     "$WORK/mapc.txt" "$WORK/alivec.txt" "2026-09-10 02:00:00" 3 0 > "$WORK/c2.tsv"
run_update "$WORK/c2.tsv"     "$WORK/mapc.txt" "$WORK/alivec.txt" "2026-09-10 03:00:00" 3 0 > "$WORK/c3.tsv"
run_update "$WORK/c3.tsv"     "$WORK/mapc.txt" "$WORK/alivec.txt" "2026-09-10 04:00:00" 3 0 > "$WORK/c4.tsv"
assert_eq "$(field "$WORK/c4.tsv" node-c 10)" "AAA" "окно не растёт длиннее window_len=3"

# --- дубли имени между разными idx: схлопываются в одну ноду, берётся минимальная задержка ---
printf 'n0001\tnode-dup\nn0002\tnode-dup\n' > "$WORK/mapdup.txt"
printf '200 n0001\n80 n0002\n' > "$WORK/alivedup.txt"
: > "$WORK/emptydup.tsv"
run_update "$WORK/emptydup.tsv" "$WORK/mapdup.txt" "$WORK/alivedup.txt" "2026-09-10 05:00:00" 200 0 > "$WORK/outdup.tsv"
assert_eq "$(wc -l < "$WORK/outdup.tsv" | tr -d ' ')" "1" "дубли имени схлопнулись в одну строку"
assert_eq "$(field "$WORK/outdup.tsv" node-dup 7)" "80" "взята минимальная задержка среди дублей"

# --- пустой mapfile/alivefile: старый агрегат просто ротируется, скрипт не падает ---
: > "$WORK/mapz.txt"
: > "$WORK/alivez.txt"
run_update "$WORK/out1.tsv" "$WORK/mapz.txt" "$WORK/alivez.txt" "2026-09-10 06:00:00" 200 0 > "$WORK/outz.tsv"
assert_eq "$(field "$WORK/outz.tsv" node-a 9)" "1" "node-a consec_absent растёт при пустом пуле, скрипт не падает"

# --- скорость копится только когда для ноды реально был speed-замер в
#     этом прогоне (speedfile), не на каждый прогон, в отличие от задержки ---
printf 'n0001\tnode-a\nn0002\tnode-b\n' > "$WORK/maps1.txt"
printf '50 n0001\n60 n0002\n' > "$WORK/alives1.txt"
printf '1048576 n0001\n' > "$WORK/speeds1.txt"   # только node-a прошла speed-тест
: > "$WORK/emptys.tsv"
run_update "$WORK/emptys.tsv" "$WORK/maps1.txt" "$WORK/alives1.txt" "2026-09-10 07:00:00" 200 0 "$WORK/speeds1.txt" > "$WORK/s1.tsv"

assert_eq "$(field "$WORK/s1.tsv" node-a 11)" "1048576" "node-a last_speed после первого замера"
assert_eq "$(field "$WORK/s1.tsv" node-a 12)" "1048576" "node-a speed_sum после первого замера"
assert_eq "$(field "$WORK/s1.tsv" node-a 13)" "1" "node-a speed_samples после первого замера"
assert_eq "$(field "$WORK/s1.tsv" node-b 11)" "0" "node-b (не тестировалась на скорость) last_speed = 0"
assert_eq "$(field "$WORK/s1.tsv" node-b 12)" "0" "node-b speed_sum = 0, замера не было"
assert_eq "$(field "$WORK/s1.tsv" node-b 13)" "0" "node-b speed_samples = 0, замера не было"

# второй прогон: обе живы (задержка растёт у обеих), но speed-тест снова
# прошла только node-a - у node-b счётчики скорости не должны сдвинуться
printf '2097152 n0001\n' > "$WORK/speeds2.txt"
run_update "$WORK/s1.tsv" "$WORK/maps1.txt" "$WORK/alives1.txt" "2026-09-10 08:00:00" 200 0 "$WORK/speeds2.txt" > "$WORK/s2.tsv"
assert_eq "$(field "$WORK/s2.tsv" node-a 11)" "2097152" "node-a last_speed обновился вторым замером"
assert_eq "$(field "$WORK/s2.tsv" node-a 12)" "3145728" "node-a speed_sum = 1048576+2097152"
assert_eq "$(field "$WORK/s2.tsv" node-a 13)" "2" "node-a speed_samples после второго замера"
assert_eq "$(field "$WORK/s2.tsv" node-b 6)" "2" "node-b runs_alive всё равно растёт по delay-check"
assert_eq "$(field "$WORK/s2.tsv" node-b 13)" "0" "node-b speed_samples по-прежнему 0 - speed-теста так и не было"

# третий прогон: speedfile вообще не передан (нет ни одного замера скорости
# в этом прогоне) - у node-a последняя скорость и сумма должны сохраниться
run_update "$WORK/s2.tsv" "$WORK/maps1.txt" "$WORK/alives1.txt" "2026-09-10 09:00:00" 200 0 > "$WORK/s3.tsv"
assert_eq "$(field "$WORK/s3.tsv" node-a 11)" "2097152" "node-a last_speed не теряется без свежего замера"
assert_eq "$(field "$WORK/s3.tsv" node-a 12)" "3145728" "node-a speed_sum не теряется без свежего замера"
assert_eq "$(field "$WORK/s3.tsv" node-a 13)" "2" "node-a speed_samples не растёт без свежего замера"

# --- дубли имени в speedfile: берётся максимальная (а не минимальная,
#     как для задержки) скорость среди дублей ---
printf 'n0001\tnode-dup2\nn0002\tnode-dup2\n' > "$WORK/mapsdup.txt"
printf '10 n0001\n10 n0002\n' > "$WORK/alivesdup.txt"
printf '500 n0001\n900 n0002\n' > "$WORK/speedsdup.txt"
: > "$WORK/emptysdup.tsv"
run_update "$WORK/emptysdup.tsv" "$WORK/mapsdup.txt" "$WORK/alivesdup.txt" "2026-09-10 10:00:00" 200 0 "$WORK/speedsdup.txt" > "$WORK/sdup.tsv"
assert_eq "$(wc -l < "$WORK/sdup.tsv" | tr -d ' ')" "1" "дубли имени в speedfile тоже схлопнулись в одну строку"
assert_eq "$(field "$WORK/sdup.tsv" node-dup2 11)" "900" "взята максимальная скорость среди дублей"

# --- skipfile: WG/AWG-нода, пропущенная (нет входа/группы замера основного
#     ядра), в пуле, но не проверена: окно "S", runs_seen не растёт,
#     last_in_pool обновляется, consec_absent 0 ---
printf 'n0001\tnode-a\nn0002\tnode-wg\n' > "$WORK/mapS.txt"
printf '100 n0001\n' > "$WORK/aliveS.txt"
printf 'n0002\n' > "$WORK/skipS.txt"
printf 'node-wg\t2026-09-01 00:00:00\t2026-09-01 00:00:00\t2026-09-01 00:00:00\t3\t3\t300\t3\t0\tAAA\t0\t0\t0\n' > "$WORK/oldS.tsv"
awk -v iso="2026-09-20 09:00:00" -v window_len=200 -v drop_after=0 \
    -v mapfile="$WORK/mapS.txt" -v alivefile="$WORK/aliveS.txt" -v speedfile=/dev/null -v skipfile="$WORK/skipS.txt" \
    -f "$SCRIPT" "$WORK/oldS.tsv" > "$WORK/outS.tsv"
assert_eq "$(field "$WORK/outS.tsv" node-wg 10)" "AAAS" "пропущенная WG-нода: окно S"
assert_eq "$(field "$WORK/outS.tsv" node-wg 5)" "3" "пропущенная WG-нода: runs_seen не растёт"
assert_eq "$(field "$WORK/outS.tsv" node-wg 4)" "2026-09-20 09:00:00" "пропущенная WG-нода: last_in_pool обновлён"
assert_eq "$(field "$WORK/outS.tsv" node-a 10)" "A" "обычная нода не затронута skipfile"

echo "test_node_stats_update: OK"
