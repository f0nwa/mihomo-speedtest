#!/bin/sh
# Меню разделов вкладки «XKeen»: без номеров в рамках (в конструкторе номера
# тоже убраны) - разделы различаются названием и подписью.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
grep -q 'xk-sec-num' "$ROOT/web/stats_app_xkeen.js" && fail "в меню XKeen остались номера разделов (xk-sec-num в JS)"
grep -q 'xk-sec-num' "$ROOT/web/stats_style.css" && fail "в стилях остались правила номеров разделов (xk-sec-num)"
grep -q "el('b', null, s\[1\])" "$ROOT/web/stats_app_xkeen.js" || fail "в меню XKeen нет названия раздела"
grep -q "'xk-sec-sub'" "$ROOT/web/stats_app_xkeen.js" || fail "в меню XKeen нет подписи раздела"
echo "OK test_xkeen_menu_ui"
