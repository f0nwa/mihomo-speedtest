#!/bin/sh
set -eu

# render_stats.awk -> stats.json (/api/stats). До 2026-09-28 был ещё
# HTML-режим со своим test_render_stats.sh; он удалён вместе со старой
# страницей stats.html. Структура и точные числа сверяются через json.loads.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/web/render_stats.awk"
FAILED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

assert_contains() {
  case "$2" in
    *"$1"*) ;;
    *) echo "FAIL: expected to find: $1" >&2; FAILED=1 ;;
  esac
}

command -v python3 >/dev/null 2>&1 || {
  echo "test_render_stats_json.sh: python3 недоступен, пропущено" >&2
  echo "test_render_stats_json.sh: OK (пропущено)"
  exit 0
}

# --- пустая история: валидный JSON с пустыми разделами, без падения ---
: > "$WORK/empty.tsv"
OUT_EMPTY=$(awk -v format=json -v last="" -f "$SCRIPT" "$WORK/empty.tsv")
echo "$OUT_EMPTY" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  || { echo "FAIL: пустая история - невалидный JSON" >&2; FAILED=1; }
assert_contains '"count":0' "$OUT_EMPTY"
assert_contains '"last_run":null' "$OUT_EMPTY"
assert_contains '"last_measurement":[]' "$OUT_EMPTY"
assert_contains '"node_history":{"total_unique":0,"cap":8,"top":[]}' "$OUT_EMPTY"
assert_contains '"node_stability":[]' "$OUT_EMPTY"

# --- HTML-режима больше нет (удалён 2026-09-28): и без -v format=json
#     скрипт отдаёт тот же JSON - флаг оставлен для совместимости ---
OUT_NOFLAG=$(awk -v last="" -f "$SCRIPT" "$WORK/empty.tsv")
[ "$OUT_NOFLAG" = "$OUT_EMPTY" ] || { echo "FAIL: без -v format=json вывод отличается от JSON-режима" >&2; FAILED=1; }
case $OUT_NOFLAG in *'<'*) echo "FAIL: в выводе осталась HTML-разметка" >&2; FAILED=1 ;; esac

# --- ограничение топа по cap и экранирование имён нод ---
: > "$WORK/runs_cap.tsv"; : > "$WORK/nodes_cap.tsv"
i=1
while [ $i -le 3 ]; do
  printf '%d000\t2026-09-12 0%d:00:00\t1\t1\t1\t1\t1\t1\t1\n' "$i" "$i" >> "$WORK/runs_cap.tsv"
  i=$((i + 1))
done
for n in a b c d; do printf '1000\t100\tnode-%s\n' "$n" >> "$WORK/nodes_cap.tsv"; done
printf '2000\t200\tnode-a\n3000\t300\tnode-a\n2000\t50\tq"uo\\te<b>\n' >> "$WORK/nodes_cap.tsv"
OUT_CAP=$(awk -v nodes="$WORK/nodes_cap.tsv" -v cap=2 -v generated="g" -f "$SCRIPT" "$WORK/runs_cap.tsv")
printf '%s' "$OUT_CAP" > "$WORK/out_cap.json"
python3 - "$WORK/out_cap.json" <<'PYCAP' || { echo "FAIL: cap/экранирование" >&2; FAILED=1; }
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
nh = d["node_history"]
assert nh["cap"] == 2 and len(nh["top"]) == nh["total_unique"] == 5, nh
assert nh["top"][0]["color"] == "#2a78d6", nh
assert nh["top"][0]["name"] == "node-a" and nh["top"][0]["values"] == [100, 200, 300], nh["top"][0]
assert nh["total_unique"] == 5, nh["total_unique"]
PYCAP
# --- больше 8 нод: отдаются все, после 8-й цвета идут по кругу оттенков (hsl) ---
: > "$WORK/nodes_many.tsv"
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do printf '1000\t100\tnode-%s\n' "$n" >> "$WORK/nodes_many.tsv"; done
awk -v nodes="$WORK/nodes_many.tsv" -v cap=30 -v generated="g" -f "$SCRIPT" "$WORK/runs_cap.tsv" | python3 -c '
import json, sys
nh = json.load(sys.stdin)["node_history"]
assert nh["cap"] == 30 and len(nh["top"]) == 12, nh
cols = [t["color"] for t in nh["top"]]
assert all(c.startswith("#") for c in cols[:8]) and all(c.startswith("hsl(") for c in cols[8:]), cols
assert len(set(cols)) == 12, cols
' || { echo "FAIL: больше 8 нод/цвета hsl" >&2; FAILED=1; }
awk -v nodes="$WORK/nodes_many.tsv" -v cap=99 -v generated="g" -f "$SCRIPT" "$WORK/runs_cap.tsv" | grep -q '"cap":8,' || { echo "FAIL: cap вне 1..50 -> 8" >&2; FAILED=1; }

