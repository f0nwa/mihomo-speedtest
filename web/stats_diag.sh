#!/bin/sh
# CGI вкладки «Диагностика» (см. docs/superpowers/specs/
# 2026-10-14-service-diagnostics-design.md): по кнопке проверяет каждую
# группу сервиса через ноду, которая в ней сейчас выбрана, и говорит, где
# сервис не пускает ноду. Только по кнопке, никакого расписания.
#
# Действие - MST_DIAG_ACTION (из API_ROUTES stats_httpd.py):
#   status  GET  /api/diag         - состояние текущей проверки (state.json в
#                                    $TMPROOT/mst-diag), иначе последний итог
#                                    ($DIR/diag_last.json), иначе пустое
#   start   POST /api/diag/start   - запустить фоновую проверку: {"started":true,
#                                    "id":...}; 409 speedtest_running - идёт
#                                    прогон замеров; 409 diag_running - уже идёт
#   check   POST /api/diag/check?url=<домен или адрес> - ручная проверка
#                                    одного домена через группу other (с
#                                    поиском рабочих нод), итог не пишется на
#                                    флешку
#           POST /api/diag/check?list=1 - то же для всех строк своего списка
#   one     GET  /api/diag/one     - состояние ручной проверки домена/списка
#   domains GET  /api/diag/domains - свой список доменов: {"text":...}
#   domains-save POST /api/diag/domains/save - сохранить список (тело -
#                                    текст; неверная строка или больше
#                                    DIAG_LIST_MAX доменов - 400)
#   cancel  POST /api/diag/cancel  - остановить (частичный итог сохраняется)
#   runner  - внутреннее: сама проверка (не маршрутизируется)
#
# Как проверяется (только основное ядро, по одному запросу за раз, выбор
# нод в группах не меняется - ни одного PUT):
#   - группы и цепочки - GET /proxies + diag.awk mode=resolve; адреса
#     проверки - diag.awk mode=targets (services.default.tsv + свой overlay
#     конструктора);
#   - запрос к сервису - GET /proxies/<текущая нода>/delay?url=<адрес>:
#     mihomo сам открывает адрес через эту ноду (прокси-порт в конфиге не
#     нужен - в шаблоне его нет). Успех с expected=200-399 - работает; иначе
#     expected=403/451 - доступ запрещён; иначе любой ответ - сервис ответил
#     ошибкой; иначе - ответа нет. Адресов у сервиса может быть несколько
#     (разные продукты одной группы) - проверяются все, вердикт - по первому
#     не прошедшему;
#   - контрольный запрос через ту же ноду - тот же delay на контрольный
#     адрес (не совпадает с test-url групп, чтобы не влиять на url-test);
#   - после проверки выбор групп цепочки перечитывается; если сменился -
#     сервис перепроверяется один раз через новую ноду.
#   - фаза 2: для blocked, suspect и lb - поиск нод, через которые сервис
#     работает: все конечные ноды группы (кроме текущей) по порядку
#     стабильности (diag.awk mode=order, node_stability.tsv), проверка -
#     GET /proxies/<нода>/delay на основной адрес сервиса с
#     expected=200-399, по одной ноде, с лимитами DIAG_ALT_*.
# Вердикты: ok blocked suspect node_dead direct rejected lb no_url missing
# error (подписи - в stats_app_diag.js). Пока сервис не проверен - pending,
# не успели (остановка, ошибка) - skipped; поиск замены не начат - alt
# skipped.
#
# Всё промежуточное - в $TMPROOT/mst-diag (tmpfs); на флешку пишется один
# раз в конце: $DIR/diag_last.json через временный файл и mv.

DIR=${DIR:-/opt/etc/mihomo-speedtest}
TMPROOT=${TMPROOT:-/tmp}
# speedtest2.sh (LOCK, API ядра, urlencode, статистика нод) нужен запуску
# и проверке; опросу состояния (раз в 1,5 с) - нет.
case ${MST_DIAG_ACTION:-status} in
  start|check|runner)
    export MST_LIB_ONLY=1
    [ -f "$DIR/speedtest2.sh" ] && . "$DIR/speedtest2.sh"
    MST_LIB_ONLY=0
    ;;
