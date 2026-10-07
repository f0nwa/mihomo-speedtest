#!/bin/sh
# Вкладка «Файлы»: подключение модуля и обращение ко всем эндпоинтам /api/fm/*.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
JS=$ROOT/web/stats_app_files.js

[ -f "$JS" ] || fail "1: нет web/stats_app_files.js"
grep -q '"app-files.js": "stats_app_files.js"' "$ROOT/web/stats_httpd.py" || fail "2: модуль не раздаётся (STATIC_FILES)"
grep -q 'href="/files" data-link' "$ROOT/web/stats_index.html" || fail "3: нет пункта меню /files"
grep -q "from './app-files.js'" "$ROOT/web/stats_app.js" || fail "4: app.js не импортирует app-files.js"
grep -q "path === '/files'" "$ROOT/web/stats_app.js" || fail "5: app.js не маршрутизирует /files"
grep -q 'filesDirty()' "$ROOT/web/stats_app.js" || fail "6: нет защиты от потери правок"
for ep in tree list read download write upload mkdir rename delete; do
  grep -q "/api/fm/$ep" "$JS" || fail "7: модуль не обращается к /api/fm/$ep"
done
for fn in renderFiles stopFiles filesDirty; do
  grep -q "export function $fn" "$JS" || fail "8: нет export function $fn"
done
grep -q 'innerHTML' "$JS" && fail "9: innerHTML запрещён, только textContent"
grep -q '\.fm-' "$ROOT/web/stats_style.css" || fail "10: нет стилей .fm-*"
if command -v node >/dev/null 2>&1; then
  cp "$JS" "${TMPDIR:-/tmp}/stats_app_files_check.$$.mjs"
  node --check "${TMPDIR:-/tmp}/stats_app_files_check.$$.mjs" || { rm -f "${TMPDIR:-/tmp}/stats_app_files_check.$$.mjs"; fail "11: синтаксис JS"; }
  rm -f "${TMPDIR:-/tmp}/stats_app_files_check.$$.mjs"
fi
echo "test_stats_files_ui.sh: OK"
