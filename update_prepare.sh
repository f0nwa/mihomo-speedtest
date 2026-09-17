#!/bin/sh
# Библиотека update.sh: снимок, загрузка и проверка. Не пишет в /opt.
# Использует WORK, MANIFEST_TMP, PLAN_AWK, SHA_TOOL и функции CLI.

target_file() { printf '%s%s\n' "$TARGET_ROOT" "$1"; }
prepare_init() {
  TARGET_ROOT=${UPDATE_TARGET_ROOT:-}
  if [ -n "$TARGET_ROOT" ]; then
    TARGET_ROOT=$(CDPATH= cd -- "$TARGET_ROOT" && pwd -P) || die 'корень установки недоступен'
    case $TARGET_ROOT in *'|'*|*[[:cntrl:]]*) die 'неверный корень установки' ;; esac
    case $INSTALLED_MANIFEST_PATH in /opt/*) INSTALLED_MANIFEST_PATH=$TARGET_ROOT$INSTALLED_MANIFEST_PATH ;; esac
    case $UPDATE_STATE_DIR in /opt/*) UPDATE_STATE_DIR=$TARGET_ROOT$UPDATE_STATE_DIR ;; esac
  fi
  case $UPDATE_STATE_DIR:$INSTALLED_MANIFEST_PATH in *'|'*|*[[:cntrl:]]*) die 'неверный путь состояния' ;; esac
  PLANS=$TMPROOT/mst-update-plans
  safe_path "$PLANS"
}
lock_plans() {
  mkdir -p "$PLANS" || die 'не удалось создать каталог планов'
  chmod 0700 "$PLANS" || die 'не удалось защитить каталог планов'
  safe_path "$PLANS/.lock"
  if ! mkdir "$PLANS/.lock" 2>/dev/null; then
    lock_pid=$(cat "$PLANS/.lock/pid" 2>/dev/null) || die 'подготовка плана уже выполняется'
    case $lock_pid in *[!0-9]*|''|0) die 'неверная блокировка подготовки' ;; esac
    if kill -0 "$lock_pid" 2>/dev/null; then die 'подготовка плана уже выполняется'; fi
    rm -rf "$PLANS/.lock"
    mkdir "$PLANS/.lock" || die 'подготовка плана уже выполняется'
  fi
  OWN_LOCK=$PLANS/.lock
  printf '%s\n' "$$" > "$OWN_LOCK/pid"
}
validate_plan_id() {
  [ "${#plan_id}" = 64 ] || die 'неверный plan-id'
  case $plan_id in *[!0-9a-f]*) die 'неверный plan-id' ;; esac
}
inspect_file() {
  # $1 фактический путь, $2 стабильная метка снимка. Полный конфиг не выводится.
  safe_path "$1"
  if [ ! -e "$1" ]; then printf '%s|missing\n' "$2"; return; fi
  [ -f "$1" ] || die 'управляемый путь не является обычным файлом'
  inspect_sum=$(sha256_of "$1") || exit 1
  inspect_size=$(wc -c < "$1" | tr -d ' ')
  inspect_mode=$(mode_of "$1") || exit 1
  printf '%s|regular|%s|%s|%s\n' "$2" "$inspect_sum" "$inspect_size" "$inspect_mode"
}
run_parser() {
  awk -v MANIFEST="$MANIFEST_TMP" -v INSTALLED="$installed_arg" \
      -v LOCALSTATE="$WORK/local.tsv" -v SELECTED="$components" \
      -v UPDATER_VERSION="$UPDATER_VERSION" -v FORMAT="$1" \
      -v PLAN_ID="${plan_id:-}" -v PREPARED="${prepared:-0}" -f "$PLAN_AWK"
}
build_snapshot() {
  safe_path "$INSTALLED_MANIFEST_PATH"
  installed_arg=
  if [ -e "$INSTALLED_MANIFEST_PATH" ]; then
    [ -f "$INSTALLED_MANIFEST_PATH" ] || die 'установленный манифест не является файлом'
    awk -v MANIFEST="$INSTALLED_MANIFEST_PATH" -v VALIDATE_ONLY=1 -f "$PLAN_AWK" || die 'невалидный установленный манифест'
    installed_arg=$INSTALLED_MANIFEST_PATH
  fi
  : > "$WORK/local.tsv"
  run_parser records > "$WORK/records"
  : > "$WORK/snapshot.tsv"
  while IFS='|' read -r kind a b c d e f g; do
    case $kind in
      FILE) logical=$c ;;
      REMOVE) logical=$b ;;
      *) continue ;;
    esac
    actual=$(target_file "$logical")
    file_record=$(inspect_file "$actual" "$logical") || exit 1
    printf '%s\n' "$file_record" >> "$WORK/snapshot.tsv"
    file_sum=$(printf '%s\n' "$file_record" | awk -F'|' '$2=="regular"{print $3}')
    if [ -n "$file_sum" ]; then
      file_mode=$(printf '%s\n' "$file_record" | awk -F'|' '{print $5}')
      printf '%s\t%s\t%s\n' "$logical" "$file_sum" "$file_mode" >> "$WORK/local.tsv"
    fi
  done < "$WORK/records"
  inspect_file "$(target_file /opt/etc/mihomo/config.yaml)" config >> "$WORK/snapshot.tsv"
  inspect_file "$INSTALLED_MANIFEST_PATH" installed-manifest >> "$WORK/snapshot.tsv"
  inspect_file "$UPDATE_STATE_DIR/config-schema-version" config-schema >> "$WORK/snapshot.tsv"
  inspect_file "$UPDATE_STATE_DIR/config-sha256" config-sha256 >> "$WORK/snapshot.tsv"
  components=$(awk -F'|' '$1=="COMPONENT"&&$3=="selected"{printf "%s%s",(n++?",":""),$2}' "$WORK/records")
  printf '%s\n' "$components" > "$WORK/request.txt"
  {
    printf 'ENGINE=%s\nMANIFEST=%s\nSOURCE=%s\nROOT=%s\n' "$UPDATER_VERSION" "$(sha256_of "$MANIFEST_TMP")" "$UPDATE_RELEASE_BASE" "$TARGET_ROOT"
    printf 'STATE_PATH=%s\nINSTALLED_PATH=%s\n' "$UPDATE_STATE_DIR" "$INSTALLED_MANIFEST_PATH"
    printf 'RECORDS=%s\nSNAPSHOT=%s\n' "$(sha256_of "$WORK/records")" "$(sha256_of "$WORK/snapshot.tsv")"
  } > "$WORK/identity.txt"
  plan_id=$(sha256_of "$WORK/identity.txt") || exit 1
}
check_schema_release() {
  [ "$(manifest_field "$MANIFEST_TMP" FORMAT_VERSION)" = 2 ] || die 'подготовка требует формат 2'
  new_version=$(manifest_field "$MANIFEST_TMP" RELEASE_VERSION)
  new_schema=$(manifest_field "$MANIFEST_TMP" CONFIG_SCHEMA_VERSION)
  old_schema=1
  if [ -n "$installed_arg" ]; then
    old_version=$(manifest_field "$installed_arg" RELEASE_VERSION)
    old_schema=$(manifest_field "$installed_arg" CONFIG_SCHEMA_VERSION)
    awk -v n="$new_version" -v o="$old_version" 'BEGIN{sub(/^0+/,"",n);sub(/^0+/,"",o);if(length(n)!=length(o)) exit !(length(n)>=length(o));exit !(n "x">=o "x")}' || die 'переход на более старый релиз запрещён'
  fi
  if [ -f "$UPDATE_STATE_DIR/config-schema-version" ]; then
    old_schema=$(cat "$UPDATE_STATE_DIR/config-schema-version")
    case $old_schema in *[!0-9]*|'') die 'неверная установленная версия схемы' ;; esac
  fi
  awk -v n="$new_schema" -v o="$old_schema" 'BEGIN{sub(/^0+/,"",n);sub(/^0+/,"",o);exit !(n "x" == o "x")}' || die 'релиз требует миграции config.yaml - она добавляется в порции 3'
  if awk -F'|' '$1=="ACTION"&&($2=="migrate-config"||$2=="restart-mihomo"){found=1} END{exit !found}' "$WORK/records"; then
    die 'действия рабочего конфига добавляются в порции 3'
  fi
}
check_space() {
  space_path=$1
  while [ ! -d "$space_path" ]; do space_path=${space_path%/*}; [ -n "$space_path" ] || space_path=/; done
  space_info=$(df -Pk "$space_path") || die 'не удалось проверить свободное место'
  printf '%s\n' "$space_info" | awk -v bytes="$2" 'NR==2{if ($4 ~ /^[0-9]+$/ && $4*1024>=bytes) ok=1} END{exit !ok}' || die 'недостаточно свободного места'
}
check_file_syntax() {
  case $2 in
    sh) sh -n "$1" 2>/dev/null || die 'файл не прошёл проверку синтаксиса shell' ;;
    awk) awk_syntax "$1" ;;
    py)
      command -v python3 >/dev/null 2>&1 || die 'проверка Python требует python3'
      python3 -c 'import sys; compile(open(sys.argv[1],"rb").read(),"<release>","exec")' "$1" 2>/dev/null || die 'файл не прошёл проверку синтаксиса Python' ;;
    none) : ;;
    *) die 'неизвестный тип проверки' ;;
  esac
}
file_budget() {
  awk -F'|' '$1=="FILE"{if ($5+0<1 || $5+0>8388608) bad=1; total+=$5} END{if (bad || total>33554432) exit 1; printf "%.0f\n",total}' "$WORK/records" || die 'превышен лимит файлов или набора релиза'
}
prune_plans() {
  now=$(date +%s)
  for entry in "$PLANS"/*; do
    name=${entry##*/}
    [ "${#name}" = 64 ] || continue
    case $name in *[!0-9a-f]*) continue ;; esac
    [ -d "$entry" ] && [ ! -L "$entry" ] && [ -f "$entry/created-at" ] && [ ! -L "$entry/created-at" ] || continue
    created=$(cat "$entry/created-at")
    case $created in *[!0-9]*|'') continue ;; esac
    if [ "$created" -le "$((now - 86400))" ]; then rm -rf "$entry"; fi
  done
}
prepare_files() {
  check_schema_release
  pinned_base
  total=$(file_budget) || exit 1
  old_bytes=$(awk -F'|' '$2=="regular"{sum+=$4} END{printf "%.0f\n",sum}' "$WORK/snapshot.tsv")
  check_space "$TMPROOT" "$((total + 3145728 + 32768))"
  check_space "$(target_file /opt)" "$((total + old_bytes + 32768))"
  lock_plans
  prune_plans
  initial_id=$plan_id
  mkdir "$WORK/files" "$WORK/engine"
  for engine_file in update.sh update_plan.awk update_prepare.sh; do
    cp "$DIR/$engine_file" "$WORK/engine/$engine_file" || die 'не удалось сохранить движок плана'
    case $engine_file in *.sh) chmod 0755 "$WORK/engine/$engine_file" ;; *) chmod 0644 "$WORK/engine/$engine_file" ;; esac
  done
  file_number=0
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    [ "$kind" = FILE ] || continue
    file_number=$((file_number + 1))
    download_to "$PINNED_BASE/$src" "$WORK/files/$file_number" "$bytes"
    check_download "$WORK/files/$file_number" "$bytes" "$sum"
    check_file_syntax "$WORK/files/$file_number" "$check"
    chmod "$mode" "$WORK/files/$file_number" || die 'не удалось задать режим файла'
    [ "$(mode_of "$WORK/files/$file_number")" = "${mode#0}" ] || die 'неверный режим подготовленного файла'
  done < "$WORK/records"
  # После загрузки не должен сохраниться план уже изменившегося состояния.
  build_snapshot
  [ "$plan_id" = "$initial_id" ] || die 'локальное состояние изменилось при подготовке; постройте новый план'
  printf '%s\n' "$(date +%s)" > "$WORK/created-at"
  safe_path "$PLANS/$plan_id"
  if [ -e "$PLANS/$plan_id" ]; then
    [ -d "$PLANS/$plan_id" ] || die 'путь плана занят файлом'
    rm -rf "$PLANS/$plan_id"
  fi
  mv "$WORK" "$PLANS/$plan_id" || die 'не удалось сохранить подготовленный план'
  WORK=$PLANS/$plan_id
  MANIFEST_TMP=$WORK/manifest.txt
  KEEP_WORK=1
  prepared=1
}
print_plan() { run_parser "$format"; }
discard_plan() {
  validate_plan_id
  safe_path "$PLANS/$plan_id"
  lock_plans
  rm -rf "$PLANS/$plan_id"
  say 'Подготовленный план удалён из /tmp'
}
verify_plan() {
  validate_plan_id
  expected_id=$plan_id
  saved=$PLANS/$plan_id
  safe_path "$saved"
  [ -d "$saved" ] || die 'подготовленный план не найден'
  lock_plans
  for saved_file in identity.txt manifest.txt request.txt created-at; do
    safe_path "$saved/$saved_file"
    [ -f "$saved/$saved_file" ] || die 'неполный подготовленный план'
  done
  [ "$(sha256_of "$saved/identity.txt")" = "$expected_id" ] || die 'повреждён идентификатор плана'
  stored_manifest=$(manifest_field "$saved/identity.txt" MANIFEST)
  [ "$(sha256_of "$saved/manifest.txt")" = "$stored_manifest" ] || die 'повреждён манифест плана'
  created=$(cat "$saved/created-at")
  case $created in *[!0-9]*|'') die 'неверный срок плана' ;; esac
  now=$(date +%s)
  [ "$created" -le "$now" ] && [ "$created" -gt "$((now - 86400))" ] || die 'срок подготовленного плана истёк'
  download_to "$UPDATE_RELEASE_BASE/manifest.txt" "$MANIFEST_TMP" 262144
  [ "$(sha256_of "$MANIFEST_TMP")" = "$stored_manifest" ] || die 'релиз изменился; постройте новый план'
  components=$(cat "$saved/request.txt")
  awk -v MANIFEST="$MANIFEST_TMP" -v VALIDATE_ONLY=1 -v SELECTED="$components" -v UPDATER_VERSION="$UPDATER_VERSION" -f "$PLAN_AWK"
  build_snapshot
  [ "$plan_id" = "$expected_id" ] || die 'локальное состояние изменилось; постройте новый план'
  check_schema_release
  total=$(file_budget) || exit 1
  file_number=0
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    [ "$kind" = FILE ] || continue
    file_number=$((file_number + 1))
    safe_path "$saved/files/$file_number"
    [ -f "$saved/files/$file_number" ] || die 'неполный набор файлов'
    check_download "$saved/files/$file_number" "$bytes" "$sum"
    [ "$(mode_of "$saved/files/$file_number")" = "${mode#0}" ] || die 'изменён режим подготовленного файла'
    check_file_syntax "$saved/files/$file_number" "$check"
  done < "$WORK/records"
  bootstrap_header
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    safe_path "$saved/engine/$src"
    [ -f "$saved/engine/$src" ] || die 'неполный движок плана'
    check_download "$saved/engine/$src" "$bytes" "$sum"
    [ "$(mode_of "$saved/engine/$src")" = "${mode#0}" ] || die 'изменён режим движка плана'
  done < "$WORK/bootstrap-files"
  overwrite=$(run_parser json | awk '/"overwrite_required":true/{print "yes"}')
  if [ -n "$overwrite" ] && [ "$confirm_local" != 1 ]; then die 'локальные изменения требуют отдельного подтверждения --confirm-local'; fi
  prepared=1
  print_plan
}