esac
DIAG_AWK=${DIAG_AWK:-$DIR/diag.awk}
SERVICES_DEFAULT=${SERVICES_DEFAULT:-$DIR/services.default.tsv}
CONFIG_STATE_DIR=${CONFIG_STATE_DIR:-$DIR/config-state}
DIAG_LAST=${DIAG_LAST:-$DIR/diag_last.json}
RUN=$TMPROOT/mst-diag
# Файлы состояния: полная диагностика - services.tsv/meta/state.json;
# ручная проверка домена (MST_DIAG_ONE - адрес) - свои, чтобы не затирать
# итог полной. Блокировка и cancel - общие: обе сразу не идут.
DIAG_ONE_GROUP=${DIAG_ONE_GROUP:-other}
# Свой список доменов (вкладка «Диагностика», «Свои домены»): по строке,
# # - комментарий; пишется только при сохранении.
DIAG_DOMAINS=${DIAG_DOMAINS:-$DIR/diag_domains.txt}
DIAG_LIST_MAX=${DIAG_LIST_MAX:-50}
set_paths() {
  if [ -n "${MST_DIAG_ONE:-}" ] || [ "$1" = one ]; then
    D_SVC=$RUN/check.tsv D_META=$RUN/check.meta D_STATE=$RUN/one.json
  else
    D_SVC=$RUN/services.tsv D_META=$RUN/meta D_STATE=$RUN/state.json
  fi
}
set_paths
# Контрольный адрес - первый из списка, который не test-url ни одной группы
# (запрос delay пишет историю ноды по этому адресу - url-test её читает).
DIAG_CONTROL_URLS=${DIAG_CONTROL_URLS:-"https://cp.cloudflare.com/generate_204 http://www.msftconnecttest.com/connecttest.txt http://captive.apple.com/hotspot-detect.html"}
DIAG_REQ_TIMEOUT=${DIAG_REQ_TIMEOUT:-8}
# Поиск рабочих нод (фаза 2): на сервис - до DIAG_ALT_FOUND найденных,
# DIAG_ALT_MAX_NODES проверенных или DIAG_ALT_MAX_SEC секунд; на весь
# прогон - DIAG_TOTAL_MAX_SEC.
DIAG_ALT_FOUND=${DIAG_ALT_FOUND:-3}
DIAG_ALT_MAX_NODES=${DIAG_ALT_MAX_NODES:-15}
DIAG_ALT_MAX_SEC=${DIAG_ALT_MAX_SEC:-60}
DIAG_TOTAL_MAX_SEC=${DIAG_TOTAL_MAX_SEC:-300}
TAB=$(printf '\t')
US=$(printf '\037')

reply() {
  # $1 - HTTP-статус, $2 - JSON-тело
  echo "Status: $1"
  echo "Content-Type: application/json; charset=utf-8"
  echo "Cache-Control: no-store"
  echo
  printf '%s\n' "$2"
  exit 0
}

dawk() { LC_ALL=C awk -f "$DIAG_AWK" "$@"; }

pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

# ----- состояние: meta (ключ<TAB>значение) + services.tsv -> state.json -----

meta_set() {
  # $1 - ключ, $2 - значение (табы и переводы строк заменяются пробелом)
  MV=$(printf '%s' "$2" | tr '\t\n\r' '   ') MK=$1 awk -F'\t' '
    BEGIN { k = ENVIRON["MK"]; v = ENVIRON["MV"] }
    $1 == k { print k "\t" v; done = 1; next }
    { print }
    END { if (!done) print k "\t" v }' "$D_META" > "$D_META.tmp" 2>/dev/null
  mv -f "$D_META.tmp" "$D_META"
}

diag_write_state() {
  dawk -v mode=render -v meta="$D_META" "$D_SVC" > "$D_STATE.tmp" 2>/dev/null \
    && mv -f "$D_STATE.tmp" "$D_STATE"
}

# diag_set_field ИМЯ ПОЛЕ ЗНАЧЕНИЕ - поле строки сервиса в services.tsv.
diag_set_field() {
  case $2 in
    chain) fi=2 ;; node) fi=3 ;; verdict) fi=4 ;; url) fi=5 ;; detail) fi=6 ;;
    ms) fi=7 ;; control_ms) fi=8 ;; alt_state) fi=9 ;; alt_checked) fi=10 ;;
    alt_limit) fi=11 ;; alt_found) fi=12 ;; *) return 1 ;;
  esac
  DN=$1 DV=$(printf '%s' "$3" | tr '\t\n\r' '   ') awk -F'\t' -v OFS='\t' -v fi="$fi" '
    $1 == ENVIRON["DN"] { $fi = ENVIRON["DV"] }
    { print }' "$D_SVC" > "$D_SVC.tmp" && mv -f "$D_SVC.tmp" "$D_SVC"
}

