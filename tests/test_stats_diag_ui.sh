#!/bin/sh
# Вкладка «Диагностика» (web/stats_app_diag.js): чистые функции без DOM -
# через node; подключение вкладки - grep по index.html, app.js, серверу и
# установщику.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
JS=$ROOT/web/stats_app_diag.js
[ -f "$JS" ] || fail "нет web/stats_app_diag.js"

grep -q '<a href="/diag" data-link>Диагностика</a>' "$ROOT/web/stats_index.html" || fail "нет вкладки в меню"
awk '/href="\/stats"/ { s = NR } /href="\/diag"/ { d = NR } /href="\/settings"/ { t = NR } END { exit !(s < d && d < t) }' "$ROOT/web/stats_index.html" \
  || fail "вкладка не между «Статистика» и «Настройки»"
grep -q "path === '/diag'" "$ROOT/web/stats_app.js" || fail "нет ветки /diag в render()"
grep -q "stopDiagPolling()" "$ROOT/web/stats_app.js" || fail "render() не останавливает опрос диагностики"
grep -q '"app-diag.js": "stats_app_diag.js"' "$ROOT/web/stats_httpd.py" || fail "app-diag.js не раздаётся"
grep -q 'ALL_PROJECT_FILES=.* stats_app_diag.js' "$ROOT/install.sh" || fail "stats_app_diag.js нет в ALL_PROJECT_FILES"
grep -q 'stats_app_diag.js' "$ROOT/release/components.txt" || fail "stats_app_diag.js нет в components.txt"
grep -q 'stats_app_diag.js' "$ROOT/uninstall.sh" || fail "stats_app_diag.js нет в uninstall.sh"
grep -q '\.v\.blocked' "$ROOT/web/stats_style.css" || fail "нет стилей пилюль вердиктов"
grep -q 'Проверить домен' "$JS" || fail "нет ручной проверки домена"
grep -q "/api/diag/check" "$JS" || fail "проверка домена не вызывает /api/diag/check"
grep -q "/api/diag/one" "$JS" || fail "результат проверки домена не опрашивается"
grep -q "/api/diag/domains/save" "$JS" || fail "список доменов не сохраняется"
grep -q "Проверить список" "$JS" || fail "нет кнопки «Проверить список»"
grep -q "list=1" "$JS" || fail "проверка списка не вызывается"

command -v node >/dev/null 2>&1 || { echo "SKIP test_stats_diag_ui (функции): нет node"; echo "OK test_stats_diag_ui"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$JS" "$T/diag.mjs"
# app-core.js тянет document - для чистых функций хватает заглушки.
printf '%s\n' "export var app = null; export function el() {} export function card() {} export function clearApp() {}" \
  "export function fetchJson() {} export function nextView() {} export function viewGuard() { return function () { return true; }; }" \
  "export function showError() {}" > "$T/app-core.js"
node --check "$T/diag.mjs" || fail "синтаксис stats_app_diag.js"
node --input-type=module - "$T/diag.mjs" <<'JS'
import { pathToFileURL } from 'node:url';
const M = await import(pathToFileURL(process.argv[2]).href);
let failed = 0;
function eq(a, b, what) { const A = JSON.stringify(a), B = JSON.stringify(b); if (A !== B) { console.error('FAIL: ' + what + '\n  ожидалось ' + B + '\n  получено  ' + A); failed = 1; } }
const L = { ok: 'Работает', blocked: 'Не пускает ноду', suspect: 'Похоже на блокировку', node_dead: 'Нода не отвечает',
  direct: 'Идёт напрямую, без ноды', rejected: 'Заблокировано правилом конфига', lb: 'Нода выбирается на каждый запрос',
  no_url: 'Нет адреса проверки', missing: 'Группы нет в ядре', error: 'Ошибка проверки', pending: 'Проверяется…', skipped: 'Не проверено' };
Object.keys(L).forEach(k => eq(M.verdictLabel(k), L[k], 'подпись ' + k));
const list = ['ok', 'direct', 'rejected', 'no_url', 'error', 'lb', 'node_dead', 'suspect', 'blocked', 'missing', 'pending', 'skipped']
  .map((v, i) => ({ name: 'S' + String.fromCharCode(108 - i), verdict: v }));
list.push({ name: 'A', verdict: 'blocked' });
eq(M.sortServices(list).map(s => s.verdict + ':' + s.name),
  ['blocked:A', 'blocked:Sd', 'suspect:Se', 'node_dead:Sf', 'lb:Sg', 'error:Sh', 'missing:Sc', 'no_url:Si', 'pending:Sb', 'skipped:Sa', 'rejected:Sj', 'direct:Sk', 'ok:Sl'],
  'порядок: проблемные первыми, внутри - по имени');
eq(M.sortServices(list).length, list.length, 'сортировка не теряет строки');
eq(list[0].name, 'Sl', 'сортировка не меняет исходный массив');
eq(M.countKpi([{ verdict: 'ok' }, { verdict: 'direct' }, { verdict: 'blocked' }, { verdict: 'suspect' }, { verdict: 'suspect' }, { verdict: 'node_dead' }, { verdict: 'lb' }]),
  { ok: 2, blocked: 1, suspect: 2, node_dead: 1 }, 'плитки: напрямую считается рабочим');
eq(M.altText({ state: 'none', checked: 0, limit: 0, found: [] }), '—', 'замена не искалась');
eq(M.altText(undefined), '—', 'нет alt');
eq(M.altText({ state: 'searching', checked: 6, limit: 15, found: ['DE-01'] }), 'DE-01 · ищу ещё… 6/15', 'идёт поиск');
eq(M.altText({ state: 'searching', checked: 2, limit: 15, found: [] }), 'ищу… 2/15', 'идёт поиск, пока пусто');
eq(M.altText({ state: 'done', checked: 15, limit: 15, found: [] }), 'ни одна из 15 проверенных нод не подошла', 'не нашлось');
eq(M.altText({ state: 'done', checked: 4, limit: 15, found: ['A', 'B'] }), 'A, B', 'нашлось');
eq(M.altText({ state: 'skipped', checked: 0, limit: 0, found: [] }), 'не искали: проверку остановили или кончилось время', 'поиск не начат');
eq(M.altText({ state: 'done', checked: 0, limit: 0, found: [] }), 'других нод в группе нет', 'кроме текущей нод нет');
eq(M.altText({ state: 'stopped', checked: 3, limit: 15, found: [] }), 'поиск остановлен (проверено 3)', 'остановлен');
eq(M.altText({ state: 'stopped', checked: 3, limit: 15, found: ['A'] }), 'A · поиск остановлен (проверено 3)', 'остановлен, что-то нашлось');
eq(M.isProblem('blocked') && M.isProblem('suspect') && M.isProblem('node_dead') && !M.isProblem('ok') && !M.isProblem('direct'), true, 'проблемные вердикты');
eq(M.fmtElapsed(0), '0:00', 'прошло 0'); eq(M.fmtElapsed(75), '1:15', 'прошло 75 с');
if (failed) process.exit(1);
JS
echo "OK test_stats_diag_ui"
