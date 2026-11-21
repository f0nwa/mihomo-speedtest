#!/bin/sh
# constructor_build.sh - собирает config.yaml-кандидат конструктора конфига:
# шаблон config.example.yaml + встроенные сервисы services.default.tsv +
# состояние пользователя (config-state/) -> render_services.awk, затем
# migrate_config.sh переносит из текущего config.yaml подписки, свои прокси,
# dns, listeners и локальные ключи. Не публикует конфиг и не запускает
# службы. См. docs/superpowers/specs/2026-10-05-config-constructor-design.md.
#
#   sh constructor_build.sh (--state DIR | --import) --source CONFIG \
#      --output OUT --report REPORT
#
# --state DIR - каталог состояния (services.tsv, subscriptions.tsv,
#   proxies.yaml, geofilter.txt,
#   user-rules.txt; любого файла может не быть).
# --import - состояния ещё нет: оно выводится из --source
#   (config_to_state.awk) во временный каталог, отчёт импорта дописывается
#   в REPORT.
# OUT и REPORT - в /tmp (как у migrate_config.sh). Инструменты - рядом со
# скриптом. Ошибка - "ERROR: ..." в stderr, код 1, OUT не создаётся.
set -eu
umask 077
DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
state= import=0 source_file= output_file= report_file=
while [ $# -gt 0 ]; do
  case $1 in
    --import) import=1; shift; continue ;;
  esac
  key=$1; shift
  [ $# -gt 0 ] || fail 'Не задан аргумент'
  case $key in
    --state) state=$1 ;; --source) source_file=$1 ;;
    --output) output_file=$1 ;; --report) report_file=$1 ;;
    *) fail 'Неизвестный аргумент' ;;
  esac
  shift
done
[ -n "$source_file" ] && [ -n "$output_file" ] && [ -n "$report_file" ] || fail 'Нужны --source --output --report'
[ -n "$state" ] || [ "$import" = 1 ] || fail 'Нужен --state DIR или --import'
for tool in config.example.yaml services.default.tsv render_services.awk config_to_state.awk migrate_config.sh; do
  [ -f "$DIR/$tool" ] || fail "Нет $tool рядом с constructor_build.sh - переустановите проект"
done
WORK=$(mktemp -d /tmp/mst-constructor.XXXXXX) || fail 'Не удалось создать RAM-каталог'
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
if [ "$import" = 1 ]; then
  mkdir "$WORK/state"
  awk -v defaults="$DIR/services.default.tsv" -v template="$DIR/config.example.yaml" \
      -v out_dir="$WORK/state" -v report="$WORK/import.report" \
      -f "$DIR/config_to_state.awk" "$source_file" 2> "$WORK/err" \
    || fail "Не удалось разобрать текущий конфиг: $(head -n 1 "$WORK/err")"
  state=$WORK/state
fi
ov= geo= ur= subs= prox=
[ ! -f "$state/subscriptions.tsv" ] || subs=$state/subscriptions.tsv
[ ! -f "$state/proxies.yaml" ] || prox=$state/proxies.yaml
[ ! -f "$state/services.tsv" ] || ov=$state/services.tsv
[ ! -f "$state/geofilter.txt" ] || geo=$state/geofilter.txt
[ ! -f "$state/user-rules.txt" ] || ur=$state/user-rules.txt
awk -v services_file="$DIR/services.default.tsv" -v overlay_file="$ov" -v geofilter_file="$geo" \
    -v user_rules_file="$ur" -f "$DIR/render_services.awk" "$DIR/config.example.yaml" \
    > "$WORK/template.yaml" 2> "$WORK/err" \
  || fail "Ошибка в настройках конструктора: $(sed 's/^render_services.awk: //' "$WORK/err" | head -n 1)"
set -- ; [ -z "$subs" ] || set -- "$@" --subs "$subs"; [ -z "$prox" ] || set -- "$@" --proxies "$prox"
sh "$DIR/migrate_config.sh" "$@" --source "$source_file" --template "$WORK/template.yaml" \
  --output "$output_file" --report "$report_file" > "$WORK/migrate.log" 2>&1 \
  || fail "$(sed -n 's/^ERROR: //p' "$WORK/migrate.log" | head -n 1)"
[ "$import" = 0 ] || cat "$WORK/import.report" >> "$report_file"
printf 'Кандидат конструктора подготовлен в RAM; применение не выполнялось.\n'