diag_cancelled() { [ -f "$RUN/cancel" ]; }

# ----- действия CGI -----

cmd_status() {
  lp=$(cat "$RUN/lock/pid" 2>/dev/null)
  if [ -d "$RUN/lock" ] && [ -n "$lp" ] && ! pid_alive "$lp"; then
    # Раннер умер, не дописав итог (перезагрузка службы, kill).
    [ -f "$D_META" ] && {
      meta_set running 0; meta_set stage error
      meta_set error "Проверка прервалась неожиданно. Запустите её ещё раз."
      meta_set finished "$(date +%s)"; diag_write_state
    }
    rm -rf "$RUN/lock"
  fi
  if [ -f "$D_STATE" ]; then reply 200 "$(cat "$D_STATE")"; fi
  if [ -z "${MST_DIAG_ONE:-}" ] && [ -f "$DIAG_LAST" ] && [ "$D_STATE" = "$RUN/state.json" ]; then reply 200 "$(cat "$DIAG_LAST")"; fi
  reply 200 '{"id":"","running":false,"stage":"none","error":"","started":0,"finished":0,"current":"","total":0,"done":0,"services":[]}'
}

# Адрес для ручной проверки: домен (example.com) или http(s)-адрес.
# QUERY_STRING url=... (процентное кодирование раскрывается).
check_url() {
  cu_v=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^url=//p' | head -n 1 | awk '
    function hv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
    { s = $0; gsub(/\+/, " ", s); out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
        if (c == "%" && i + 2 <= length(s)) { out = out sprintf("%c", hv(substr(s, i + 1, 1)) * 16 + hv(substr(s, i + 2, 1))); i += 2 }
        else out = out c }
      print out }')
  url_of "$cu_v"
}

# url_of СТРОКА - адрес для проверки: http(s)-адрес как есть, домен ->
# https://домен; иначе код 1.
url_of() {
  case $1 in
    http://*|https://*)
      case $1 in *[\ \"\'\<\>\\]*) return 1 ;; esac
      printf '%s\n' "$1" ;;
    *)
      printf '%s\n' "$1" | grep -q -E '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$' || return 1
      printf 'https://%s\n' "$1" ;;
  esac
}

# list_targets ФАЙЛ - строки targets.tsv (как записано<TAB>адрес<TAB>группа)
# из списка доменов: без пустых строк, комментариев, неверных строк и
# повторов адреса. Код 1 - ошибка в строке: в LT_ERR её текст.
list_targets() {
  lt_n=0 lt_seen=" " LT_ERR=
  while IFS= read -r lt_l || [ -n "$lt_l" ]; do
    lt_n=$((lt_n + 1))
    lt_l=$(printf '%s' "$lt_l" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case $lt_l in ''|'#'*) continue ;; esac
    if ! lt_u=$(url_of "$lt_l"); then LT_ERR="Строка $lt_n: «$lt_l» - не домен и не адрес http(s)://"; return 1; fi
    case $lt_seen in *" $lt_u "*) continue ;; esac
    lt_seen="$lt_seen$lt_u "
    printf '%s\t%s\t%s\n' "$lt_l" "$lt_u" "$DIAG_ONE_GROUP"
  done < "$1"
}

json_text() {
  # файл -> JSON-строка в кавычках
  awk 'BEGIN { printf "\"" }
    { gsub(/\r/, ""); gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t")
      if (NR > 1) printf "\\n"; printf "%s", $0 }
    END { printf "\"" }' "$1"
}

cmd_domains() {
  if [ -f "$DIAG_DOMAINS" ]; then reply 200 "{\"text\":$(json_text "$DIAG_DOMAINS")}"; fi
  reply 200 '{"text":""}'
}

