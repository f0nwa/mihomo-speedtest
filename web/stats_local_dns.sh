#!/bin/sh
# GET /api/local-dns: состояние локального имени панели.
# POST enabled=1|0: добавить или убрать только собственную запись Keenetic.
set -u

NAME=speedtest.home.arpa
DIR=${DIR:-/opt/etc/mihomo-speedtest}
ENV=${ENV:-$DIR/speedtest2.env}
STATE=${LOCAL_DNS_STATE_FILE:-$DIR/.local-dns-state}
CHECK=${LOCAL_DNS_CHECK_SCRIPT:-$DIR/local_dns_check.sh}
LOCK=${LOCAL_DNS_LOCK_DIR:-${TMPDIR:-/tmp}/mihomo-speedtest-local-dns.lock}

valid_ip() {
  printf '%s\n' "$1" | awk '
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
      split($0, p, ".")
      if (p[1] == 192 && p[2] == 168 && p[3] <= 255 && p[4] == 1) ok = 1
    }
    END { exit !ok }
  '
}

read_config() {
  config=
  records=
  config=$(ndmc -c 'show running-config' 2>/dev/null) || return 1
  records=$(printf '%s\n' "$config" | awk -v name="$NAME" '$1 == "ip" && $2 == "host" && $3 == name {print $4}')
}

read_state() {
  state_ip=
  state_bad=0
  [ -f "$STATE" ] || return 0
  state_ip=$(cat "$STATE" 2>/dev/null) || { state_bad=1; return 0; }
  valid_ip "$state_ip" || state_bad=1
}

read_guard() {
  allowed_ip=
  guard_reason=
  if [ ! -f "$CHECK" ]; then
    guard_reason='Проверка DNS не установлена'
  elif guard_output=$(sh "$CHECK" 2>&1); then
    allowed_ip=$guard_output
    valid_ip "$allowed_ip" || { allowed_ip=; guard_reason='Неверный адрес Home'; }
  else
    guard_reason=$guard_output
    [ -n "$guard_reason" ] || guard_reason='Не удалось проверить DNS Keenetic'
    allowed_ip=
  fi
}

refresh() {
  enabled=false
  available=false
  reason=
  read_state
  read_guard
  if ! read_config; then
    reason='Не удалось прочитать DNS-записи Keenetic'
    return 0
  fi
  if [ "$state_bad" = 1 ]; then
    reason='Повреждён маркер локального имени'
    return 0
  fi
  if [ -n "$state_ip" ] && [ "$records" = "$state_ip" ]; then enabled=true; fi
  if [ -n "$records" ] && [ "$enabled" != true ]; then
    reason='Имя speedtest.home.arpa уже занято другой записью'
  elif [ -n "$state_ip" ] && [ -n "$allowed_ip" ] && [ "$state_ip" != "$allowed_ip" ]; then
    reason='Адрес Home изменился; требуется обновить локальную запись'
  elif [ -z "$allowed_ip" ]; then
    reason=$guard_reason
  elif [ -n "$state_ip" ] && [ -z "$records" ]; then
    reason='Собственная DNS-запись отсутствует в Keenetic'
    available=true
  else
    available=true
  fi
}

web_port() {
  port=$(sed -n 's/^STATS_HTTP_PORT=//p' "$ENV" 2>/dev/null | tail -1 | tr -d "'\"")
  port=${port:-8899}
  case $port in ''|*[!0-9]*) return 1 ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

