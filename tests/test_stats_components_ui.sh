#!/bin/sh
# Карточка "Компоненты" раздела "Обновления": логика строк и "есть обновление"
# (web/stats_app_components.js) проверяется node с заглушкой document; проводка
# в stats_app_updates.js - grep-ом, как у соседних UI-тестов. Нет node - часть
# с логикой пропускается (на роутере его нет).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
MOD=$ROOT/web/stats_app_components.js
UPD=$ROOT/web/stats_app_updates.js
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- проводка
grep -q "from './app-components.js'" "$UPD" || fail "updates: нет импорта app-components.js"
grep -q "buildComponentsCard" "$UPD" || fail "updates: карточка компонентов не подключена в renderUpdates"
grep -q "componentsAvailable" "$UPD" || fail "updates: бейдж/плитка не учитывают компоненты"
grep -q "/api/components/status" "$UPD" || fail "updates: refreshUpdatesBadge не читает /api/components/status"
grep -q "/api/components/apply" "$MOD" || fail "модуль не вызывает /api/components/apply"
grep -q "/api/components/check" "$MOD" || fail "модуль не вызывает /api/components/check"
grep -q "confirm(" "$MOD" || fail "обновление ядра должно спрашивать подтверждение"
grep -q "update-console" "$MOD" || fail "нет мини-консоли хода обновления"
# единая формула "есть обновление" проекта не должна размножаться (см. test_stats_updates_ui.sh)
[ "$(grep -c "f.state === 'missing'" "$UPD")" = 2 ] || fail "число проверок f.state === 'missing' изменилось"

command -v node >/dev/null 2>&1 || { echo "SKIP test_stats_components_ui (логика): нет node"; echo "test_stats_components_ui: OK"; exit 0; }
# На диске файлы называются stats_app_*.js, а импорты идут по URL-именам
# app-*.js (их сопоставляет stats_httpd.py) - копируем под URL-именами.
TMPD=$(mktemp -d /tmp/test-components-ui.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT INT TERM
cp "$ROOT/web/stats_app_core.js" "$TMPD/app-core.js"
cp "$MOD" "$TMPD/app-components.js"
node --input-type=module - "$TMPD/app-components.js" <<'JS'
import { pathToFileURL } from 'node:url';
globalThis.document = { getElementById() { return null; }, createElement() { return {}; } };
const M = await import(pathToFileURL(process.argv[2]).href);
let failed = 0;
function eq(a, b, what) { const A = JSON.stringify(a), B = JSON.stringify(b); if (A !== B) { console.error('FAIL: ' + what + '\n  ожидалось ' + B + '\n  получено  ' + A); failed = 1; } }
const item = (o) => Object.assign({ installed: null, latest: null, channel: null, available: false, can_apply: true, error: null }, o);
const st = (items) => ({ components: { items } });

// componentsAvailable
eq(M.componentsAvailable(null), false, 'null -> false');
eq(M.componentsAvailable({ components: null }), false, 'components null -> false');
eq(M.componentsAvailable(st({ mihomo: item({}), xkeen: item({}) })), false, 'нет available -> false');
eq(M.componentsAvailable(st({ mihomo: item({}), xkeen: item({ available: true, can_apply: false }) })), true, 'индикатор xkeen считается');
eq(M.componentsAvailable(st({ mihomo: item({ available: true, error: 'x' }) })), true, 'available при error всё равно true');

// componentRows
const rows = M.componentRows({ items: {
  mihomo: item({ installed: 'v1.19.2', latest: 'v1.19.3', channel: 'stable', available: true }),
  zashboard: item({ latest: 'v2.6.0' }),
  xkeen: item({ installed: '1.0', latest: '1.1', available: true, can_apply: false }),
} });
eq(rows.map((r) => r.key), ['mihomo', 'zashboard', 'xkeen'], 'порядок строк');
eq([rows[0].canApply, rows[0].tone, rows[0].installed, rows[0].latest], [true, 'warn', 'v1.19.2', 'v1.19.3'], 'mihomo: есть обновление');
eq([rows[1].canApply, rows[1].installed], [true, 'неизвестна'], 'zashboard: версия неизвестна, но обновить можно');
eq([rows[2].canApply, rows[2].tone], [false, 'warn'], 'xkeen: без кнопки, но с индикатором');
if (!/вручную/.test(rows[2].note || '')) { console.error('FAIL: xkeen: нет пометки про ручное обновление'); failed = 1; }

const rows2 = M.componentRows({ items: {
  mihomo: item({ error: 'ядро не отвечает: версия неизвестна', latest: 'v1.19.3' }),
  zashboard: item({ installed: 'v2.6.0', latest: 'v2.6.0' }),
  xkeen: item({ can_apply: false }),
} });
eq([rows2[0].canApply, rows2[0].tone], [false, 'err'], 'ошибка ядра: кнопки нет');
if (rows2[0].status.indexOf('ядро не отвечает') < 0) { console.error('FAIL: статус ошибки не показан'); failed = 1; }
eq([rows2[1].canApply, rows2[1].tone, rows2[1].status], [false, 'ok', 'Актуально'], 'zashboard актуален');
eq([rows2[2].tone], ['muted'], 'нет данных');
eq(M.componentRows(null).map((r) => r.key), ['mihomo', 'zashboard', 'xkeen'], 'null -> три строки без данных');
process.exit(failed);
JS
echo "test_stats_components_ui: OK"
