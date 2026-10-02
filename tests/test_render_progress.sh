#!/bin/sh
set -eu

# render_progress.awk - прогресс скоростного теста по нодам ТЕКУЩЕГО
# прогона (см. шапку самого файла и write_progress() в speedtest2.sh,
# шаг 1 задачи "видно по нодам при прогоне"). Отдельный файл от
# test_speedtest2.sh - тот покрывает write_progress() (обвязку в
# speedtest2.sh: awk + publish_file), здесь - сам render_progress.awk
# как отдельная программа, по образцу test_render_stats_json.sh.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/web/render_progress.awk"
# Примечание: write_progress() в speedtest2.sh всегда создаёт
# $WORK/progress.tsv заранее (": > ..."), поэтому несуществующий входной
# файл не входит в контракт этого скрипта (awk на нём падает - это ок).
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
  echo "test_render_progress.sh: python3 недоступен, пропущено" >&2
  echo "test_render_progress.sh: OK (пропущено)"
  exit 0
}

# --- цикл только начался: пустой/отсутствующий TSV, tested=0, results=[] ---
: > "$WORK/empty.tsv"
OUT_EMPTY=$(awk -v running=1 -v total=5 -v started_iso="2026-09-14 10:00:00" \
    -v updated_iso="2026-09-14 10:00:00" -f "$SCRIPT" "$WORK/empty.tsv")
printf '%s\n' "$OUT_EMPTY" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  || { echo "FAIL: пустой прогресс - невалидный JSON" >&2; FAILED=1; }
assert_contains '"running":true' "$OUT_EMPTY"
assert_contains '"total":5' "$OUT_EMPTY"
assert_contains '"tested":0' "$OUT_EMPTY"
assert_contains '"results":[]' "$OUT_EMPTY"

# --- несколько протестированных нод: порядок сохраняется (порядок
#     тестирования, не сортировка по скорости), статусы ok/slow как есть,
#     running=true пока идёт цикл ---
printf 'node-a\t3145728\tok\nnode-b\t524288\tslow\nnode-c\t2097152\tok\n' > "$WORK/progress.tsv"
OUT=$(awk -v running=1 -v total=5 -v started_iso="2026-09-14 10:00:00" \
    -v updated_iso="2026-09-14 10:00:07" -f "$SCRIPT" "$WORK/progress.tsv")
printf '%s\n' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  || { echo "FAIL: заполненный прогресс - невалидный JSON" >&2; FAILED=1; }
printf '%s' "$OUT" > "$WORK/out.json"
python3 - "$WORK/out.json" <<'PYCHECK' || { echo "FAIL: см. вывод python выше" >&2; FAILED=1; }
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)

def check(cond, msg):
    if not cond:
        print("FAIL:", msg)
        sys.exit(1)

check(d["running"] is True, "running")
check(d["started_iso"] == "2026-09-14 10:00:00", "started_iso")
check(d["updated_iso"] == "2026-09-14 10:00:07", "updated_iso")
check(d["total"] == 5, "total")
check(d["tested"] == 3, "tested")
check(d["results"] == [
    {"name": "node-a", "speed_bytes": 3145728, "status": "ok"},
    {"name": "node-b", "speed_bytes": 524288, "status": "slow"},
    {"name": "node-c", "speed_bytes": 2097152, "status": "ok"},
], "results (порядок тестирования, не по скорости)")

print("python checks OK")
PYCHECK

# --- финальный вызов после цикла: running=false, те же results ---
OUT_DONE=$(awk -v running=0 -v total=5 -v started_iso="2026-09-14 10:00:00" \
    -v updated_iso="2026-09-14 10:00:09" -f "$SCRIPT" "$WORK/progress.tsv")
assert_contains '"running":false' "$OUT_DONE"
assert_contains '"tested":3' "$OUT_DONE"

# --- имя ноды со спецсимволами JSON (кавычка, обратный слэш) - не должно
#     ломать вывод (json_esc - тот же код, что и в render_stats.awk) ---
printf 'node "quoted"\\x\t1048576\tok\n' > "$WORK/weird.tsv"
OUT_WEIRD=$(awk -v running=1 -v total=1 -v started_iso="2026-09-14 10:00:00" \
    -v updated_iso="2026-09-14 10:00:00" -f "$SCRIPT" "$WORK/weird.tsv")
printf '%s\n' "$OUT_WEIRD" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  || { echo "FAIL: спецсимволы в имени ноды - невалидный JSON" >&2; FAILED=1; }

if [ "$FAILED" = 1 ]; then
  echo "test_render_progress.sh: FAILED" >&2
  exit 1
fi
echo "test_render_progress.sh: OK"
