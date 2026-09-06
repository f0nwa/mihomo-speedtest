#!/bin/sh
# Подбор рабочего User-Agent для подписки в proxy-providers.
#
# Некоторые панели подписок отдают разный формат ответа в зависимости от
# User-Agent запроса: JSON для v2rayNG/xray, полный clash YAML для
# clash.meta/mihomo/clash-verge, укороченный YAML для старых ClashX/CFW,
# base64-список нод для Shadowrocket/Quantumult X/Surge и т.п. mihomo как
# proxy-providers понимает только clash YAML, поэтому перед добавлением
# новой подписки в config.yaml (по образцу config.example.yaml) стоит
# проверить, под каким User-Agent сервер отдаёт нужный формат.
#
# Инструмент не устанавливается на роутер и не входит в состав install.sh —
# это разовая помощь при сборке конфига на рабочей машине, где есть curl.
#
# Использование:
#   sh detect_ua.sh <URL подписки> [доп. User-Agent ...]
#
# Пример:
#   sh detect_ua.sh "https://connect.wpn.me/XXXXXXXXXXXXXXXX"
#
# Для юнит-тестов classify_body() без обращения к сети:
#   DETECT_UA_LIB_ONLY=1 . ./detect_ua.sh

set -eu

# Список часто встречающихся клиентских User-Agent, по которым панели
# подписок различают формат ответа. При необходимости дополните список
# аргументами командной строки — они проверяются вместе со стандартными.
UA_LIST='
v2rayNG/1.8.0
v2rayNG/1.10.10
ClashforWindows/0.20.39
clash-verge/v2.0.5
clash.meta
clash
mihomo/1.18.0
ClashX/1.95.1
ClashX Pro/1.95.1
Shadowrocket/1897
Quantumult%20X/1.0.30
Surge/1651
Stash/2.5.4
V2rayU/3.6
sing-box
FlClash/0.8.0
Netch/1.4.0.0
'

# Классифицирует тело ответа подписки по характерным маркерам.
# Аргумент: путь к файлу с телом ответа. Печатает одну строку в stdout.
classify_body() {
  file=$1
  [ -s "$file" ] || { echo "пусто"; return; }

  head_bytes=$(head -c 2 "$file" 2>/dev/null || true)
  case "$head_bytes" in
    '[{'|'{"')
      echo "v2ray/xray JSON (НЕ подходит для mihomo proxy-providers)"
      return
      ;;
  esac

  if grep -q 'proxy-groups:' "$file" 2>/dev/null && grep -q 'mixed-port:' "$file" 2>/dev/null; then
    echo "clash YAML, полный (подходит для mihomo proxy-providers)"
    return
  fi

  if grep -q 'proxies:' "$file" 2>/dev/null; then
    echo "clash YAML, укороченный (частично подходит, сверьте набор нод)"
    return
  fi

  # Похоже на base64: во всём файле нет символов вне base64-алфавита.
  if ! grep -q '[^A-Za-z0-9+/=_[:space:]-]' "$file" 2>/dev/null; then
    echo "base64-список нод (нужен provider type: file/raw, не clash YAML)"
    return
  fi

  echo "неизвестный формат, смотрите тело ответа глазами"
}

# Делает один запрос с заданным User-Agent и печатает строку результата.
# Аргументы: User-Agent, URL, путь к файлу для тела ответа.
# Не полагается на общие $URL/$TMP — так функцию можно тестировать
# отдельно, подменяя curl через PATH (см. tests/test_detect_ua.sh).
try_one() {
  ua=$1
  target=$2
  out=$3
  code=$(curl -s -o "$out" -w '%{http_code}' -m 10 -A "$ua" "$target" 2>/dev/null) || code=000
  # При полном сбое соединения curl иногда не создаёт файл -o вовсе —
  # подстрахуемся, чтобы classify_body()/wc не спотыкались об его отсутствие.
  [ -f "$out" ] || : > "$out"
  size=$(wc -c < "$out" 2>/dev/null | tr -d ' ')
  kind=$(classify_body "$out")
  printf 'UA=[%s] -> HTTP %s, bytes=%s, %s\n' "$ua" "$code" "${size:-0}" "$kind"
}

if [ "${DETECT_UA_LIB_ONLY:-0}" != 1 ]; then
  URL=${1:-}
  if [ -z "$URL" ]; then
    echo "Использование: sh detect_ua.sh <URL подписки> [доп. User-Agent ...]" >&2
    exit 1
  fi
  shift

  TMP=$(mktemp "${TMPDIR:-/tmp}/detect_ua.XXXXXX")
  trap 'rm -f "$TMP"' EXIT INT TERM

  echo "$UA_LIST" | while IFS= read -r ua; do
    [ -n "$ua" ] || continue
    try_one "$ua" "$URL" "$TMP"
  done

  for ua in "$@"; do
    try_one "$ua" "$URL" "$TMP"
  done
fi
