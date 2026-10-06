#!/bin/sh
# CGI конструктора конфига (вкладка "Конфиг", режим "Конструктор"): чтение
# состояния, предпросмотр и применение. Ставится install.sh в
# $DIR/stats_constructor.sh, stats_httpd.py запускает его оттуда. Функции
# применения (бэкап, mihomo -t, перезапуск, откат) - из stats_config.sh,
# подключённого как библиотека. См. docs/superpowers/specs/
# 2026-10-05-config-constructor-design.md, п. 4.
#
# Действие - в MST_CONSTRUCTOR_ACTION:
#   read     GET  - {"imported","manual_edits","base","defaults","services",
#                   "geofilter","user_rules","report"}: состояние из
#                   $CONFIG_STATE_DIR, а если его нет (или ?import=1) - перенос
#                   из config.yaml (imported=true, отчёт в report); null -
#                   файла нет.
#   preview  POST - собрать кандидата из присланного состояния, без записи:
#                   {"ok","text","report","check"}.
#   catalog  GET  - {"text"}: каталог наборов правил для поиска
#                   (rule-catalog.tsv, release/build_rule_catalog.sh).
#   apply    POST - то же и применить (?base= как у save в stats_config.sh);
#                   состояние и managed.sig пишутся только после успешного
#                   применения.
# Тело preview/apply - блоки "### MST-STATE <файл>" (services.tsv,
# geofilter.txt, user-rules.txt), за строкой блока - содержимое файла; нет
# блока - нет файла.
#
# managed.sig - отпечаток разделов anchors, proxy-groups, rule-providers и
# rules config.yaml после применения: если он другой, эти разделы правили
# вручную (YAML-режим, восстановление бэкапа) - manual_edits=true.
set -eu

DIR=${DIR:-/opt/etc/mihomo-speedtest}
CONFIG_LIB=${CONFIG_LIB:-$DIR/stats_config.sh}
MST_CONFIG_LIB=1 . "$CONFIG_LIB"
CONSTRUCTOR_DEFAULTS=${CONSTRUCTOR_DEFAULTS:-$DIR/services.default.tsv}
CONFIG_TO_STATE_AWK=${CONFIG_TO_STATE_AWK:-$DIR/config_to_state.awk}
CONSTRUCTOR_CATALOG=${CONSTRUCTOR_CATALOG:-$DIR/rule-catalog.tsv}
APPLY_LOG=${CONSTRUCTOR_APPLY_LOG:-$APPLY_LOG}
STATE_FILES="services.tsv geofilter.txt user-rules.txt"

# Файл JSON-строкой или null, если файла нет.
jfile_or_null() {
  if [ -f "$1" ]; then jstr_file "$1"; else printf 'null'; fi
}

