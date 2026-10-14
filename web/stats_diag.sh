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
#   cancel  POST /api/diag/cancel  - остановить (частичный итог сохраняется)
#   runner  - внутреннее: сама проверка (не маршрутизируется)
#
# Как проверяется (только основное ядро, по одному запросу за раз, выбор
# нод в группах не меняется - ни одного PUT):
#   - группы и цепочки - GET /proxies + diag.awk mode=resolve; адреса
#     проверки - diag.awk mode=targets (services.default.tsv + свой overlay
#     конструктора);
#   - запрос к сервису - curl через mixed-port ядра: по правилам он уходит в
#     группу сервиса, т. е. через её текущую ноду; адресов у сервиса может
#     быть несколько (разные продукты одной группы) - проверяются все,
#     вердикт - по первому не прошедшему; 5xx/429 и страница блокировки (в
#     ответе не 2xx или редирект на «unavailable») - не прошёл;
#   - контрольный запрос через ту же ноду - GET /proxies/<нода>/delay на
#     DIAG_CONTROL_URL (не совпадает с test-url групп, чтобы не влиять на
#     url-test);
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
export MST_LIB_ONLY=1
[ -f "$DIR/speedtest2.sh" ] && . "$DIR/speedtest2.sh"
MST_LIB_ONLY=0
TMPROOT=${TMPROOT:-/tmp}
NETCHECK=${NETCHECK:-$DIR/netcheck.sh}
[ -f "$NETCHECK" ] && . "$NETCHECK"
DIAG_AWK=${DIAG_AWK:-$DIR/diag.awk}
SERVICES_DEFAULT=${SERVICES_DEFAULT:-$DIR/services.default.tsv}
CONFIG_STATE_DIR=${CONFIG_STATE_DIR:-$DIR/config-state}
DIAG_LAST=${DIAG_LAST:-$DIR/diag_last.json}
RUN=$TMPROOT/mst-diag
# Контрольный адрес - первый из списка, который не test-url ни одной группы
# (запрос delay пишет историю ноды по этому адресу - url-test её читает).
DIAG_CONTROL_URLS=${DIAG_CONTROL_URLS:-"https://cp.cloudflare.com/generate_204 http://www.msftconnecttest.com/connecttest.txt http://captive.apple.com/hotspot-detect.html"}
DIAG_MAX_BODY=${DIAG_MAX_BODY:-2097152}
DIAG_REQ_TIMEOUT=${DIAG_REQ_TIMEOUT:-8}
# Поиск рабочих нод (фаза 2): на сервис - до DIAG_ALT_FOUND найденных,
# DIAG_ALT_MAX_NODES проверенных или DIAG_ALT_MAX_SEC секунд; на весь
# прогон - DIAG_TOTAL_MAX_SEC.
DIAG_ALT_FOUND=${DIAG_ALT_FOUND:-3}
DIAG_ALT_MAX_NODES=${DIAG_ALT_MAX_NODES:-15}
DIAG_ALT_MAX_SEC=${DIAG_ALT_MAX_SEC:-60}
DIAG_TOTAL_MAX_SEC=${DIAG_TOTAL_MAX_SEC:-300}
DIAG_UA=${DIAG_UA:-'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'}
# Признаки страницы блокировки - только в ответах не 2xx (обычные страницы
# Cloudflare тоже подключают /cdn-cgi/challenge-platform); у редиректа
# смотрится адрес, куда он ведёт.
DIAG_BLOCK_RE='unsupported_country|unsupported_region|not available in your (country|region)|/cdn-cgi/challenge-platform|google\.com/sorry'
DIAG_REDIR_RE='unavailable|unsupported|not[-_]available|restricted|geo[-_]?block'
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
    END { if (!done) print k "\t" v }' "$RUN/meta" > "$RUN/meta.tmp" 2>/dev/null
  mv -f "$RUN/meta.tmp" "$RUN/meta"
}

diag_write_state() {
  dawk -v mode=render -v meta="$RUN/meta" "$RUN/services.tsv" > "$RUN/state.json.tmp" 2>/dev/null \
    && mv -f "$RUN/state.json.tmp" "$RUN/state.json"
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
    { print }' "$RUN/services.tsv" > "$RUN/services.tmp" && mv -f "$RUN/services.tmp" "$RUN/services.tsv"
}