cmd_domains_save() {
  [ "${REQUEST_METHOD:-GET}" = POST ] || reply 405 '{"error":"method"}'
  mkdir -p "$RUN" || reply 500 '{"error":"run_dir"}'
  head -c "${CONTENT_LENGTH:-0}" > "$RUN/domains.new"
  if ! list_targets "$RUN/domains.new" > "$RUN/domains.tsv"; then
    rm -f "$RUN/domains.new" "$RUN/domains.tsv"
    reply 400 "{\"error\":\"line\",\"message\":$(printf '%s\n' "$LT_ERR" > "$RUN/err"; json_text "$RUN/err")}"
  fi
  n=$(wc -l < "$RUN/domains.tsv" | tr -d ' ')
  rm -f "$RUN/domains.tsv" "$RUN/err"
  if [ "$n" -gt "$DIAG_LIST_MAX" ]; then
    rm -f "$RUN/domains.new"
    reply 400 "{\"error\":\"too_many\",\"message\":\"В списке $n доменов, можно не больше $DIAG_LIST_MAX\"}"
  fi
  if cp "$RUN/domains.new" "$DIAG_DOMAINS.tmp.$$" 2>/dev/null && mv -f "$DIAG_DOMAINS.tmp.$$" "$DIAG_DOMAINS"; then
    rm -f "$RUN/domains.new"
    reply 200 "{\"saved\":true,\"count\":$n}"
  fi
  rm -f "$RUN/domains.new" "$DIAG_DOMAINS.tmp.$$"
  reply 500 '{"error":"write","message":"Не удалось записать список доменов"}'
}

cmd_start() {
  [ "${REQUEST_METHOD:-GET}" = POST ] || reply 405 '{"error":"method"}'
  if [ "${MST_DIAG_ACTION:-}" = check ] && printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | grep -q '^list=1$'; then
    mkdir -p "$RUN" || reply 500 '{"error":"run_dir"}'
    if [ ! -f "$DIAG_DOMAINS" ] || ! list_targets "$DIAG_DOMAINS" > "$RUN/list.check" || [ ! -s "$RUN/list.check" ]; then
      rm -f "$RUN/list.check"
      reply 400 '{"error":"empty","message":"Список доменов пуст или в нём ошибка - сохраните список"}'
    fi
    rm -f "$RUN/list.check"
    MST_DIAG_ONE=@list; export MST_DIAG_ONE; set_paths
  elif [ "${MST_DIAG_ACTION:-}" = check ]; then
    MST_DIAG_ONE=$(check_url) || reply 400 '{"error":"url","message":"Введите домен (example.com) или адрес, начинающийся с http:// или https://"}'
    export MST_DIAG_ONE
    set_paths
  fi
  if [ -n "${LOCK:-}" ] && pid_alive "$(cat "$LOCK/pid" 2>/dev/null)"; then
    reply 409 '{"error":"speedtest_running","message":"Сейчас идёт прогон замеров. Запустите диагностику после него."}'
  fi
  mkdir -p "$RUN" || reply 500 '{"error":"run_dir"}'
  if ! mkdir "$RUN/lock" 2>/dev/null; then
    lp=$(cat "$RUN/lock/pid" 2>/dev/null)
    if [ -z "$lp" ] || pid_alive "$lp"; then
      reply 409 '{"error":"diag_running","message":"Диагностика уже идёт."}'
    fi
    rm -rf "$RUN/lock"
    mkdir "$RUN/lock" 2>/dev/null || reply 409 '{"error":"diag_running","message":"Диагностика уже идёт."}'
  fi
  # pid сразу: status без pid считает, что запуск ещё идёт
  echo $$ > "$RUN/lock/pid"
  id=$(date +%s)-$$
  rm -f "$RUN/cancel" "$D_SVC" "$D_STATE" "$D_META"
  [ -z "${MST_DIAG_ONE:-}" ] || meta_set one 1
  : > "$D_SVC"; : > "$D_META"
  meta_set id "$id"; meta_set running 1; meta_set stage phase1
  meta_set started "$(date +%s)"; meta_set current "Готовлю проверку"
  diag_write_state
  MST_DIAG_ACTION=runner "$0" </dev/null >/dev/null 2>&1 &
  echo $! > "$RUN/lock/pid"
  reply 200 "{\"started\":true,\"id\":\"$id\"}"
}

cmd_cancel() {
  [ "${REQUEST_METHOD:-GET}" = POST ] || reply 405 '{"error":"method"}'
  [ -d "$RUN/lock" ] || reply 200 '{"cancelled":false}'
  : > "$RUN/cancel"
  reply 200 '{"cancelled":true}'
}

