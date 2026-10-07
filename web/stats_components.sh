#!/bin/sh
# CGI/CLI веб-раздела "Обновления", карточка "Компоненты": проверка версий
# ядра mihomo, zashboard и xkeen и обновление ядра/zashboard через API
# mihomo. Ставится install.sh в $DIR/stats_components.sh, stats_httpd.py
# запускает его оттуда; cron-проверка проекта (stats_update.sh check) зовёт
# "check cron" этого же скрипта. Спецификация:
# docs/superpowers/specs/2026-10-07-components-update-design.md
#
# Действие приходит в MST_COMPONENTS_ACTION (из API_ROUTES stats_httpd.py)
# или первым позиционным аргументом при прямом запуске:
#   check  [источник]  POST - проверить версии, записать components.json
#   status             GET  - components.json, состояние и журнал обновления
#   apply  ?name=      POST - обновить mihomo или zashboard (xkeen не обновляется):
#                          фоновое задание, состояние - components-job.json,
#                          ход - components-job.log; общий с редактором конфига
#                          замок CONFIGEDIT_LOCK, один apply за раз
set -eu

DIR=${DIR:-/opt/etc/mihomo-speedtest}
MIHOMO_DIR=${MIHOMO_DIR:-/opt/etc/mihomo}
CONFIG=${CONFIG:-$MIHOMO_DIR/config.yaml}
BIN=${BIN:-/opt/sbin/mihomo}
XKEEN_BIN=${XKEEN_BIN:-/opt/sbin/xkeen}
TMPROOT=${TMPROOT:-/tmp}
STATS_UPDATE_RUNTIME_DIR=${STATS_UPDATE_RUNTIME_DIR:-/tmp/mihomo-speedtest-update}
COMPONENTS_FILE=$STATS_UPDATE_RUNTIME_DIR/components.json
JOB_FILE=$STATS_UPDATE_RUNTIME_DIR/components-job.json
JOB_LOG=$STATS_UPDATE_RUNTIME_DIR/components-job.log
GITHUB_API_BASE=${GITHUB_API_BASE:-https://api.github.com}
XKEEN_RELEASES_REPO=${XKEEN_RELEASES_REPO:-jameszeroX/XKeen}
# COMPONENTS_HTTP_CMD - только для тестов: команда вместо curl.
COMPONENTS_HTTP_CMD=${COMPONENTS_HTTP_CMD:-}
COMP_HTTP_TIMEOUT=${COMP_HTTP_TIMEOUT:-30}
COMPONENTS_UPGRADE_WAIT=${COMPONENTS_UPGRADE_WAIT:-60}   # сколько ждать смены версии ядра после /upgrade, с
COMPONENTS_POLL=${COMPONENTS_POLL:-2}                    # период опроса /version, с
RESTART_TIMEOUT=${RESTART_TIMEOUT:-30}
CONFIGEDIT_LOCK=${CONFIGEDIT_LOCK:-$TMPROOT/mst-configedit.lock}
WORK=
API_BASE=
CURL_CFG=
LOCK_OWNED=0
JOB_NAME=
JOB_STARTED=

cleanup() {
  [ -z "$WORK" ] || rm -rf "$WORK"
  [ "$LOCK_OWNED" != 1 ] || rm -rf "$CONFIGEDIT_LOCK"
}
trap cleanup EXIT INT TERM

json_error() {
  echo "Content-Type: application/json; charset=utf-8"
  echo
  printf '{"error":"%s"}\n' "$1"
  exit 0
}

# Печатает JSON-файл как есть или "null", если файла нет.
read_json_or_null() {
  if [ -f "$1" ]; then cat "$1"; else printf 'null'; fi
}

# Содержимое файла как одна JSON-строка или "null" (нет файла/python3).
read_log_json() {
  [ -f "$1" ] || { printf 'null'; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf 'null'; return 0; }
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
        print(json.dumps(f.read(), ensure_ascii=False))
except Exception:
    print("null")
' "$1"
}

write_json_atomic() {
  mv -f "$1" "$2"
}

# Версия из недоверенного источника: только безопасные для JSON символы.
clean_ver() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._+-' | cut -c1-40; }

# Значение строкового поля "$1" из JSON на stdin (наивно, первое вхождение).
json_field() {
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

# HTTP без секрета (GitHub).
comp_http() {
  if [ -n "$COMPONENTS_HTTP_CMD" ]; then
    "$COMPONENTS_HTTP_CMD" "$@"
  else
    curl -fsS -m "$COMP_HTTP_TIMEOUT" "$@"
  fi
}

# HTTP к API ядра: secret уходит через файл настроек curl (-K, 0600), а не
# в аргументы (их видно в ps) - и только сюда, никогда на GitHub.
comp_api() {
  if [ -n "$COMPONENTS_HTTP_CMD" ] || [ -z "$CURL_CFG" ]; then
    comp_http "$@"
  else
    curl -fsS -m "$COMP_HTTP_TIMEOUT" -K "$CURL_CFG" "$@"
  fi
}

# Адрес и secret API ядра из рабочего конфига (та же логика, что
# main_api_init() в speedtest2.sh). 0 - API_BASE готов, 1 - определить нельзя.
api_init() {
  [ -f "$CONFIG" ] || return 1
  [ -n "$WORK" ] || WORK=$(mktemp -d "$TMPROOT/mst-components.XXXXXX") || return 1
  CURL_CFG=$WORK/api.curl
  ( umask 077; : > "$CURL_CFG" ) || return 1
  ai_vals=$(awk '
    function val(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); sub(/[ \t\r]+$/, "", s)
      if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2); return s }
    /^external-controller:/ { c = val($0) }
    /^secret:/ { k = val($0) }
    END { printf "%s\t%s", c, k }' "$CONFIG") || return 1
  ai_ctl=${ai_vals%%"$(printf '\t')"*}
  ai_secret=${ai_vals#*"$(printf '\t')"}
  [ -n "$ai_ctl" ] || return 1
  ai_port=${ai_ctl##*:}
  case $ai_port in ''|*[!0-9]*) return 1 ;; esac
  case $ai_ctl in
    :*|0.0.0.0:*|'[::]:'*|'::':*) ai_host=127.0.0.1 ;;
    *) ai_host=${ai_ctl%:*} ;;
  esac
  case $ai_host in ''|*[!A-Za-z0-9.:\[\]-]*) return 1 ;; esac
  if [ -n "$ai_secret" ]; then
    case $ai_secret in *'"'*|*'\'*) return 1 ;; esac
    printf 'header = "Authorization: Bearer %s"\n' "$ai_secret" > "$CURL_CFG" || return 1
  fi
  API_BASE=$ai_host:$ai_port
}

