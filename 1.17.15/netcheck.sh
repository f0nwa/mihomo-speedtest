#!/bin/sh
# netcheck.sh - лёгкая диагностика соединений роутера: что доступно напрямую
# и через mihomo, не только GitHub. Подключается как `. ./netcheck.sh`;
# при подключении ничего не делает. Вывод - через ui_ok/ui_warn/ui_note, если
# они определены (installer/ui.sh), иначе в stderr.
#
# Использование:
#   nc_diagnose   - пробы + сводка + совет; код 0, если сеть в порядке
#   nc_run        - только пробы (результаты в $NC_DIR, убрать: nc_cleanup)
#   nc_verdict    - вердикт по результатам nc_run (одно слово, см. nc_advice_for)
#   nc_proxy_url  - адрес прокси mihomo (NC_PROXY, иначе порт из config.yaml)
#
# Окружение: NC_TIMEOUT - таймаут пробы, с (5); NC_PROXY - прокси вручную
# (например, INSTALL_PROXY); NC_CONFIG - config.yaml mihomo
# ($MIHOMO_DIR/config.yaml); TMPDIR.
# Пробы идут параллельно, поэтому вся проверка занимает не больше NC_TIMEOUT.
# Совместимо с busybox ash: без массивов и [[ ]].

NC_TIMEOUT=${NC_TIMEOUT:-5}

nc_say() {
  # $1 - ok|warn|fail, $2 - строка
  case $1 in
    ok)   if command -v ui_ok >/dev/null 2>&1; then ui_ok "$2"; else printf '  [OK] %s\n' "$2" >&2; fi ;;
    warn) if command -v ui_warn >/dev/null 2>&1; then ui_warn "$2"; else printf '  [!] %s\n' "$2" >&2; fi ;;
    *)    if command -v ui_fail >/dev/null 2>&1; then ui_fail "$2"; else printf '  [!!] %s\n' "$2" >&2; fi ;;
  esac
}

nc_block() {
  # stdin - строки совета: блоком (ui_note warn) или как есть в stderr
  if command -v ui_note >/dev/null 2>&1; then ui_note warn; else cat >&2; fi
}

# Результат одной пробы словом: по коду возврата curl и HTTP-коду. Любой
# HTTP-ответ, кроме 403/451, - достучались (у objects.githubusercontent.com
# корень отвечает 400/404, и это нормально).
nc_classify() {
  case $1 in
    0)
      case $2 in
        403) echo http403 ;;
        451) echo http451 ;;
        000|'') echo fail:0 ;;
        *) echo ok ;;
      esac ;;
    6) echo dns ;;
    7) echo refused ;;
    28) echo timeout ;;
    35|51|58|59|60|64|77|83|90|91) echo tls ;;
    52|55|56) echo reset ;;
    *) echo "fail:$1" ;;
  esac
}

# Результат словами для человека.
nc_reason() {
  case $1 in
    ok) echo "доступен" ;;
    dns) echo "имя не резолвится (DNS)" ;;
    timeout) echo "таймаут" ;;
    refused) echo "отказ в соединении" ;;
    reset) echo "соединение сброшено" ;;
    tls) echo "ошибка TLS (сертификат или время)" ;;
    proxy) echo "mihomo не отвечает на этом порту" ;;
    http403) echo "ответ HTTP 403 (доступ запрещён)" ;;
    http451) echo "ответ HTTP 451 (заблокировано)" ;;
    na) echo "не проверялось" ;;
    fail:*) echo "ошибка соединения (код ${1#fail:})" ;;
    *) echo "$1" ;;
  esac
}

# nc_probe ИМЯ АДРЕС [ПРОКСИ] - результат в $NC_DIR/ИМЯ.direct|ИМЯ.proxy
nc_probe() {
  np_name=$1; np_url=$2; np_proxy=${3:-}
  np_path=direct; np_rc=0
  if [ -n "$np_proxy" ]; then
    np_path=proxy
    np_code=$(curl -s -o /dev/null -w '%{http_code}' -m "$NC_TIMEOUT" -x "$np_proxy" "$np_url" 2>/dev/null) || np_rc=$?
  else
    np_code=$(curl -s -o /dev/null -w '%{http_code}' -m "$NC_TIMEOUT" "$np_url" 2>/dev/null) || np_rc=$?
  fi
  np_res=$(nc_classify "$np_rc" "$np_code")
  # Отказ или сброс на пути через прокси - это не GitHub, а сам mihomo.
  if [ "$np_path" = proxy ]; then
    case $np_res in refused|reset) np_res=proxy ;; esac
  fi
  printf '%s\n' "$np_res" > "$NC_DIR/$np_name.$np_path"
}

nc_proxy_url() {
  if [ -n "${NC_PROXY:-}" ]; then printf '%s\n' "$NC_PROXY"; return 0; fi
  npu_cfg=${NC_CONFIG:-${MIHOMO_DIR:-/opt/etc/mihomo}/config.yaml}
  [ -f "$npu_cfg" ] || return 0
  for npu_key in mixed-port port socks-port; do
    npu_val=$(sed -n "s/^$npu_key:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$npu_cfg" | head -n 1)
    [ -n "$npu_val" ] && [ "$npu_val" != 0 ] || continue
    case $npu_key in
      socks-port) printf 'socks5h://127.0.0.1:%s\n' "$npu_val" ;;
      *) printf 'http://127.0.0.1:%s\n' "$npu_val" ;;
    esac
    return 0
  done
  return 0
}

