#!/bin/sh
set -eu
umask 077
LC_ALL=C
export LC_ALL

DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
PLAN_AWK="$DIR/update_plan.awk"
UPDATER_VERSION=6
UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE:-https://github.com/f0nwa/mihomo-speedtest/releases/latest/download}
UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE%/}
UPDATE_HTTP_TIMEOUT=${UPDATE_HTTP_TIMEOUT:-15}
UPDATE_STATE_DIR=${UPDATE_STATE_DIR:-/opt/etc/mihomo/.update}
INSTALLED_MANIFEST_PATH=${INSTALLED_MANIFEST_PATH:-$UPDATE_STATE_DIR/installed-manifest.txt}
TMPROOT=${TMPROOT:-/tmp}

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
initialize_web_auth() {
  # $DIR здесь - каталог проверенного движка обновления (bootstrap-копия
  # update.sh/update_plan.awk/update_prepare.sh/update_transaction.sh), а не
  # каталог установки: компонент web (stats_auth.py) в bootstrap не входит
  # (bootstrap_header пропускает только FILE|updater|...). Реальный
  # установленный stats_auth.py нужно искать через target_file(), которая
  # уже доступна - update_prepare.sh подключён и prepare_init выполнен до
  # вызова initialize_web_auth() в единственной точке вызова (ветка apply).
  auth_dir=$(target_file /opt/etc/mihomo)
  auth_py=$auth_dir/stats_auth.py
  [ -f "$auth_py" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    say 'WARN: обновление применено, но Python 3 отсутствует; веб-интерфейс не запущен'
    return 0
  fi
  if ! setup_code=$(python3 "$auth_py" initialize --state-dir "$auth_dir/.stats-auth" --runtime-dir /tmp/mihomo-speedtest-auth); then
    say "WARN: обновление применено, но авторизация не инициализирована; выполните sh $auth_dir/stats_auth.sh reset"
    return 0
  fi
  if [ -n "$setup_code" ]; then
    say "Одноразовый код первичной настройки: $setup_code"
    say "Откройте http://<адрес роутера>:${STATS_HTTP_PORT:-8899}/setup и задайте логин и пароль"
  fi
}
manifest_field() { awk -F= -v k="$2" '$1==k{print $2; exit}' "$1"; }
sha256_tool() {
  if command -v sha256sum >/dev/null 2>&1; then echo sha256sum
  elif command -v openssl >/dev/null 2>&1; then echo openssl
  elif command -v busybox >/dev/null 2>&1 && printf '' | busybox sha256sum >/dev/null 2>&1; then echo busybox
  else return 1; fi
}
sha256_of() {
  case $SHA_TOOL in
    sha256sum) hash_output=$(sha256sum "$1") || die 'ошибка вычисления SHA256' ;;
    openssl) hash_output=$(openssl dgst -sha256 "$1") || die 'ошибка вычисления SHA256' ;;
    busybox) hash_output=$(busybox sha256sum "$1") || die 'ошибка вычисления SHA256' ;;
  esac
  hash_value=$(printf '%s\n' "$hash_output" | awk '{if ($1 ~ /^[0-9a-f]{64}$/) print $1; else if ($NF ~ /^[0-9a-f]{64}$/) print $NF}')
  [ "${#hash_value}" = 64 ] || die 'инструмент SHA256 вернул неверный результат'
  printf '%s\n' "$hash_value"
}
safe_path() {
  path_check=$1
  case $path_check in /*) ;; *) die 'путь должен быть абсолютным' ;; esac
  while [ "$path_check" != / ]; do
    [ ! -L "$path_check" ] || die 'символическая ссылка в управляемом пути'
    path_check=${path_check%/*}; [ -n "$path_check" ] || path_check=/
    if [ -e "$path_check" ] && [ ! -d "$path_check" ]; then die 'родитель пути не является каталогом'; fi
  done
}
mode_of() {
  if mode_value=$(stat -c '%a' "$1" 2>/dev/null); then :
  elif mode_value=$(stat -f '%Lp' "$1" 2>/dev/null); then :
  else
    # Минимальный BusyBox stat не имеет форматирования; POSIX ls даёт rwx.
    mode_listing=$(ls -ld "$1") || die 'не удалось прочитать режим файла'
    mode_value=$(printf '%s\n' "$mode_listing" | awk '
      function bit(ch, kind) {
        if (ch=="-") return 0
        if (kind==1 && ch=="r") return 4
        if (kind==2 && ch=="w") return 2
        if (kind==3 && ch ~ /^[xst]$/) return 1
        if (kind==3 && ch ~ /^[ST]$/) return 0
        bad=1; return 0
      }
      NR==1 {
        bits=substr($1,2,9)
        if (length(bits)!=9 || substr($1,1,1)!="-") bad=1
        for (i=1;i<=3;i++) {
          group=0
          for (j=1;j<=3;j++) group+=bit(substr(bits,(i-1)*3+j,1),j)
          value=value*10+group
        }
        u=substr(bits,3,1); g=substr(bits,6,1); o=substr(bits,9,1)
        if (u ~ /^[sS]$/) special+=4
        if (g ~ /^[sS]$/) special+=2
        if (o ~ /^[tT]$/) special+=1
        if (u ~ /^[tT]$/ || g ~ /^[tT]$/ || o ~ /^[sS]$/) bad=1
        if (!bad) {printf "%d\n", special*1000+value; ok=1}
      }
      END {exit !ok}
    ') || die 'не удалось разобрать режим файла'
  fi
  case $mode_value in *[!0-7]*|'') die 'неверный режим файла' ;; esac
  printf '%s\n' "$mode_value"
}
http_get() {
  if [ -n "${UPDATE_HTTP_CMD:-}" ]; then $UPDATE_HTTP_CMD "$1"
  elif command -v curl >/dev/null 2>&1; then
    case $1 in
      https://*) curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$UPDATE_HTTP_TIMEOUT" --max-filesize "$2" "$1" 2>/dev/null ;;
      http://*) curl -fsSL --proto '=http' --proto-redir '=http' --max-redirs 0 --max-time "$UPDATE_HTTP_TIMEOUT" --max-filesize "$2" "$1" 2>/dev/null ;;
      *) return 1 ;;
    esac
  else die 'штатная загрузка требует curl с поддержкой HTTPS'; fi
}
download_to() {
  # ulimit ограничивает запись curl и подменённого транспорта.
  # В разных shell блок равен 512/1024 байтам; фактический размер проверяем ниже.
  write_limit=$3
  # Лимит касается всех файлов процесса транспорта, включая его журнал.
  # Минимум 256 КиБ допускает небольшой журнал даже при загрузке короткого файла.
  [ "$write_limit" -ge 262144 ] || write_limit=262144
  if ! (ulimit -f "$(( (write_limit + 511) / 512 ))"; http_get "$1" "$3") > "$2"; then
    die 'не удалось получить манифест или файл релиза - проверьте сеть и сертификаты роутера'
  fi
  download_size=$(wc -c < "$2" | tr -d ' ')
  [ "$download_size" -gt 0 ] && [ "$download_size" -le "$3" ] || die 'пустой файл или превышен лимит загрузки'
}
check_download() {
  [ "$(wc -c < "$1" | tr -d ' ')" = "$2" ] || die 'неверный размер файла релиза'
  [ "$(sha256_of "$1")" = "$3" ] || die 'неверная сумма SHA256 файла релиза'
}
awk_syntax() {
  # Первый BEGIN предотвращает запуск пользовательского BEGIN, первый END
  # предотвращает выполнение остальных END. Весь файл предварительно разбирается.
  printf 'BEGIN { exit 0 }\nEND { exit 0 }\n' > "$WORK/awk-guard"
  awk -f "$WORK/awk-guard" -f "$1" /dev/null >/dev/null 2>&1 || die 'файл не прошёл проверку синтаксиса AWK'
}
bootstrap_header() {
  # Это стабильный небольшой протокол. Не использует установленный PLAN_AWK.
  awk -F'|' '
    function bad(){exit 1}
    /^[A-Z_]+=/ {
      if (split($0,h,"=") != 2 || seen[h[1]]++) bad()
      if (h[1]=="FORMAT_VERSION") fmt=h[2]
      if (h[1]=="RELEASE_TAG") tag=h[2]
      if (h[1] ~ /^(RELEASE_VERSION|MIN_UPDATER_VERSION|CONFIG_SCHEMA_VERSION)$/ && h[2] !~ /^[0-9]+$/) bad()
      next
    }
    $1=="FILE" && $2=="updater" {
      if (NF!=8 || used[$3]++ || $4!="/opt/etc/mihomo/" $3) bad()
      if ($3!="update.sh" && $3!="update_plan.awk" && $3!="update_prepare.sh" && $3!="update_transaction.sh") bad()
      if ($5 !~ /^[0-9]+$/ || $5+0<1 || $5+0>1048576 || $6 !~ /^[0-9a-f]{64}$/) bad()
      if ($3=="update_plan.awk") {if ($7!="0644" || $8!="awk") bad()}
      else if ($7!="0755" || $8!="sh") bad()
      row[++n]=$0
    }
    END {
      if (fmt!="2" || tag !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ || tag ~ /\.\./ || (n!=3 && n!=4) ||
          !seen["RELEASE_VERSION"] || !seen["MIN_UPDATER_VERSION"] || !seen["CONFIG_SCHEMA_VERSION"]) exit 1
      for (i=1;i<=n;i++) print row[i]
    }
  ' "$MANIFEST_TMP" > "$WORK/bootstrap-files" || die 'несовместимый bootstrap - обновите update.sh вручную; инструкция: release/manifest-format.md'
}
pinned_base() {
  case $UPDATE_RELEASE_BASE in
    */releases/latest/download) PINNED_BASE=${UPDATE_RELEASE_BASE%/latest/download}/download/$(manifest_field "$MANIFEST_TMP" RELEASE_TAG) ;;
    *) die 'подготовка требует источник .../releases/latest/download' ;;
  esac
}
bootstrap_prepare() {
  bootstrap_header
  pinned_base
  mkdir "$WORK/bootstrap"
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    download_to "$PINNED_BASE/$src" "$WORK/bootstrap/$src" "$bytes"
    check_download "$WORK/bootstrap/$src" "$bytes" "$sum"
    case $check in
      sh) sh -n "$WORK/bootstrap/$src" || die 'неверный синтаксис bootstrap' ;;
      awk) awk_syntax "$WORK/bootstrap/$src" ;;
    esac
    chmod "$mode" "$WORK/bootstrap/$src" || die 'не удалось задать режим bootstrap'
  done < "$WORK/bootstrap-files"
  UPDATE_PINNED_MANIFEST="$MANIFEST_TMP" UPDATE_BOOTSTRAP_DIR="$WORK/bootstrap" \
    sh "$WORK/bootstrap/update.sh" "$@"
}
cached_plan_header() {
  [ "${#plan_id}" = 64 ] || die 'неверный plan-id'
  case $plan_id in *[!0-9a-f]*) die 'неверный plan-id' ;; esac
  cache_plan=$TMPROOT/mst-update-plans/$plan_id
  safe_path "$cache_plan"
  for cache_file in identity.txt manifest.txt; do
    safe_path "$cache_plan/$cache_file"
    [ -f "$cache_plan/$cache_file" ] || die 'подготовленный план не найден'
    cache_bytes=$(wc -c < "$cache_plan/$cache_file" | tr -d ' ')
    [ "$cache_bytes" -le 262144 ] || die 'повреждён подготовленный план'
  done
  [ "$(sha256_of "$cache_plan/identity.txt")" = "$plan_id" ] || die 'повреждён идентификатор плана'
  cache_manifest_sum=$(manifest_field "$cache_plan/identity.txt" MANIFEST)
  [ "$(sha256_of "$cache_plan/manifest.txt")" = "$cache_manifest_sum" ] || die 'повреждён манифест плана'
  cp "$cache_plan/manifest.txt" "$MANIFEST_TMP" || die 'не удалось прочитать манифест плана'
  bootstrap_header
}
bootstrap_verify() {
  cached_plan_header
  mkdir "$WORK/bootstrap"
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    safe_path "$cache_plan/engine/$src"
    [ -f "$cache_plan/engine/$src" ] || die 'неполный движок плана'
    [ "$(mode_of "$cache_plan/engine/$src")" = "${mode#0}" ] || die 'изменён режим движка плана'
    cp "$cache_plan/engine/$src" "$WORK/bootstrap/$src" || die 'не удалось прочитать движок плана'
    check_download "$WORK/bootstrap/$src" "$bytes" "$sum"
    case $check in sh) sh -n "$WORK/bootstrap/$src" || die 'неверный синтаксис движка плана' ;; awk) awk_syntax "$WORK/bootstrap/$src" ;; esac
    chmod "$mode" "$WORK/bootstrap/$src"
  done < "$WORK/bootstrap-files"
  set -- "--$cmd" "$plan_id" "--format=$format"
  [ "$confirm_local" != 1 ] || set -- "$@" --confirm-local
  [ "$confirm_config" != 1 ] || set -- "$@" --confirm-config
  [ "$full_config_diff" != 1 ] || set -- "$@" --full-config-diff
  UPDATE_VERIFIED_ENGINE_DIR="$WORK/bootstrap" UPDATE_VERIFIED_PLAN_ID="$plan_id" \
    sh "$WORK/bootstrap/update.sh" "$@"
}
lock_plans() {
  mkdir -p "$PLANS" || die 'не удалось создать каталог планов'
  chmod 0700 "$PLANS" || die 'не удалось защитить каталог планов'
  safe_path "$PLANS/.lock"
  if ! mkdir "$PLANS/.lock" 2>/dev/null; then
    lock_pid=$(cat "$PLANS/.lock/pid" 2>/dev/null) || die 'операция уже выполняется'
    case $lock_pid in *[!0-9]*|''|0) die 'неверная блокировка операции' ;; esac
    if kill -0 "$lock_pid" 2>/dev/null; then die 'операция уже выполняется'; fi
    # Только один процесс может удалять устаревшую блокировку.
    safe_path "$PLANS/.lock.reap"
    mkdir "$PLANS/.lock.reap" 2>/dev/null || die 'очистка блокировки уже выполняется; проверьте .lock.reap'
    REAP_LOCK=$PLANS/.lock.reap
    printf '%s\n' "$$" > "$REAP_LOCK/pid" || die 'не удалось записать владельца очистки'
    lock_pid=$(cat "$PLANS/.lock/pid" 2>/dev/null) || die 'блокировка изменилась; повторите команду'
    case $lock_pid in *[!0-9]*|''|0) die 'неверная блокировка операции' ;; esac
    if kill -0 "$lock_pid" 2>/dev/null; then die 'операция уже выполняется'; fi
    rm -rf "$PLANS/.lock" || die 'не удалось удалить устаревшую блокировку'
    mkdir "$PLANS/.lock" || die 'операция уже выполняется'
  fi
  OWN_LOCK=$PLANS/.lock
  printf '%s\n' "$$" > "$OWN_LOCK/pid" || die 'не удалось записать владельца операции'
  if [ -n "$REAP_LOCK" ]; then
    rm -rf "$REAP_LOCK" || die 'не удалось завершить очистку блокировки'
    REAP_LOCK=
  fi
}
transaction_result() {
  case $cmd in apply) result_status=applied ;; rollback-last) result_status=rolled-back ;; recover) result_status=recovered ;; esac
  if [ "$format" = json ]; then printf '{"status":"%s"}\n' "$result_status"
  else say "Операция завершена: $result_status"; fi
}
bootstrap_recovery() {
  recovery_state=$UPDATE_STATE_DIR
  if [ -n "${UPDATE_TARGET_ROOT:-}" ]; then
    recovery_root=$(CDPATH= cd -- "$UPDATE_TARGET_ROOT" && pwd -P) || die 'корень установки недоступен'
    case $recovery_state in /opt/*) recovery_state=$recovery_root$recovery_state ;; esac
  fi
  safe_path "$recovery_state/transaction.txt"
  if [ "$cmd" = recover ] && [ ! -e "$recovery_state/transaction.txt" ]; then
    PLANS=$TMPROOT/mst-update-plans
    safe_path "$PLANS"
    lock_plans
    [ ! -e "$recovery_state/transaction.txt" ] || die 'состояние восстановления изменилось'
    safe_path "$recovery_state/rollback.pending"
    safe_path "$recovery_state/transaction.new"
    # До публикации первого журнала назначения ещё не менялись.
    # Прерванное создание комплекта можно явно очистить без движка и сети.
    rm -rf "$recovery_state/rollback.pending" || die 'не удалось очистить незавершённый комплект'
    rm -f "$recovery_state/transaction.new" || die 'не удалось очистить временный журнал'
    transaction_result
    return
  fi
  recovery_bundle=$recovery_state/rollback
  if [ -e "$recovery_state/transaction.txt" ]; then
    [ -f "$recovery_state/transaction.txt" ] || die 'неверный журнал транзакции'
    case $(cat "$recovery_state/transaction.txt") in
      CLEANUP_PENDING)
        [ "$cmd" = recover ] || die 'сначала выполните --recover'
        PLANS=$TMPROOT/mst-update-plans
        safe_path "$PLANS"
        lock_plans
        [ "$(cat "$recovery_state/transaction.txt")" = CLEANUP_PENDING ] || die 'состояние восстановления изменилось'
        safe_path "$recovery_state/rollback.pending"
        # Старые файлы уже восстановлены; engine может быть частично удалён.
        rm -rf "$recovery_state/rollback.pending" || die 'не удалось завершить очистку комплекта'
        sync || die 'не удалось сохранить очистку комплекта'
        rm -f "$recovery_state/transaction.txt" || die 'не удалось завершить очистку журнала'
        sync || die 'не удалось сохранить очистку журнала'
        transaction_result
        return ;;
      APPLY_PENDING) recovery_bundle=$recovery_state/rollback.pending ;;
      COMMIT) if [ -d "$recovery_state/rollback.pending" ]; then recovery_bundle=$recovery_state/rollback.pending; fi ;;
      ROLLBACK_SAVED) : ;;
      *) die 'неизвестный журнал транзакции; восстановление заблокировано' ;;
    esac
  fi
  safe_path "$recovery_bundle/engine-manifest.txt"
  [ -f "$recovery_bundle/engine-manifest.txt" ] || die 'комплект восстановления не найден'
  [ "$(wc -c < "$recovery_bundle/engine-manifest.txt" | tr -d ' ')" -le 262144 ] || die 'повреждён манифест восстановления'
  cp "$recovery_bundle/engine-manifest.txt" "$MANIFEST_TMP"
  bootstrap_header
  mkdir "$WORK/recovery-engine"
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    safe_path "$recovery_bundle/engine/$src"
    [ -f "$recovery_bundle/engine/$src" ] || die 'неполный движок восстановления'
    [ "$(mode_of "$recovery_bundle/engine/$src")" = "${mode#0}" ] || die 'изменён режим движка восстановления'
    cp "$recovery_bundle/engine/$src" "$WORK/recovery-engine/$src" || die 'не удалось прочитать движок восстановления'
    check_download "$WORK/recovery-engine/$src" "$bytes" "$sum"
    case $check in sh) sh -n "$WORK/recovery-engine/$src" || die 'неверный синтаксис recovery-engine' ;; awk) awk_syntax "$WORK/recovery-engine/$src" ;; esac
    chmod "$mode" "$WORK/recovery-engine/$src"
  done < "$WORK/bootstrap-files"
  [ -f "$WORK/recovery-engine/update_transaction.sh" ] || die 'движок не поддерживает транзакции'
  UPDATE_RECOVERY_ENGINE_DIR="$WORK/recovery-engine" \
    sh "$WORK/recovery-engine/update.sh" "--$cmd" "--format=$format"
}
usage() {
  cat <<'HELP'
Использование:
  update.sh --check
  update.sh --plan [--components=id1,id2,...] [--format=text|json]
  update.sh --prepare [--components=id1,id2,...] [--format=text|json]
  update.sh --verify-plan <plan-id> [--confirm-local] [--confirm-config] [--format=text|json]
  update.sh --show-config-diff <plan-id> [--full-config-diff] [--format=text|json]
  update.sh --discard-plan <plan-id>
  update.sh --apply <plan-id> [--confirm-local] [--confirm-config] [--format=text|json]
  update.sh --rollback-last [--format=text|json]
  update.sh --recover [--format=text|json]
HELP
}
cmd=plan
format=text
components=
plan_id=
confirm_local=0
confirm_config=0
full_config_diff=0
command_seen=0
while [ $# -gt 0 ]; do
  case $1 in
    --check|--plan|--prepare|--verify-plan|--discard-plan|--show-config-diff|--apply|--rollback-last|--recover)
      [ "$command_seen" = 0 ] || die 'задайте один режим'
      command_seen=1; cmd=${1#--}
      case $cmd in verify-plan|discard-plan|show-config-diff|apply) shift; [ $# -gt 0 ] || die 'не задан plan-id'; plan_id=$1 ;; esac ;;
    --format=text|--format=json) format=${1#--format=} ;;
    --components=*) components=${1#--components=} ;;
    --confirm-local) confirm_local=1 ;;
    --confirm-config) confirm_config=1 ;;
    --full-config-diff) full_config_diff=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die 'неизвестный аргумент' ;;
  esac
  shift
done
case $cmd in
  verify-plan|discard-plan|show-config-diff|apply|rollback-last|recover) [ -z "$components" ] || die 'выбор компонентов уже закреплён в plan-id' ;;
esac
if [ "$confirm_local" = 1 ] && [ "$cmd" != verify-plan ] && [ "$cmd" != apply ]; then die '--confirm-local применяется только при --verify-plan/--apply'; fi
if [ "$confirm_config" = 1 ] && [ "$cmd" != verify-plan ] && [ "$cmd" != apply ]; then die '--confirm-config применяется только при --verify-plan/--apply'; fi
if [ "$full_config_diff" = 1 ] && [ "$format" = json ]; then die 'полный diff допускается только в текстовом формате'; fi
if [ "$full_config_diff" = 1 ] && [ "$cmd" != show-config-diff ]; then die '--full-config-diff применяется только при --show-config-diff'; fi
case $UPDATE_HTTP_TIMEOUT in *[!0-9]*|'') die 'неверный таймаут загрузки' ;; esac
[ "$UPDATE_HTTP_TIMEOUT" -gt 0 ] || die 'неверный таймаут загрузки'
case $UPDATE_RELEASE_BASE in *'@'*|*'|'*|*'?'*|*'#'*|*[[:space:]]*|*[[:cntrl:]]*) die 'неверный URL источника' ;; esac
url_authority=${UPDATE_RELEASE_BASE#*://}; url_authority=${url_authority%%/*}
[ -n "$url_authority" ] || die 'неверный URL источника'
case $UPDATE_RELEASE_BASE in
  https://*) : ;;
  http://*)
    case $url_authority in localhost:*|127.0.0.1:*) ;; *) die 'HTTP допускается только для локального сервера' ;; esac
    url_port=${url_authority##*:}
    case $url_port in *[!0-9]*|'') die 'неверный порт локального сервера' ;; esac
    [ "${#url_port}" -le 5 ] && [ "$url_port" -ge 1 ] && [ "$url_port" -le 65535 ] || die 'неверный порт локального сервера' ;;
  *) die 'источник требует HTTPS' ;;
esac
TMPROOT=$(CDPATH= cd -- "$TMPROOT" && pwd -P) || die 'TMPROOT недоступен'
case $TMPROOT in /opt|/opt/*|/) die 'рабочий каталог должен находиться во временном разделе' ;; esac
WORK=$(mktemp -d "$TMPROOT/mst-update-work.XXXXXX")
KEEP_WORK=0
OWN_LOCK=
REAP_LOCK=
cleanup() {
  [ -z "${CONFIG_CHECK_PID:-}" ] || kill "$CONFIG_CHECK_PID" 2>/dev/null || :
  [ -z "${CONFIG_WATCHDOG_PID:-}" ] || kill "$CONFIG_WATCHDOG_PID" 2>/dev/null || :
  [ "$KEEP_WORK" = 1 ] || rm -rf "$WORK"
  [ -z "$OWN_LOCK" ] || rm -rf "$OWN_LOCK"
  [ -z "$REAP_LOCK" ] || rm -rf "$REAP_LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
MANIFEST_TMP=$WORK/manifest.txt
case $cmd in
  discard-plan)
    . "$DIR/update_prepare.sh"
    prepare_init
    discard_plan
    exit 0 ;;
  rollback-last|recover)
    SHA_TOOL=$(sha256_tool) || die 'не найден инструмент SHA256'
    if [ -z "${UPDATE_RECOVERY_ENGINE_DIR:-}" ]; then bootstrap_recovery; exit 0; fi
    [ "$UPDATE_RECOVERY_ENGINE_DIR" = "$DIR" ] || die 'неверный recovery-engine'
    . "$DIR/update_prepare.sh"
    prepare_init
    lock_plans
    . "$DIR/update_transaction.sh"
    if [ "$cmd" = recover ]; then transaction_recover; else transaction_rollback; fi
    transaction_result
    exit 0 ;;
  verify-plan|show-config-diff|apply)
    SHA_TOOL=$(sha256_tool) || die 'не найден инструмент SHA256'
    if [ -z "${UPDATE_VERIFIED_ENGINE_DIR:-}" ]; then bootstrap_verify; exit 0; fi
    [ "$UPDATE_VERIFIED_ENGINE_DIR" = "$DIR" ] && [ "${UPDATE_VERIFIED_PLAN_ID:-}" = "$plan_id" ] || die 'неверный движок проверки'
    cached_plan_header
    while IFS='|' read -r kind cid src dest bytes sum mode check; do
      [ ! -L "$DIR/$src" ] || die 'символическая ссылка в движке проверки'
      check_download "$DIR/$src" "$bytes" "$sum"
    done < "$WORK/bootstrap-files"
    . "$DIR/update_prepare.sh"
    prepare_init
    verify_plan
    if [ "$cmd" = show-config-diff ]; then show_config_diff; fi
    if [ "$cmd" = apply ]; then
      . "$DIR/update_transaction.sh"
      transaction_apply
      transaction_result
      initialize_web_auth
    fi
    exit 0 ;;
  *)
    if [ "$cmd" = prepare ] && [ -n "${UPDATE_BOOTSTRAP_DIR:-}" ]; then
      [ -f "${UPDATE_PINNED_MANIFEST:-}" ] && [ ! -L "$UPDATE_PINNED_MANIFEST" ] || die 'отсутствует закреплённый манифест'
      cp "$UPDATE_PINNED_MANIFEST" "$MANIFEST_TMP"
    else
      download_to "$UPDATE_RELEASE_BASE/manifest.txt" "$MANIFEST_TMP" 262144
    fi ;;
esac
if [ "$cmd" = prepare ]; then
  SHA_TOOL=$(sha256_tool) || die 'не найден инструмент SHA256'
  if [ -z "${UPDATE_BOOTSTRAP_DIR:-}" ]; then
    # Передаём только фиксированные, уже разобранные CLI-аргументы.
    bootstrap_prepare --prepare "--components=$components" "--format=$format"
    exit 0
  fi
  # Не подключаем helper, пока его сумма не сверена с закреплённым манифестом.
  [ "$UPDATE_BOOTSTRAP_DIR" = "$DIR" ] || die 'неверный каталог bootstrap'
  bootstrap_header
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    [ ! -L "$DIR/$src" ] || die 'символическая ссылка в bootstrap'
    check_download "$DIR/$src" "$bytes" "$sum"
  done < "$WORK/bootstrap-files"
fi
if [ "$cmd" != check ] && [ -z "$components" ]; then
  components=$(awk -F'|' '$1=="COMPONENT"{printf "%s%s", (n++?",":""), $2}' "$MANIFEST_TMP")
fi
awk -v MANIFEST="$MANIFEST_TMP" -v VALIDATE_ONLY=1 -v SELECTED="$components" \
    -v UPDATER_VERSION="$UPDATER_VERSION" -f "$PLAN_AWK"
if [ "$cmd" = check ]; then
  installed_version=
  if [ -f "$INSTALLED_MANIFEST_PATH" ]; then installed_version=$(manifest_field "$INSTALLED_MANIFEST_PATH" RELEASE_VERSION); fi
  if [ -n "$installed_version" ]; then say "Установлена версия релиза: $installed_version"
  else say 'Установленный релиз не отслеживается update.sh'; fi
  say "Доступна версия релиза: $(manifest_field "$MANIFEST_TMP" RELEASE_VERSION) (формат манифеста $(manifest_field "$MANIFEST_TMP" FORMAT_VERSION))"
  release_tag=$(manifest_field "$MANIFEST_TMP" RELEASE_TAG)
  if [ -n "$release_tag" ]; then say "Тег релиза: $release_tag"; fi
  exit 0
fi
SHA_TOOL=$(sha256_tool) || die 'не найден инструмент SHA256'
. "$DIR/update_prepare.sh"
prepare_init
assert_no_transaction
build_snapshot
if [ "$cmd" = prepare ]; then prepare_files; fi
print_plan
