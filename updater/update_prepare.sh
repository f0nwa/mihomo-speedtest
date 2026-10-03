#!/bin/sh
# Библиотека update.sh: снимок, загрузка и проверка. Не пишет в /opt.
# Использует WORK, MANIFEST_TMP, PLAN_AWK, SHA_TOOL и функции CLI.

target_file() { printf '%s%s\n' "$TARGET_ROOT" "$1"; }
# config_path - фактический файл рабочего конфига Mihomo. Обычно это сам
# $MIHOMO_DIR/config.yaml. Сторонние панели (XKeen UI) держат профили в
# $MIHOMO_DIR/profiles/*.yaml и переключают активный символической ссылкой
# config.yaml -> profiles/<имя>.yaml - тогда возвращается цель ссылки, чтобы
# снимок, резервная копия, миграция и откат работали с файлом профиля, а сама
# ссылка оставалась нетронутой. Допускается ровно одна ссылка (сам
# config.yaml) и только на обычный файл внутри $MIHOMO_DIR без "..", "." и
# других ссылок на пути (safe_path); всё остальное - отказ, как и раньше.
config_path() {
  cfg_dir=$(target_file "$MIHOMO_DIR")
  cfg_link=$cfg_dir/config.yaml
  safe_path "$cfg_dir"
  if [ ! -L "$cfg_link" ]; then printf '%s\n' "$cfg_link"; return 0; fi
  cfg_to=$(readlink "$cfg_link") || die 'Не удалось прочитать ссылку config.yaml'
  case $cfg_to in
    "$cfg_dir"/*) cfg_real=$cfg_to ;;
    "$MIHOMO_DIR"/*) cfg_real=$(target_file "$cfg_to") ;;
    /*|'') die "config.yaml ссылается за пределы $MIHOMO_DIR: $cfg_to" ;;
    *) cfg_real=$cfg_dir/$cfg_to ;;
  esac
  case ${cfg_real#"$cfg_dir"/} in
    ''|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*|*'|'*|*[[:cntrl:]]*|*.mst-update-new)
      die "Недопустимая цель ссылки config.yaml: $cfg_to" ;;
  esac
  [ "$cfg_real" != "$cfg_link" ] || die "Недопустимая цель ссылки config.yaml: $cfg_to"
  safe_path "$cfg_real"
  [ -f "$cfg_real" ] || die "Ссылка config.yaml указывает на отсутствующий файл: $cfg_to"
  printf '%s\n' "$cfg_real"
}
prepare_init() {
  TARGET_ROOT=${UPDATE_TARGET_ROOT:-}
  if [ -n "$TARGET_ROOT" ]; then
    TARGET_ROOT=$(CDPATH= cd -- "$TARGET_ROOT" && pwd -P) || die 'Корень установки недоступен'
    case $TARGET_ROOT in *'|'*|*[[:cntrl:]]*) die 'Неверный корень установки' ;; esac
    case $INSTALLED_MANIFEST_PATH in /opt/*) INSTALLED_MANIFEST_PATH=$TARGET_ROOT$INSTALLED_MANIFEST_PATH ;; esac
    case $UPDATE_STATE_DIR in /opt/*) UPDATE_STATE_DIR=$TARGET_ROOT$UPDATE_STATE_DIR ;; esac
  fi
  case $UPDATE_STATE_DIR:$INSTALLED_MANIFEST_PATH in *'|'*|*[[:cntrl:]]*) die 'Неверный путь состояния' ;; esac
  PLANS=$TMPROOT/mst-update-plans
  safe_path "$PLANS"
}
assert_no_transaction() {
  safe_path "$UPDATE_STATE_DIR/transaction.txt"
  [ ! -e "$UPDATE_STATE_DIR/transaction.txt" ] || die 'Незавершённая транзакция; выполните --recover'
}
validate_plan_id() {
  [ "${#plan_id}" = 64 ] || die 'Неверный plan-id'
  case $plan_id in *[!0-9a-f]*) die 'Неверный plan-id' ;; esac
}
inspect_file() {
  # $1 фактический путь, $2 стабильная метка снимка. Полный конфиг не выводится.
  safe_path "$1"
  if [ ! -e "$1" ]; then printf '%s|missing\n' "$2"; return; fi
  [ -f "$1" ] || die 'Управляемый путь не является обычным файлом'
  inspect_sum=$(sha256_of "$1") || exit 1
  inspect_size=$(wc -c < "$1" | tr -d ' ')
  inspect_mode=$(mode_of "$1") || exit 1
  printf '%s|regular|%s|%s|%s\n' "$2" "$inspect_sum" "$inspect_size" "$inspect_mode"
}
run_parser() {
  awk -v MANIFEST="$MANIFEST_TMP" -v INSTALLED="$installed_arg" \
      -v LOCALSTATE="$WORK/local.tsv" -v SELECTED="$components" \
      -v UPDATER_VERSION="$UPDATER_VERSION" -v FORMAT="$1" \
      -v MIGRATE_CONFIG="${migration_required:-0}" -v OLD_SCHEMA="${old_schema:-1}" \
      -v CONFIG_CONFIRM="${config_confirm_required:-0}" -v CONFIG_HASH="${config_candidate_hash:-}" \
      -v PLAN_ID="${plan_id:-}" -v PREPARED="${prepared:-0}" -f "$PLAN_AWK"
}
build_snapshot() {
  safe_path "$INSTALLED_MANIFEST_PATH"
  installed_arg=
  if [ -e "$INSTALLED_MANIFEST_PATH" ]; then
    [ -f "$INSTALLED_MANIFEST_PATH" ] || die 'Установленный манифест не является файлом'
    awk -v MANIFEST="$INSTALLED_MANIFEST_PATH" -v VALIDATE_ONLY=1 -f "$PLAN_AWK" || die 'Невалидный установленный манифест'
    installed_arg=$INSTALLED_MANIFEST_PATH
  fi
  detect_config_schema
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
  config_actual=$(config_path) || exit 1
  inspect_file "$config_actual" config >> "$WORK/snapshot.tsv"
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
check_release_not_older() {
  # Отказ, если RELEASE_VERSION манифеста меньше установленного (например,
  # после переключения dev -> stable при установленной сборке dev). Общая
  # проверка для --plan (update.sh) и подготовки (check_schema_release);
  # без отслеживаемого установленного манифеста ничего не проверяет.
  [ -n "$installed_arg" ] || return 0
  awk -v n="$(manifest_field "$MANIFEST_TMP" RELEASE_VERSION)" -v o="$(manifest_field "$installed_arg" RELEASE_VERSION)" 'BEGIN{sub(/^0+/,"",n);sub(/^0+/,"",o);if(length(n)!=length(o)) exit !(length(n)>=length(o));exit !(n "x">=o "x")}' || die 'Установлена версия новее, чем последняя в выбранном канале обновлений; обновление появится со следующим релизом'
}
check_schema_release() {
  [ "$(manifest_field "$MANIFEST_TMP" FORMAT_VERSION)" = 2 ] || die 'Подготовка требует формат 2'
  new_schema=$(manifest_field "$MANIFEST_TMP" CONFIG_SCHEMA_VERSION)
  old_schema=1
  if [ -n "$installed_arg" ]; then
    old_schema=$(manifest_field "$installed_arg" CONFIG_SCHEMA_VERSION)
    check_release_not_older
  fi
  if [ -f "$UPDATE_STATE_DIR/config-schema-version" ]; then
    old_schema=$(cat "$UPDATE_STATE_DIR/config-schema-version")
    case $old_schema in *[!0-9]*|'') die 'Неверная установленная версия схемы' ;; esac
  fi
  if [ "$migration_required" != 1 ] && awk -F'|' '$1=="ACTION"&&($2=="migrate-config"||$2=="restart-mihomo"){found=1} END{exit !found}' "$WORK/records"; then
    die 'Действия рабочего конфига требуют повышения схемы'
  fi
}
check_space() {
  space_path=$1
  while [ ! -d "$space_path" ]; do space_path=${space_path%/*}; [ -n "$space_path" ] || space_path=/; done
  space_info=$(df -Pk "$space_path") || die 'Не удалось проверить свободное место'
  printf '%s\n' "$space_info" | awk -v bytes="$2" 'NR==2{if ($4 ~ /^[0-9]+$/ && $4*1024>=bytes) ok=1} END{exit !ok}' || die 'Недостаточно свободного места'
}
check_file_syntax() {
  case $2 in
    sh) sh -n "$1" 2>/dev/null || die 'Файл не прошёл проверку синтаксиса shell' ;;
    awk) awk_syntax "$1" ;;
    py)
      command -v python3 >/dev/null 2>&1 || die 'Проверка Python требует python3'
      python3 -c 'import sys; compile(open(sys.argv[1],"rb").read(),"<release>","exec")' "$1" 2>/dev/null || die 'Файл не прошёл проверку синтаксиса Python' ;;
    none) : ;;
    *) die 'Неизвестный тип проверки' ;;
  esac
}
file_budget() {
  awk -F'|' '$1=="FILE"{if ($5+0<1 || $5+0>8388608) bad=1; total+=$5} END{if (bad || total>33554432) exit 1; printf "%.0f\n",total}' "$WORK/records" || die 'Превышен лимит файлов или набора релиза'
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
  check_space "$TMPROOT" "$((total + 8388608 + 32768))"
  check_space "$(target_file /opt)" "$((total + old_bytes + 32768))"
  lock_plans
  assert_no_transaction
  prune_plans
  initial_id=$plan_id
  mkdir "$WORK/files" "$WORK/engine"
  for engine_file in update.sh update_plan.awk update_prepare.sh update_transaction.sh; do
    cp "$DIR/$engine_file" "$WORK/engine/$engine_file" || die 'Не удалось сохранить движок плана'
    case $engine_file in *.sh) chmod 0755 "$WORK/engine/$engine_file" ;; *) chmod 0644 "$WORK/engine/$engine_file" ;; esac
  done
  file_number=0
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    [ "$kind" = FILE ] || continue
    file_number=$((file_number + 1))
    # Построчный прогресс для мини консоли раздела /updates (job.log,
    # см. stats_update.sh) - пункт фидбека по макету "Панель управления":
    # раньше на весь prepare был один общий чекпоинт, не видно, что
    # реально скачивается.
    echo "Загрузка файла: $dest" >&2
    download_to "$PINNED_BASE/$src" "$WORK/files/$file_number" "$bytes"
    check_download "$WORK/files/$file_number" "$bytes" "$sum"
    check_file_syntax "$WORK/files/$file_number" "$check"
    chmod "$mode" "$WORK/files/$file_number" || die 'Не удалось задать режим файла'
    [ "$(mode_of "$WORK/files/$file_number")" = "${mode#0}" ] || die 'Неверный режим подготовленного файла'
  done < "$WORK/records"
  # После загрузки не должен сохраниться план уже изменившегося состояния.
  build_snapshot
  [ "$plan_id" = "$initial_id" ] || die 'Локальное состояние изменилось при подготовке; запустите обновление заново'
  if [ "$migration_required" = 1 ]; then
    prepare_config_candidate
    build_snapshot
    [ "$plan_id" = "$initial_id" ] || die 'Локальное состояние изменилось при проверке конфига'
    config_confirm_required=$(manifest_field "$WORK/config-info.txt" CONFIRM)
    bind_config_identity
  fi
  printf '%s\n' "$(date +%s)" > "$WORK/created-at"
  safe_path "$PLANS/$plan_id"
  if [ -e "$PLANS/$plan_id" ]; then
    [ -d "$PLANS/$plan_id" ] || die 'Путь плана занят файлом'
    rm -rf "$PLANS/$plan_id"
  fi
  mv "$WORK" "$PLANS/$plan_id" || die 'Не удалось сохранить подготовленный план'
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
  say 'Скачанное обновление удалено из /tmp'
}
verify_plan() {
  validate_plan_id
  expected_id=$plan_id
  saved=$PLANS/$plan_id
  safe_path "$saved"
  [ -d "$saved" ] || die 'Скачанное обновление не найдено; запустите обновление заново'
  lock_plans
  if [ "$cmd" = apply ]; then assert_no_transaction; fi
  for saved_file in identity.txt manifest.txt request.txt created-at; do
    safe_path "$saved/$saved_file"
    [ -f "$saved/$saved_file" ] || die 'Неполный подготовленный план'
  done
  [ "$(sha256_of "$saved/identity.txt")" = "$expected_id" ] || die 'Повреждён идентификатор плана'
  stored_manifest=$(manifest_field "$saved/identity.txt" MANIFEST)
  [ "$(sha256_of "$saved/manifest.txt")" = "$stored_manifest" ] || die 'Повреждён манифест плана'
  created=$(cat "$saved/created-at")
  case $created in *[!0-9]*|'') die 'Неверный срок плана' ;; esac
  now=$(date +%s)
  [ "$created" -le "$now" ] && [ "$created" -gt "$((now - 86400))" ] || die 'Скачанное обновление устарело (старше суток); запустите обновление заново'
  download_to "$UPDATE_RELEASE_BASE/manifest.txt" "$MANIFEST_TMP" 262144
  [ "$(sha256_of "$MANIFEST_TMP")" = "$stored_manifest" ] || die 'Релиз изменился; запустите обновление заново'
  components=$(cat "$saved/request.txt")
  awk -v MANIFEST="$MANIFEST_TMP" -v VALIDATE_ONLY=1 -v SELECTED="$components" -v UPDATER_VERSION="$UPDATER_VERSION" -f "$PLAN_AWK"
  build_snapshot
  if [ "$migration_required" != 1 ]; then
    [ "$plan_id" = "$expected_id" ] || die 'Локальное состояние изменилось; запустите обновление заново'
  fi
  check_schema_release
  total=$(file_budget) || exit 1
  file_number=0
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    [ "$kind" = FILE ] || continue
    file_number=$((file_number + 1))
    safe_path "$saved/files/$file_number"
    [ -f "$saved/files/$file_number" ] || die 'Неполный набор файлов'
    check_download "$saved/files/$file_number" "$bytes" "$sum"
    [ "$(mode_of "$saved/files/$file_number")" = "${mode#0}" ] || die 'Изменён режим подготовленного файла'
    check_file_syntax "$saved/files/$file_number" "$check"
  done < "$WORK/records"
  bootstrap_header
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    safe_path "$saved/engine/$src"
    [ -f "$saved/engine/$src" ] || die 'Неполный движок плана'
    check_download "$saved/engine/$src" "$bytes" "$sum"
    [ "$(mode_of "$saved/engine/$src")" = "${mode#0}" ] || die 'Изменён режим движка плана'
  done < "$WORK/bootstrap-files"
  if [ "$migration_required" = 1 ]; then verify_config_candidate; fi
  [ "$plan_id" = "$expected_id" ] || die 'Локальное состояние изменилось; запустите обновление заново'
  overwrite=$(run_parser json | awk '/"overwrite_required":true/{print "yes"}')
  if [ -n "$overwrite" ] && [ "$confirm_local" != 1 ] && [ "$cmd" != show-config-diff ]; then die 'Локальные изменения требуют отдельного подтверждения --confirm-local'; fi
  prepared=1
  if [ "$cmd" != apply ] && [ "$cmd" != show-config-diff ]; then print_plan; fi
}

# 3.2: кандидат конфига остаётся только частью проверяемого RAM-плана.
detect_config_schema() {
  new_schema=$(manifest_field "$MANIFEST_TMP" CONFIG_SCHEMA_VERSION)
  old_schema=1
  [ -z "$installed_arg" ] || old_schema=$(manifest_field "$installed_arg" CONFIG_SCHEMA_VERSION)
  safe_path "$UPDATE_STATE_DIR/config-schema-version"
  if [ -f "$UPDATE_STATE_DIR/config-schema-version" ]; then old_schema=$(cat "$UPDATE_STATE_DIR/config-schema-version"); fi
  case $old_schema:$new_schema in *[!0-9:]*|:*|*:) die 'Неверная версия схемы конфига' ;; esac
  schema_relation=$(awk -v n="$new_schema" -v o="$old_schema" 'BEGIN{sub(/^0+/,"",n);sub(/^0+/,"",o);if(length(n)!=length(o)) print (length(n)>length(o)?"upgrade":"downgrade");else print (n "x"==o "x"?"same":(n "x">o "x"?"upgrade":"downgrade"))}')
  [ "$schema_relation" != downgrade ] || die 'Понижение схемы конфига запрещено'
  migration_required=0
  config_confirm_required=0
  if [ "$schema_relation" = upgrade ]; then migration_required=1; config_confirm_required=1; fi
}
config_tools() {
  mkdir "$WORK/migration-tools" || die 'Не удалось подготовить инструменты миграции'
  for config_tool in migrate_config.sh migrate_config.awk config_diff.awk config.example.yaml; do
    config_number=$(awk -F'|' -v name="$config_tool" '$1=="FILE"{n++;if($2=="config-tools"&&$3==name&&$4=="/opt/etc/mihomo-speedtest/" name) {number=n;count++}} END{if(count!=1)exit 1;print number}' "$WORK/records") || die 'Релиз не содержит обязательный инструмент миграции'
    safe_path "$CONFIG_PAYLOAD/files/$config_number"
    cp "$CONFIG_PAYLOAD/files/$config_number" "$WORK/migration-tools/$config_tool" || die 'Не удалось скопировать проверенный инструмент'
  done
}
run_config_test() {
  config_binary=${UPDATE_MIHOMO_BIN:-$(target_file /opt/sbin/mihomo)}
  [ -x "$config_binary" ] || die 'Не найден исполняемый Mihomo для проверки конфига'
  config_timeout=${UPDATE_CONFIG_TEST_TIMEOUT:-30}
  case $config_timeout in *[!0-9]*|'') die 'Неверный таймаут проверки конфига' ;; esac
  [ "$config_timeout" -ge 1 ] && [ "$config_timeout" -le 120 ] || die 'Таймаут проверки конфига должен быть 1-120 секунд'
  mkdir "$WORK/mihomo-test" || die 'Не удалось создать RAM-каталог проверки'
  # Для GEO-правил нужны существующие базы. В RAM копируем ограниченный набор,
  # никогда не даём тестовому процессу путь записи в /opt.
  geo_total=0
  for geo_name in GeoSite.dat GeoIP.dat Country.mmdb geoip.metadb geoip.db ASN.mmdb BundleMRS.7z; do
    geo_source=$(target_file "$MIHOMO_DIR")/$geo_name
    safe_path "$geo_source"
    [ -f "$geo_source" ] || continue
    geo_bytes=$(wc -c < "$geo_source" | tr -d ' ')
    geo_total=$((geo_total + geo_bytes))
    [ "$geo_bytes" -le 33554432 ] && [ "$geo_total" -le 67108864 ] || die 'Базы GEO превышают RAM-лимит проверки'
    check_space "$TMPROOT" "$((geo_bytes + 8388608))"
    cp "$geo_source" "$WORK/mihomo-test/$geo_name" || die 'Не удалось скопировать базу GEO в RAM'
  done
  config_before_test=$(sha256_of "$WORK/candidate.yaml")
  (
    unset SAFE_PATHS SKIP_SAFE_PATH_CHECK CLASH_CONFIG_STRING CLASH_CONFIG_FILE CLASH_HOME_DIR CLASH_AGE_SECRET_KEY CLASH_POST_UP CLASH_POST_DOWN
    cd "$WORK/mihomo-test" || exit 1
    ulimit -f 4096
    exec "$config_binary" -t -d "$WORK/mihomo-test" -f "$WORK/candidate.yaml"
  ) > "$WORK/mihomo-test.log" 2>&1 &
  CONFIG_CHECK_PID=$!
  (sleep "$config_timeout"; if kill -0 "$CONFIG_CHECK_PID" 2>/dev/null; then touch "$WORK/config-test-timeout"; kill -KILL "$CONFIG_CHECK_PID" 2>/dev/null || :; fi) >/dev/null 2>&1 &
  CONFIG_WATCHDOG_PID=$!
  config_status=0
  wait "$CONFIG_CHECK_PID" || config_status=$?
  CONFIG_CHECK_PID=
  kill "$CONFIG_WATCHDOG_PID" 2>/dev/null || :
  wait "$CONFIG_WATCHDOG_PID" 2>/dev/null || :
  CONFIG_WATCHDOG_PID=
  rm -rf "$WORK/mihomo-test" || die 'Не удалось очистить RAM-каталог проверки'
  [ "$config_before_test" = "$(sha256_of "$WORK/candidate.yaml")" ] || die 'Кандидат изменился во время mihomo -t'
  [ "$config_status" = 0 ] && [ ! -e "$WORK/config-test-timeout" ] || die 'Кандидат не прошёл mihomo -t или истёк таймаут; подробный вывод скрыт для защиты секретов'
}
check_config_source_snapshot() {
  config_snapshot_hash=$(awk -F'|' '$1=="config"&&$2=="regular"{print $3}' "$WORK/snapshot.tsv")
  [ -n "$config_snapshot_hash" ] && [ "$config_snapshot_hash" = "$(sha256_of "$WORK/config-source.yaml")" ] || die 'Копия исходного конфига не соответствует снимку плана'
}
# Служебный вход mst-speedtest (замер WireGuard/AmneziaWG через основное ядро,
# см. config.example.yaml). Если миграция добавляет его впервые, порт 7896
# должен быть свободен: иначе mihomo после перезапуска не поднимет вход.
# Вход уже был в исходном конфиге - порт держит само ядро, это не конфликт.
check_service_listener_port() {
  grep -q '^  - name: mst-speedtest$' "$WORK/config-source.yaml" && return 0
  grep -q '^  - name: mst-speedtest$' "$WORK/candidate.yaml" || return 0
  if ! command -v netstat >/dev/null 2>&1; then
    say 'WARN: Нет netstat - не проверить, свободен ли порт 7896 служебного входа mst-speedtest' >&2
    return 0
  fi
  if netstat -ltnu 2>/dev/null | awk '$4 ~ /[:.]7896$/ {busy=1} END {exit !busy}'; then
    die 'Порт 7896 для служебного входа mst-speedtest (замер WireGuard/AmneziaWG) уже занят другой программой; освободите его и повторите'
  fi
}
prepare_config_candidate() {
  CONFIG_PAYLOAD=$WORK
  config_tools
  config_actual=$(config_path) || exit 1
  cp "$config_actual" "$WORK/config-source.yaml" || die 'Не удалось прочитать рабочий конфиг'
  check_config_source_snapshot
  sh "$WORK/migration-tools/migrate_config.sh" --source "$WORK/config-source.yaml" --template "$WORK/migration-tools/config.example.yaml" \
    --output "$WORK/candidate.yaml" --report "$WORK/migration-report.txt" > "$WORK/migration.log" 2>&1 || die 'Не удалось собрать кандидат конфига; подробный вывод скрыт'
  awk -v OLD="$WORK/config-source.yaml" -v NEW="$WORK/candidate.yaml" -f "$WORK/migration-tools/config_diff.awk" > "$WORK/config-diff.json" || die 'Не удалось построить структурный diff'
  check_service_listener_port
  run_config_test
  config_confirm_required=0
  config_baseline=missing
  if [ -f "$UPDATE_STATE_DIR/config-sha256" ]; then
    config_baseline=$(cat "$UPDATE_STATE_DIR/config-sha256")
    [ "${#config_baseline}" = 64 ] || die 'Неверная исходная сумма конфига'
    case $config_baseline in *[!0-9a-f]*) die 'Неверная исходная сумма конфига' ;; esac
  fi
  config_manual_changed=0
  [ "$config_baseline" = "$(sha256_of "$WORK/config-source.yaml")" ] || config_manual_changed=1
  config_review=0
  if awk -F'|' '$1=="REVIEW"{found=1}END{exit !found}' "$WORK/migration-report.txt"; then config_review=1; fi
  if [ "$config_manual_changed" = 1 ] || [ "$config_review" = 1 ]; then config_confirm_required=1; fi
  printf 'CONFIRM=%s\nMANUAL_CHANGED=%s\nREVIEW=%s\nOLD_SCHEMA=%s\nNEW_SCHEMA=%s\n' "$config_confirm_required" "$config_manual_changed" "$config_review" "$old_schema" "$new_schema" > "$WORK/config-info.txt"
  chmod 0600 "$WORK/config-source.yaml" "$WORK/candidate.yaml" "$WORK/migration-report.txt" "$WORK/config-diff.json" "$WORK/config-info.txt" || die 'Не удалось защитить RAM-кандидат'
  rm -rf "$WORK/migration-tools" || die 'Не удалось очистить инструменты миграции'
}
bind_config_identity() {
  for config_artifact in candidate.yaml migration-report.txt config-diff.json config-source.yaml config-info.txt; do
    printf 'CONFIG_%s=%s\n' "$config_artifact" "$(sha256_of "$WORK/$config_artifact")" >> "$WORK/identity.txt"
  done
  config_candidate_hash=$(sha256_of "$WORK/candidate.yaml")
  plan_id=$(sha256_of "$WORK/identity.txt")
}
verify_config_candidate() {
  for config_artifact in candidate.yaml migration-report.txt config-diff.json config-source.yaml config-info.txt; do
    safe_path "$saved/$config_artifact"
    [ -f "$saved/$config_artifact" ] && [ "$(mode_of "$saved/$config_artifact")" = 600 ] || die 'Неполный или незащищённый кандидат конфига'
    [ "$(sha256_of "$saved/$config_artifact")" = "$(manifest_field "$saved/identity.txt" "CONFIG_$config_artifact")" ] || die 'Повреждён кандидат, отчёт или diff конфига'
    cp "$saved/$config_artifact" "$WORK/$config_artifact" || die 'Не удалось прочитать проверенный кандидат'
  done
  check_config_source_snapshot
  bind_config_identity
  [ "$plan_id" = "$expected_id" ] || die 'Локальное состояние изменилось; запустите обновление заново'
  config_confirm_required=$(manifest_field "$WORK/config-info.txt" CONFIRM)
  CONFIG_PAYLOAD=$saved
  config_tools
  # Повторная сборка гарантирует связь результата с проверенными инструментами.
  sh "$WORK/migration-tools/migrate_config.sh" --source "$WORK/config-source.yaml" --template "$WORK/migration-tools/config.example.yaml" \
    --output "$WORK/config-rebuilt.yaml" --report "$WORK/config-rebuilt-report.txt" > "$WORK/migration.log" 2>&1 || die 'Повторная сборка конфига не прошла'
  cmp -s "$WORK/config-rebuilt.yaml" "$WORK/candidate.yaml" && cmp -s "$WORK/config-rebuilt-report.txt" "$WORK/migration-report.txt" || die 'Результат миграции изменился; запустите обновление заново'
  awk -v OLD="$WORK/config-source.yaml" -v NEW="$WORK/candidate.yaml" -f "$WORK/migration-tools/config_diff.awk" > "$WORK/config-rebuilt-diff.json" || die 'Повторная проверка diff не прошла'
  cmp -s "$WORK/config-rebuilt-diff.json" "$WORK/config-diff.json" || die 'diff изменился; запустите обновление заново'
  run_config_test
  verified_confirm=$config_confirm_required
  build_snapshot
  check_config_source_snapshot
  bind_config_identity
  [ "$plan_id" = "$expected_id" ] || die 'Локальное состояние изменилось при проверке конфига'
  config_confirm_required=$verified_confirm
  if [ "$config_confirm_required" = 1 ] && [ "$confirm_config" != 1 ] && [ "$cmd" != show-config-diff ]; then die 'Миграция требует отдельного подтверждения --confirm-config'; fi
}
show_config_diff() {
  [ "$migration_required" = 1 ] || die 'Этот план не содержит миграции конфига'
  if [ "$full_config_diff" = 1 ]; then
    config_diff_status=0
    diff -u "$WORK/config-source.yaml" "$WORK/candidate.yaml" || config_diff_status=$?
    [ "$config_diff_status" -le 1 ] || die 'Не удалось построить полный diff'
  else cat "$WORK/config-diff.json"; fi
}