# ----- проверка (раннер) -----

# delay УЗЕЛ АДРЕС EXPECTED - GET /proxies/<узел>/delay: mihomo сам ходит на
# адрес через этот узел (нода, DIRECT). EXPECTED - коды ответа, которые
# считаются успехом (пусто - любой ответ). Печатает задержку, код 0 -
# успех.
delay() {
  d_q="url=$(urlencode "$2")&timeout=$((DIAG_REQ_TIMEOUT * 1000))"
  [ -z "$3" ] || d_q="$d_q&expected=$3"
  d_ms=$(main_curl -s -m $((DIAG_REQ_TIMEOUT + 2)) "http://$API_MAIN/proxies/$(urlencode "$1")/delay?$d_q" 2>/dev/null \
    | sed -n 's/.*"delay":\([0-9][0-9]*\).*/\1/p')
  [ -n "$d_ms" ] || return 1
  echo "$d_ms"
}

# probe УЗЕЛ АДРЕС -> P_STATE: ok (ответ 2xx/3xx), denied (403/451), error
# (другой код ошибки), none (ответа нет); P_MS - задержка при ok.
probe() {
  P_STATE=none; P_MS=
  if P_MS=$(delay "$1" "$2" 200-399); then P_STATE=ok; return; fi
  P_MS=
  diag_cancelled && return
  if delay "$1" "$2" 403/451 > /dev/null; then P_STATE=denied; return; fi
  if delay "$1" "$2" "" > /dev/null; then P_STATE=error; fi
}

# control NODE -> C_MS (пусто, если нода не ответила)
control() {
  C_MS=$(delay "$1" "$CONTROL_URL" "") || C_MS=
}

# Цепочка (через \037) всё ещё та же? Перечитывает now у групп цепочки.
chain_same() {
  cs_rest=$1
  while :; do
    case $cs_rest in *"$US"*) ;; *) return 0 ;; esac
    cs_g=${cs_rest%%"$US"*}; cs_rest=${cs_rest#*"$US"}
    cs_next=${cs_rest%%"$US"*}
    main_curl -s -m 5 "http://$API_MAIN/proxies/$(urlencode "$cs_g")" > "$RUN/group.json" 2>/dev/null || return 0
    cs_now=$(dawk -v mode=now "$RUN/group.json")
    [ -z "$cs_now" ] || [ "$cs_now" = "$cs_next" ] || return 1
  done
}

resolve_one() {
  # $1 - группа -> R_CHAIN R_END R_KIND из свежего /proxies
  printf '%s\n' "$1" > "$RUN/one.groups"
  dawk -v mode=resolve -v groups_file="$RUN/one.groups" "$RUN/proxies.json" > "$RUN/one.res"
  R_CHAIN=$(cut -f2 "$RUN/one.res"); R_END=$(cut -f3 "$RUN/one.res"); R_KIND=$(cut -f4 "$RUN/one.res")
}

state_text() {
  case $1 in
    denied) echo "ответ 403 или 451 - доступ запрещён" ;;
    error) echo "сервис ответил кодом ошибки (не 2xx/3xx)" ;;
    *) echo "нет ответа" ;;
  esac
}