json_escape() {
  printf '%s' "$1" | tr '\n\r' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

respond() {
  result=$1
  override=${2:-}
  refresh
  [ -z "$override" ] || reason=$override
  url=null
  if [ "$enabled" = true ] && [ "$available" = true ] && web_port; then
    url="\"http://$NAME:$port/stats\""
  fi
  printf 'Content-Type: application/json; charset=utf-8\n\n'
  printf '{"ok":%s,"enabled":%s,"available":%s,"name":"%s","url":%s,"reason":"%s"}' \
    "$result" "$enabled" "$available" "$NAME" "$url" "$(json_escape "$reason")"
}

write_state() {
  stage=$(mktemp "${TMPDIR:-/tmp}/mst-local-dns.XXXXXX") || return 1
  candidate=$STATE.tmp.$$
  if ! printf '%s\n' "$1" > "$stage" 2>/dev/null \
      || ! cp "$stage" "$candidate" 2>/dev/null \
      || ! chmod 0600 "$candidate" 2>/dev/null \
      || ! mv "$candidate" "$STATE" 2>/dev/null; then
    rm -f "$stage" "$candidate" 2>/dev/null || :
    return 1
  fi
  rm -f "$stage"
}

rollback_add() {
  ndmc -c "no ip host $NAME $1" >/dev/null 2>&1 || return 1
  ndmc -c 'system configuration save' >/dev/null 2>&1
}

enable_name() {
  refresh
  if [ "$enabled" = true ] && [ "$available" = true ]; then respond true; return; fi
  if [ "$available" != true ]; then respond false "$reason"; return; fi
  if [ -n "$state_ip" ] && [ "$state_ip" != "$allowed_ip" ]; then
    respond false 'Адрес Home изменился; прежнюю запись нужно проверить вручную'
    return
  fi
  if ! ndmc -c "ip host $NAME $allowed_ip" >/dev/null 2>&1; then
    respond false 'Keenetic не добавил DNS-запись'
    return
  fi
  if ! read_config || [ "$records" != "$allowed_ip" ]; then
    rollback_add "$allowed_ip" || :
    respond false 'Не удалось подтвердить DNS-запись Keenetic'
    return
  fi
  if ! ndmc -c 'system configuration save' >/dev/null 2>&1; then
    rollback_add "$allowed_ip" || :
    respond false 'Keenetic не сохранил DNS-запись'
    return
  fi
  if ! write_state "$allowed_ip"; then
    rollback_add "$allowed_ip" || :
    respond false 'Не удалось сохранить маркер собственной DNS-записи'
    return
  fi
  respond true
}

disable_name() {
  refresh
  if [ "$state_bad" = 1 ]; then respond false "$reason"; return; fi
  if [ -z "$state_ip" ] && [ -z "$records" ]; then respond true; return; fi
  if [ -z "$state_ip" ] || { [ -n "$records" ] && [ "$records" != "$state_ip" ]; }; then
    respond false 'Нельзя удалять DNS-запись, которая не принадлежит speedtest'
    return
  fi
  if [ "$records" = "$state_ip" ]; then
    if ! ndmc -c "no ip host $NAME $state_ip" >/dev/null 2>&1; then
      respond false 'Keenetic не удалил DNS-запись'
      return
    fi
    if ! read_config || [ -n "$records" ]; then
      respond false 'Не удалось подтвердить удаление DNS-записи'
      return
    fi
    if ! ndmc -c 'system configuration save' >/dev/null 2>&1; then
      ndmc -c "ip host $NAME $state_ip" >/dev/null 2>&1 || :
      ndmc -c 'system configuration save' >/dev/null 2>&1 || :
      respond false 'Keenetic не сохранил удаление DNS-записи'
      return
    fi
  fi
  if ! rm -f "$STATE"; then
    respond false 'Не удалось удалить маркер собственной DNS-записи'
    return
  fi
  respond true
}

case ${REQUEST_METHOD:-GET} in
  GET) respond true ;;
  POST)
    length=${CONTENT_LENGTH:-0}
    case $length in ''|*[!0-9]*) respond false 'Некорректная длина запроса'; exit 0 ;; esac
    [ "$length" -le 32 ] || { respond false 'Слишком длинный запрос'; exit 0; }
    body=$(dd bs=1 count="$length" 2>/dev/null)
    case $body in
      enabled=1|enabled=0) ;;
      *) respond false 'Ожидалось enabled=1 или enabled=0'; exit 0 ;;
    esac
    if ! mkdir "$LOCK" 2>/dev/null; then
      respond false 'Изменение локального имени уже выполняется'
      exit 0
    fi
    trap 'rmdir "$LOCK" 2>/dev/null || :' EXIT
    case $body in enabled=1) enable_name ;; enabled=0) disable_name ;; esac
    ;;
  *) respond false 'Метод запроса не поддерживается' ;;
esac