# Все пробы параллельно; ждём только свои фоновые процессы (у вызывающего
# могут быть и другие, например индикатор загрузки).
nc_run() {
  NC_DIR=$(mktemp -d "${TMPDIR:-/tmp}/netcheck.XXXXXX") || return 1
  NC_PROXYURL=$(nc_proxy_url)
  nr_pids=
  for nr_t in \
    'ip|https://1.1.1.1' \
    'gstatic|https://www.gstatic.com/generate_204' \
    'cloudflare|https://www.cloudflare.com/cdn-cgi/trace' \
    'github|https://github.com' \
    'api|https://api.github.com' \
    'raw|https://raw.githubusercontent.com' \
    'objects|https://objects.githubusercontent.com'; do
    nc_probe "${nr_t%%|*}" "${nr_t#*|}" "" &
    nr_pids="$nr_pids $!"
  done
  if [ -n "$NC_PROXYURL" ]; then
    for nr_t in \
      'github|https://github.com' \
      'raw|https://raw.githubusercontent.com' \
      'gstatic|https://www.gstatic.com/generate_204'; do
      nc_probe "${nr_t%%|*}" "${nr_t#*|}" "$NC_PROXYURL" &
      nr_pids="$nr_pids $!"
    done
  fi
  # shellcheck disable=SC2086
  wait $nr_pids 2>/dev/null || :
  return 0
}

nc_cleanup() {
  [ -z "${NC_DIR:-}" ] || rm -rf "$NC_DIR"
  NC_DIR=
}

# nc_result ИМЯ ПУТЬ (direct|proxy) -> результат пробы словом или na
nc_result() {
  cat "$NC_DIR/$1.$2" 2>/dev/null || echo na
}

# Вердикт одним словом (порядок правил - как в docs/superpowers/specs/
# 2026-10-11-network-diagnostics-design.md):
#   no-internet | dns | tls | provider-block | ok | partial |
#   blocked-proxy-ok | blocked-proxy-fail | blocked-core-down | blocked-no-proxy
nc_verdict() {
  nv_ip=$(nc_result ip direct); nv_gs=$(nc_result gstatic direct); nv_cf=$(nc_result cloudflare direct)
  if [ "$nv_ip" != ok ] && [ "$nv_gs" != ok ] && [ "$nv_cf" != ok ]; then echo no-internet; return 0; fi
  nv_dns=0; nv_tls=0; nv_blk=0; nv_ok=0
  for nv_h in ip gstatic cloudflare github api raw objects; do
    nv_r=$(nc_result "$nv_h" direct)
    case $nv_r in
      dns) nv_dns=1 ;;
      tls) nv_tls=1 ;;
      http403|http451) case $nv_h in github|api|raw|objects) nv_blk=1 ;; esac ;;
    esac
    case $nv_h in github|api|raw|objects) [ "$nv_r" != ok ] || nv_ok=$((nv_ok + 1)) ;; esac
  done
  [ "$nv_dns" = 0 ] || { echo dns; return 0; }
  [ "$nv_tls" = 0 ] || { echo tls; return 0; }
  [ "$nv_blk" = 0 ] || { echo provider-block; return 0; }
  [ "$nv_ok" != 4 ] || { echo ok; return 0; }
  [ "$nv_ok" = 0 ] || { echo partial; return 0; }
  # GitHub напрямую недоступен, контрольные хосты отвечают: режется GitHub.
  if [ -z "${NC_PROXYURL:-}" ]; then echo blocked-no-proxy; return 0; fi
  nv_pg=$(nc_result github proxy); nv_pr=$(nc_result raw proxy)
  if [ "$nv_pg" = ok ] && [ "$nv_pr" = ok ]; then echo blocked-proxy-ok; return 0; fi
  if [ "$nv_pg" = proxy ] || [ "$nv_pr" = proxy ]; then echo blocked-core-down; return 0; fi
  echo blocked-proxy-fail
}