# check_service ИМЯ АДРЕСА KIND END CHAIN - фаза 1 для одного сервиса.
check_service() {
  cs_name=$1 cs_urls=$2 cs_kind=$3 cs_end=$4 cs_chain=$5
  diag_set_field "$cs_name" chain "$cs_chain"
  diag_set_field "$cs_name" node "$cs_end"
  case $cs_kind in
    missing) set_verdict missing "" "Группы нет в работающем конфиге ядра - примените конфиг"; return ;;
    loop) set_verdict error "" "Группы ссылаются друг на друга по кругу"; return ;;
    reject) set_verdict rejected "" "Правило конфига отправляет группу в REJECT"; return ;;
    lb) set_verdict lb "" "Группа распределяет запросы по нескольким нодам"; return ;;
  esac
  if [ "$cs_urls" = - ] || [ -z "$cs_urls" ]; then
    set_verdict no_url "" "Укажите адрес проверки в конструкторе"; return
  fi
  # Несколько адресов у сервиса - разные продукты одной группы (AI:
  # ChatGPT, Claude): проверяются все, вердикт - по первому не прошедшему.
  f_url= f_state= ok_url= ok_ms=
  set -f
  for u in $cs_urls; do
    diag_cancelled && { set +f; return; }
    probe "$cs_end" "$u"
    if [ "$P_STATE" = ok ]; then
      [ -n "$ok_url" ] || { ok_url=$u ok_ms=$P_MS; }
    elif [ -z "$f_url" ]; then
      f_url=$u f_state=$P_STATE
    fi
  done
  set +f
  if [ -z "$f_url" ]; then
    if [ "$cs_kind" = direct ]; then set_verdict direct "$ok_url" "напрямую: отвечает, $ok_ms мс" "$ok_ms"
    else set_verdict ok "$ok_url" "отвечает, $ok_ms мс" "$ok_ms"; fi
    return
  fi
  if [ "$cs_kind" = direct ]; then
    set_verdict direct "$f_url" "напрямую: $(state_text "$f_state")"; return
  fi
  control "$cs_end"
  diag_set_field "$cs_name" control_ms "$C_MS"
  case $f_state in
    denied) set_verdict blocked "$f_url" "$(state_text denied)" ;;
    # Сервис ответил кодом - трафик через ноду прошёл, нода жива.
    error) set_verdict suspect "$f_url" "$(state_text error); нода отвечает" ;;
    *)
      if [ -n "$C_MS" ]; then set_verdict suspect "$f_url" "нет ответа от сервиса; нода отвечает"
      else set_verdict node_dead "$f_url" "нет ответа; нода не прошла контрольный запрос"; fi ;;
  esac
}

set_verdict() {
  # $1 - вердикт, $2 - адрес, $3 - что видно, $4 - мс (необязательно)
  diag_set_field "$cs_name" verdict "$1"
  diag_set_field "$cs_name" url "$2"
  diag_set_field "$cs_name" detail "$3"
  diag_set_field "$cs_name" ms "${4:-}"
  case $1 in blocked|suspect|lb) diag_set_field "$cs_name" alt_state none ;; esac
}

# phase2 - поиск рабочих нод для проблемных сервисов.
phase2() {
  meta_set stage phase2
  p2_t0=$(date +%s)
  p2_i=1
  while [ "$p2_i" -le "$total" ]; do
    diag_cancelled && return
    p2_name=$(sed -n "${p2_i}p" "$RUN/targets.tsv" | cut -f1)
    p2_url=$(sed -n "${p2_i}p" "$RUN/targets.tsv" | cut -f2 | cut -d' ' -f1)
    p2_i=$((p2_i + 1))
    p2_row=$(DN=$p2_name awk -F'\t' '$1 == ENVIRON["DN"] { print $4 "\t" $3; exit }' "$D_SVC")
    p2_verdict=${p2_row%%"$TAB"*}; p2_node=${p2_row#*"$TAB"}
    case $p2_verdict in blocked|suspect|lb) ;; *) continue ;; esac
    [ "$p2_url" != - ] && [ -n "$p2_url" ] || continue
    [ $(( $(date +%s) - p2_t0 )) -lt "$DIAG_TOTAL_MAX_SEC" ] || return
    [ "$p2_verdict" = lb ] && p2_node=
    DN=$p2_name awk -F'\t' '$1 == ENVIRON["DN"] { print $5; exit }' "$RUN/resolved.tsv" | tr '\037' '\n' > "$RUN/cands"
    DIAG_EXCLUDE=$p2_node LC_ALL=C awk -f "$DIAG_AWK" -v mode=order -v min_uptime="${STABLE_MIN_UPTIME:-80}" \
      -v min_runs="${STABLE_MIN_RUNS:-8}" -v stab_file="${HISTORY_STABILITY:-}" "$RUN/cands" > "$RUN/order"
    p2_n=$(wc -l < "$RUN/order" | tr -d ' ')
    [ "$p2_n" -gt "$DIAG_ALT_MAX_NODES" ] && p2_n=$DIAG_ALT_MAX_NODES
    diag_set_field "$p2_name" alt_limit "$p2_n"
    diag_set_field "$p2_name" alt_checked 0
    diag_set_field "$p2_name" alt_found ""
    diag_set_field "$p2_name" alt_state searching
    diag_write_state
    p2_found= p2_nfound=0 p2_checked=0 p2_state=done p2_s0=$(date +%s)
    while [ "$p2_checked" -lt "$p2_n" ] && [ "$p2_nfound" -lt "$DIAG_ALT_FOUND" ]; do
      if diag_cancelled || [ $(( $(date +%s) - p2_t0 )) -ge "$DIAG_TOTAL_MAX_SEC" ]; then p2_state=stopped; break; fi
      [ $(( $(date +%s) - p2_s0 )) -lt "$DIAG_ALT_MAX_SEC" ] || break
      p2_cand=$(sed -n "$((p2_checked + 1))p" "$RUN/order")
      meta_set current "Ищу замену для $p2_name · нода $((p2_checked + 1)) из $p2_n"
      diag_write_state
      if main_curl -s -m $((DIAG_REQ_TIMEOUT + 2)) \
          "http://$API_MAIN/proxies/$(urlencode "$p2_cand")/delay?url=$(urlencode "$p2_url")&timeout=$((DIAG_REQ_TIMEOUT * 1000))&expected=200-399" 2>/dev/null \
          | grep -q '"delay":[0-9]'; then
        if [ -n "$p2_found" ]; then p2_found=$p2_found$US$p2_cand; else p2_found=$p2_cand; fi
        p2_nfound=$((p2_nfound + 1))
        diag_set_field "$p2_name" alt_found "$p2_found"
      fi
      p2_checked=$((p2_checked + 1))
      diag_set_field "$p2_name" alt_checked "$p2_checked"
      diag_write_state
    done
    diag_set_field "$p2_name" alt_state "$p2_state"
    diag_write_state
    [ "$p2_state" = stopped ] && return
  done
}