# Последний stable-релиз репозитория $1 (тег). 1 - сеть/разбор не удались.
latest_stable() {
  ls_raw=$(comp_http "$GITHUB_API_BASE/repos/$1/releases/latest" 2>/dev/null) || return 1
  ls_tag=$(clean_ver "$(printf '%s' "$ls_raw" | json_field tag_name)")
  [ -n "$ls_tag" ] || return 1
  printf '%s' "$ls_tag"
}

# Версия alpha-сборки ядра ("alpha-<sha>") из имени ассета релиза Prerelease-Alpha.
latest_alpha() {
  la_raw=$(comp_http "$GITHUB_API_BASE/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha" 2>/dev/null) || return 1
  la_ver=$(printf '%s' "$la_raw" | sed -n 's/.*\(alpha-[0-9a-f]\{7,\}\).*/\1/p' | head -n 1)
  [ -n "$la_ver" ] || return 1
  printf '%s' "$la_ver"
}

# 0 - $2 (последняя) это обновление для $1 (установленной). Пустые версии -
# нет; равные (без ведущей v) - нет; числовые X.Y.Z сравниваются по полям
# (установленная новее - не обновление); остальные (alpha) - просто "не равны".
is_update() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  iu_a=${1#v}; iu_b=${2#v}
  [ "$iu_a" != "$iu_b" ] || return 1
  case $iu_a$iu_b in *[!0-9.]*) return 0 ;; esac
  awk -v a="$iu_a" -v b="$iu_b" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, "."); n = na > nb ? na : nb
    for (i = 1; i <= n; i++) { p = x[i] + 0; q = y[i] + 0; if (q > p) exit 0; if (q < p) exit 1 }
    exit 1 }'
}

# JSON-строка в кавычках или null.
jq_str() { if [ -n "$1" ]; then printf '"%s"' "$1"; else printf 'null'; fi; }

