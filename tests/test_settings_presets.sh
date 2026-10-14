#!/bin/sh
# Настройки: на виду - выбор «Насколько строго отбирать» (Мягко / Обычно /
# Строго), минимальная скорость ноды и число нод в пуле; точные пороги, Uptime, объёмы проверки и история
# - в свёрнутом блоке «Дополнительно». Логика пресетов (PRESETS-LOGIC) -
# чистые функции, проверяются в node.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
FILE="$ROOT/web/stats_app_settings.js"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'PRESETS-LOGIC-BEGIN' "$FILE" || fail "нет метки PRESETS-LOGIC-BEGIN"
grep -q 'PRESETS-LOGIC-END' "$FILE" || fail "нет метки PRESETS-LOGIC-END"
# на виду: только пресет и topn
grep -q "title: 'Быстрый пул', preset: true, fields: \['fixed_min_speed_mb', 'topn'\]" "$FILE" || fail "основная карточка: пресет, минимальная скорость и topn"
# остальное - в свёрнутом блоке, все прежние поля на месте
MAIN=$(awk '/^var CARDS = \[/{on=1} on{print} /^\];/{on=0}' "$FILE")
for f in min_ratio min_floor_mb min_winners stable_min_uptime stable_lookback max_tested enough keep_runs keep_days node_cap extype size_mb dl_timeout min_speed_mb stability_window stability_drop_after stable_min_runs; do
  printf '%s' "$MAIN" | grep -q "'$f'" || fail "поле $f пропало из карточек настроек"
done
ADV=$(printf '%s\n' "$MAIN" | awk '/advanced: true/{on=1} on')
for f in min_ratio min_floor_mb min_winners stable_min_uptime stable_lookback max_tested enough keep_runs keep_days node_cap; do
  printf '%s' "$ADV" | grep -q "'$f'" || fail "поле $f должно быть в «Дополнительно»"
done
printf '%s' "$MAIN" | awk '/advanced: true/{exit} {print}' | grep -q "'min_ratio'" && fail "min_ratio остался на виду"
grep -q 'buildPresetField' "$FILE" || fail "нет buildPresetField"
grep -q "settings-group" "$ROOT/web/stats_style.css" || fail "нет стиля подзаголовков блока «Дополнительно»"

command -v node >/dev/null 2>&1 || { echo "OK test_settings_presets (без node - только grep)"; exit 0; }
LOGIC=$(awk '/PRESETS-LOGIC-BEGIN/{on=1;next} /PRESETS-LOGIC-END/{on=0} on' "$FILE" | sed 's/^export //')
TMP=$(mktemp "${TMPDIR:-/tmp}/presets-test.XXXXXX")
trap 'rm -f "$TMP"' EXIT INT TERM
{
  printf '%s\n' "$LOGIC"
  cat <<'JS'
var assert = require('assert');
assert.deepStrictEqual(STRICTNESS_PRESETS.map(function (p) { return p.id; }), ['soft', 'normal', 'strict']);
assert.strictEqual(presetOf({ min_ratio: '0.25', stable_min_uptime: '80' }), 'normal', 'значения по умолчанию - Обычно');
assert.strictEqual(presetOf({ min_ratio: 0.15, stable_min_uptime: 60 }), 'soft');
assert.strictEqual(presetOf({ min_ratio: '0.4', stable_min_uptime: '90' }), 'strict');
assert.strictEqual(presetOf({ min_ratio: '0,25', stable_min_uptime: '80' }), 'normal', 'запятая как десятичный разделитель');
assert.strictEqual(presetOf({ min_ratio: '0.3', stable_min_uptime: '80' }), 'custom', 'своё значение порога');
assert.strictEqual(presetOf({ min_ratio: '0.25', stable_min_uptime: '75' }), 'custom', 'своё значение Uptime');
assert.strictEqual(presetOf({}), 'normal', 'нет значений - по умолчанию Обычно');
assert.strictEqual(presetOf({ min_ratio: '', stable_min_uptime: '' }), 'normal', 'пустые поля - по умолчанию');
assert.deepStrictEqual(presetValues('soft'), { min_ratio: 0.15, stable_min_uptime: 60 });
assert.deepStrictEqual(presetValues('normal'), { min_ratio: 0.25, stable_min_uptime: 80 });
assert.deepStrictEqual(presetValues('strict'), { min_ratio: 0.4, stable_min_uptime: 90 });
assert.strictEqual(presetValues('custom'), null, 'свои значения - ничего не подставляется');
assert.strictEqual(presetValues('нет'), null);
// круг: значения пресета снова распознаются как он сам
STRICTNESS_PRESETS.forEach(function (p) { assert.strictEqual(presetOf(presetValues(p.id)), p.id, 'круг ' + p.id); });
console.log('OK');
JS
} > "$TMP.js"
mv "$TMP.js" "$TMP"
node "$TMP" > /dev/null || fail "логика пресетов"
echo "OK test_settings_presets"