# Тело запроса ($1) -> файлы состояния в каталоге $2. Код 3 - неизвестный
# блок, повтор блока или текст до первого блока.
parse_state() {
  mkdir "$2"
  awk -v dir="$2" -v allowed=" $STATE_FILES " '
    /^### MST-STATE / {
      name = $0; sub(/^### MST-STATE /, "", name); sub(/[ \r]+$/, "", name)
      if (index(allowed, " " name " ") == 0 || name ~ /\// || (name in seen)) exit 3
      seen[name] = 1
      if (out != "") close(out)
      out = dir "/" name
      printf "" > out
      next
    }
    out == "" { if ($0 ~ /^[ \t\r]*$/) next; exit 3 }
    { print > out }
  ' "$1"
}

build_candidate() {
  # $1 - каталог состояния; кандидат - $WORK/cand.yaml, отчёт - $WORK/report
  target=$(config_target) || fail_json 500 config_path "Не удалось определить путь конфига"
  [ -f "$target" ] || fail_json 404 no_config "Файл $CONFIG не найден"
  [ -f "$CONSTRUCTOR_BUILD" ] || fail_json 500 no_tools "constructor_build.sh не найден - переустановите проект"
  if ! sh "$CONSTRUCTOR_BUILD" --state "$1" --source "$target" --output "$WORK/cand.yaml" \
      --report "$WORK/report" > "$WORK/build.log" 2>&1; then
    fail_json 422 build_failed "$(sed -n 's/^ERROR: //p' "$WORK/build.log" | head -n 1)"
  fi
}

read_state_body() {
  read_body "$WORK/body"
  rc=0; parse_state "$WORK/body" "$WORK/state" || rc=$?
  [ "$rc" = 0 ] || fail_json 400 bad_body "Тело должно состоять из блоков ### MST-STATE с файлами: $STATE_FILES"
}

# Замена состояния прервалась между двумя mv (осталась только копия .old) -
# вернуть её на место. Вызывается перед чтением и перед записью.
recover_state() {
  if [ ! -d "$CONFIG_STATE_DIR" ] && [ -d "$CONFIG_STATE_DIR.old" ]; then
    mv "$CONFIG_STATE_DIR.old" "$CONFIG_STATE_DIR" 2>/dev/null || true
  fi
}

# Новое состояние ($NEW_STATE) - на место $CONFIG_STATE_DIR: собирается в
# соседнем .new и меняется местами, managed.sig - от нового config.yaml.
# Любой сбой - WARN в журнал: конфиг уже применён, ответ должен уйти.
after_apply_ok() {
  [ -n "${NEW_STATE:-}" ] || return 0
  recover_state
  ns=$CONFIG_STATE_DIR.new
  rm -rf "$ns" "$CONFIG_STATE_DIR.old" 2>/dev/null || true
  if mkdir -p "$ns" && { [ -z "$(ls "$NEW_STATE")" ] || cp -p "$NEW_STATE"/* "$ns"/; } &&
      { [ -f "$ns/services.tsv" ] || : > "$ns/services.tsv"; } &&
      managed_sig "$(config_target)" > "$ns/managed.sig"; then
    if [ ! -d "$CONFIG_STATE_DIR" ] || mv "$CONFIG_STATE_DIR" "$CONFIG_STATE_DIR.old"; then
      if mv "$ns" "$CONFIG_STATE_DIR"; then
        rm -rf "$CONFIG_STATE_DIR.old" 2>/dev/null || true
        alog "Состояние конструктора сохранено в $CONFIG_STATE_DIR"
        return 0
      fi
      recover_state
    fi
  fi
  rm -rf "$ns" 2>/dev/null || true
  alog "WARN: конфиг применён, но состояние конструктора не сохранилось ($CONFIG_STATE_DIR)"
  return 0
}

if [ "${MST_CONSTRUCTOR_LIB:-0}" != 1 ]; then
new_work
method=${REQUEST_METHOD:-GET}
action=${MST_CONSTRUCTOR_ACTION:-read}

case $action:$method in
  read:GET|read:HEAD)
    recover_state
    target=$(config_target) || fail_json 500 config_path "Не удалось определить путь конфига"
    [ -f "$target" ] || fail_json 404 no_config "Файл $CONFIG не найден"
    [ -f "$CONSTRUCTOR_DEFAULTS" ] || fail_json 500 no_tools "services.default.tsv не найден - переустановите проект"
    imported=false manual=false
    : > "$WORK/report"
    # ?import=1 - «Перенести в конструктор»: перенос из config.yaml даже при
    # сохранённом состоянии (оно заменится только при применении).
    if [ "$(query_param import)" != 1 ] && [ -f "$CONFIG_STATE_DIR/services.tsv" ]; then
      st=$CONFIG_STATE_DIR
      if [ -f "$st/managed.sig" ] && [ "$(cat "$st/managed.sig")" != "$(managed_sig "$target")" ]; then manual=true; fi
    else
      st=$WORK/state; mkdir "$st"; imported=true
      awk -v defaults="$CONSTRUCTOR_DEFAULTS" -v template="$CONFIG_TEMPLATE" -v out_dir="$st" \
          -v report="$WORK/report" -f "$CONFIG_TO_STATE_AWK" "$target" 2> "$WORK/err" \
        || fail_json 422 import_failed "Не удалось разобрать config.yaml: $(head -n 1 "$WORK/err")"
    fi
    printf '{"imported":%s,"manual_edits":%s,"base":"%s","defaults":%s,"services":%s,"geofilter":%s,"user_rules":%s,"report":%s}\n' \
      "$imported" "$manual" "$(fingerprint "$target")" "$(jstr_file "$CONSTRUCTOR_DEFAULTS")" \
      "$(jfile_or_null "$st/services.tsv")" "$(jfile_or_null "$st/geofilter.txt")" \
      "$(jfile_or_null "$st/user-rules.txt")" "$(lines_json "$WORK/report")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  catalog:GET|catalog:HEAD)
    [ -f "$CONSTRUCTOR_CATALOG" ] || fail_json 404 no_catalog "Каталог наборов правил не найден - переустановите проект"
    printf '{"text":%s}\n' "$(jstr_file "$CONSTRUCTOR_CATALOG")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  preview:POST)
    read_state_body
    build_candidate "$WORK/state"
    rc=0; check_file "$WORK/cand.yaml" || rc=$?
    printf '{"ok":true,"text":%s,"report":%s,"check":%s}\n' "$(jstr_file "$WORK/cand.yaml")" \
      "$(lines_json "$WORK/report")" "$(check_json "$rc")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  apply:POST)
    read_state_body
    build_candidate "$WORK/state"
    NEW_STATE=$WORK/state
    apply_candidate "$WORK/cand.yaml" ;;
  *)
    fail_json 405 method_not_allowed "" ;;
esac
fi