# ITEM: $1 installed $2 latest $3 channel $4 can_apply(true|false) $5 error
item_json() {
  ij_av=false
  is_update "$1" "$2" && ij_av=true
  printf '{"installed":%s,"latest":%s,"channel":%s,"available":%s,"can_apply":%s,"error":%s}' \
    "$(jq_str "$1")" "$(jq_str "$2")" "$(jq_str "$3")" "$ij_av" "$4" "$(jq_str "$5")"
}

item_mihomo() {
  im_inst=; im_latest=; im_chan=stable; im_err=
  if api_init && im_raw=$(comp_api "http://$API_BASE/version" 2>/dev/null); then
    im_inst=$(clean_ver "$(printf '%s' "$im_raw" | json_field version)")
  fi
  [ -n "$im_inst" ] || im_err="ядро не отвечает: версия неизвестна"
  case $im_inst in alpha*) im_chan=alpha ;; esac
  if [ "$im_chan" = alpha ]; then
    im_latest=$(latest_alpha) || im_latest=
  else
    im_latest=$(latest_stable MetaCubeX/mihomo) || im_latest=
  fi
  [ -n "$im_latest" ] || [ -n "$im_err" ] || im_err="не удалось получить последнюю версию с GitHub"
  item_json "$im_inst" "$im_latest" "$im_chan" true "$im_err"
}

item_zashboard() {
  iz_inst=$(clean_ver "$(cat "$MIHOMO_DIR/zash/.mst-version" 2>/dev/null | head -n 1)") || iz_inst=
  iz_err=
  iz_latest=$(latest_stable Zephyruso/zashboard) || iz_latest=
  [ -n "$iz_latest" ] || iz_err="не удалось получить последнюю версию с GitHub"
  item_json "$iz_inst" "$iz_latest" "" true "$iz_err"
}

item_xkeen() {
  ix_inst=$("$XKEEN_BIN" -v 2>&1 </dev/null | awk '{ if (match($0, /[0-9]+(\.[0-9]+)+/)) { print substr($0, RSTART, RLENGTH); exit } }') || ix_inst=
  ix_err=
  ix_latest=$(latest_stable "$XKEEN_RELEASES_REPO") || ix_latest=
  [ -n "$ix_latest" ] || ix_err="не удалось получить последнюю версию с GitHub"
  item_json "$ix_inst" "$ix_latest" "" false "$ix_err"
}

cmd_check() {
  cc_source=${1:-button}
  mkdir -p "$STATS_UPDATE_RUNTIME_DIR" 2>/dev/null || true
  cc_tmp=$STATS_UPDATE_RUNTIME_DIR/.components.$$
  {
    printf '{"schema_version":1,"checked_at":"%s","source":"%s","items":{' "$(date '+%Y-%m-%d %H:%M:%S')" "$cc_source"
    printf '"mihomo":%s,' "$(item_mihomo)"
    printf '"zashboard":%s,' "$(item_zashboard)"
    printf '"xkeen":%s}}\n' "$(item_xkeen)"
  } > "$cc_tmp"
  write_json_atomic "$cc_tmp" "$COMPONENTS_FILE"
  cat "$COMPONENTS_FILE"
}

cmd_status() {
  printf '{"components":%s,"job":%s,"log":%s}\n' \
    "$(read_json_or_null "$COMPONENTS_FILE")" "$(read_json_or_null "$JOB_FILE")" "$(read_log_json "$JOB_LOG")"
}

# ----- обновление (apply) -----

reply_status() {
  # $1 = HTTP-статус, $2 = код ошибки
  echo "Status: $1"
  echo "Content-Type: application/json; charset=utf-8"
  echo
  printf '{"error":"%s"}\n' "$2"
  exit 0
}

# Замок общий с редактором конфига и командами XKeen (CONFIGEDIT_LOCK, pid
# внутри): пока ядро обновляется, конфиг не применяется и наоборот. Мёртвый
# замок снимается. 0 - взят, 1 - занят живым процессом.
take_lock() {
  if ! mkdir "$CONFIGEDIT_LOCK" 2>/dev/null; then
    tl_old=$(cat "$CONFIGEDIT_LOCK/pid" 2>/dev/null || true)
    case $tl_old in
      ''|*[!0-9]*) ;;
      *) if kill -0 "$tl_old" 2>/dev/null; then return 1; fi ;;
    esac
    rm -rf "$CONFIGEDIT_LOCK"
    mkdir "$CONFIGEDIT_LOCK" 2>/dev/null || return 1
  fi
  echo $$ > "$CONFIGEDIT_LOCK/pid" || true
}