run_fail() {
  meta_set stage error; meta_set error "$1"
  finish
}

finish() {
  [ "$(awk -F'\t' '$1 == "stage" { print $2 }' "$D_META")" = error ] || {
    if diag_cancelled; then meta_set stage cancelled; else meta_set stage done; fi
  }
  # Что не успели: непроверенные сервисы и не начатые поиски замены.
  awk -F'\t' -v OFS='\t' '
    $4 == "pending" { $4 = "skipped"; $6 = "Не проверено: проверку остановили" }
    ($4 == "blocked" || $4 == "suspect" || $4 == "lb") && ($9 == "" || $9 == "none") { $9 = "skipped" }
    { print }' "$D_SVC" > "$D_SVC.tmp" 2>/dev/null && mv -f "$D_SVC.tmp" "$D_SVC"
  meta_set running 0; meta_set current ""; meta_set finished "$(date +%s)"
  diag_write_state
  if [ -z "${MST_DIAG_ONE:-}" ] && cp "$D_STATE" "$DIAG_LAST.tmp.$$" 2>/dev/null; then
    mv -f "$DIAG_LAST.tmp.$$" "$DIAG_LAST" || rm -f "$DIAG_LAST.tmp.$$"
  fi
  rm -rf "$RUN/cands" "$RUN/order" "$RUN/work" "$RUN/proxies.json" "$RUN/group.json" "$RUN/one.groups" "$RUN/one.res" \
    "$RUN/targets.tsv" "$RUN/groups" "$RUN/resolved.tsv" "$RUN/cancel" "$RUN/lock"
  exit 0
}