# Совет по вердикту - строки текста (stdout).
nc_advice_for() {
  case $1 in
    ok)
      echo "Сеть в порядке: GitHub доступен напрямую." ;;
    no-internet)
      echo "Роутер не выходит в интернет: не отвечает ни один контрольный адрес."
      echo "  Проверьте подключение WAN (кабель, провайдер), раздел «Интернет» в Keenetic."
      echo "  Пока интернета нет, скачать релиз нельзя - поставьте файлы вручную (см. README.md)." ;;
    dns)
      echo "Интернет есть, но имена не резолвятся (DNS)."
      echo "  Проверьте DNS роутера (раздел «Интернет» -> DNS-серверы, opkg dns-override)"
      echo "  и блок dns: в config.yaml mihomo; если DNS держит Xkeen UI, проверьте её настройки." ;;
    tls)
      echo "Соединение есть, но проверка сертификата TLS не проходит."
      echo "  Проверьте время на роутере (date): при неверной дате сертификаты считаются просроченными."
      echo "  Если время верное: opkg update && opkg install ca-certificates." ;;
    provider-block)
      echo "GitHub отвечает кодом блокировки (HTTP 403/451): доступ режет провайдер или регион."
      echo "  Направьте трафик роутера через прокси: включите в XKeen проксирование трафика самого роутера"
      echo "  или запустите с INSTALL_PROXY=http://127.0.0.1:ПОРТ (mixed-port mihomo)." ;;
    partial)
      echo "Часть адресов GitHub недоступна напрямую, часть отвечает - похоже на частичную блокировку."
      echo "  Домены github.com, api.github.com, raw.githubusercontent.com и objects.githubusercontent.com"
      echo "  должны идти одним путём: добавьте *.githubusercontent.com в правила проксирования XKeen" ;;
    blocked-proxy-ok)
      echo "GitHub напрямую недоступен, но через mihomo работает: трафик роутера идёт мимо прокси."
      echo "  В XKeen включите проксирование трафика самого роутера (не только клиентов сети)"
      echo "  или запустите с INSTALL_PROXY=$NC_PROXYURL - установщик сам пойдёт через прокси." ;;
    blocked-core-down)
      echo "GitHub напрямую недоступен, а прокси mihomo не отвечает ($NC_PROXYURL)."
      echo "  Ядро, видимо, не запущено или порт закрыт: xkeen -start (или xkeen -restart),"
      echo "  затем повторите. Если нод ещё нет, поставьте файлы вручную (см. README.md)." ;;
    blocked-proxy-fail)
      echo "GitHub недоступен ни напрямую, ни через mihomo ($NC_PROXYURL)."
      echo "  Проверьте, что в конфиге есть рабочая нода и группа «Заблок. сервисы» не на DIRECT,"
      echo "  а github.com и *.githubusercontent.com идут через живую ноду; затем повторите." ;;
    blocked-no-proxy)
      echo "GitHub напрямую недоступен, а порта прокси mihomo в config.yaml нет."
      echo "  Включите в XKeen проксирование трафика самого роутера или укажите прокси вручную:"
      echo "  INSTALL_PROXY=http://127.0.0.1:ПОРТ (mixed-port mihomo) - либо поставьте файлы вручную." ;;
    *)
      echo "Не удалось определить причину - пришлите этот вывод для диагностики." ;;
  esac
}

# Компактная сводка по результатам nc_run.
nc_summary() {
  ns_ip=$(nc_result ip direct); ns_gs=$(nc_result gstatic direct); ns_cf=$(nc_result cloudflare direct)
  if [ "$ns_ip" = ok ]; then nc_say ok "Интернет напрямую: доступен (1.1.1.1)"
  else nc_say fail "Интернет напрямую: $(nc_reason "$ns_ip") (1.1.1.1)"; fi
  if [ "$ns_gs" = ok ] && [ "$ns_cf" = ok ]; then nc_say ok "Контрольные хосты (gstatic, cloudflare): доступны"
  else nc_say warn "Контрольные хосты: gstatic - $(nc_reason "$ns_gs"), cloudflare - $(nc_reason "$ns_cf")"; fi
  ns_bad=; ns_good=0
  for ns_h in github:github.com api:api.github.com raw:raw.githubusercontent.com objects:objects.githubusercontent.com; do
    ns_r=$(nc_result "${ns_h%%:*}" direct)
    if [ "$ns_r" = ok ]; then ns_good=$((ns_good + 1))
    else ns_bad="$ns_bad${ns_bad:+, }${ns_h#*:}: $(nc_reason "$ns_r")"; fi
  done
  if [ "$ns_good" = 4 ]; then nc_say ok "GitHub напрямую: доступен (4 из 4 адресов)"
  else nc_say fail "GitHub напрямую: $ns_good из 4 адресов - $ns_bad"; fi
  if [ -z "${NC_PROXYURL:-}" ]; then
    # Напрямую всё в порядке - прокси не нужен, строка только шумела бы.
    [ "$ns_good" = 4 ] || nc_say warn "GitHub через mihomo: не проверялся (порта прокси в config.yaml нет)"
  else
    ns_pg=$(nc_result github proxy); ns_pr=$(nc_result raw proxy)
    if [ "$ns_pg" = ok ] && [ "$ns_pr" = ok ]; then nc_say ok "GitHub через mihomo ($NC_PROXYURL): доступен"
    else nc_say warn "GitHub через mihomo ($NC_PROXYURL): github.com - $(nc_reason "$ns_pg"), raw - $(nc_reason "$ns_pr")"; fi
  fi
}

# Пробы + сводка + совет. Код 0 - сеть в порядке (GitHub доступен напрямую).
nc_diagnose() {
  nc_run || return 1
  nc_summary
  nd_v=$(nc_verdict)
  nc_advice_for "$nd_v" | nc_block
  nc_cleanup
  [ "$nd_v" = ok ]
}