# Команда с ограничением по времени, вывод в /dev/null (xkeen -restart
# запускает демон mihomo - унаследованный stdout держал бы ответ открытым).
bounded() {
  bd_limit=$1; shift
  ( exec "$@" ) > /dev/null 2>&1 < /dev/null &
  bd_pid=$!
  bd_waited=0
  while kill -0 "$bd_pid" 2>/dev/null; do
    if [ "$bd_waited" -ge "$bd_limit" ]; then kill "$bd_pid" 2>/dev/null || true; return 124; fi
    sleep 1; bd_waited=$((bd_waited + 1))
  done
  wait "$bd_pid"
}

jlog() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$JOB_LOG" 2>/dev/null || true; }

# $1 = running|done|error, $2 = текст ошибки или пусто
write_job() {
  wj_fin=null; wj_err=null
  case $1 in done|error) wj_fin="\"$(date '+%Y-%m-%d %H:%M:%S')\"" ;; esac
  if [ -n "$2" ]; then wj_err=$(printf '%s' "$2" | tr -d '"\\' | tr '\n' ' '); wj_err="\"$wj_err\""; fi
  wj_tmp=$STATS_UPDATE_RUNTIME_DIR/.components-job.$$
  printf '{"schema_version":1,"name":"%s","state":"%s","started_at":"%s","finished_at":%s,"error":%s}\n' \
    "$JOB_NAME" "$1" "$JOB_STARTED" "$wj_fin" "$wj_err" > "$wj_tmp"
  write_json_atomic "$wj_tmp" "$JOB_FILE"
}

job_fail() {
  jlog "ОШИБКА: $1"
  write_job error "$1"
  exit 1
}

# Версия ядра из /version или пусто.
core_version() {
  cv_raw=$(comp_api "http://$API_BASE/version" 2>/dev/null) || return 0
  clean_ver "$(printf '%s' "$cv_raw" | json_field version)"
}

worker_zashboard() {
  jlog "Обновляю zashboard (POST /upgrade/ui)"
  comp_api -X POST "http://$API_BASE/upgrade/ui" > /dev/null 2>&1 || job_fail "ядро не приняло обновление zashboard (POST /upgrade/ui)"
  if [ -z "$(ls -A "$MIHOMO_DIR/zash" 2>/dev/null)" ]; then
    job_fail "после обновления каталог $MIHOMO_DIR/zash пуст"
  fi
  wz_ver=$(latest_stable Zephyruso/zashboard) || wz_ver=
  [ -z "$wz_ver" ] || printf '%s\n' "$wz_ver" > "$MIHOMO_DIR/zash/.mst-version"
  jlog "zashboard обновлён${wz_ver:+ до $wz_ver}"
}

