#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'id="mainNav"' "$ROOT/web/stats_index.html" || fail "нет управляемой навигации"
grep -q 'id="logoutBtn"' "$ROOT/web/stats_index.html" || fail "нет кнопки выхода"
grep -q '/api/auth/status' "$ROOT"/web/stats_app*.js || fail "SPA не запрашивает статус авторизации"
grep -q "'/api/auth/' + mode" "$ROOT"/web/stats_app*.js || fail "нет настройки учётной записи и входа"
grep -q '/api/auth/logout' "$ROOT"/web/stats_app*.js || fail "нет выхода"
grep -q 'X-CSRF-Token' "$ROOT"/web/stats_app*.js || fail "SPA не передаёт CSRF"
! grep -q 'name = .auth_user\|name="auth_user"\|name = .auth_pass\|name="auth_pass"\|name = .no_auth\|name="no_auth"' "$ROOT"/web/stats_app*.js || fail "в SPA остались поля Basic Auth"

if command -v node >/dev/null 2>&1; then
  for f in "$ROOT"/web/stats_app*.js; do node --input-type=module --check < "$f"; done
fi

echo "test_stats_auth_ui.sh: OK"
