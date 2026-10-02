#!/bin/sh
# Фильтр по статусу в «Статистики доступности нод» (stats_app.js): фильтрует
# уже полученные строки в браузере, без запросов к серверу, и переживает
# перерисовку карточки renderStats().
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
FILE=$ROOT/web/stats_app.js
CSS=$ROOT/web/stats_style.css
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q "function buildStabilityFilter(rows, table, emptyHint)" "$FILE" || fail "нет buildStabilityFilter()"
grep -q "var group = stabilityGroup(r.status);" "$FILE" && grep -q "tr.setAttribute('data-group', group)" "$FILE" || fail "строки таблицы не помечены группой статуса"
grep -q "var stabilityFilter = { alive: true, down: true, other: true };" "$FILE" || fail "выбор фильтра должен храниться вне DOM и по умолчанию показывать всё"
grep -q "buildStabilityFilter(data.node_stability, stabilityTable, stabilityEmpty)" "$FILE" || fail "фильтр не подключён к карточке доступности"
grep -q "Нет нод с выбранными статусами." "$FILE" || fail "нет подсказки для пустого результата"
grep -q "label.stability-filter-item" "$CSS" || fail "нет стилей фильтра"

# Фильтр не должен ходить на сервер: внутри функции нет fetch.
awk '/function buildStabilityFilter/{f=1} f&&/fetch/{bad=1} f&&/^  }$/{exit} END{exit bad}' "$FILE" || fail "фильтр обращается к серверу"

# Поведение группировки: skipped и неизвестные статусы попадают в other.
if command -v node >/dev/null 2>&1; then
  node -e '
    var src = require("fs").readFileSync(process.argv[1], "utf8");
    var m = src.match(/function stabilityGroup\(status\) \{[\s\S]*?\n  \}/);
    if (!m) { process.exit(2); }
    var g = new Function(m[0] + "; return stabilityGroup;")();
    var ok = g("alive") === "alive" && g("down") === "down" && g("skipped") === "other" && g(undefined) === "other";
    process.exit(ok ? 0 : 1);
  ' "$FILE" || fail "stabilityGroup() неверно группирует статусы"
fi

# Сортировка по клику на заголовок: пустые значения всегда внизу,
# повторный клик меняет направление, статус - жива/недоступна/остальное.
if command -v node >/dev/null 2>&1; then
  node -e '
    var src = require("fs").readFileSync(process.argv[1], "utf8");
    var a = src.indexOf("  var STATUS_ORDER"), b = src.indexOf("  function buildStabilityTable(");
    if (a < 0 || b < 0) { process.exit(2); }
    var api = new Function(src.slice(a, b) + "; return { sort: sortStabilityRows, st: stabilitySort };")();
    var rows = [
      { name: "b", status: "down", last_seen: "2026-09-28 10:00:00", uptime_pct: 40, avg_speed_bytes: 5 },
      { name: "A", status: "skipped", last_seen: "", uptime_pct: null, avg_speed_bytes: null },
      { name: "c", status: "alive", last_seen: "2026-09-29 10:00:00", uptime_pct: 90, avg_speed_bytes: 2 }
    ];
    function names(k, d) { api.st.key = k; api.st.dir = d; return api.sort(rows).map(function (r) { return r.name; }).join(""); }
    var ok = names(null, 1) === "bAc" && names("name", 1) === "Abc" && names("name", -1) === "cbA" &&
      names("status", 1) === "cbA" && names("uptime", -1) === "cbA" && names("uptime", 1) === "bcA" &&
      names("last_seen", 1) === "bcA" && names("avg", -1) === "bcA";
    process.exit(ok ? 0 : 1);
  ' "$FILE" || fail "сортировка таблицы доступности работает неверно"
fi

echo "test_stats_stability_filter.sh: OK"
