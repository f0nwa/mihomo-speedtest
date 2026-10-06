#!/bin/sh
# Собирает RAM-кандидат; не публикует рабочий конфиг и не запускает службы.
set -eu
umask 077
LC_ALL=C; export LC_ALL
DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
source_file= template_file= output_file= report_file= subs_file= proxies_file=
while [ $# -gt 0 ]; do
  key=$1; shift
  [ $# -gt 0 ] || fail 'Не задан аргумент'
  case $key in
    --source) source_file=$1 ;; --template) template_file=$1 ;;
    --output) output_file=$1 ;; --report) report_file=$1 ;;
    --subs) subs_file=$1 ;; --proxies) proxies_file=$1 ;;
    *) fail 'Неизвестный аргумент' ;;
  esac
  shift
done
[ -n "$source_file" ] && [ -n "$template_file" ] && [ -n "$output_file" ] && [ -n "$report_file" ] || fail 'Нужны --source --template --output --report'
canonical_file() {
  [ ! -L "$1" ] || fail 'Символические ссылки не поддерживаются'
  file_parent=$(CDPATH= cd -- "$(dirname "$1")" && pwd -P) || fail 'Каталог недоступен'
  file_name=$(basename "$1")
  case $file_name in .|..|*'|'*|*[[:cntrl:]]*) fail 'Неверное имя файла' ;; esac
  printf '%s/%s\n' "$file_parent" "$file_name"
}
source_file=$(canonical_file "$source_file")
template_file=$(canonical_file "$template_file")
output_file=$(canonical_file "$output_file")
report_file=$(canonical_file "$report_file")
[ -f "$source_file" ] && [ -f "$template_file" ] || fail 'Входной файл отсутствует'
for path in "$output_file" "$report_file"; do
  case $path in /tmp/*|/private/tmp/*) ;; *) fail 'Выход и отчёт должны находиться в /tmp' ;; esac
  [ "$path" != "$source_file" ] && [ "$path" != "$template_file" ] || fail 'Выход совпадает со входом'
  [ ! -e "$path" ] || [ -f "$path" ] || fail 'Выход не является файлом'
done
[ "$output_file" != "$report_file" ] || fail 'Выход совпадает с отчётом'
for input in "$source_file" "$template_file"; do
  input_size=$(wc -c < "$input" | tr -d ' ')
  [ "$input_size" -le 1048576 ] || fail 'Вход превышает лимит 1 МиБ'
done
WORK=$(mktemp -d /tmp/mst-config-migrate.XXXXXX) || fail 'Не удалось создать RAM-каталог'
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
# Причину отказа migrate_config.awk пишет в отдельный файл (без значений
# конфига) - без неё пользователь видел только общую фразу и не мог понять,
# что поправить.
if ! (ulimit -f 4096; awk -v SUBS_FILE="$subs_file" -v PROXIES_FILE="$proxies_file" -v SOURCE="$source_file" -v OUT="$WORK/candidate" -v REPORT="$WORK/report" -v REASONF="$WORK/reason" -f "$DIR/migrate_config.awk" "$source_file" "$template_file"); then
  reason=
  [ -f "$WORK/reason" ] && reason=$(head -n 1 "$WORK/reason" | cut -c1-300)
  [ -n "$reason" ] || reason='причина не определена'
  fail "Структура конфига не поддерживается: $reason; выход сохранён"
fi
# Очистка прежних групп FAST-WG и сохранение прямых ссылок на WG-победителей.
awk -f "$DIR/fast_wg.awk" "$WORK/candidate" > "$WORK/candidate.wg" && mv -f "$WORK/candidate.wg" "$WORK/candidate" \
  || fail 'Не удалось обновить ссылки на WG-ноды; выход сохранён'
[ "$(wc -c < "$WORK/candidate" | tr -d ' ')" -le 4194304 ] && [ "$(wc -c < "$WORK/report" | tr -d ' ')" -le 65536 ] || fail 'Результат превышает лимит'
chmod 0600 "$WORK/candidate" "$WORK/report" || fail 'Не удалось защитить результат'
# Оба назначения в RAM. Отчёт публикуется первым; ошибка не заменяет кандидат.
mv -f "$WORK/report" "$report_file" || fail 'Не удалось сохранить отчёт'
mv -f "$WORK/candidate" "$output_file" || fail 'Не удалось сохранить кандидат'
printf 'Кандидат и отчёт подготовлены в RAM; применение не выполнялось.\n'
