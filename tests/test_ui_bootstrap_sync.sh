#!/bin/sh
# Тест синхронности: встроенная в install.sh копия функций UI (блок
# ui-bootstrap) должна быть дословной копией installer/ui.sh. Под
# "curl ... | sh" install.sh один на диске и пользуется только встроенной
# копией; после загрузки релиза её перекрывает настоящий ui.sh. Если копии
# разойдутся, вид установки зависел бы от способа запуска - ловим это здесь.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALL=$ROOT/install.sh
LIB=$ROOT/installer/ui.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ui-sync.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$LIB" ] || fail "нет installer/ui.sh"

# Без блока сравнивать нечего - это тоже провал (а не "пустое совпадение").
grep -q '^# >>> ui-bootstrap' "$INSTALL" || fail "в install.sh нет маркера '# >>> ui-bootstrap'"
grep -q '^# <<< ui-bootstrap' "$INSTALL" || fail "в install.sh нет маркера '# <<< ui-bootstrap'"
awk '/^# >>> ui-bootstrap/{f=1;next} /^# <<< ui-bootstrap/{f=0} f' "$INSTALL" > "$TMP/block.sh"
[ -s "$TMP/block.sh" ] || fail "блок ui-bootstrap пуст"

# extract_fn ФАЙЛ ИМЯ: тело функции - от "ИМЯ() {" до "^}$"; однострочная
# форма "ИМЯ() { ...; }" (ui_ok и т.п.) целиком умещается в одной строке.
extract_fn() {
  awk -v n="$2" '
    !f && index($0, n "()") == 1 && $0 ~ /^[A-Za-z_0-9]+\(\) *\{/ {
      f = 1; print
      if ($0 ~ /\}[ \t]*$/ && $0 !~ /\{[ \t]*$/) exit
      next
    }
    f { print; if ($0 == "}") exit }
  ' "$1"
}

# Полный список функций, которые вызывает путь бутстрапа (вместе с
# помощниками, которых они вызывают): отсутствие любой - провал.
REQUIRED="ui_init ui_log ui_banner ui_kv ui_step ui_ok ui_fail ui_warn ui_progress ui_progress_end ui_on_exit ui__exit ui__len ui__rep ui__cut ui__frame ui__log_prepare ui__sub"
for fn in $REQUIRED; do
  [ -n "$(extract_fn "$TMP/block.sh" "$fn")" ] || fail "в блоке ui-bootstrap нет функции $fn"
done

# Каждая функция блока (любая, не только из REQUIRED) совпадает с ui.sh.
names=$(sed -n 's/^\([A-Za-z_0-9][A-Za-z_0-9]*\)() *{.*/\1/p' "$TMP/block.sh")
[ -n "$names" ] || fail "в блоке ui-bootstrap не найдено ни одной функции"
for fn in $names; do
  extract_fn "$TMP/block.sh" "$fn" > "$TMP/a.txt"
  extract_fn "$LIB" "$fn" > "$TMP/b.txt"
  [ -s "$TMP/b.txt" ] || fail "функции $fn из блока нет в installer/ui.sh"
  cmp -s "$TMP/a.txt" "$TMP/b.txt" || fail "функция $fn в блоке ui-bootstrap отличается от installer/ui.sh"
done

echo "test_ui_bootstrap_sync.sh: OK"
