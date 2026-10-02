#!/bin/sh
# Логика карточки "Какие ноды не проверять" (гео-фильтр BLOCK) в
# web/stats_app.js: блок GEO-LOGIC-BEGIN/END вырезается и проверяется в node.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
FILE="$ROOT/web/stats_app.js"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q "GEO-LOGIC-BEGIN" "$FILE" || fail "нет метки GEO-LOGIC-BEGIN"
grep -q "function buildGeoFilterCard" "$FILE" || fail "нет buildGeoFilterCard"
grep -q "hidden.name = 'geo_filter'" "$FILE" || fail "готовая строка не уходит в поле geo_filter"
! grep -q "Регулярное выражение для исключения нод" "$FILE" || fail "осталась подпись про регулярное выражение"
grep -q "\.geo-grid" "$ROOT/web/stats_style.css" || fail "нет стилей карточки в stats_style.css"

command -v node >/dev/null 2>&1 || { echo "test_stats_geo_filter.sh: OK (без node - только grep)"; exit 0; }
node --check "$FILE"

LOGIC=$(awk '/GEO-LOGIC-BEGIN/{on=1;next} /GEO-LOGIC-END/{on=0} on' "$FILE")
TMP=$(mktemp "${TMPDIR:-/tmp}/geo-test.XXXXXX")
trap 'rm -f "$TMP"' EXIT INT TERM
{
  printf '%s\n' "$LOGIC"
  cat <<'JS'
var assert = require('assert');
var RU = '🇷🇺', JP = '🇯🇵', MX = '🇲🇽';

// Разбор: (?i) и пробелы срезаются.
assert.deepStrictEqual(geoSplit(' (?i)Russia | RU- ||(?i)Обход '), ['Russia', 'RU-', 'Обход']);

// Реальная строка из config.yaml: страны по флагу, остальное - свои слова.
var SAVED = '(?i)Russia|RU|whitelist|Белые|Москва|Россия|SPB|MSK|' + RU + '|' + MX + '|' + JP + '|RU-|RU_|Moscow|СПб|Обход';
var p = geoParse(SAVED);
assert.deepStrictEqual(Object.keys(p.sel).sort(), ['JP', 'MX', 'RU']);
assert.deepStrictEqual(p.custom, ['RU', 'whitelist', 'Белые', 'Обход']);
assert.strictEqual(p.hadRegex, true);

// Сборка: слова стран в порядке каталога, затем свои; дубликаты без учёта регистра.
var built = geoBuild(p.sel, p.custom.concat(['russia', 'WHITELIST']));
assert.strictEqual(built[0], RU);
assert.ok(built.indexOf('Japan') >= 0 && built.indexOf('Mexico') >= 0 && built.indexOf('Мексика') >= 0);
assert.strictEqual(built.filter(function (t) { return t.toLowerCase() === 'russia'; }).length, 1);
assert.strictEqual(built.filter(function (t) { return t.toLowerCase() === 'whitelist'; }).length, 1);
assert.strictEqual(built.join('|').indexOf('(?i)'), -1);

// Круговой путь: разобрать собранное - те же страны и свои слова.
var again = geoParse(built.join('|'));
assert.deepStrictEqual(Object.keys(again.sel).sort(), ['JP', 'MX', 'RU']);
assert.deepStrictEqual(again.custom, ['RU', 'whitelist', 'Белые', 'Обход']);
assert.strictEqual(again.hadRegex, false);

// В каталоге нет голых 1-3-буквенных латинских слов (кроме меток России
// из шаблона: MSK, SPB).
GEO_CATALOG.forEach(function (c) {
  c.words.forEach(function (w) {
    if (c.code === 'RU' && (w === 'MSK' || w === 'SPB')) { return; }
    assert.ok(!/^[A-Za-z]{1,3}$/.test(w), c.code + ': короткое слово ' + w);
  });
});

// Свои слова: по строке, | внутри строки тоже делит.
assert.deepStrictEqual(geoCustomList('whitelist\r\n\n Обход|RU- \n'), ['whitelist', 'Обход', 'RU-']);

// Замечания.
function kinds(w) { return w.map(function (x) { return x.kind; }); }
var w = geoWarnings(p.sel, p.custom, true);
assert.ok(w.some(function (x) { return x.kind === 'warn' && x.text.indexOf('«RU»') === 0 && x.text.indexOf('Brussels') > 0; }), 'нет предупреждения про RU');
assert.ok(w.some(function (x) { return x.kind === 'info' && x.text.indexOf('(?i)') >= 0; }), 'нет пояснения про (?i)');
assert.ok(kinds(w).indexOf('important') < 0, 'Россия выбрана, а предупреждение есть');
assert.ok(kinds(geoWarnings({}, ['whitelist'], false)).indexOf('important') >= 0, 'нет предупреждения "Россия не выбрана"');
assert.ok(kinds(geoWarnings({}, [], false)).indexOf('err') >= 0, 'пустой фильтр без ошибки');
assert.ok(geoWarnings({}, ['.*Russia'], false).some(function (x) { return x.kind === 'warn' && x.text.indexOf('регулярное') > 0; }));
assert.ok(geoWarnings({ RU: true }, ['Moscow'], false).some(function (x) { return x.kind === 'info' && x.text.indexOf('Россия') > 0; }));
assert.strictEqual(geoWarnings({ RU: true }, ['whitelist'], false).length, 0);
JS
} > "$TMP"
node "$TMP" || fail "логика гео-фильтра"
echo "test_stats_geo_filter.sh: OK"