worker_mihomo() {
  [ -x "$BIN" ] || job_fail "mihomo не найден: $BIN"
  jlog "Проверяю текущий конфиг: mihomo -t"
  if ! "$BIN" -t -d "$MIHOMO_DIR" -f "$CONFIG" > "$WORK/t.log" 2>&1 < /dev/null; then
    tail -n 10 "$WORK/t.log" | while IFS= read -r wm_l; do jlog "  | $wm_l"; done
    job_fail "текущий конфиг не проходит mihomo -t - обновление ядра не начато"
  fi
  wm_old=$(core_version)
  cp -p "$BIN" "$BIN.mst-bak" || job_fail "не удалось сохранить копию ядра $BIN.mst-bak"
  jlog "Копия ядра: $BIN.mst-bak. Запускаю обновление (POST /upgrade), сейчас: ${wm_old:-неизвестно}"
  wm_rc=0
  comp_api -X POST "http://$API_BASE/upgrade" > /dev/null 2>&1 || wm_rc=$?
  if [ "$wm_rc" = 22 ]; then
    rm -f "$BIN.mst-bak"
    job_fail "обновление ядра недоступно: ядро отклонило POST /upgrade (сборка без поддержки или уже последняя версия)"
  fi
  [ "$wm_rc" = 0 ] || jlog "Ответ на /upgrade не получен (код $wm_rc) - ядро могло перезапуститься, жду новую версию"
  wm_waited=0; wm_new=
  while [ "$wm_waited" -lt "$COMPONENTS_UPGRADE_WAIT" ]; do
    sleep "$COMPONENTS_POLL"; wm_waited=$((wm_waited + COMPONENTS_POLL))
    wm_new=$(core_version)
    if [ -n "$wm_new" ] && [ "$wm_new" != "$wm_old" ]; then
      rm -f "$BIN.mst-bak"
      jlog "ядро обновлено до $wm_new"
      return 0
    fi
  done
  jlog "Версия ядра не сменилась за $COMPONENTS_UPGRADE_WAIT с - возвращаю прежний бинарник"
  if mv -f "$BIN.mst-bak" "$BIN"; then
    wm_rrc=0; bounded "$RESTART_TIMEOUT" "$XKEEN_BIN" -restart || wm_rrc=$?
    jlog "xkeen -restart завершился с кодом $wm_rrc"
    jlog "откат выполнен: ядро возвращено к ${wm_old:-прежней версии}"
  else
    jlog "ОШИБКА: не удалось вернуть $BIN.mst-bak - восстановите ядро по SSH"
  fi
  job_fail "ядро не обновилось за $COMPONENTS_UPGRADE_WAIT с, выполнен откат"
}

# Фоновый воркер: вызывается self-exec из cmd_apply с очищенными
# MST_COMPONENTS_ACTION/REQUEST_METHOD (иначе он снова попал бы в CGI-ветку).
# Замок уже взят cmd_apply (pid воркера записан туда же).
cmd_apply_worker() {
  LOCK_OWNED=1
  JOB_NAME=$1
  JOB_STARTED=$(date '+%Y-%m-%d %H:%M:%S')
  COMP_HTTP_TIMEOUT=120
  : > "$JOB_LOG" 2>/dev/null || true
  write_job running ""
  api_init || job_fail "ядро не отвечает: не удалось определить адрес API из $CONFIG"
  case $JOB_NAME in
    zashboard) worker_zashboard ;;
    mihomo) worker_mihomo ;;
  esac
  jlog "Пересчитываю версии"
  cmd_check worker > /dev/null 2>&1 || true
  write_job done ""
}

cmd_apply() {
  ca_name=$1
  case $ca_name in mihomo|zashboard) ;; *) reply_status 400 unknown_component ;; esac
  mkdir -p "$STATS_UPDATE_RUNTIME_DIR" 2>/dev/null || true
  take_lock || reply_status 409 busy
  JOB_NAME=$ca_name
  JOB_STARTED=$(date '+%Y-%m-%d %H:%M:%S')
  write_job running ""
  MST_COMPONENTS_ACTION= REQUEST_METHOD= sh "$0" apply-worker "$ca_name" < /dev/null > /dev/null 2>&1 &
  echo $! > "$CONFIGEDIT_LOCK/pid" || true
  echo "Content-Type: application/json; charset=utf-8"; echo
  printf '{"started":true}\n'
  exit 0
}

action=${MST_COMPONENTS_ACTION:-${1:-}}
if [ -n "${REQUEST_METHOD:-}" ]; then
  case $action:$REQUEST_METHOD in
    check:POST)
      out=$(cmd_check button)
      echo "Content-Type: application/json; charset=utf-8"; echo
      printf '%s\n' "$out"
      exit 0 ;;
    status:GET|status:HEAD)
      echo "Content-Type: application/json; charset=utf-8"; echo
      cmd_status
      exit 0 ;;
    apply:POST)
      ap_name=
      for ap_kv in $(printf '%s' "${QUERY_STRING:-}" | tr '&' ' '); do
        case $ap_kv in name=*) ap_name=${ap_kv#name=} ;; esac
      done
      cmd_apply "$ap_name" ;;
    *) json_error "unknown_action" ;;
  esac
else
  case $action in
    check) cmd_check "${2:-button}" ;;
    status) cmd_status ;;
    apply-worker) cmd_apply_worker "${2:-}" ;;
    *) echo "usage: stats_components.sh check [источник]|status" >&2; exit 2 ;;
  esac
fi
