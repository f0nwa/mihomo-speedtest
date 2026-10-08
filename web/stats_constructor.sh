#!/bin/sh
# CGI конструктора конфига (вкладка "Конфиг", режим "Конструктор"): чтение
# состояния, предпросмотр и применение. Ставится install.sh в
# $DIR/stats_constructor.sh, stats_httpd.py запускает его оттуда. Функции
# применения (бэкап, mihomo -t, перезапуск, откат) - из stats_config.sh,
# подключённого как библиотека. См. docs/superpowers/specs/
# 2026-10-05-config-constructor-design.md, п. 4.
#
# Действие - в MST_CONSTRUCTOR_ACTION:
#   read     GET  - {"imported","manual_edits","base","defaults","services",
#                   "geofilter","user_rules","subscriptions","proxies",
#                   "template_base","block","report"}: состояние из
#                   $CONFIG_STATE_DIR, а если его нет (или ?import=1) - перенос
#                   из config.yaml (imported=true, отчёт в report); null -
#                   файла нет.
#   preview  POST - собрать кандидата из присланного состояния, без записи:
#                   {"ok","text","report","check"}.
#   wgconf   POST - перевод одного WireGuard/AmneziaWG .conf в ноду mihomo
#                   (тело: строка "### MST-WG <имя ноды>" и текст .conf):
#                   {"ok":true,"yaml":"  - name: ...","report":[...]}.
#   detect-ua POST - подбор User-Agent для адреса подписки (тело: один адрес
#                   http(s)://...; detect_ua.sh): перебирает типичные
#                   клиентские UA и останавливается на первом, под которым
#                   панель отдаёт clash YAML или base64-список нод:
#                   {"ok":true,"ua","quality":"full|short|","kind","reason":
#                   "|none|unreachable","tried":[{"ua","http","bytes","kind"}]}.
#   probe-nodes POST - проверка, отвечают ли ноды подписки (тело: адрес и
#                   User-Agent, по строке): подписка качается, ноды (clash
#                   YAML или список vless-ссылок) проверяются по одной во
#                   временном ядре на 127.0.0.1, по журналу рукопожатия
#                   REALITY определяется, отклоняет ли сервер клиента
#                   Mihomo: {"ok":true,"verdict":"alive|reality_rejected|
#                   unreachable","total","tested","alive","mlkem":"true|
#                   false|","nodes":[{"name","delay","reality"}]}.
#   catalog  GET  - {"text"}: каталог наборов правил для поиска
#                   (rule-catalog.tsv, release/build_rule_catalog.sh).
#   apply    POST - то же и применить (?base= как у save в stats_config.sh);
#                   состояние и managed.sig пишутся только после успешного
#                   применения.
# Тело preview/apply - блоки "### MST-STATE <файл>" (services.tsv,
# geofilter.txt, user-rules.txt, subscriptions.tsv, proxies.yaml), за строкой блока - содержимое файла; нет
# блока - нет файла.
#
# managed.sig - отпечаток разделов anchors, proxy-groups, rule-providers и
# rules config.yaml после применения: если он другой, эти разделы правили
# вручную (YAML-режим, восстановление бэкапа) - manual_edits=true.
set -eu

DIR=${DIR:-/opt/etc/mihomo-speedtest}
CONFIG_LIB=${CONFIG_LIB:-$DIR/stats_config.sh}
MST_CONFIG_LIB=1 . "$CONFIG_LIB"
CONSTRUCTOR_DEFAULTS=${CONSTRUCTOR_DEFAULTS:-$DIR/services.default.tsv}
CONFIG_TO_STATE_AWK=${CONFIG_TO_STATE_AWK:-$DIR/config_to_state.awk}
CONSTRUCTOR_CATALOG=${CONSTRUCTOR_CATALOG:-$DIR/rule-catalog.tsv}
APPLY_LOG=${CONSTRUCTOR_APPLY_LOG:-$APPLY_LOG}
STATE_FILES="services.tsv geofilter.txt user-rules.txt subscriptions.tsv proxies.yaml"
WG_IMPORT_AWK=${WG_IMPORT_AWK:-$DIR/wg_import.awk}
DETECT_UA_SH=${DETECT_UA_SH:-$DIR/detect_ua.sh}
SUB_CONVERT_AWK=${SUB_CONVERT_AWK:-$DIR/sub_convert.awk}
# Порты временного ядра проверки нод: только 127.0.0.1, не пересекаются с
# основным ядром (9090) и со вторым ядром спидтеста.
PROBE_API_PORT=${MST_PROBE_API_PORT:-19090}
PROBE_MIXED_PORT=${MST_PROBE_MIXED_PORT:-17890}
PROBE_MAX_NODES=${MST_PROBE_MAX_NODES:-8}

