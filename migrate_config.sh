#!/bin/sh
# Собирает RAM-кандидат; не публикует рабочий конфиг и не запускает службы.
set -eu
umask 077
LC_ALL=C; export LC_ALL
DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
source_file= template_file= output_file= report_file=
while [ $# -gt 0 ]; do
  key=$1; shift
  [ $# -gt 0 ] || fail 'не задан аргумент'
  case $key in
    --source) source_file=$1 ;; --template) template_file=$1 ;;
    --output) output_file=$1 ;; --report) report_file=$1 ;;
    *) fail 'неизвестный аргумент' ;;
  esac
  shift
done
[ -n "$source_file" ] && [ -n "$template_file" ] && [ -n "$output_file" ] && [ -n "$report_file" ] || fail 'нужны --source --template --output --report'
canonical_file() {
  [ ! -L "$1" ] || fail 'символические ссылки не поддерживаются'
  file_parent=$(CDPATH= cd -- "$(dirname "$1")" && pwd -P) || fail 'каталог недоступен'
  file_name=$(basename "$1")
  case $file_name in .|..|*'|'*|*[[:cntrl:]]*) fail 'неверное имя файла' ;; esac
  printf '%s/%s\n' "$file_parent" "$file_name"
}
source_file=$(canonical_file "$source_file")
template_file=$(canonical_file "$template_file")
output_file=$(canonical_file "$output_file")
report_file=$(canonical_file "$report_file")
[ -f "$source_file" ] && [ -f "$template_file" ] || fail 'входной файл отсутствует'
for path in "$output_file" "$report_file"; do
  case $path in /tmp/*|/private/tmp/*) ;; *) fail 'выход и отчёт должны находиться в /tmp' ;; esac
  [ "$path" != "$source_file" ] && [ "$path" != "$template_file" ] || fail 'выход совпадает со входом'
  [ ! -e "$path" ] || [ -f "$path" ] || fail 'выход не является файлом'
done
[ "$output_file" != "$report_file" ] || fail 'выход совпадает с отчётом'
for input in "$source_file" "$template_file"; do
  input_size=$(wc -c < "$input" | tr -d ' ')
  [ "$input_size" -le 1048576 ] || fail 'вход превышает лимит 1 МиБ'
done
WORK=$(mktemp -d /tmp/mst-config-migrate.XXXXXX) || fail 'не удалось создать RAM-каталог'
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
(ulimit -f 4096; awk -v SOURCE="$source_file" -v OUT="$WORK/candidate" -v REPORT="$WORK/report" -f "$DIR/migrate_config.awk" "$source_file" "$template_file") || fail 'структура конфига не поддерживается; выход сохранён'
[ "$(wc -c < "$WORK/candidate" | tr -d ' ')" -le 4194304 ] && [ "$(wc -c < "$WORK/report" | tr -d ' ')" -le 65536 ] || fail 'результат превышает лимит'
chmod 0600 "$WORK/candidate" "$WORK/report" || fail 'не удалось защитить результат'
# Оба назначения в RAM. Отчёт публикуется первым; ошибка не заменяет кандидат.
mv -f "$WORK/report" "$report_file" || fail 'не удалось сохранить отчёт'
mv -f "$WORK/candidate" "$output_file" || fail 'не удалось сохранить кандидат'
printf 'Кандидат и отчёт подготовлены в RAM; применение не выполнялось.\n'
