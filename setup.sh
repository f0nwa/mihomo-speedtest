#!/bin/sh
# setup.sh — установка с нуля: копирует config.example.yaml, собирает
# подписки (с необязательным импортом из старого config.yaml) и
# статические proxies, подбирает User-Agent автоматически, применяет
# конфиг и передаёт управление install.sh (speedtest).
set -eu

DIR=${DIR:-/opt/etc/mihomo}
BIN=${BIN:-/opt/sbin/mihomo}
API_MAIN=${API_MAIN:-127.0.0.1:9090}
SELFDIR=${SELFDIR:-.}
CONFIG=${CONFIG:-$DIR/config.yaml}
TEMPLATE=${TEMPLATE:-$SELFDIR/config.example.yaml}

. "$SELFDIR/version_check.sh"
DETECT_UA_LIB_ONLY=1
. "$SELFDIR/detect_ua.sh"

collect_subscriptions() {
  # Печатает в stdout URL по одному на строку — итоговый список подписок
  # до автоподбора UA. Порядок: импорт из старого CONFIG (за вычетом
  # номеров, убранных пользователем) -> SUB_URLS из окружения -> ручной
  # интерактивный ввод.
  urls_file=$(mktemp "${TMPDIR:-/tmp}/setup_urls.XXXXXX")
  n=0

  if [ -f "$CONFIG" ]; then
    imported=$(mktemp "${TMPDIR:-/tmp}/setup_imported.XXXXXX")
    if awk -v urls_out="$imported" -v proxies_out="" -f "$SELFDIR/existing_config.awk" "$CONFIG" 2>/dev/null && [ -s "$imported" ]; then
      echo "Найдены подписки в текущем $CONFIG:" >&2
      i=0
      while IFS= read -r u; do
        i=$((i + 1))
        echo "  $i) $u" >&2
      done < "$imported"
      printf 'Введите номера через пробел, чтобы убрать лишние (Enter — оставить все): ' >&2
      read -r drop || drop=""
      i=0
      while IFS= read -r u; do
        i=$((i + 1))
        case " $drop " in
          *" $i "*) continue ;;
        esac
        n=$((n + 1))
        echo "$u" >> "$urls_file"
      done < "$imported"
    fi
    rm -f "$imported"
  fi

  if [ -n "${SUB_URLS:-}" ]; then
    for u in $SUB_URLS; do
      n=$((n + 1))
      echo "$u" >> "$urls_file"
    done
  else
    attempt=0
    while :; do
      if [ "$n" -eq 0 ]; then
        printf 'Ссылка на подписку #%d (обязательно): ' "$((n + 1))" >&2
      else
        printf 'Ссылка на подписку #%d (Enter — закончить): ' "$((n + 1))" >&2
      fi
      read -r url || url=""
      if [ -z "$url" ]; then
        if [ "$n" -gt 0 ]; then break; fi
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
          echo "setup.sh: нужна хотя бы одна ссылка на подписку" >&2
          rm -f "$urls_file"
          return 1
        fi
        continue
      fi
      n=$((n + 1))
      echo "$url" >> "$urls_file"
    done
  fi

  cat "$urls_file"
  rm -f "$urls_file"
}

pick_ua() {
  # $1 = URL. Печатает две строки: выбранный User-Agent и вид ответа
  # ("full"/"short"). Пустой вывод — ни один UA не подошёл.
  url=$1
  tmp=$(mktemp "${TMPDIR:-/tmp}/setup_ua.XXXXXX")
  found=""
  fallback=""
  while IFS= read -r ua; do
    [ -n "$ua" ] || continue
    curl -s -o "$tmp" -w '%{http_code}' -m 10 -A "$ua" "$url" >/dev/null 2>&1 || true
    [ -f "$tmp" ] || : > "$tmp"
    kind=$(classify_body "$tmp")
    case "$kind" in
      "clash YAML, полный"*) found=$ua; break ;;
      "clash YAML, укороченный"*) [ -z "$fallback" ] && fallback=$ua ;;
    esac
  done <<UALIST
$UA_LIST
UALIST
  rm -f "$tmp"
  if [ -n "$found" ]; then
    printf '%s\nfull\n' "$found"
  elif [ -n "$fallback" ]; then
    printf '%s\nshort\n' "$fallback"
  fi
}

