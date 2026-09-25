#!/bin/sh
# Библиотека update.sh. Вызывается под общей блокировкой после verify_plan.
# WORK и saved находятся в RAM. Журнал содержит только фиксированную стадию,
# никогда не исполняется. COMMIT означает проверенное новое состояние;
# восстановление завершает публикацию комплекта, остальные стадии откатываются.
# Возврат 1: ошибка обновления; 2: восстановление требует вмешательства.

tx_logical_path() {
  case $1 in
    /opt/etc/init.d/S80speedtest-stats) ;;
    /opt/etc/mihomo-speedtest/*)
      case $1 in /opt/etc/mihomo-speedtest/.update|/opt/etc/mihomo-speedtest/.update/*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  case $1 in *'|'*|*[[:cntrl:]]*|*//*|*/../*|*/./*|*/..|*/.) return 1 ;; esac
  safe_path "$(target_file "$1")"
}
tx_record_destination() {
  case $1:$2 in
    CONFIG:active-config) target_file "$MIHOMO_DIR/config.yaml" ;;
    SCHEMA:config-schema-version) printf '%s\n' "$UPDATE_STATE_DIR/config-schema-version" ;;
    HASH:config-sha256) printf '%s\n' "$UPDATE_STATE_DIR/config-sha256" ;;
    STATE:installed-manifest) printf '%s\n' "$INSTALLED_MANIFEST_PATH" ;;
    FILE:*) tx_logical_path "$2" && target_file "$2" ;;
    *) return 1 ;;
  esac
}
tx_context() {
  printf 'ROOT=%s\nSTATE=%s\nINSTALLED=%s\n' "$TARGET_ROOT" "$UPDATE_STATE_DIR" "$INSTALLED_MANIFEST_PATH"
}
tx_verify_file() {
  safe_path "$1"
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  tx_verify_mode=${4#0}
  [ -n "$tx_verify_mode" ] || tx_verify_mode=0
  [ "$(sha256_of "$1")" = "$2" ] &&
  [ "$(wc -c < "$1" | tr -d ' ')" = "$3" ] &&
  [ "$(mode_of "$1")" = "$tx_verify_mode" ]
}
transaction_validate_bundle() (
  tx_bundle=$1
  safe_path "$tx_bundle"
  [ -d "$tx_bundle" ] || exit 1
  for tx_meta in list.txt context.txt engine-manifest.txt actions.txt integrity.txt; do
    safe_path "$tx_bundle/$tx_meta"
    [ -f "$tx_bundle/$tx_meta" ] || exit 1
  done
  [ "$INSTALLED_MANIFEST_PATH" != "$(target_file "$MIHOMO_DIR/config.yaml")" ] || exit 1
  tx_context > "$WORK/tx-context-check"
  cmp -s "$WORK/tx-context-check" "$tx_bundle/context.txt" || exit 1
  tx_integrity=$(cat "$tx_bundle/integrity.txt")
  [ "${#tx_integrity}" = 64 ] || exit 1
  { sha256_of "$tx_bundle/list.txt"; sha256_of "$tx_bundle/context.txt"; sha256_of "$tx_bundle/engine-manifest.txt"; sha256_of "$tx_bundle/actions.txt"; } > "$WORK/tx-integrity-check"
  [ "$(sha256_of "$WORK/tx-integrity-check")" = "$tx_integrity" ] || exit 1
  awk -F'|' '
    NF!=7 || ($1!="FILE" && $1!="STATE" && $1!="CONFIG" && $1!="SCHEMA" && $1!="HASH") {exit 1}
    seen[$1 SUBSEP $2]++ {exit 1}
    $1=="STATE" {if($2!="installed-manifest" || state++) exit 1}
    $1=="CONFIG" {if($2!="active-config" || $3!="present" || config++)exit 1}
    $1=="SCHEMA" {if($2!="config-schema-version" || schema++)exit 1}
    $1=="HASH" {if($2!="config-sha256" || hash++)exit 1}
    $3!="present" && $3!="missing" {exit 1}
    $7 !~ /^[1-9][0-9]*$/ || number[$7]++ {exit 1}
    $3=="present" && (length($4)!=64 || $4 !~ /^[0-9a-f]+$/ || $5 !~ /^[0-9]+$/ || $6 !~ /^[0-7]+$/ || length($6)<1 || length($6)>4) {exit 1}
    $3=="missing" && ($4!="-" || $5!="0" || $6!="-") {exit 1}
    END {if(state!=1 || config!=schema || schema!=hash) exit 1}' "$tx_bundle/list.txt" || exit 1
  : > "$WORK/tx-reserved-check"
  for tx_reserved in "$(target_file "$MIHOMO_DIR/config.yaml")" "$INSTALLED_MANIFEST_PATH" "$UPDATE_STATE_DIR/config-schema-version" "$UPDATE_STATE_DIR/config-sha256"; do
    safe_path "$tx_reserved"; safe_path "$tx_reserved.mst-update-new"
    printf '%s\n%s\n' "$tx_reserved" "$tx_reserved.mst-update-new" >> "$WORK/tx-reserved-check"
  done
  awk 'seen[$0]++{exit 1}' "$WORK/tx-reserved-check" || exit 1
  : > "$WORK/tx-paths-check"
  while IFS='|' read -r tx_kind tx_path tx_presence tx_sha tx_bytes tx_mode tx_num; do
    tx_validate_actual=$(tx_record_destination "$tx_kind" "$tx_path") || exit 1
    safe_path "$tx_validate_actual"
    safe_path "$tx_validate_actual.mst-update-new"
    printf '%s\n%s\n' "$tx_validate_actual" "$tx_validate_actual.mst-update-new" >> "$WORK/tx-paths-check"
    if [ "$tx_presence" = present ]; then
      tx_verify_file "$tx_bundle/backups/$tx_num" "$tx_sha" "$tx_bytes" "$tx_mode" || exit 1
    fi
  done < "$tx_bundle/list.txt"
  awk 'seen[$0]++{exit 1}' "$WORK/tx-paths-check" || exit 1
  # FILE не может занимать фиксированные метаданные даже в старом комплекте.
  while IFS='|' read -r tx_kind tx_path tx_rest; do
    [ "$tx_kind" = FILE ] || continue
    tx_actual=$(target_file "$tx_path")
    for tx_reserved in "$INSTALLED_MANIFEST_PATH" "$UPDATE_STATE_DIR/config-schema-version" "$UPDATE_STATE_DIR/config-sha256"; do
      case $tx_actual in "$tx_reserved"|"$tx_reserved.mst-update-new") exit 1 ;; esac
      [ "$tx_actual.mst-update-new" != "$tx_reserved" ] || exit 1
    done
  done < "$tx_bundle/list.txt"
  # Резервный движок проверяется по релизному манифесту перед его загрузкой CLI.
  awk -v MANIFEST="$tx_bundle/engine-manifest.txt" -v VALIDATE_ONLY=1 -v UPDATER_VERSION="$UPDATER_VERSION" -f "$PLAN_AWK" || exit 1
  for tx_engine in update.sh update_plan.awk update_prepare.sh update_transaction.sh; do
    tx_engine_record=$(awk -F'|' -v n="$tx_engine" '$1=="FILE"&&$3==n{print $5 "|" $6 "|" $7; count++} END{if(count!=1)exit 1}' "$tx_bundle/engine-manifest.txt") || exit 1
    IFS='|' read -r tx_bytes tx_sha tx_mode <<RECORD
$tx_engine_record
RECORD
    tx_verify_file "$tx_bundle/engine/$tx_engine" "$tx_sha" "$tx_bytes" "$tx_mode" || exit 1
  done
  safe_path "$tx_bundle/actions.txt"
  [ -f "$tx_bundle/actions.txt" ] || exit 1
  awk '($0!="restart-web" && $0!="restart-mihomo") || seen[$0]++ {exit 1}' "$tx_bundle/actions.txt" || exit 1
  tx_has_config=$(awk -F'|' '$1=="CONFIG"{print 1}' "$tx_bundle/list.txt")
  if grep -q '^restart-mihomo$' "$tx_bundle/actions.txt"; then [ "$tx_has_config" = 1 ] || exit 1
  else [ -z "$tx_has_config" ] || exit 1; fi
)
tx_journal() {
  safe_path "$UPDATE_STATE_DIR/transaction.txt"
  safe_path "$UPDATE_STATE_DIR/transaction.new"
  # POSIX sync обеспечивает сохранение backup/целевых файлов до стадии,
  # затем самого атомарно опубликованного журнала до следующей записи.
  sync || return 1
  printf '%s\n' "$1" > "$UPDATE_STATE_DIR/transaction.new" &&
  chmod 0600 "$UPDATE_STATE_DIR/transaction.new" &&
  mv -f "$UPDATE_STATE_DIR/transaction.new" "$UPDATE_STATE_DIR/transaction.txt" && sync
}
tx_clear_journal() {
  sync && rm -f "$UPDATE_STATE_DIR/transaction.txt" && sync
}
tx_publish() {
  # Только одно копирование нового содержимого на постоянный раздел.
  tx_source=$1 tx_dest=$2 tx_sha=$3 tx_bytes=$4 tx_mode=$5
  safe_path "$tx_dest"
  tx_tmp=$tx_dest.mst-update-new
  safe_path "$tx_tmp"
  mkdir -p "${tx_dest%/*}" || return 1
  cp "$tx_source" "$tx_tmp" && chmod "$tx_mode" "$tx_tmp" &&
  tx_verify_file "$tx_tmp" "$tx_sha" "$tx_bytes" "$tx_mode" &&
  mv -f "$tx_tmp" "$tx_dest"
}
tx_bounded_action() (
  tx_init=$(target_file /opt/etc/init.d/S80speedtest-stats)
  safe_path "$tx_init"
  [ -f "$tx_init" ] || exit 1
  # DIR/SERVICE/ENV службы статистики - это файлы ПРОЕКТА (мигрировали
  # в /opt/etc/mihomo-speedtest), а не самой Mihomo (MIHOMO_DIR) - см.
  # docs/superpowers/specs/2026-09-25-install-dir-separation-design.md.
  tx_project=$(target_file /opt/etc/mihomo-speedtest)
  tx_runtime=${STATS_SERVICE_RUNTIME_DIR:-/tmp/mihomo-speedtest-stats}
  tx_supervisor=${SUPERVISOR_PIDFILE:-$tx_runtime/supervisor.pid}
  tx_http_pid=${STATS_HTTP_PIDFILE:-$tx_runtime/httpd.pid}
  if [ -n "$TARGET_ROOT" ]; then
    printf '%s\n' "$TARGET_ROOT" > "$WORK/tx-service-root"
    tx_runtime=$TMPROOT/mst-update-service-$(sha256_of "$WORK/tx-service-root")
    tx_supervisor=$tx_runtime/supervisor.pid
    tx_http_pid=$tx_runtime/httpd.pid
  fi
  # DIR обновлятора указывает на engine, поэтому явно передаём пути службы.
  tx_bounded_command "${UPDATE_ACTION_TIMEOUT:-15}" env \
    DIR="$tx_project" SERVICE="$tx_project/stats_service.sh" ENV="$tx_project/speedtest2.env" \
    STATS_SERVICE_RUNTIME_DIR="$tx_runtime" SUPERVISOR_PIDFILE="$tx_supervisor" \
    STATS_HTTP_PIDFILE="$tx_http_pid" sh "$tx_init" "$1"
)
tx_timeout_valid() {
  case $1 in ''|0|*[!0-9]*) return 1 ;; esac
  [ "$1" -le 300 ]
}
tx_list_tree() (
  tx_parent=$1
  case $tx_parent in ''|*[!0-9]*) exit 1 ;; esac
  # Убиваем только потомков конкретной команды при timeout/cancel.
  if [ -r "/proc/$tx_parent/task/$tx_parent/children" ]; then
    tx_children=$(cat "/proc/$tx_parent/task/$tx_parent/children")
  elif [ -d /proc/self ]; then
    tx_children=$(awk -v p="$tx_parent" 'BEGIN {
      for(i=1;i<ARGC;i++) {
        path=ARGV[i];pid="";parent=""
        while((getline line<path)>0) {
          split(line,a,/[[:space:]]+/)
          if(a[1]=="Pid:")pid=a[2]
          if(a[1]=="PPid:")parent=a[2]
        }
        close(path)
        if(parent==p&&pid ~ /^[0-9]+$/)print pid
      }
      exit
    }' /proc/[0-9]*/status 2>/dev/null)
  else
    tx_children=$(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$tx_parent" '$2==p{print $1}')
  fi
  for tx_descendant in $tx_children; do
    tx_list_tree "$tx_descendant"
  done
  printf '%s\n' "$tx_parent"
)
tx_kill_tree() (
  tx_signal=$2
  for tx_tree_pid in $(tx_list_tree "$1"); do
    kill "-$tx_signal" "$tx_tree_pid" 2>/dev/null || :
  done
)
tx_cancel_action_children() {
  [ -f "$WORK/tx-action-children" ] || return 0
  while IFS= read -r tx_cancel_pid; do
    case $tx_cancel_pid in ''|*[!0-9]*) continue ;; esac
    tx_kill_tree "$tx_cancel_pid" KILL
  done < "$WORK/tx-action-children"
  rm -f "$WORK/tx-action-children"
}
tx_watchdog() (
  tx_watch_limit=$1 tx_watch_pending=$2 tx_watch_timeout=$3
  tx_watch_done=$4 tx_watch_child=$5
  tx_watch_timer=
  trap '[ -z "$tx_watch_timer" ] || kill -KILL "$tx_watch_timer" 2>/dev/null || :; exit 0' HUP INT TERM
  sleep "$tx_watch_limit" &
  tx_watch_timer=$!
  wait "$tx_watch_timer" 2>/dev/null || exit 0
  kill -0 "$tx_watch_child" 2>/dev/null || exit 0
  if mv "$tx_watch_pending" "$tx_watch_timeout" 2>/dev/null; then
    tx_watch_tree=$(tx_list_tree "$tx_watch_child")
    for tx_watch_pid in $tx_watch_tree; do
      kill -TERM "$tx_watch_pid" 2>/dev/null || :
    done
  else
    [ -e "$tx_watch_done" ] || tx_kill_tree "$tx_watch_child" KILL
    exit 1
  fi
  sleep 1
  for tx_watch_pid in $tx_watch_tree; do
    kill -KILL "$tx_watch_pid" 2>/dev/null || :
  done
)
tx_bounded_command() (
  tx_limit=$1; shift
  tx_timeout_valid "$tx_limit" || exit 1
  tx_log=$WORK/tx-command-$$.log
  : > "$tx_log" || exit 1
  tx_pending=$(mktemp "$WORK/tx-command-state.XXXXXX") || exit 1
  tx_timed_out=$tx_pending.timeout
  tx_done=$tx_pending.done
  rm -f "$tx_timed_out" "$tx_done"
  ( ulimit -f 64; exec "$@" ) >> "$tx_log" 2>&1 &
  tx_child=$!
  printf '%s\n' "$tx_child" > "$WORK/tx-action-children" || {
    tx_kill_tree "$tx_child" KILL; wait "$tx_child" 2>/dev/null || :
    rm -f "$tx_log" "$tx_pending" "$tx_timed_out" "$tx_done" "$WORK/tx-action-children"; exit 1
  }
  tx_watchdog "$tx_limit" "$tx_pending" "$tx_timed_out" "$tx_done" "$tx_child" >/dev/null 2>&1 &
  tx_watch=$!
  printf '%s\n%s\n' "$tx_child" "$tx_watch" > "$WORK/tx-action-children" || {
    tx_kill_tree "$tx_child" KILL; tx_kill_tree "$tx_watch" KILL
    wait "$tx_child" 2>/dev/null || :
    rm -f "$tx_log" "$tx_pending" "$tx_timed_out" "$tx_done" "$WORK/tx-action-children"; exit 1
  }
  trap 'tx_kill_tree "$tx_child" KILL; tx_kill_tree "$tx_watch" KILL; wait "$tx_child" 2>/dev/null || :; rm -f "$tx_log" "$tx_pending" "$tx_timed_out" "$tx_done" "$WORK/tx-action-children"; exit 1' HUP INT TERM
  tx_rc=0; wait "$tx_child" || tx_rc=$?
  if mv "$tx_pending" "$tx_done" 2>/dev/null; then
    tx_kill_tree "$tx_watch" TERM
  else
    tx_rc=1
    [ -e "$tx_timed_out" ] || tx_kill_tree "$tx_watch" TERM
  fi
  wait "$tx_watch" 2>/dev/null || :
  [ ! -e "$tx_timed_out" ] || tx_rc=1
  [ -e "$tx_done" ] || tx_rc=1
  rm -f "$tx_log" "$tx_pending" "$tx_timed_out" "$tx_done" "$WORK/tx-action-children"
  exit "$tx_rc"
)
tx_health_config() (
  tx_config=$1
  # Только простые однострочные scalars; неоднозначный YAML закрывает проверку.
  awk '
    /^external-controller:|^secret:/ {
      key=$0;sub(/:.*/,"",key);value=$0;sub(/^[^:]*:[[:space:]]*/,"",value)
      if(seen[key]++ || value ~ /[\\[:cntrl:]]/ || value ~ /[#!&*{}\[\]]/)exit 1
      if(value ~ /^".*"$/){sub(/^"/,"",value);sub(/"$/,"",value)}
      if(value ~ /"/)exit 1
      if(value ~ /^\047.*\047$/){sub(/^\047/,"",value);sub(/\047$/,"",value)}
      if(value ~ /\047/)exit 1
      if(key=="external-controller")controller=value;else secret=value
    }
    END {
      if(controller !~ /^(127\.0\.0\.1|localhost|0\.0\.0\.0):[0-9]+$/)exit 1
      sub(/^[^:]+:/,"",controller)
      if(controller+0<1 || controller+0>65535)exit 1
      print "url = \"http://127.0.0.1:" controller "/version\""
      print "silent";print "fail";print "max-time = 3";print "noproxy = \"*\""
      if(secret!="")print "header = \"Authorization: Bearer " secret "\""
    }' "$tx_config" > "$WORK/tx-curl-config" || exit 1
  chmod 0600 "$WORK/tx-curl-config" || exit 1
  exit 0
)
tx_default_health() (
  pidof mihomo >/dev/null 2>&1 || exit 1
  tx_health_config "$(target_file "$MIHOMO_DIR/config.yaml")" || exit 1
  curl -q --config - < "$WORK/tx-curl-config" >/dev/null 2>&1
  tx_rc=$?; rm -f "$WORK/tx-curl-config"; exit "$tx_rc"
)
tx_mihomo_health() (
  tx_limit=${UPDATE_HEALTH_TIMEOUT:-15}
  tx_timeout_valid "$tx_limit" || exit 1
  if [ -n "${UPDATE_HEALTH_CMD:-}" ]; then
    tx_bounded_command "$tx_limit" "$UPDATE_HEALTH_CMD"
    exit $?
  fi
  : > "$WORK/tx-health.log" || exit 1
  tx_pending=$(mktemp "$WORK/tx-health-state.XXXXXX") || exit 1
  tx_timed_out=$tx_pending.timeout
  tx_done=$tx_pending.done
  rm -f "$tx_timed_out" "$tx_done"
  ( while ! tx_default_health; do sleep 1; done ) >> "$WORK/tx-health.log" 2>&1 &
  tx_health=$!
  printf '%s\n' "$tx_health" > "$WORK/tx-action-children" || {
    tx_kill_tree "$tx_health" KILL; wait "$tx_health" 2>/dev/null || :
    rm -f "$WORK/tx-health.log" "$tx_pending" "$tx_timed_out" "$tx_done" "$WORK/tx-action-children"; exit 1
  }
  tx_watchdog "$tx_limit" "$tx_pending" "$tx_timed_out" "$tx_done" "$tx_health" >/dev/null 2>&1 &
  tx_watch=$!
  printf '%s\n%s\n' "$tx_health" "$tx_watch" > "$WORK/tx-action-children" || {
    tx_kill_tree "$tx_health" KILL; tx_kill_tree "$tx_watch" KILL
    wait "$tx_health" 2>/dev/null || :
    rm -f "$WORK/tx-health.log" "$tx_pending" "$tx_timed_out" "$tx_done" "$WORK/tx-action-children"; exit 1
  }
  trap 'tx_kill_tree "$tx_health" KILL; tx_kill_tree "$tx_watch" KILL; wait "$tx_health" 2>/dev/null || :; rm -f "$WORK/tx-health.log" "$WORK/tx-curl-config" "$tx_pending" "$tx_timed_out" "$tx_done" "$WORK/tx-action-children"; exit 1' HUP INT TERM
  tx_rc=0; wait "$tx_health" || tx_rc=$?
  if mv "$tx_pending" "$tx_done" 2>/dev/null; then
    tx_kill_tree "$tx_watch" TERM
  else
    tx_rc=1
    [ -e "$tx_timed_out" ] || tx_kill_tree "$tx_watch" TERM
  fi
  wait "$tx_watch" 2>/dev/null || :
  [ ! -e "$tx_timed_out" ] || tx_rc=1
  [ -e "$tx_done" ] || tx_rc=1
  rm -f "$WORK/tx-health.log" "$WORK/tx-curl-config" "$tx_pending" "$tx_timed_out" "$tx_done" "$WORK/tx-action-children"
  exit "$tx_rc"
)
tx_actions() {
  if grep -q '^restart-mihomo$' "$1/actions.txt"; then
    tx_xkeen=${UPDATE_XKEEN_BIN:-$(target_file /opt/sbin/xkeen)}
    safe_path "$tx_xkeen"
    tx_bounded_command "${UPDATE_ACTION_TIMEOUT:-15}" "$tx_xkeen" -restart && tx_mihomo_health || return 1
  fi
  if grep -q '^restart-web$' "$1/actions.txt"; then
    tx_bounded_action restart && tx_bounded_action check || return 1
  fi
  return 0
}
tx_restore() (
  tx_bundle=$1
  transaction_validate_bundle "$tx_bundle" || exit 2
  tx_failed=0
  while IFS='|' read -r tx_kind tx_path tx_presence tx_sha tx_bytes tx_mode tx_num; do
    tx_dest=$(tx_record_destination "$tx_kind" "$tx_path") || exit 2
    safe_path "$tx_dest"
    if [ "$tx_presence" = present ]; then
      tx_publish "$tx_bundle/backups/$tx_num" "$tx_dest" "$tx_sha" "$tx_bytes" "$tx_mode" || tx_failed=1
    else
      rm -f "$tx_dest" || tx_failed=1
    fi
    safe_path "$tx_dest.mst-update-new"
    rm -f "$tx_dest.mst-update-new" || tx_failed=1
  done < "$tx_bundle/list.txt"
  [ "$tx_failed" = 0 ] || exit 2
  # При первой установке веб-службы прежнее состояние не содержит init.
  if awk -F'|' '$1=="FILE"&&$2=="/opt/etc/init.d/S80speedtest-stats"&&$3=="missing"{absent=1} END{exit !absent}' "$tx_bundle/list.txt"; then :
  else tx_actions "$tx_bundle" || exit 2; fi
)
tx_finish_commit() {
  # Повторяемо после сбоя между двумя rename. Старый rollback жив до COMMIT.
  if [ -d "$UPDATE_STATE_DIR/rollback.pending" ]; then
    transaction_validate_bundle "$UPDATE_STATE_DIR/rollback.pending" || return 2
    if [ -d "$UPDATE_STATE_DIR/rollback" ]; then
      [ ! -e "$UPDATE_STATE_DIR/rollback.previous" ] || return 2
      mv "$UPDATE_STATE_DIR/rollback" "$UPDATE_STATE_DIR/rollback.previous" || return 2
    fi
    mv "$UPDATE_STATE_DIR/rollback.pending" "$UPDATE_STATE_DIR/rollback" || return 2
  else
    transaction_validate_bundle "$UPDATE_STATE_DIR/rollback" || return 2
  fi
  sync || return 2
  rm -rf "$UPDATE_STATE_DIR/rollback.previous" || return 2
  tx_clear_journal || return 2
}
transaction_recover() (
  safe_path "$UPDATE_STATE_DIR/transaction.txt"
  [ -f "$UPDATE_STATE_DIR/transaction.txt" ] || exit 0
  for tx_name in rollback rollback.pending rollback.previous; do safe_path "$UPDATE_STATE_DIR/$tx_name"; done
  case $(cat "$UPDATE_STATE_DIR/transaction.txt") in
    APPLY_PENDING)
      tx_restore "$UPDATE_STATE_DIR/rollback.pending" || exit 2
      tx_journal CLEANUP_PENDING || exit 2
      rm -rf "$UPDATE_STATE_DIR/rollback.pending" || exit 2
      tx_clear_journal || exit 2 ;;
    CLEANUP_PENDING)
      # Эта стадия публикуется только после полного восстановления файлов
      # и проверки старой службы. Частичный cleanup уже мог удалить engine.
      # rm -rf фиксированного каталога не следует внутренним symlink.
      if [ -e "$UPDATE_STATE_DIR/rollback.pending" ]; then
        safe_path "$UPDATE_STATE_DIR/rollback.pending"
        rm -rf "$UPDATE_STATE_DIR/rollback.pending" || exit 2
      fi
      tx_clear_journal || exit 2 ;;
    ROLLBACK_SAVED)
      tx_restore "$UPDATE_STATE_DIR/rollback" || exit 2
      tx_clear_journal || exit 2 ;;
    COMMIT) tx_finish_commit || exit 2 ;;
    *) say 'ERROR: неверный журнал транзакции' >&2; exit 2 ;;
  esac
)
transaction_rollback() (
  safe_path "$UPDATE_STATE_DIR/transaction.txt"
  [ ! -e "$UPDATE_STATE_DIR/transaction.txt" ] || { say 'ERROR: сначала выполните recover' >&2; exit 2; }
  transaction_validate_bundle "$UPDATE_STATE_DIR/rollback" || { say 'ERROR: комплект отката повреждён' >&2; exit 2; }
  tx_journal ROLLBACK_SAVED || exit 2
  transaction_recover
)
tx_build_installed() {
  # Сохраняем декларации старых неперевыбранных компонентов, берём новые
  # декларации выбранных. Общая повторная валидация отвергает несовместимую смесь.
  awk -F'|' -v records="$WORK/records" -v old="$INSTALLED_MANIFEST_PATH" '
    BEGIN {
      while((getline line<records)>0){split(line,a,"|");if(a[1]=="COMPONENT")selected[a[2]]=1}
      close(records)
      while((getline line<old)>0){split(line,a,"|");if(a[1]=="COMPONENT"&&!selected[a[2]])kept[a[2]]=1; previous[++n]=line}
      close(old)
    }
    /^[A-Z_]+=/ {print;next}
    $1=="CONFLICT" {if((selected[$2]||kept[$2])&&(selected[$3]||kept[$3])&&(selected[$2]||selected[$3]))print;next}
    $1=="DEPENDS" {if(selected[$2])print;next}
    selected[$2] {print}
    END {
      for(i=1;i<=n;i++){split(previous[i],a,"|");if(!kept[a[2]])continue
        if(a[1]=="CONFLICT"&&!kept[a[3]]&&!selected[a[3]])continue
        print previous[i]}
    }' "$MANIFEST_TMP" > "$WORK/tx-installed.txt" || return 1
  tx_installed_components=$(awk -F'|' '$1=="COMPONENT"{printf "%s%s",(n++?",":""),$2}' "$WORK/tx-installed.txt")
  awk -v MANIFEST="$WORK/tx-installed.txt" -v SELECTED="$tx_installed_components" -v VALIDATE_ONLY=1 -v UPDATER_VERSION="$UPDATER_VERSION" -f "$PLAN_AWK"
}
tx_backup_record() {
  tx_bk_kind=$1 tx_bk_logical=$2 tx_bk_actual=$3
  safe_path "$tx_bk_actual"
  tx_num=$((tx_num + 1))
  if [ -e "$tx_bk_actual" ]; then
    [ -f "$tx_bk_actual" ] || return 1
    tx_bk_sha=$(sha256_of "$tx_bk_actual") tx_bk_bytes=$(wc -c < "$tx_bk_actual" | tr -d ' ') tx_bk_mode=$(mode_of "$tx_bk_actual")
    cp -p "$tx_bk_actual" "$WORK/tx-bundle/backups/$tx_num" || return 1
    tx_verify_file "$WORK/tx-bundle/backups/$tx_num" "$tx_bk_sha" "$tx_bk_bytes" "$tx_bk_mode" || return 1
    printf '%s|%s|present|%s|%s|%s|%s\n' "$tx_bk_kind" "$tx_bk_logical" "$tx_bk_sha" "$tx_bk_bytes" "$tx_bk_mode" "$tx_num"
  else printf '%s|%s|missing|-|0|-|%s\n' "$tx_bk_kind" "$tx_bk_logical" "$tx_num"; fi
}
transaction_apply() (
  tx_active=0 tx_pending_owned=0
  tx_exit() {
    tx_rc=$?
    trap - EXIT HUP INT TERM
    # Сигнал может прийти сразу после mv журнала, до присваивания tx_active.
    # Уже опубликованный журнал принадлежит этой операции только если она
    # создала pending; ранее существующий журнал apply не восстанавливает.
    if [ "$tx_active" = 1 ] || { [ "$tx_pending_owned" = 1 ] && [ -e "$UPDATE_STATE_DIR/transaction.txt" ]; }; then
      tx_exit_stage=$(cat "$UPDATE_STATE_DIR/transaction.txt" 2>/dev/null) || tx_exit_stage=
      if [ "$tx_exit_stage" = COMMIT ]; then tx_commit_started=1; fi
      if transaction_recover; then
        case ${tx_commit_started:-0} in
          1) say 'ERROR: публикация комплекта была прервана; проверенное обновление сохранено' >&2 ;;
          *) say 'ERROR: обновление отменено, прежнее состояние восстановлено' >&2 ;;
        esac
        exit 1
      else
        say 'ERROR: ошибка отката; журнал сохранён, выполните recover' >&2
        exit 2
      fi
    fi
    if [ "$tx_pending_owned" = 1 ]; then
      rm -rf "$UPDATE_STATE_DIR/rollback.pending" || exit 2
    fi
    exit "$tx_rc"
  }
  trap tx_exit EXIT
  trap 'tx_cancel_action_children; exit 1' HUP INT TERM
  safe_path "$UPDATE_STATE_DIR"
  safe_path "$INSTALLED_MANIFEST_PATH"
  [ "$INSTALLED_MANIFEST_PATH" != "$(target_file "$MIHOMO_DIR/config.yaml")" ] || die 'config.yaml не является файлом состояния обновлятора'
  safe_path "$INSTALLED_MANIFEST_PATH.mst-update-new"
  [ ! -e "$INSTALLED_MANIFEST_PATH.mst-update-new" ] || die 'временный путь манифеста занят'
  for tx_name in transaction.txt rollback.pending rollback rollback.previous; do safe_path "$UPDATE_STATE_DIR/$tx_name"; done
  [ ! -e "$UPDATE_STATE_DIR/transaction.txt" ] || die 'сначала восстановите незавершённую транзакцию'
  [ ! -e "$UPDATE_STATE_DIR/rollback.pending" ] && [ ! -e "$UPDATE_STATE_DIR/rollback.previous" ] || die 'оставшийся комплект требует проверки до обновления'
  tx_expected=$plan_id
  build_snapshot
  if [ "${migration_required:-0}" = 1 ]; then check_config_source_snapshot; bind_config_identity; fi
  [ "$plan_id" = "$tx_expected" ] || die 'локальное состояние изменилось; постройте новый план'
  tx_build_installed || die 'несовместимая смесь компонентов'
  while IFS='|' read -r tx_collision_kind tx_collision_cid tx_collision_src tx_collision_dest tx_collision_rest; do
    case $tx_collision_kind in
      FILE) tx_collision_actual=$(target_file "$tx_collision_dest") ;;
      REMOVE) tx_collision_actual=$(target_file "$tx_collision_src") ;;
      *) continue ;;
    esac
    case $INSTALLED_MANIFEST_PATH in
      "$tx_collision_actual"|"$tx_collision_actual.mst-update-new") die 'путь установленного манифеста совпадает с назначением плана' ;;
    esac
    [ "$INSTALLED_MANIFEST_PATH.mst-update-new" != "$tx_collision_actual" ] || die 'временный путь манифеста совпадает с назначением плана'
  done < "$WORK/records"
  mkdir "$WORK/tx-bundle" "$WORK/tx-bundle/backups" "$WORK/tx-bundle/engine" "$WORK/tx-files" || die 'не удалось подготовить транзакцию в RAM'
  tx_context > "$WORK/tx-bundle/context.txt"
  : > "$WORK/tx-bundle/list.txt"
  : > "$WORK/tx-bundle/actions.txt"
  tx_num=0 tx_file=0 tx_changed=0 tx_web=0 tx_space=32768
  while IFS='|' read -r tx_kind tx_cid tx_src tx_dest tx_bytes tx_sha tx_mode tx_check; do
    case $tx_kind in
      FILE)
        tx_logical_path "$tx_dest" || die 'запрещённое назначение'
        tx_file=$((tx_file + 1))
        tx_actual=$(target_file "$tx_dest")
        safe_path "$tx_actual.mst-update-new"
        [ ! -e "$tx_actual.mst-update-new" ] || die 'временный путь назначения занят'
        cp "$saved/files/$tx_file" "$WORK/tx-files/$tx_file" || die 'не удалось подготовить новый файл'
        chmod "$tx_mode" "$WORK/tx-files/$tx_file" || die 'не удалось подготовить режим'
        tx_verify_file "$WORK/tx-files/$tx_file" "$tx_sha" "$tx_bytes" "$tx_mode" || die 'повреждён подготовленный файл'
        check_file_syntax "$WORK/tx-files/$tx_file" "$tx_check"
        if ! tx_verify_file "$tx_actual" "$tx_sha" "$tx_bytes" "$tx_mode"; then
          tx_changed=1
          case $tx_dest in */stats_*|*/render_stats.awk|/opt/etc/init.d/S80speedtest-stats) tx_web=1 ;; esac
        fi
        tx_backup_record FILE "$tx_dest" "$tx_actual" >> "$WORK/tx-bundle/list.txt" || die 'не удалось сохранить старый файл'
        tx_space=$((tx_space + tx_bytes)) ;;
      REMOVE)
        tx_dest=$tx_src
        [ -f "$INSTALLED_MANIFEST_PATH" ] && awk -F'|' -v p="$tx_dest" '$1=="FILE"&&$4==p{known=1}END{exit !known}' "$INSTALLED_MANIFEST_PATH" || die 'нельзя удалять неизвестный файл'
        tx_logical_path "$tx_dest" || die 'запрещённое удаление'
        tx_actual=$(target_file "$tx_dest")
        safe_path "$tx_actual.mst-update-new"
        [ ! -e "$tx_actual.mst-update-new" ] || die 'временный путь удаления занят'
        if [ -e "$tx_actual" ]; then tx_changed=1; case $tx_dest in */stats_*|*/render_stats.awk|/opt/etc/init.d/S80speedtest-stats) tx_web=1 ;; esac; fi
        tx_backup_record FILE "$tx_dest" "$tx_actual" >> "$WORK/tx-bundle/list.txt" || die 'не удалось сохранить удаляемый файл' ;;
      ACTION) case $tx_cid in restart-web) ;; migrate-config|restart-mihomo) [ "${migration_required:-0}" = 1 ] || die 'действие требует миграции' ;; *) die 'неподдерживаемое действие' ;; esac ;;
    esac
  done < "$WORK/records"
  if [ "${migration_required:-0}" = 1 ]; then
    tx_config=$(target_file "$MIHOMO_DIR/config.yaml")
    [ -f "$tx_config" ] && [ ! -L "$tx_config" ] || die 'исходный конфиг отсутствует'
    tx_config_mode=$(mode_of "$tx_config")
    tx_timeout_valid "${UPDATE_ACTION_TIMEOUT:-15}" && tx_timeout_valid "${UPDATE_HEALTH_TIMEOUT:-15}" || die 'неверный таймаут завершающих действий'
    tx_xkeen=${UPDATE_XKEEN_BIN:-$(target_file /opt/sbin/xkeen)}
    safe_path "$tx_xkeen"
    [ -f "$tx_xkeen" ] && [ -x "$tx_xkeen" ] || die 'XKeen недоступен для перезапуска'
    for tx_reserved in "$tx_config" "$UPDATE_STATE_DIR/config-schema-version" "$UPDATE_STATE_DIR/config-sha256"; do
      safe_path "$tx_reserved.mst-update-new"
      [ ! -e "$tx_reserved.mst-update-new" ] || die 'временный путь конфига занят'
    done
    if [ -z "${UPDATE_HEALTH_CMD:-}" ]; then
      tx_health_config "$WORK/config-source.yaml" && tx_health_config "$WORK/candidate.yaml" || die 'неподдерживаемые параметры проверки здоровья'
      rm -f "$WORK/tx-curl-config"
    fi
    tx_backup_record CONFIG active-config "$tx_config" >> "$WORK/tx-bundle/list.txt" || die 'не удалось сохранить конфиг'
    tx_backup_record SCHEMA config-schema-version "$UPDATE_STATE_DIR/config-schema-version" >> "$WORK/tx-bundle/list.txt" || die 'не удалось сохранить схему'
    tx_backup_record HASH config-sha256 "$UPDATE_STATE_DIR/config-sha256" >> "$WORK/tx-bundle/list.txt" || die 'не удалось сохранить сумму'
    printf '%s\n' "$new_schema" > "$WORK/tx-schema"
    sha256_of "$WORK/candidate.yaml" > "$WORK/tx-hash"
    tx_space=$((tx_space + $(wc -c < "$WORK/candidate.yaml") + 128))
    printf 'restart-mihomo\n' > "$WORK/tx-bundle/actions.txt"
  fi
  tx_backup_record STATE installed-manifest "$INSTALLED_MANIFEST_PATH" >> "$WORK/tx-bundle/list.txt" || die 'не удалось сохранить установленный манифест'
  if [ "$tx_web" = 1 ] && grep -q '^ACTION|restart-web$' "$WORK/records"; then
    # Первичная установка службы требует отдельного протокола stop при откате;
    # эта порция обновляет уже установленную службу и не запускает новую.
    tx_old_init=$(target_file /opt/etc/init.d/S80speedtest-stats)
    safe_path "$tx_old_init"
    [ -f "$tx_old_init" ] || die 'первичная установка веб-службы не поддерживается управляемым обновлением'
    printf 'restart-web\n' >> "$WORK/tx-bundle/actions.txt"
  fi
  cp "$MANIFEST_TMP" "$WORK/tx-bundle/engine-manifest.txt" || die 'не удалось сохранить манифест движка'
  for tx_engine in update.sh update_plan.awk update_prepare.sh update_transaction.sh; do
    cp -p "$DIR/$tx_engine" "$WORK/tx-bundle/engine/$tx_engine" || die 'не удалось сохранить движок'
  done
  { sha256_of "$WORK/tx-bundle/list.txt"; sha256_of "$WORK/tx-bundle/context.txt"; sha256_of "$WORK/tx-bundle/engine-manifest.txt"; sha256_of "$WORK/tx-bundle/actions.txt"; } > "$WORK/tx-integrity-input"
  sha256_of "$WORK/tx-integrity-input" > "$WORK/tx-bundle/integrity.txt"
  transaction_validate_bundle "$WORK/tx-bundle" || die 'невалидный комплект восстановления'
  tx_backup_bytes=$(awk -F'|' '$3=="present"{s+=$5}END{printf "%.0f",s}' "$WORK/tx-bundle/list.txt")
  check_space "$(target_file /opt)" "$((tx_space + tx_backup_bytes + 4194304))"
  build_snapshot
  if [ "${migration_required:-0}" = 1 ]; then check_config_source_snapshot; bind_config_identity; fi
  [ "$plan_id" = "$tx_expected" ] || die 'локальное состояние изменилось при подготовке транзакции'
  mkdir -p "$UPDATE_STATE_DIR" || die 'не удалось создать каталог состояния'
  mkdir "$UPDATE_STATE_DIR/rollback.pending" || die 'не удалось создать комплект отката'
  tx_pending_owned=1
  # Метаданные компактны; backup сохраняется hardlink без chmod общего inode.
  cp -pR "$WORK/tx-bundle/engine" "$UPDATE_STATE_DIR/rollback.pending/engine" || die 'не удалось сохранить движок'
  for tx_meta in list.txt context.txt actions.txt engine-manifest.txt integrity.txt; do
    cp "$WORK/tx-bundle/$tx_meta" "$UPDATE_STATE_DIR/rollback.pending/$tx_meta" || die 'не удалось сохранить метаданные отката'
  done
  mkdir "$UPDATE_STATE_DIR/rollback.pending/backups" || die 'не удалось создать backups'
  while IFS='|' read -r tx_kind tx_path tx_presence tx_sha tx_bytes tx_mode tx_num; do
    [ "$tx_presence" = present ] || continue
    tx_actual=$(tx_record_destination "$tx_kind" "$tx_path") || die 'неверное назначение backup'
    ln "$tx_actual" "$UPDATE_STATE_DIR/rollback.pending/backups/$tx_num" 2>/dev/null ||
      cp -p "$WORK/tx-bundle/backups/$tx_num" "$UPDATE_STATE_DIR/rollback.pending/backups/$tx_num" || die 'не удалось сохранить backup'
  done < "$WORK/tx-bundle/list.txt"
  transaction_validate_bundle "$UPDATE_STATE_DIR/rollback.pending" || die 'не удалось проверить постоянный комплект'
  tx_journal APPLY_PENDING || die 'не удалось записать журнал'
  tx_active=1 tx_pending_owned=0
  tx_file=0
  while IFS='|' read -r tx_kind tx_cid tx_src tx_dest tx_bytes tx_sha tx_mode tx_check; do
    case $tx_kind in
      FILE)
        tx_file=$((tx_file + 1)); tx_actual=$(target_file "$tx_dest")
        tx_verify_file "$tx_actual" "$tx_sha" "$tx_bytes" "$tx_mode" && continue
        tx_publish "$WORK/tx-files/$tx_file" "$tx_actual" "$tx_sha" "$tx_bytes" "$tx_mode" || die 'ошибка публикации файла' ;;
      REMOVE) tx_actual=$(target_file "$tx_src"); safe_path "$tx_actual"; rm -f "$tx_actual" || die 'ошибка удаления файла' ;;
    esac
  done < "$WORK/records"
  tx_publish "$WORK/tx-installed.txt" "$INSTALLED_MANIFEST_PATH" "$(sha256_of "$WORK/tx-installed.txt")" "$(wc -c < "$WORK/tx-installed.txt" | tr -d ' ')" 0600 || die 'ошибка публикации установленного манифеста'
  if [ "${migration_required:-0}" = 1 ]; then
    tx_publish "$WORK/candidate.yaml" "$tx_config" "$(sha256_of "$WORK/candidate.yaml")" "$(wc -c < "$WORK/candidate.yaml" | tr -d ' ')" "$tx_config_mode" || die 'ошибка публикации конфига'
    for tx_meta in schema hash; do
      case $tx_meta in schema) tx_dest=$UPDATE_STATE_DIR/config-schema-version ;; hash) tx_dest=$UPDATE_STATE_DIR/config-sha256 ;; esac
      tx_publish "$WORK/tx-$tx_meta" "$tx_dest" "$(sha256_of "$WORK/tx-$tx_meta")" "$(wc -c < "$WORK/tx-$tx_meta" | tr -d ' ')" 0600 || die 'ошибка публикации метаданных конфига'
    done
  fi
  tx_actions "$UPDATE_STATE_DIR/rollback.pending" || die 'ошибка перезапуска или проверки служб'
  tx_journal COMMIT || die 'ошибка фиксации транзакции'
  tx_commit_started=1
  tx_finish_commit || die 'ошибка публикации комплекта отката'
  tx_active=0
)
