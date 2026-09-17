#!/bin/sh
set -eu
umask 077
LC_ALL=C
export LC_ALL

DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
PLAN_AWK="$DIR/update_plan.awk"
UPDATER_VERSION=3
UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE:-https://github.com/f0nwa/mihomo-speedtest/releases/latest/download}
UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE%/}
UPDATE_HTTP_TIMEOUT=${UPDATE_HTTP_TIMEOUT:-15}
UPDATE_STATE_DIR=${UPDATE_STATE_DIR:-/opt/etc/mihomo/.update}
INSTALLED_MANIFEST_PATH=${INSTALLED_MANIFEST_PATH:-$UPDATE_STATE_DIR/installed-manifest.txt}
TMPROOT=${TMPROOT:-/tmp}

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
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
  else mode_value=$(stat -f '%Lp' "$1" 2>/dev/null) || die 'не удалось прочитать режим файла'; fi
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
      if ($3!="update.sh" && $3!="update_plan.awk" && $3!="update_prepare.sh") bad()
      if ($5 !~ /^[0-9]+$/ || $5+0<1 || $5+0>1048576 || $6 !~ /^[0-9a-f]{64}$/) bad()
      if ($3=="update_plan.awk") {if ($7!="0644" || $8!="awk") bad()}
      else if ($7!="0755" || $8!="sh") bad()
      row[++n]=$0
    }
    END {
      if (fmt!="2" || tag !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ || tag ~ /\.\./ || n!=3 ||
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
  if [ "$confirm_local" = 1 ]; then
    UPDATE_VERIFIED_ENGINE_DIR="$WORK/bootstrap" UPDATE_VERIFIED_PLAN_ID="$plan_id" \
      sh "$WORK/bootstrap/update.sh" --verify-plan "$plan_id" "--format=$format" --confirm-local
  else
    UPDATE_VERIFIED_ENGINE_DIR="$WORK/bootstrap" UPDATE_VERIFIED_PLAN_ID="$plan_id" \
      sh "$WORK/bootstrap/update.sh" --verify-plan "$plan_id" "--format=$format"
  fi
}
usage() {
  cat <<'HELP'
Использование:
  update.sh --check
  update.sh --plan [--components=id1,id2,...] [--format=text|json]
  update.sh --prepare [--components=id1,id2,...] [--format=text|json]
  update.sh --verify-plan <plan-id> [--confirm-local] [--format=text|json]
  update.sh --discard-plan <plan-id>
Применение и откат добавляются в части 2.3.
HELP
}
cmd=plan
format=text
components=
plan_id=
confirm_local=0
command_seen=0
while [ $# -gt 0 ]; do
  case $1 in
    --check|--plan|--prepare|--verify-plan|--discard-plan)
      [ "$command_seen" = 0 ] || die 'задайте один режим'
      command_seen=1; cmd=${1#--}
      case $cmd in verify-plan|discard-plan) shift; [ $# -gt 0 ] || die 'не задан plan-id'; plan_id=$1 ;; esac ;;
    --format=text|--format=json) format=${1#--format=} ;;
    --components=*) components=${1#--components=} ;;
    --confirm-local) confirm_local=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die 'неизвестный аргумент' ;;
  esac
  shift
done
case $cmd in
  verify-plan|discard-plan) [ -z "$components" ] || die 'выбор компонентов уже закреплён в plan-id' ;;
esac
if [ "$confirm_local" = 1 ] && [ "$cmd" != verify-plan ]; then die '--confirm-local применяется только при --verify-plan'; fi
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
cleanup() {
  [ "$KEEP_WORK" = 1 ] || rm -rf "$WORK"
  [ -z "$OWN_LOCK" ] || rm -rf "$OWN_LOCK"
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
  verify-plan)
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
build_snapshot
if [ "$cmd" = prepare ]; then prepare_files; fi
print_plan
