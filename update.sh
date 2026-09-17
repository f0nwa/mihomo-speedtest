#!/bin/sh
set -eu

DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PLAN_AWK="$DIR/update_plan.awk"

UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE:-https://github.com/f0nwa/mihomo-speedtest/releases/latest/download}
UPDATE_HTTP_TIMEOUT=${UPDATE_HTTP_TIMEOUT:-15}
UPDATE_STATE_DIR=${UPDATE_STATE_DIR:-/opt/etc/mihomo/.update}
INSTALLED_MANIFEST_PATH=${INSTALLED_MANIFEST_PATH:-$UPDATE_STATE_DIR/installed-manifest.txt}
TMPROOT=${TMPROOT:-/tmp}

say() { echo "$*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

http_get() {
  # $1=URL. Собственная минимальная загрузка - update.sh (компонент
  # "updater") намеренно не подключает speedtest2.sh через MST_LIB_ONLY=1,
  # чтобы оставаться независимым от состояния другого компонента.
  url=$1
  if [ -n "${UPDATE_HTTP_CMD:-}" ]; then
    $UPDATE_HTTP_CMD "$url"
    return $?
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time "$UPDATE_HTTP_TIMEOUT" "$url"
    return $?
  fi
  if command -v busybox >/dev/null 2>&1; then
    busybox wget -q -T "$UPDATE_HTTP_TIMEOUT" -O - "$url"
    return $?
  fi
  return 127
}

fetch_manifest() {
  http_get "$UPDATE_RELEASE_BASE/manifest.txt"
}

sha256_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    echo sha256sum; return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    echo openssl-dgst; return 0
  fi
  if command -v busybox >/dev/null 2>&1 && printf '' | busybox sha256sum >/dev/null 2>&1; then
    echo busybox-sha256sum; return 0
  fi
  return 1
}

sha256_of() {
  f=$1
  case $SHA_TOOL in
    sha256sum) sha256sum "$f" | awk '{print $1}' ;;
    busybox-sha256sum) busybox sha256sum "$f" | awk '{print $1}' ;;
    openssl-dgst) openssl dgst -sha256 "$f" | awk '{print $NF}' ;;
  esac
}

build_localstate() {
  # $1=manifest, печатает "путь\tsha256" для каждого FILE-назначения,
  # реально присутствующего на диске. Пропускает отсутствующие - для них
  # update_plan.awk сам определит "отсутствует".
  manifest=$1
  awk -F'|' '$1=="FILE"{print $4}' "$manifest" | while IFS= read -r dest; do
    [ -f "$dest" ] || continue
    printf '%s\t%s\n' "$dest" "$(sha256_of "$dest")"
  done
}

manifest_field() {
  # $1=файл манифеста, $2=имя ключа (RELEASE_VERSION и т.п.)
  awk -F= -v k="$2" '$1==k{print $2; exit}' "$1"
}

usage() {
  cat >&2 << 'EOF'
Использование:
  update.sh --check
  update.sh --plan [--format=text|json] [--components=id1,id2,...]
EOF
  exit 2
}

cmd=plan
format=text
components=""

if [ $# -gt 0 ]; then
  for arg in "$@"; do
    case $arg in
      --check) cmd=check ;;
      --plan) cmd=plan ;;
      --format=json) format=json ;;
      --format=text) format=text ;;
      --components=*) components=${arg#--components=} ;;
      -h|--help) usage ;;
      *) echo "неизвестный аргумент: $arg" >&2; usage ;;
    esac
  done
fi

MANIFEST_BODY=$(fetch_manifest) || MANIFEST_BODY=""
[ -n "$MANIFEST_BODY" ] || die "не удалось получить манифест с $UPDATE_RELEASE_BASE - проверьте сеть роутера"

MANIFEST_TMP=$(mktemp "$TMPROOT/mst-update-manifest.XXXXXX")
trap 'rm -f "$MANIFEST_TMP" "${LOCALSTATE_TMP:-}"' EXIT INT TERM
printf '%s\n' "$MANIFEST_BODY" > "$MANIFEST_TMP"

case $cmd in
  check)
    release_version=$(manifest_field "$MANIFEST_TMP" RELEASE_VERSION)
    format_version=$(manifest_field "$MANIFEST_TMP" FORMAT_VERSION)
    [ -n "$release_version" ] && [ -n "$format_version" ] \
      || die "манифест получен, но не содержит распознаваемых RELEASE_VERSION=/FORMAT_VERSION="
    if [ -f "$INSTALLED_MANIFEST_PATH" ]; then
      installed_version=$(manifest_field "$INSTALLED_MANIFEST_PATH" RELEASE_VERSION)
      say "Установлена версия релиза: ${installed_version:-?}"
    else
      say "Установленный релиз не отслеживается update.sh (появится после --apply в следующей порции)"
    fi
    say "Доступна версия релиза: $release_version (формат манифеста $format_version)"
    ;;
  plan)
    SHA_TOOL=$(sha256_tool) || die "не найден sha256sum/busybox sha256sum/openssl - построить план невозможно"
    if [ -z "$components" ]; then
      components=$(awk -F'|' '$1=="COMPONENT"{printf "%s%s", (n++?",":""), $2}' "$MANIFEST_TMP")
    fi
    LOCALSTATE_TMP=$(mktemp "$TMPROOT/mst-update-local.XXXXXX")
    build_localstate "$MANIFEST_TMP" > "$LOCALSTATE_TMP"
    installed_arg=""
    [ -f "$INSTALLED_MANIFEST_PATH" ] && installed_arg=$INSTALLED_MANIFEST_PATH
    awk -v MANIFEST="$MANIFEST_TMP" -v LOCALSTATE="$LOCALSTATE_TMP" -v INSTALLED="$installed_arg" \
        -v SELECTED="$components" -v FORMAT="$format" -f "$PLAN_AWK"
    ;;
esac