cmd_runner() {
  echo $$ > "$RUN/lock/pid"
  WORK=$RUN/work
  mkdir -p "$WORK"
  [ -f "$DIAG_AWK" ] || run_fail "Не найден $DIAG_AWK - переустановите проект"
  main_api_init || run_fail "Не удалось найти адрес API ядра mihomo: в config.yaml нет external-controller"
  main_curl -f -s -m 10 -o "$RUN/proxies.json" "http://$API_MAIN/proxies" 2>/dev/null \
    || run_fail "API ядра mihomo не отвечает ($API_MAIN). Ядро запущено?"
  CONTROL_URL=
  for cu in $DIAG_CONTROL_URLS; do
    grep -q -F "\"testUrl\":\"$cu\"" "$RUN/proxies.json" && continue
    CONTROL_URL=$cu; break
  done
  [ -n "$CONTROL_URL" ] || CONTROL_URL=${DIAG_CONTROL_URLS##* }
  # targets.tsv: имя строки<TAB>адреса<TAB>группа ядра
  if [ "${MST_DIAG_ONE:-}" = @list ]; then
    list_targets "$DIAG_DOMAINS" > "$RUN/targets.tsv" || run_fail "Ошибка в списке доменов: $LT_ERR"
  elif [ -n "${MST_DIAG_ONE:-}" ]; then
    one_host=${MST_DIAG_ONE#*://}; one_host=${one_host%%/*}
    printf '%s\t%s\t%s\n' "$one_host" "$MST_DIAG_ONE" "$DIAG_ONE_GROUP" > "$RUN/targets.tsv"
  else
    overlay=
    [ -f "$CONFIG_STATE_DIR/services.tsv" ] && overlay=$CONFIG_STATE_DIR/services.tsv
    dawk -v mode=targets -v overlay_file="$overlay" "$SERVICES_DEFAULT" > "$RUN/targets.tmp" \
      || run_fail "Не удалось прочитать список сервисов ($SERVICES_DEFAULT)"
    awk -F'\t' -v OFS='\t' '{ print $1, $2, $1 }' "$RUN/targets.tmp" > "$RUN/targets.tsv"
    rm -f "$RUN/targets.tmp"
  fi
  cut -f3 "$RUN/targets.tsv" > "$RUN/groups"
  dawk -v mode=resolve -v groups_file="$RUN/groups" "$RUN/proxies.json" > "$RUN/resolved.tmp" \
    || run_fail "Не удалось разобрать ответ API ядра"
  # первое поле - имя строки (у проверки домена - домен, а не группа)
  awk -F'\t' -v OFS='\t' 'NR == FNR { n[FNR] = $1; next } { $1 = n[FNR]; print }' \
    "$RUN/targets.tsv" "$RUN/resolved.tmp" > "$RUN/resolved.tsv"
  rm -f "$RUN/resolved.tmp"
  if [ -n "${MST_DIAG_ONE:-}" ] && [ "$(head -n 1 "$RUN/resolved.tsv" | cut -f4)" = missing ]; then
    run_fail "Группы $DIAG_ONE_GROUP нет в работающем конфиге - домен проверить не через что"
  fi
  # Строки сервисов сразу - вкладка показывает весь список «проверяется».
  awk -F'\t' -v OFS='\t' '{ print $1, $2, $3, "pending", "", "", "", "", "none", 0, 0, "" }' \
    "$RUN/resolved.tsv" > "$D_SVC"
  total=$(wc -l < "$RUN/targets.tsv" | tr -d ' ')
  meta_set total "$total"; meta_set done 0
  diag_write_state
  i=1
  while [ "$i" -le "$total" ]; do
    diag_cancelled && break
    name=$(sed -n "${i}p" "$RUN/targets.tsv" | cut -f1)
    urls=$(sed -n "${i}p" "$RUN/targets.tsv" | cut -f2)
    group=$(sed -n "${i}p" "$RUN/targets.tsv" | cut -f3)
    chain=$(sed -n "${i}p" "$RUN/resolved.tsv" | cut -f2)
    end=$(sed -n "${i}p" "$RUN/resolved.tsv" | cut -f3)
    kind=$(sed -n "${i}p" "$RUN/resolved.tsv" | cut -f4)
    meta_set current "Проверяю $name ($i из $total)"
    diag_write_state
    check_service "$name" "$urls" "$kind" "$end" "$chain"
    if [ "$kind" = node ] && ! diag_cancelled && ! chain_same "$chain"; then
      # Выбор группы сменился во время проверки - один раз через новую ноду.
      if main_curl -f -s -m 10 -o "$RUN/proxies.json" "http://$API_MAIN/proxies" 2>/dev/null; then
        resolve_one "$group"
        diag_set_field "$name" control_ms ""
        check_service "$name" "$urls" "$R_KIND" "$R_END" "$R_CHAIN"
      fi
    fi
    meta_set done "$i"
    diag_write_state
    i=$((i + 1))
  done
  diag_cancelled || phase2
  finish
}

case ${MST_DIAG_ACTION:-status} in
  status) cmd_status ;;
  one) set_paths one; cmd_status ;;
  domains) cmd_domains ;;
  domains-save) cmd_domains_save ;;
  start|check) cmd_start ;;
  cancel) cmd_cancel ;;
  runner) cmd_runner ;;
  *) reply 400 '{"error":"action"}' ;;
esac