diag_cancelled() { [ -f "$RUN/cancel" ]; }

# ----- действия CGI -----

cmd_status() {
  lp=$(cat "$RUN/lock/pid" 2>/dev/null)
  if [ -d "$RUN/lock" ] && [ -n "$lp" ] && ! pid_alive "$lp"; then
    # Раннер умер, не дописав итог (перезагрузка службы, kill).
    [ -f "$RUN/meta" ] && {
      meta_set running 0; meta_set stage error
      meta_set error "Проверка прервалась неожиданно. Запустите её ещё раз."
      meta_set finished "$(date +%s)"; diag_write_state
    }
    rm -rf "$RUN/lock"
  fi
  if [ -f "$RUN/state.json" ]; then reply 200 "$(cat "$RUN/state.json")"; fi
  if [ -f "$DIAG_LAST" ]; then reply 200 "$(cat "$DIAG_LAST")"; fi
  reply 200 '{"id":"","running":false,"stage":"none","error":"","started":0,"finished":0,"current":"","total":0,"done":0,"services":[]}'
}

cmd_start() {
  [ "${REQUEST_METHOD:-GET}" = POST ] || reply 405 '{"error":"method"}'
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
  rm -f "$RUN/cancel" "$RUN/services.tsv" "$RUN/state.json" "$RUN/meta"
  : > "$RUN/services.tsv"; : > "$RUN/meta"
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

# probe URL - запрос через mixed-port; P_RC P_CODE P_MS P_CLASS P_SIG.
probe() {
  rm -f "$RUN/body"
  P_RC=0
  p_out=$(curl -s -o "$RUN/body" -w '%{http_code} %{time_total} %{redirect_url}' -m "$DIAG_REQ_TIMEOUT" \
    --max-filesize "$DIAG_MAX_BODY" -A "$DIAG_UA" -x "$PROXY" "$1" 2>/dev/null) || P_RC=$?
  # 63 - ответ больше DIAG_MAX_BODY: сервис ответил, тело не нужно
  [ "$P_RC" = 63 ] && P_RC=0
  P_CODE=${p_out%% *}; p_out=${p_out#* }
  P_MS=$(printf '%s' "${p_out%% *}" | awk '{ t = $1 + 0; if (t > 0) printf "%d", t * 1000 + 0.5 }')
  case $p_out in *' '*) P_REDIR=${p_out#* } ;; *) P_REDIR= ;; esac
  P_CLASS=$(nc_classify "$P_RC" "$P_CODE")
  P_SIG=
  case $P_CODE in
    2??) ;;
    3??) printf '%s' "$P_REDIR" | grep -q -i -E "$DIAG_REDIR_RE" && P_SIG="редирект на $P_REDIR" ;;
    *) [ -s "$RUN/body" ] && P_SIG=$(head -c 65536 "$RUN/body" | grep -o -i -E "$DIAG_BLOCK_RE" | head -n 1) ;;
  esac
  rm -f "$RUN/body"
}

