#!/bin/sh
# Страховка: в пользовательских скриптах не должно появляться новых голых
# `echo ... >&2` / `printf ... >&2` - весь вывод идёт через ui_* (иначе он
# выпадет из журнала, спиннера и plain-режима). Законные исключения
# перечислены в tests/fixtures/ui_echo_allowlist.txt (`файл:фрагмент`).
# Блок ui-bootstrap в install.sh (копия ui.sh) в проверку не входит.
# Ограничение: ловятся только однострочные `echo ... >&2` / `printf ... >&2`;
# многострочные вызовы и форма `>&2 echo ...` не обнаруживаются.
cd "$(dirname "$0")/.." || exit 1
ALLOW=tests/fixtures/ui_echo_allowlist.txt
fail=0
bad=$(mktemp)
used=$(mktemp)
trap 'rm -f "$bad" "$used"' EXIT

for f in install.sh config-tools/setup.sh uninstall.sh; do
  # Без блока ui-bootstrap; печатаем «номер:строка» только для кандидатов.
  awk '/^# >>> ui-bootstrap/{s=1} !s && /(echo|printf)[^|]*>&2/ {print NR ":" $0} /^# <<< ui-bootstrap/{s=0}' "$f" |
  while IFS= read -r line; do
    ok=0
    while IFS= read -r entry; do
      case "$entry" in ''|'#'*) continue ;; esac
      [ "${entry%%:*}" = "$f" ] || continue
      frag=${entry#*:}
      case "$line" in *"$frag"*) ok=1; printf '%s\n' "$entry" >> "$used"; break ;; esac
    done < "$ALLOW"
    [ "$ok" = 1 ] || printf '%s:%s\n' "$f" "$line" >> "$bad"
  done
done

if [ -s "$bad" ]; then
  echo "FAIL: голые echo/printf >&2 вне белого списка (используйте ui_* или добавьте в $ALLOW):"
  cat "$bad"
  fail=1
fi

# Устаревшие записи белого списка (код удалён) - тоже ошибка, чтобы список не гнил.
while IFS= read -r entry; do
  case "$entry" in ''|'#'*) continue ;; esac
  grep -qxF -- "$entry" "$used" || { echo "FAIL: запись белого списка не используется: $entry"; fail=1; }
done < "$ALLOW"

[ "$fail" = 0 ] && echo "OK: test_ui_no_raw_echo"
exit "$fail"
