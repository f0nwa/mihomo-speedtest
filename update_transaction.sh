#!/bin/sh
# Библиотека update.sh. Вызывается под общей блокировкой после verify_plan.
# WORK и saved находятся в RAM. Журнал содержит только фиксированную стадию,
# никогда не исполняется. COMMIT означает проверенное новое состояние;
# восстановление завершает публикацию комплекта, остальные стадии откатываются.
# Возврат 1: ошибка обновления; 2: восстановление требует вмешательства.

tx_logical_path() {
  case $1 in
    /opt/etc/init.d/S80speedtest-stats) ;;
    /opt/etc/mihomo/*)
      case $1 in /opt/etc/mihomo/config.yaml|/opt/etc/mihomo/.update|/opt/etc/mihomo/.update/*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  case $1 in *'|'*|*[[:cntrl:]]*|*//*|*/../*|*/./*|*/..|*/.) return 1 ;; esac
  safe_path "$(target_file "$1")"
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
  [ "$INSTALLED_MANIFEST_PATH" != "$(target_file /opt/etc/mihomo/config.yaml)" ] || exit 1
  tx_context > "$WORK/tx-context-check"
  cmp -s "$WORK/tx-context-check" "$tx_bundle/context.txt" || exit 1
  tx_integrity=$(cat "$tx_bundle/integrity.txt")
  [ "${#tx_integrity}" = 64 ] || exit 1
  { sha256_of "$tx_bundle/list.txt"; sha256_of "$tx_bundle/context.txt"; sha256_of "$tx_bundle/engine-manifest.txt"; sha256_of "$tx_bundle/actions.txt"; } > "$WORK/tx-integrity-check"
  [ "$(sha256_of "$WORK/tx-integrity-check")" = "$tx_integrity" ] || exit 1
  awk -F'|' '
    NF!=7 || ($1!="FILE" && $1!="STATE") {exit 1}
    seen[$1 SUBSEP $2]++ {exit 1}
    $1=="STATE" {if($2!="installed-manifest" || state++) exit 1}
    $3!="present" && $3!="missing" {exit 1}
    $7 !~ /^[1-9][0-9]*$/ || number[$7]++ {exit 1}
    $3=="present" && (length($4)!=64 || $4 !~ /^[0-9a-f]+$/ || $5 !~ /^[0-9]+$/ || $6 !~ /^[0-7]+$/ || length($6)<1 || length($6)>4) {exit 1}
    $3=="missing" && ($4!="-" || $5!="0" || $6!="-") {exit 1}
    END {if(state!=1) exit 1}' "$tx_bundle/list.txt" || exit 1
  while IFS='|' read -r tx_kind tx_path tx_presence tx_sha tx_bytes tx_mode tx_num; do
    case $tx_kind in
      FILE)
        tx_logical_path "$tx_path" || exit 1
        tx_validate_actual=$(target_file "$tx_path")
        case $INSTALLED_MANIFEST_PATH in "$tx_validate_actual"|"$tx_validate_actual.mst-update-new") exit 1 ;; esac
        [ "$INSTALLED_MANIFEST_PATH.mst-update-new" != "$tx_validate_actual" ] || exit 1 ;;
      STATE) safe_path "$INSTALLED_MANIFEST_PATH" ;;
    esac
    if [ "$tx_presence" = present ]; then
      tx_verify_file "$tx_bundle/backups/$tx_num" "$tx_sha" "$tx_bytes" "$tx_mode" || exit 1
    fi
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
  case $(cat "$tx_bundle/actions.txt") in ''|restart-web) ;; *) exit 1 ;; esac
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
  tx_timeout=${UPDATE_ACTION_TIMEOUT:-15}
  case $tx_timeout in *[!0-9]*|''|0) exit 1 ;; esac
  [ "$tx_timeout" -le 300 ] || exit 1
  tx_init=$(target_file /opt/etc/init.d/S80speedtest-stats)
  safe_path "$tx_init"
  [ -f "$tx_init" ] || exit 1
  tx_action_log=$WORK/tx-action-$$.log
  safe_path "$tx_action_log"
  # Потомки init не удерживают SSH/stdout после таймаута. Вывод ограничен
  # ulimit и остаётся только в RAM; журнал может содержать данные службы.
  tx_mihomo=$(target_file /opt/etc/mihomo)
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
  ( ulimit -f 64
    DIR="$tx_mihomo" SERVICE="$tx_mihomo/stats_service.sh" ENV="$tx_mihomo/speedtest2.env" \
      STATS_SERVICE_RUNTIME_DIR="$tx_runtime" SUPERVISOR_PIDFILE="$tx_supervisor" \
      STATS_HTTP_PIDFILE="$tx_http_pid" exec sh "$tx_init" "$1"
  ) > "$tx_action_log" 2>&1 &
  tx_child=$!
  # POSIX watchdog; не требует timeout из GNU coreutils.
  ( sleep "$tx_timeout"; kill -TERM "$tx_child" 2>/dev/null; sleep 1; kill -KILL "$tx_child" 2>/dev/null ) > /dev/null 2>&1 &
  tx_watch=$!
  trap 'kill "$tx_child" "$tx_watch" 2>/dev/null || :; wait "$tx_child" 2>/dev/null || :' HUP INT TERM
  tx_rc=0
  wait "$tx_child" || tx_rc=$?
  kill "$tx_watch" 2>/dev/null || :
  wait "$tx_watch" 2>/dev/null || :
  rm -f "$tx_action_log"
  exit "$tx_rc"
)
tx_actions() {
  [ -s "$1/actions.txt" ] || return 0
  tx_bounded_action restart && tx_bounded_action check
}
tx_restore() (
  tx_bundle=$1
  transaction_validate_bundle "$tx_bundle" || exit 2
  tx_failed=0
  while IFS='|' read -r tx_kind tx_path tx_presence tx_sha tx_bytes tx_mode tx_num; do
    if [ "$tx_kind" = STATE ]; then tx_dest=$INSTALLED_MANIFEST_PATH
    else tx_dest=$(target_file "$tx_path"); fi
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
  trap 'exit 1' HUP INT TERM
  safe_path "$UPDATE_STATE_DIR"
  safe_path "$INSTALLED_MANIFEST_PATH"
  [ "$INSTALLED_MANIFEST_PATH" != "$(target_file /opt/etc/mihomo/config.yaml)" ] || die 'config.yaml не является файлом состояния обновлятора'
  safe_path "$INSTALLED_MANIFEST_PATH.mst-update-new"
  [ ! -e "$INSTALLED_MANIFEST_PATH.mst-update-new" ] || die 'временный путь манифеста занят'
  for tx_name in transaction.txt rollback.pending rollback rollback.previous; do safe_path "$UPDATE_STATE_DIR/$tx_name"; done
  [ ! -e "$UPDATE_STATE_DIR/transaction.txt" ] || die 'сначала восстановите незавершённую транзакцию'
  [ ! -e "$UPDATE_STATE_DIR/rollback.pending" ] && [ ! -e "$UPDATE_STATE_DIR/rollback.previous" ] || die 'оставшийся комплект требует проверки до обновления'
  tx_expected=$plan_id
  build_snapshot
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
      ACTION) [ "$tx_cid" = restart-web ] || die 'неподдерживаемое действие' ;;
    esac
  done < "$WORK/records"
  tx_backup_record STATE installed-manifest "$INSTALLED_MANIFEST_PATH" >> "$WORK/tx-bundle/list.txt" || die 'не удалось сохранить установленный манифест'
  if [ "$tx_web" = 1 ] && grep -q '^ACTION|restart-web$' "$WORK/records"; then
    # Первичная установка службы требует отдельного протокола stop при откате;
    # эта порция обновляет уже установленную службу и не запускает новую.
    tx_old_init=$(target_file /opt/etc/init.d/S80speedtest-stats)
    safe_path "$tx_old_init"
    [ -f "$tx_old_init" ] || die 'первичная установка веб-службы не поддерживается управляемым обновлением'
    printf 'restart-web\n' > "$WORK/tx-bundle/actions.txt"
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
    if [ "$tx_kind" = STATE ]; then tx_actual=$INSTALLED_MANIFEST_PATH; else tx_actual=$(target_file "$tx_path"); fi
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
  tx_actions "$UPDATE_STATE_DIR/rollback.pending" || die 'ошибка перезапуска или проверки веб-службы'
  tx_publish "$WORK/tx-installed.txt" "$INSTALLED_MANIFEST_PATH" "$(sha256_of "$WORK/tx-installed.txt")" "$(wc -c < "$WORK/tx-installed.txt" | tr -d ' ')" 0600 || die 'ошибка публикации установленного манифеста'
  tx_journal COMMIT || die 'ошибка фиксации транзакции'
  tx_commit_started=1
  tx_finish_commit || die 'ошибка публикации комплекта отката'
  tx_active=0
)