# Файл JSON-строкой или null, если файла нет.
jfile_or_null() {
  if [ -f "$1" ]; then jstr_file "$1"; else printf 'null'; fi
}

# Тело запроса ($1) -> файлы состояния в каталоге $2. Код 3 - неизвестный
# блок, повтор блока или текст до первого блока.
parse_state() {
  mkdir "$2"
  awk -v dir="$2" -v allowed=" $STATE_FILES " '
    /^### MST-STATE / {
      name = $0; sub(/^### MST-STATE /, "", name); sub(/[ \r]+$/, "", name)
      if (index(allowed, " " name " ") == 0 || name ~ /\// || (name in seen)) exit 3
      seen[name] = 1
      if (out != "") close(out)
      out = dir "/" name
      printf "" > out
      next
    }
    out == "" { if ($0 ~ /^[ \t\r]*$/) next; exit 3 }
    { print > out }
  ' "$1"
}

build_candidate() {
  # $1 - каталог состояния; кандидат - $WORK/cand.yaml, отчёт - $WORK/report
  target=$(config_target) || fail_json 500 config_path "Не удалось определить путь конфига"
  [ -f "$target" ] || fail_json 404 no_config "Файл $CONFIG не найден"
  [ -f "$CONSTRUCTOR_BUILD" ] || fail_json 500 no_tools "constructor_build.sh не найден - переустановите проект"
  if ! sh "$CONSTRUCTOR_BUILD" --state "$1" --source "$target" --output "$WORK/cand.yaml" \
      --report "$WORK/report" > "$WORK/build.log" 2>&1; then
    fail_json 422 build_failed "$(sed -n 's/^ERROR: //p' "$WORK/build.log" | head -n 1)"
  fi
}

read_state_body() {
  read_body "$WORK/body"
  rc=0; parse_state "$WORK/body" "$WORK/state" || rc=$?
  [ "$rc" = 0 ] || fail_json 400 bad_body "Тело должно состоять из блоков ### MST-STATE с файлами: $STATE_FILES"
}

# Замена состояния прервалась между двумя mv (осталась только копия .old) -
# вернуть её на место. Вызывается перед чтением и перед записью.
recover_state() {
  if [ ! -d "$CONFIG_STATE_DIR" ] && [ -d "$CONFIG_STATE_DIR.old" ]; then
    mv "$CONFIG_STATE_DIR.old" "$CONFIG_STATE_DIR" 2>/dev/null || true
  fi
}

# Список нод, которые спидтест не проверяет (BLOCK в speedtest2.env), -
# тот же фильтр, что exclude-filter подписок: слова из geofilter.txt нового
# состояния, а без него - слова шаблона. Единственное место правки фильтра -
# конструктор. Сбой записи - WARN, конфиг уже применён.
sync_block() {
  env_file=${ENV:-$DIR/speedtest2.env}
  [ -f "$env_file" ] || return 0
  if [ -f "$NEW_STATE/geofilter.txt" ]; then
    blk=$(awk '{ gsub(/^[ \t]+|[ \t\r]+$/, "") } $0 != "" && !seen[tolower($0)]++ { printf "%s%s", (n++ ? "|" : ""), $0 }' "$NEW_STATE/geofilter.txt")
  else
    blk=$(sed -n "s/.*exclude-filter: &geofilter '\([^']*\)'.*/\1/p" "$CONFIG_TEMPLATE" | head -n 1 | sed 's/^(?i)//')
  fi
  if [ -z "$blk" ] || [ "${#blk}" -gt 4000 ]; then
    alog "WARN: фильтр нод не записан в BLOCK (пуст или длиннее 4000 символов)"
    return 0
  fi
  esc=$(printf '%s' "$blk" | sed "s/'/'\\\\''/g")
  tmp="$env_file.cgi.$$"
  if { grep -v '^BLOCK=' "$env_file"; printf "BLOCK='%s'\n" "$esc"; } > "$tmp" 2>/dev/null && mv "$tmp" "$env_file"; then
    alog "Фильтр нод записан в BLOCK спидтеста"
  else
    rm -f "$tmp"
    alog "WARN: не удалось записать BLOCK в $env_file"
  fi
}

# Новое состояние ($NEW_STATE) - на место $CONFIG_STATE_DIR: собирается в
# соседнем .new и меняется местами, managed.sig - от нового config.yaml.
# Любой сбой - WARN в журнал: конфиг уже применён, ответ должен уйти.
after_apply_ok() {
  [ -n "${NEW_STATE:-}" ] || return 0
  recover_state
  ns=$CONFIG_STATE_DIR.new
  rm -rf "$ns" "$CONFIG_STATE_DIR.old" 2>/dev/null || true
  if mkdir -p "$ns" && { [ -z "$(ls "$NEW_STATE")" ] || cp -p "$NEW_STATE"/* "$ns"/; } &&
      { [ -f "$ns/services.tsv" ] || : > "$ns/services.tsv"; } &&
      managed_sig "$(config_target)" > "$ns/managed.sig"; then
    if [ ! -d "$CONFIG_STATE_DIR" ] || mv "$CONFIG_STATE_DIR" "$CONFIG_STATE_DIR.old"; then
      if mv "$ns" "$CONFIG_STATE_DIR"; then
        rm -rf "$CONFIG_STATE_DIR.old" 2>/dev/null || true
        alog "Состояние конструктора сохранено в $CONFIG_STATE_DIR"
        sync_block
        return 0
      fi
      recover_state
    fi
  fi
  rm -rf "$ns" 2>/dev/null || true
  alog "WARN: конфиг применён, но состояние конструктора не сохранилось ($CONFIG_STATE_DIR)"
  return 0
}

if [ "${MST_CONSTRUCTOR_LIB:-0}" != 1 ]; then
new_work
method=${REQUEST_METHOD:-GET}
action=${MST_CONSTRUCTOR_ACTION:-read}

case $action:$method in
  read:GET|read:HEAD)
    recover_state
    target=$(config_target) || fail_json 500 config_path "Не удалось определить путь конфига"
    [ -f "$target" ] || fail_json 404 no_config "Файл $CONFIG не найден"
    [ -f "$CONSTRUCTOR_DEFAULTS" ] || fail_json 500 no_tools "services.default.tsv не найден - переустановите проект"
    imported=false manual=false
    : > "$WORK/report"
    # Разбор config.yaml - всегда: из него берётся недостающее в сохранённом
    # состоянии (подписки и свои прокси появились позже сервисов).
    imp=$WORK/imp; mkdir "$imp"
    awk -v defaults="$CONSTRUCTOR_DEFAULTS" -v template="$CONFIG_TEMPLATE" -v out_dir="$imp" \
        -v report="$WORK/imp.report" -f "$CONFIG_TO_STATE_AWK" "$target" 2> "$WORK/err" \
      || fail_json 422 import_failed "Не удалось разобрать config.yaml: $(head -n 1 "$WORK/err")"
    # ?import=1 - «Перенести в конструктор»: перенос из config.yaml даже при
    # сохранённом состоянии (оно заменится только при применении).
    if [ "$(query_param import)" != 1 ] && [ -f "$CONFIG_STATE_DIR/services.tsv" ]; then
      st=$CONFIG_STATE_DIR
      if [ -f "$st/managed.sig" ] && [ "$(cat "$st/managed.sig")" != "$(managed_sig "$target")" ]; then manual=true; fi
    else
      st=$imp; imported=true
      cp "$WORK/imp.report" "$WORK/report"
    fi
    subs=null prox=null
    if [ -f "$st/subscriptions.tsv" ]; then subs=$(jstr_file "$st/subscriptions.tsv")
    elif [ -f "$imp/subscriptions.tsv" ]; then subs=$(jstr_file "$imp/subscriptions.tsv"); fi
    if [ -f "$st/proxies.yaml" ]; then prox=$(jstr_file "$st/proxies.yaml")
    elif [ -f "$imp/proxies.yaml" ]; then prox=$(jstr_file "$imp/proxies.yaml"); fi
    # Базовая часть шаблона (anchors и группы до сервисных): значения
    # interval/tolerance, proxies базовых групп и слова фильтра нод.
    awk '/^[A-Za-z0-9_-]+:/ { on = ($0 ~ /^(anchors|proxy-groups):/) } /SERVICE_GROUPS:BEGIN/ { exit } on' \
      "$CONFIG_TEMPLATE" > "$WORK/tbase" 2>/dev/null || : > "$WORK/tbase"
    # Текущий BLOCK спидтеста (прежний гео-фильтр из настроек): пока в
    # конструкторе нет своего фильтра, он берётся как исходный.
    block=
    env_file=${ENV:-$DIR/speedtest2.env}
    [ ! -f "$env_file" ] || block=$( (. "$env_file" >/dev/null 2>&1; printf '%s' "${BLOCK:-}") 2>/dev/null ) || block=
    printf '{"imported":%s,"manual_edits":%s,"base":"%s","defaults":%s,"services":%s,"geofilter":%s,"user_rules":%s,"subscriptions":%s,"proxies":%s,"template_base":%s,"block":%s,"report":%s}\n' \
      "$imported" "$manual" "$(fingerprint "$target")" "$(jstr_file "$CONSTRUCTOR_DEFAULTS")" \
      "$(jfile_or_null "$st/services.tsv")" "$(jfile_or_null "$st/geofilter.txt")" \
      "$(jfile_or_null "$st/user-rules.txt")" "$subs" "$prox" "$(jstr_file "$WORK/tbase")" "$(jstr "$block")" "$(lines_json "$WORK/report")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  catalog:GET|catalog:HEAD)
    [ -f "$CONSTRUCTOR_CATALOG" ] || fail_json 404 no_catalog "Каталог наборов правил не найден - переустановите проект"
    printf '{"text":%s}\n' "$(jstr_file "$CONSTRUCTOR_CATALOG")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  wgconf:POST)
    [ -f "$WG_IMPORT_AWK" ] || fail_json 500 no_tools "wg_import.awk не найден - переустановите проект"
    read_body "$WORK/body"
    mkdir "$WORK/wg"
    # первая строка - "### MST-WG <имя>", остальное - текст .conf
    if ! LC_ALL=C awk -v D="$WORK/wg" '
      function chars(t) { gsub(/[\200-\277]/, "", t); return length(t) }
      { line = $0; sub(/\r$/, "", line) }
      NR == 1 {
        if (line !~ /^### MST-WG /) exit 3
        name = substr(line, 12)
        if (name == "" || name ~ /[\001-\037\177|]/ || name ~ /^[ \t]/ || name ~ /[ \t]$/ || chars(name) > 64) exit 4
        printf "%s/in.conf\t%s\n", D, name > (D "/list"); next
      }
      { print > (D "/in.conf") }' "$WORK/body"; then
      fail_json 400 bad_body "Первая строка тела: ### MST-WG <имя ноды> (до 64 символов, без | и пробелов по краям)"
    fi
    [ -f "$WORK/wg/in.conf" ] || : > "$WORK/wg/in.conf"
    : > "$WORK/report"
    awk -v MODE=nodes -v LIST="$WORK/wg/list" -v REPORT="$WORK/report" -f "$WG_IMPORT_AWK" /dev/null > "$WORK/nodes.yaml" \
      || fail_json 422 import_failed "Не удалось перевести .conf"
    if [ ! -s "$WORK/nodes.yaml" ]; then
      fail_json 422 bad_conf "$(sed -n 's/^ERROR|[^|]*|//p' "$WORK/report" | head -n 1)"
    fi
    printf '{"ok":true,"yaml":%s,"report":%s}\n' "$(jstr_file "$WORK/nodes.yaml")" "$(lines_json "$WORK/report")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  detect-ua:POST)
    [ -f "$DETECT_UA_SH" ] || fail_json 500 no_tools "detect_ua.sh не найден - переустановите проект"
    read_body "$WORK/body"
    # Тело - один адрес: ключ доступа не попадает ни в строку запроса, ни в
    # журнал, ни в ответ.
    du_url=$(sed -n '1p' "$WORK/body" | tr -d '\r')
    du_extra=$(sed -n '2,$p' "$WORK/body" | tr -d '[:space:]')
    if [ -n "$du_extra" ] || ! printf '%s' "$du_url" | grep -Eq '^https?://[^[:space:]"\\]+$'; then
      fail_json 400 bad_url "Адрес подписки должен начинаться с http:// или https:// и не содержать пробелов, кавычек и обратных косых черт"
    fi
    DETECT_UA_LIB_ONLY=1 . "$DETECT_UA_SH"
    # Перебор в порядке UA_LIST, как pick_ua в setup.sh: полный clash YAML и
    # base64-список подходят сразу, укороченный YAML - запасной вариант.
    # Первый же ответ без соединения (код 000) - сеть или хост недоступны,
    # остальные 16 запросов по 10 секунд ждать незачем.
    du_tab=$(printf '\t')
    du_tmp=$WORK/probe.body
    : > "$WORK/du.rows"
    du_found="" du_found_kind="" du_fallback="" du_fallback_kind="" du_n=0 du_dead=0
    while IFS= read -r du_cand; do
      [ -n "$du_cand" ] || continue
      du_res=$(probe_ua "$du_cand" "$du_url" "$du_tmp")
      du_code=${du_res%%"$du_tab"*}; du_res=${du_res#*"$du_tab"}
      du_size=${du_res%%"$du_tab"*}; du_kind=${du_res#*"$du_tab"}
      [ "$du_n" = 0 ] || printf ',' >> "$WORK/du.rows"
      du_n=$((du_n + 1))
      printf '{"ua":%s,"http":%s,"bytes":%s,"kind":%s}' "$(jstr "$du_cand")" "$(jstr "$du_code")" "$du_size" "$(jstr "$du_kind")" >> "$WORK/du.rows"
      case $du_kind in
        "clash YAML, полный"*|"v2ray-подписка"*) du_found=$du_cand; du_found_kind=$du_kind; break ;;
        "clash YAML, укороченный"*) [ -n "$du_fallback" ] || { du_fallback=$du_cand; du_fallback_kind=$du_kind; } ;;
      esac
      if [ "$du_n" = 1 ] && [ "$du_code" = 000 ]; then du_dead=1; break; fi
    done <<UALIST
$UA_LIST
UALIST
    rm -f "$du_tmp"
    du_quality="" du_ua="" du_kind=""
    if [ -n "$du_found" ]; then du_quality=full du_ua=$du_found du_kind=$du_found_kind
    elif [ -n "$du_fallback" ]; then du_quality=short du_ua=$du_fallback du_kind=$du_fallback_kind; fi
    du_reason=""
    if [ -z "$du_ua" ]; then if [ "$du_dead" = 1 ]; then du_reason=unreachable; else du_reason=none; fi; fi
    printf '{"ok":true,"ua":%s,"quality":%s,"kind":%s,"reason":%s,"tried":[%s]}\n' "$(jstr "$du_ua")" "$(jstr "$du_quality")" \
      "$(jstr "$du_kind")" "$(jstr "$du_reason")" "$(cat "$WORK/du.rows")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  probe-nodes:POST)
    [ -x "$BIN" ] || fail_json 500 no_core "mihomo не найден: $BIN"
    read_body "$WORK/body"
    # Адрес и User-Agent - телом: ключ доступа не попадает ни в строку
    # запроса, ни в журнал, ни в ответ.
    pn_url=$(sed -n '1p' "$WORK/body" | tr -d '\r')
    pn_ua=$(sed -n '2p' "$WORK/body" | tr -d '\r')
    pn_extra=$(sed -n '3,$p' "$WORK/body" | tr -d '[:space:]')
    if [ -n "$pn_extra" ] || ! printf '%s' "$pn_url" | grep -Eq '^https?://[^[:space:]"\\]+$'; then
      fail_json 400 bad_url "Адрес подписки должен начинаться с http:// или https:// и не содержать пробелов, кавычек и обратных косых черт"
    fi
    if printf '%s' "$pn_ua" | grep -q '["\\]'; then
      fail_json 400 bad_ua "User-Agent: нельзя кавычки и обратную косую черту"
    fi
    pn_code=$(curl -sL --compressed --proto '=http,https' --proto-redir '=http,https' -m 15 -A "$pn_ua" \
      -o "$WORK/sub.body" -w '%{http_code}' "$pn_url" 2>/dev/null) || pn_code=000
    [ "$pn_code" = 200 ] || fail_json 502 fetch_failed "Подписка не открылась (HTTP $pn_code)"
    # Источник нод: clash YAML (блок proxies:) или base64-список vless-ссылок.
    : > "$WORK/nodes.yaml"
    if grep -q '^proxies:' "$WORK/sub.body" 2>/dev/null; then
      awk '/^proxies:[ \t]*$/ { on = 1; print; next } on && /^[^ \t#-]/ { exit } on { print }' "$WORK/sub.body" > "$WORK/nodes.yaml"
    else
      if ! base64 -d "$WORK/sub.body" > "$WORK/dec.txt" 2>/dev/null || [ ! -s "$WORK/dec.txt" ]; then
        openssl base64 -d -A -in "$WORK/sub.body" > "$WORK/dec.txt" 2>/dev/null || : > "$WORK/dec.txt"
      fi
      case $(sed -n '1p' "$WORK/dec.txt") in
        vless://*)
          [ -f "$SUB_CONVERT_AWK" ] || fail_json 500 no_tools "sub_convert.awk не найден - переустановите проект"
          LC_ALL=C awk -f "$SUB_CONVERT_AWK" "$WORK/dec.txt" > "$WORK/nodes.yaml" 2>/dev/null || : > "$WORK/nodes.yaml" ;;
        *) fail_json 422 unsupported "Проверка нод понимает clash YAML и список vless-ссылок, а подписка в другом формате" ;;
      esac
    fi
    # Ноды получают короткие имена n1..nN (в имени могут быть эмодзи и
    # пробелы, а в адрес API они не помещаются); настоящее имя - в map.tsv.
    : > "$WORK/map.tsv"
    LC_ALL=C awk -v MAP="$WORK/map.tsv" -v MAX="$PROBE_MAX_NODES" -v TOTALF="$WORK/total" '
      /^proxies:/ { print; next }
      /^[ \t]*-[ \t]+name:/ {
        pre = $0; sub(/name:.*/, "", pre)
        nm = $0; sub(/^[^:]*name:[ \t]*/, "", nm); sub(/[ \t\r]+$/, "", nm)
        if (nm ~ /^".*"$/ || nm ~ /^\x27.*\x27$/) nm = substr(nm, 2, length(nm) - 2)
        total++
        if (total <= MAX) { skip = 0; printf "%sname: n%d\n", pre, total; printf "n%d\t%s\n", total, nm >> MAP } else { skip = 1 }
        next
      }
      !skip { print }
      END { print total + 0 > TOTALF }' "$WORK/nodes.yaml" > "$WORK/nodes.tmp"
    pn_total=$(cat "$WORK/total" 2>/dev/null || echo 0)
    [ "${pn_total:-0}" -gt 0 ] || fail_json 422 no_nodes "В подписке не найдено нод"
    mkdir "$WORK/core"
    { echo "mixed-port: $PROBE_MIXED_PORT"; echo "external-controller: 127.0.0.1:$PROBE_API_PORT"
      echo "log-level: debug"; echo "mode: rule"; cat "$WORK/nodes.tmp"
      echo "proxy-groups:"; echo "  - name: T"; echo "    type: select"; echo "    include-all-proxies: true"
      echo "rules:"; echo "  - MATCH,T"; } > "$WORK/core/c.yaml"
    if ! "$BIN" -t -d "$WORK/core" -f "$WORK/core/c.yaml" > "$WORK/core/t.log" 2>&1 < /dev/null; then
      fail_json 422 bad_nodes "Ноды не прошли проверку mihomo -t: $(sed -n 's/.*level=error msg=//p' "$WORK/core/t.log" | head -n 1)"
    fi
    PN_PID=
    trap '[ -z "$PN_PID" ] || kill "$PN_PID" 2>/dev/null' EXIT
    "$BIN" -d "$WORK/core" -f "$WORK/core/c.yaml" > "$WORK/core.log" 2>&1 < /dev/null &
    PN_PID=$!
    pn_up=0; pn_i=0
    while [ "$pn_i" -lt 10 ]; do
      if curl -s --noproxy '*' -m 2 "http://127.0.0.1:$PROBE_API_PORT/version" > /dev/null 2>&1; then pn_up=1; break; fi
      pn_i=$((pn_i + 1)); sleep 1
    done
    [ "$pn_up" = 1 ] || fail_json 500 core_failed "Не удалось запустить проверочное ядро (порт $PROBE_API_PORT занят?): $(tail -n 1 "$WORK/core.log")"
    pn_tab=$(printf '\t')
    : > "$WORK/pn.rows"
    pn_tested=0 pn_alive=0 pn_rejected=0 pn_mlkem=""
    while IFS="$pn_tab" read -r pn_id pn_name; do
      [ -n "$pn_id" ] || continue
      pn_before=$(wc -l < "$WORK/core.log" | tr -d ' ')
      pn_res=$(curl -s --noproxy '*' -m 12 "http://127.0.0.1:$PROBE_API_PORT/proxies/$pn_id/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=6000" < /dev/null 2>/dev/null || true)
      pn_delay=$(printf '%s' "$pn_res" | sed -n 's/.*"delay":\([0-9][0-9]*\).*/\1/p')
      pn_delay=${pn_delay:-0}
      tail -n +$((pn_before + 1)) "$WORK/core.log" > "$WORK/node.log" 2>/dev/null || : > "$WORK/node.log"
      pn_reality=""
      if grep -q 'REALITY Authentication: false' "$WORK/node.log"; then pn_reality=rejected; pn_rejected=$((pn_rejected + 1))
      elif grep -q 'REALITY Authentication: true' "$WORK/node.log"; then pn_reality=ok; fi
      if grep -q "communication: true" "$WORK/node.log"; then pn_mlkem=true
      elif [ "$pn_mlkem" != true ] && grep -q "communication: false" "$WORK/node.log"; then pn_mlkem=false; fi
      pn_tested=$((pn_tested + 1))
      [ "$pn_delay" -le 0 ] || pn_alive=$((pn_alive + 1))
      [ "$pn_tested" = 1 ] || printf ',' >> "$WORK/pn.rows"
      printf '{"name":%s,"delay":%s,"reality":%s}' "$(jstr "$pn_name")" "$pn_delay" "$(jstr "$pn_reality")" >> "$WORK/pn.rows"
    done < "$WORK/map.tsv"
    kill "$PN_PID" 2>/dev/null || true
    PN_PID=
    if [ "$pn_alive" -gt 0 ]; then pn_verdict=alive
    elif [ "$pn_rejected" -gt 0 ]; then pn_verdict=reality_rejected
    else pn_verdict=unreachable; fi
    printf '{"ok":true,"verdict":%s,"total":%s,"tested":%s,"alive":%s,"mlkem":%s,"nodes":[%s]}\n' "$(jstr "$pn_verdict")" \
      "$pn_total" "$pn_tested" "$pn_alive" "$(jstr "$pn_mlkem")" "$(cat "$WORK/pn.rows")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  preview:POST)
    read_state_body
    build_candidate "$WORK/state"
    rc=0; check_file "$WORK/cand.yaml" || rc=$?
    printf '{"ok":true,"text":%s,"report":%s,"check":%s}\n' "$(jstr_file "$WORK/cand.yaml")" \
      "$(lines_json "$WORK/report")" "$(check_json "$rc")" > "$WORK/resp"
    reply 200 "$WORK/resp" ;;
  apply:POST)
    read_state_body
    build_candidate "$WORK/state"
    NEW_STATE=$WORK/state
    apply_candidate "$WORK/cand.yaml" ;;
  *)
    fail_json 405 method_not_allowed "" ;;
esac
fi
