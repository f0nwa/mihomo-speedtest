#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
FILE="$ROOT/web/stats_app.js"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Баг: на свежей установке (или сразу после переустановки) stats.json ещё
# не создан - /api/stats через SPA-фоллбек в stats_httpd.py отдаёт
# index.html с кодом 200, fetchJson() не может распарсить JSON и
# превращает это в {} (см. комментарий про /api/progress рядом). До
# фикса renderStats() падал на data.runs.count без проверки на data.runs.
grep -q "data.runs && typeof data.runs.count === 'number'" "$FILE" \
  || fail "нет защиты data.runs.count (аналогичной защите /api/progress)"

# "data.runs.count" должен встречаться только внутри самой проверки выше -
# нигде больше не должно быть прямого небезопасного обращения.
count=$(grep -o 'data\.runs\.count' "$FILE" | wc -l | tr -d ' ')
[ "$count" = 2 ] || fail "ожидалось 2 (только внутри защиты) occurrence data.runs.count, найдено $count"

# оба места использования (заголовок с датой и заголовок графика) должны
# использовать защищённую переменную
uses=$(grep -o 'runsCount' "$FILE" | wc -l | tr -d ' ')
[ "$uses" -ge 3 ] || fail "ожидалось минимум 3 упоминания runsCount (объявление + 2 использования), найдено $uses"

if command -v node >/dev/null 2>&1; then
  node --check "$FILE"
fi

echo "test_stats_app_stats_guard.sh: OK"