# control NODE -> C_MS (пусто, если нода не ответила)
control() {
  C_MS=$(main_curl -s -m $((DIAG_REQ_TIMEOUT + 2)) \
    "http://$API_MAIN/proxies/$(urlencode "$1")/delay?url=$(urlencode "$CONTROL_URL")&timeout=$((DIAG_REQ_TIMEOUT * 1000))" 2>/dev/null \
    | sed -n 's/.*"delay":\([0-9][0-9]*\).*/\1/p')
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

reason_text() {
  # $1 - класс nc_classify, $2 - HTTP-код
  case $1 in
    ok) echo "HTTP $2" ;;
    http403|http451) echo "HTTP $2 - доступ запрещён" ;;
    *) nc_reason "$1" ;;
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
  f_url= ok_url= ok_code= ok_ms=
  set -f
  for u in $cs_urls; do
    diag_cancelled && { set +f; return; }
    probe "$u"
    # 5xx и 429 - сервис не отдал страницу: не «работает».
    case $P_CODE in 5??|429) p_bad=1 ;; *) p_bad=0 ;; esac
    if [ "$P_CLASS" = ok ] && [ -z "$P_SIG" ] && [ "$p_bad" = 0 ]; then
      [ -n "$ok_url" ] || { ok_url=$u ok_code=$P_CODE ok_ms=$P_MS; }
    elif [ -z "$f_url" ]; then
      f_url=$u f_rc=$P_RC f_code=$P_CODE f_class=$P_CLASS f_sig=$P_SIG f_ms=$P_MS
    fi
  done
  set +f
  if [ -z "$f_url" ]; then
    detail="HTTP $ok_code${ok_ms:+, $ok_ms мс}"
    if [ "$cs_kind" = direct ]; then set_verdict direct "$ok_url" "напрямую: $detail" "$ok_ms"
    else set_verdict ok "$ok_url" "$detail" "$ok_ms"; fi
    return
  fi
  if [ "$cs_kind" = direct ]; then
    set_verdict direct "$f_url" "напрямую: $(reason_text "$f_class" "$f_code")"; return
  fi
  control "$cs_end"
  diag_set_field "$cs_name" control_ms "$C_MS"
  if [ "$f_rc" = 0 ] && [ -n "$f_sig" ]; then
    case $f_sig in
      'редирект на '*) set_verdict blocked "$f_url" "HTTP $f_code, $f_sig" "$f_ms" ;;
      *) set_verdict blocked "$f_url" "HTTP $f_code, страница блокировки ($f_sig)" "$f_ms" ;;
    esac
  elif [ "$f_class" = http403 ] || [ "$f_class" = http451 ]; then
    set_verdict blocked "$f_url" "$(reason_text "$f_class" "$f_code")" "$f_ms"
  elif [ -n "$C_MS" ] || { [ -n "$f_code" ] && [ "$f_code" != 000 ]; }; then
    # Сервис ответил кодом - трафик через ноду прошёл, нода жива.
    if [ "$f_code" = 429 ]; then d="HTTP 429 - слишком много запросов"
    elif [ "$f_class" = ok ]; then d="HTTP $f_code"
    else d=$(reason_text "$f_class" "$f_code"); fi
    set_verdict suspect "$f_url" "$d; нода отвечает" "$f_ms"
  else
    set_verdict node_dead "$f_url" "$(reason_text "$f_class" "$f_code"); нода не прошла контрольный запрос"
  fi
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
    p2_row=$(DN=$p2_name awk -F'\t' '$1 == ENVIRON["DN"] { print $4 "\t" $3; exit }' "$RUN/services.tsv")
    p2_verdict=${p2_row%%"$TAB"*}; p2_node=${p2_row#*"$TAB"}
    case $p2_verdict in blocked|suspect|lb) ;; *) continue ;; esac
    [ "$p2_url" != - ] && [ -n "$p2_url" ] || continue
    [ $(( $(date +%s) - p2_t0 )) -lt "$DIAG_TOTAL_MAX_SEC" ] || return
    [ "$p2_verdict" = lb ] && p2_node=
    DN=$p2_name awk -F'\t' '$1 == ENVIRON["DN"] { print $5; exit }' "$RUN/resolved.tsv" | tr '\037' '\n' > "$RUN/cands"
    LC_ALL=C awk -f "$DIAG_AWK" -v mode=order -v exclude="$p2_node" -v min_uptime="${STABLE_MIN_UPTIME:-80}" \
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
  [ "$(awk -F'\t' '$1 == "stage" { print $2 }' "$RUN/meta")" = error ] || {
    if diag_cancelled; then meta_set stage cancelled; else meta_set stage done; fi
  }
  # Что не успели: непроверенные сервисы и не начатые поиски замены.
  awk -F'\t' -v OFS='\t' '
    $4 == "pending" { $4 = "skipped"; $6 = "Не проверено: проверку остановили" }
    ($4 == "blocked" || $4 == "suspect" || $4 == "lb") && ($9 == "" || $9 == "none") { $9 = "skipped" }
    { print }' "$RUN/services.tsv" > "$RUN/services.tmp" 2>/dev/null && mv -f "$RUN/services.tmp" "$RUN/services.tsv"
  meta_set running 0; meta_set current ""; meta_set finished "$(date +%s)"
  diag_write_state
  if cp "$RUN/state.json" "$DIAG_LAST.tmp.$$" 2>/dev/null; then
    mv -f "$DIAG_LAST.tmp.$$" "$DIAG_LAST" || rm -f "$DIAG_LAST.tmp.$$"
  fi
  rm -rf "$RUN/cands" "$RUN/order" "$RUN/work" "$RUN/proxies.json" "$RUN/group.json" "$RUN/one.groups" "$RUN/one.res" \
    "$RUN/targets.tsv" "$RUN/groups" "$RUN/resolved.tsv" "$RUN/body" "$RUN/cancel" "$RUN/lock"
  exit 0
}

