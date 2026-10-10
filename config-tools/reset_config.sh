#!/bin/sh
# reset_config.sh - полная замена конфига шаблоном: из текущего config.yaml
# берутся только подписки (с User-Agent) и свои ноды, всё остальное (dns,
# listeners, secret, порты, группы, правила, гео-фильтр) - из шаблона
# config.example.yaml. Не публикует конфиг и не запускает службы.
#
#   sh reset_config.sh --source CONFIG --output OUT --report REPORT --state-out DIR
#
# Разбор источника построчный (config_to_state.awk) и не зависит от того,
# проходит ли он mihomo -t: так можно заменить и битый конфиг.
# OUT, REPORT и DIR - в /tmp (DIR не должен существовать; в нём состояние
# конструктора: subscriptions.tsv, proxies.yaml и пустой services.tsv - его
# сохраняет вызывающий после применения). REPORT: строки
# "RESET|kept-subscriptions|N", "RESET|kept-nodes|M", "REVIEW|file-provider-
# dropped|имя" и отчёт сборки. Ошибка - "ERROR: ..." в stderr, код 1, OUT не
# создаётся. Нет ни подписок, ни нод - отказ: пустой конфиг не запустить.
set -eu
umask 077
DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
source_file= output_file= report_file= state_out=
while [ $# -gt 0 ]; do
  key=$1; shift
  [ $# -gt 0 ] || fail 'Не задан аргумент'
  case $key in
    --source) source_file=$1 ;; --output) output_file=$1 ;;
    --report) report_file=$1 ;; --state-out) state_out=$1 ;;
    *) fail 'Неизвестный аргумент' ;;
  esac
  shift
done
[ -n "$source_file" ] && [ -n "$output_file" ] && [ -n "$report_file" ] && [ -n "$state_out" ] || fail 'Нужны --source --output --report --state-out'
for tool in constructor_build.sh config.example.yaml services.default.tsv config_to_state.awk; do
  [ -f "$DIR/$tool" ] || fail "Нет $tool рядом с reset_config.sh - переустановите проект"
done
[ -f "$source_file" ] || fail 'Текущий конфиг не найден'
source_size=$(wc -c < "$source_file" | tr -d ' ')
[ "$source_size" -le 1048576 ] || fail 'Текущий конфиг превышает лимит 1 МиБ'
for path in "$output_file" "$report_file" "$state_out"; do
  case $path in /tmp/*|/private/tmp/*) ;; *) fail 'Выход, отчёт и каталог состояния должны находиться в /tmp' ;; esac
done
[ ! -e "$state_out" ] || fail 'Каталог состояния уже существует'
WORK=$(mktemp -d /tmp/mst-reset.XXXXXX) || fail 'Не удалось создать RAM-каталог'
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
mkdir "$WORK/imp" "$WORK/state"
awk -v defaults="$DIR/services.default.tsv" -v template="$DIR/config.example.yaml" \
    -v out_dir="$WORK/imp" -v report="$WORK/imp.report" -f "$DIR/config_to_state.awk" "$source_file" 2> "$WORK/err" \
  || fail "Не удалось разобрать текущий конфиг: $(head -n 1 "$WORK/err")"
subs=0 nodes=0
if [ -f "$WORK/imp/subscriptions.tsv" ]; then
  cp "$WORK/imp/subscriptions.tsv" "$WORK/state/subscriptions.tsv"
  subs=$(wc -l < "$WORK/state/subscriptions.tsv" | tr -d ' ')
fi
if [ -f "$WORK/imp/proxies.yaml" ]; then
  cp "$WORK/imp/proxies.yaml" "$WORK/state/proxies.yaml"
  nodes=$(grep -c '^  - name:' "$WORK/state/proxies.yaml" || true)
fi
: > "$WORK/state/services.tsv"
[ $((subs + nodes)) -gt 0 ] || fail 'нет ни подписок, ни нод - заменять нечем'
# Заглушка вместо источника: constructor_build.sh берёт подписки и ноды из
# состояния, а остальное из источника - там только обязательная секция.
printf 'proxy-providers:\n' > "$WORK/stub.yaml"
sh "$DIR/constructor_build.sh" --state "$WORK/state" --source "$WORK/stub.yaml" \
  --output "$output_file" --report "$WORK/build.report" > "$WORK/build.log" 2>&1 \
  || fail "$(sed -n 's/^ERROR: //p' "$WORK/build.log" | head -n 1)"
{
  printf 'RESET|kept-subscriptions|%s\n' "$subs"
  printf 'RESET|kept-nodes|%s\n' "$nodes"
  grep '^REVIEW|file-provider-dropped|' "$WORK/imp.report" || true
  cat "$WORK/build.report"
} > "$report_file" || fail 'Не удалось сохранить отчёт'
cp -R "$WORK/state" "$state_out" || fail 'Не удалось сохранить состояние'
printf 'Кандидат замены подготовлен в RAM; применение не выполнялось.\n'
