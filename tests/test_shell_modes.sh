#!/bin/sh
# Страховка от потерянных битов исполнения: правки файлов (редактор, mv, cp)
# уже молча превращали 755 в 644. Проверяем: всё, что в git HEAD было 755,
# остаётся исполняемым; installer/ui.sh и все tests/test_*.sh исполняемы.
cd "$(dirname "$0")/.." || exit 1
fail=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
chk() { [ -x "$1" ] || { echo "FAIL: не исполняемый файл: $1"; fail=1; }; }

# Файлы, которые в HEAD были 755 (если файла уже нет - пропускаем).
git ls-tree -r HEAD 2>/dev/null | while read -r mode _ _ path; do
  [ "$mode" = 100755 ] || continue
  case "$path" in *.sh) [ -e "$path" ] && chk "$path" ;; esac
done > "$tmp" 2>&1
[ -s "$tmp" ] && { cat "$tmp"; fail=1; }

chk installer/ui.sh
for t in tests/test_*.sh; do chk "$t"; done

[ "$fail" = 0 ] && echo "OK: test_shell_modes"
exit "$fail"
