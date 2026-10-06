#!/bin/sh
# Запоздалый ответ сервера не перерисовывает уже открытый другой раздел:
# render() и экраны входа увеличивают номер раздела (nextView), а разделы
# проверяют viewGuard() перед отрисовкой ответа. Поведение в браузере
# проверялось вручную (медленный ответ + переход по меню); здесь - что
# проводка не потерялась.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
W=$ROOT/web
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q '^export function viewGuard()' "$W/stats_app_core.js" || fail "нет viewGuard() в core"
grep -q '^export function nextView()' "$W/stats_app_core.js" || fail "нет nextView() в core"
for fn in 'function render(path)' 'function renderAuthForm(mode)' 'function renderUninitialized()'; do
  awk -v f="$fn" 'index($0, f) == 1 {on = 1; next} on && /^}/ {exit 1} on && /nextView\(\)/ {found = 1; exit 0} END {exit !found}' "$W/stats_app.js" \
    || fail "$fn не вызывает nextView()"
done
check() {
  # $1 - файл, $2 - начало функции: внутри должны быть viewGuard() и проверка alive()
  awk -v f="$2" 'index($0, f) == 1 {on = 1; next} on && /^}/ {exit} on && /viewGuard\(\)/ {g = 1} on && /alive\(\)/ {a = 1} END {exit !(g && a)}' "$1" \
    || fail "$2 в ${1##*/} не проверяет viewGuard()/alive()"
}
check "$W/stats_app_stats.js" 'export function renderStats()'
check "$W/stats_app_stats.js" 'function progressPollTick()'
check "$W/stats_app_settings.js" 'export function renderSettings('
check "$W/stats_app_updates.js" 'export function renderUpdates()'
# renderConfig() только выбирает режим: YAML-редактор и конструктор
check "$W/stats_app_config.js" 'function renderYaml(bar)'
check "$W/stats_app_constructor.js" 'export function renderConstructor('

echo "test_stats_view_guard.sh: OK"