build_provider_specs() {
  # $1 = файл со списком URL (по одному на строку). Печатает "url<TAB>ua"
  # для тех, где UA подобран; для остальных — WARN в stderr.
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    result=$(pick_ua "$url")
    ua=$(printf '%s\n' "$result" | sed -n 1p)
    kind=$(printf '%s\n' "$result" | sed -n 2p)
    if [ -z "$ua" ]; then
      echo "setup.sh: для $url не подобран рабочий User-Agent — подписка исключена (проверьте вручную: sh detect_ua.sh \"$url\")" >&2
      continue
    fi
    if [ "$kind" = "short" ]; then
      echo "setup.sh: WARN для $url подошёл только укороченный clash YAML — сверьте набор нод после установки" >&2
    fi
    printf '%s\t%s\n' "$url" "$ua"
  done < "$1"
}

atomic_install() {
  src=$1
  dst=$2
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  if ! cp "$src" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
}

main() {
  check_mihomo_process && check_versions || return 1

  [ -f "$TEMPLATE" ] || { echo "setup.sh: шаблон $TEMPLATE не найден" >&2; return 1; }

  subs_file=$(mktemp "${TMPDIR:-/tmp}/setup_urls.XXXXXX")
  if ! collect_subscriptions > "$subs_file"; then
    rm -f "$subs_file"
    return 1
  fi

  specs_file=$(mktemp "${TMPDIR:-/tmp}/setup_specs.XXXXXX")
  build_provider_specs "$subs_file" > "$specs_file"
  rm -f "$subs_file"

  if [ ! -s "$specs_file" ]; then
    echo "setup.sh: ни одна подписка не прошла проверку — устанавливать нечего" >&2
    rm -f "$specs_file"
    return 1
  fi

  static_file=""
  if [ -f "$CONFIG" ]; then
    candidate=$(mktemp "${TMPDIR:-/tmp}/setup_static.XXXXXX")
    awk -v urls_out=/dev/null -v proxies_out="$candidate" -f "$SELFDIR/existing_config.awk" "$CONFIG" 2>/dev/null || true
    if [ -s "$candidate" ]; then
      count=$(grep -c '^  - name:' "$candidate" 2>/dev/null || echo 0)
      printf 'Найден блок proxies (%s нод) в текущем %s.\nПеренести как есть в новый config.yaml? [Y/n] ' "$count" "$CONFIG" >&2
      read -r ans || ans=""
      case "$ans" in
        [Nn]*) ;;
        *) static_file=$candidate ;;
      esac
    fi
    [ "$static_file" = "$candidate" ] || rm -f "$candidate"
  fi

  if [ -f "$CONFIG" ]; then
    backup="$CONFIG.$(date '+%Y-%m-%d_%H%M%S').bak"
    cp "$CONFIG" "$backup" || {
      echo "setup.sh: не удалось сохранить бэкап $backup" >&2
      rm -f "$specs_file"
      [ -z "$static_file" ] || rm -f "$static_file"
      return 1
    }
    echo "setup.sh: старый конфиг сохранён в $backup" >&2
  fi

  rendered=$(mktemp "${TMPDIR:-/tmp}/setup_config.XXXXXX")
  awk -v providers_file="$specs_file" -v static_file="$static_file" \
      -f "$SELFDIR/render_config.awk" "$TEMPLATE" > "$rendered"
  rm -f "$specs_file"
  [ -z "$static_file" ] || rm -f "$static_file"

  if ! "$BIN" -t -d "$DIR" -f "$rendered" >/dev/null 2>&1; then
    echo "setup.sh: новый конфиг не прошёл mihomo -t, $CONFIG не тронут" >&2
    rm -f "$rendered"
    return 1
  fi

  mkdir -p "$DIR/proxy-providers"
  atomic_install "$rendered" "$CONFIG" || {
    echo "setup.sh: не удалось записать $CONFIG" >&2
    rm -f "$rendered"
    return 1
  }

  xkeen -restart

  i=0
  while [ "$i" -lt 20 ]; do
    curl -s -m 2 "http://$API_MAIN/version" >/dev/null 2>&1 && break
    sleep 1; i=$((i + 1))
  done
  if ! curl -s -m 2 "http://$API_MAIN/version" >/dev/null 2>&1; then
    echo "setup.sh: mihomo не поднялся после xkeen -restart" >&2
    return 1
  fi

  echo "setup.sh: конфиг применён, запускаю install.sh" >&2
  exec "$SELFDIR/install.sh"
}

if [ "${SETUP_LIB_ONLY:-0}" != 1 ]; then
  main "$@"
fi