cmd_runner() {
  echo $$ > "$RUN/lock/pid"
  WORK=$RUN/work
  mkdir -p "$WORK"
  [ -f "$DIAG_AWK" ] || run_fail "Не найден $DIAG_AWK - переустановите проект"
  command -v nc_classify >/dev/null 2>&1 || run_fail "Не найден $NETCHECK - переустановите проект"
  main_api_init || run_fail "Не удалось найти адрес API ядра mihomo: в config.yaml нет external-controller"
  PROXY=$(nc_proxy_url)
  [ -n "$PROXY" ] || run_fail "В config.yaml нет mixed-port, port или socks-port - не через что отправить запрос к сервису"
  main_curl -f -s -m 10 -o "$RUN/proxies.json" "http://$API_MAIN/proxies" 2>/dev/null \
    || run_fail "API ядра mihomo не отвечает ($API_MAIN). Ядро запущено?"
  CONTROL_URL=
  for cu in $DIAG_CONTROL_URLS; do
    grep -q -F "\"testUrl\":\"$cu\"" "$RUN/proxies.json" && continue
    CONTROL_URL=$cu; break
  done
  [ -n "$CONTROL_URL" ] || CONTROL_URL=${DIAG_CONTROL_URLS##* }
  overlay=
  [ -f "$CONFIG_STATE_DIR/services.tsv" ] && overlay=$CONFIG_STATE_DIR/services.tsv
  dawk -v mode=targets -v overlay_file="$overlay" "$SERVICES_DEFAULT" > "$RUN/targets.tsv" \
    || run_fail "Не удалось прочитать список сервисов ($SERVICES_DEFAULT)"
  cut -f1 "$RUN/targets.tsv" > "$RUN/groups"
  dawk -v mode=resolve -v groups_file="$RUN/groups" "$RUN/proxies.json" > "$RUN/resolved.tsv" \
    || run_fail "Не удалось разобрать ответ API ядра"
  # Строки сервисов сразу - вкладка показывает весь список «проверяется».
  awk -F'\t' -v OFS='\t' '{ print $1, $2, $3, "pending", "", "", "", "", "none", 0, 0, "" }' \
    "$RUN/resolved.tsv" > "$RUN/services.tsv"
  total=$(wc -l < "$RUN/targets.tsv" | tr -d ' ')
  meta_set total "$total"; meta_set done 0
  diag_write_state
  i=1
  while [ "$i" -le "$total" ]; do
    diag_cancelled && break
    name=$(sed -n "${i}p" "$RUN/targets.tsv" | cut -f1)
    urls=$(sed -n "${i}p" "$RUN/targets.tsv" | cut -f2)
    chain=$(sed -n "${i}p" "$RUN/resolved.tsv" | cut -f2)
    end=$(sed -n "${i}p" "$RUN/resolved.tsv" | cut -f3)
    kind=$(sed -n "${i}p" "$RUN/resolved.tsv" | cut -f4)
    meta_set current "Проверяю $name ($i из $total)"
    diag_write_state
    check_service "$name" "$urls" "$kind" "$end" "$chain"
    if [ "$kind" = node ] && ! diag_cancelled && ! chain_same "$chain"; then
      # Выбор группы сменился во время проверки - один раз через новую ноду.
      if main_curl -f -s -m 10 -o "$RUN/proxies.json" "http://$API_MAIN/proxies" 2>/dev/null; then
        resolve_one "$name"
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
  start) cmd_start ;;
  cancel) cmd_cancel ;;
  runner) cmd_runner ;;
  *) reply 400 '{"error":"action"}' ;;
esac