OUT_ESC=$(awk -v nodes="$WORK/nodes_cap.tsv" -v cap=8 -v generated="g" -f "$SCRIPT" "$WORK/runs_cap.tsv")
printf '%s' "$OUT_ESC" | python3 -c '
import json, sys
names = [t["name"] for t in json.load(sys.stdin)["node_history"]["top"]]
assert "q\"uo\\te<b>" in names, names
' || { echo "FAIL: имя ноды с кавычкой/обратным слешем/тегом должно приходить в JSON как есть" >&2; FAILED=1; }

# --- обычная история: runs + nodes (история побед) + last + stability ---
printf '1000\t2026-09-12 09:00:00\t5242880\t1310720\t30\t20\t15\t10\t8\n' > "$WORK/runs.tsv"
printf '4000\t2026-09-12 12:00:00\t6291456\t1572864\t31\t22\t16\t12\t9\n' >> "$WORK/runs.tsv"
printf '1000\t3145728\tnode-fast\n1000\t2097152\tnode-slow\n4000\t3407872\tnode-fast\n' > "$WORK/nodes.tsv"
printf '12.3\tМБ/с\tnode-fast\n11.9\tМБ/с\tnode-two\n' > "$WORK/last.txt"
printf 'node-fast\t2026-09-01\tx\tx\tx\tx\tx\tx\tx\tAA\t3407872\t6553600\t2\n' > "$WORK/stability.tsv"
printf 'node-slow\t2026-09-02\tx\tx\tx\tx\tx\tx\tx\tAD\t0\t0\t0\n' >> "$WORK/stability.tsv"

OUT=$(awk -v format=json -v last="$WORK/last.txt" -v nodes="$WORK/nodes.tsv" -v cap=8 \
    -v stability="$WORK/stability.tsv" -v generated="2026-09-12 12:00:05" \
    -f "$SCRIPT" "$WORK/runs.tsv")

echo "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  || { echo "FAIL: обычная история - невалидный JSON" >&2; FAILED=1; }

printf '%s' "$OUT" > "$WORK/out.json"
python3 - "$WORK/out.json" <<'PYCHECK' || { echo "FAIL: см. вывод python выше" >&2; FAILED=1; }
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)

def check(cond, msg):
    if not cond:
        print("FAIL:", msg)
        sys.exit(1)

check(d["generated"] == "2026-09-12 12:00:05", "generated")
check(d["runs"]["count"] == 2, "runs.count")
check(d["runs"]["series"][0]["channel_bytes"] == 5242880, "runs.series[0].channel_bytes")
check(d["runs"]["series"][1]["winners"] == 9, "runs.series[1].winners")
check(d["last_run"]["winners"] == 9, "last_run.winners (последний прогон)")
check(d["last_measurement"] == [
    {"speed_mb": 12.3, "unit": "МБ/с", "name": "node-fast"},
    {"speed_mb": 11.9, "unit": "МБ/с", "name": "node-two"},
], "last_measurement")

nh = d["node_history"]
check(nh["total_unique"] == 2, "node_history.total_unique")
top_by_name = {t["name"]: t for t in nh["top"]}
check(top_by_name["node-fast"]["wins"] == 2, "node-fast.wins")
check(top_by_name["node-fast"]["values"] == [3145728, 3407872], "node-fast.values (побеждала в обоих прогонах)")
check(top_by_name["node-slow"]["wins"] == 1, "node-slow.wins")
check(top_by_name["node-slow"]["values"] == [2097152, None], "node-slow.values (пропустила второй прогон)")

st_by_name = {s["name"]: s for s in d["node_stability"]}
fast = st_by_name["node-fast"]
check(fast["last_seen"] == "x", "node-fast.last_seen (поле f[3] node_stability.tsv пробрасывается как есть)")
check(fast["status"] == "alive", "node-fast.status")
check(fast["uptime_pct"] == 100, "node-fast.uptime_pct")
check(fast["avg_speed_bytes"] == 3276800, "node-fast.avg_speed_bytes (6553600/2)")
check(fast["delta_bytes"] == 131072, "node-fast.delta_bytes (3407872-3276800)")
slow = st_by_name["node-slow"]
check(slow["status"] == "down", "node-slow.status")
check(slow["avg_speed_bytes"] is None, "node-slow.avg_speed_bytes (0 замеров -> null)")
check(slow["delta_bytes"] is None, "node-slow.delta_bytes")

print("python checks OK")
PYCHECK

if [ "$FAILED" = 1 ]; then
  echo "test_render_stats_json.sh: FAILED" >&2
  exit 1
fi
# --- S (WG/AWG-нода в пуле, но не проверена - нет входа замера основного ядра) ---
printf 'node-wg\t2026-09-01\tx\tx\tx\tx\tx\tx\tx\tAS\t0\t0\t0\n' > "$WORK/stability_s.tsv"
OUT_S=$(awk -v format=json -v stability="$WORK/stability_s.tsv" -v generated="g" -f "$SCRIPT" "$WORK/runs.tsv")
case $OUT_S in *'"status":"skipped"'*) ;; *) echo "FAIL: окно ...S должно давать status skipped" >&2; exit 1 ;; esac

echo "test_render_stats_json.sh: OK"
