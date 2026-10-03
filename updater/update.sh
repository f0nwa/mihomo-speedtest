#!/bin/sh
set -eu
umask 077
LC_ALL=C
export LC_ALL

DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
PLAN_AWK="$DIR/update_plan.awk"
UPDATER_VERSION=7
UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE:-https://github.com/f0nwa/mihomo-speedtest/releases/latest/download}
UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE%/}
# Канал обновлений: stable (releases/latest) или dev (наибольший тег x.y.z
# среди последних релизов любого вида, включая pre-release). См.
# read_update_channel и resolve_channel_base.
UPDATE_ENV_FILE=${UPDATE_ENV_FILE:-/opt/etc/mihomo-speedtest/speedtest2.env}
UPDATE_RELEASES_API=${UPDATE_RELEASES_API:-https://api.github.com/repos/f0nwa/mihomo-speedtest/releases?per_page=10}
UPDATE_HTTP_TIMEOUT=${UPDATE_HTTP_TIMEOUT:-15}
UPDATE_STATE_DIR=${UPDATE_STATE_DIR:-/opt/etc/mihomo-speedtest/.update}
MIHOMO_DIR=${MIHOMO_DIR:-/opt/etc/mihomo}
INSTALLED_MANIFEST_PATH=${INSTALLED_MANIFEST_PATH:-$UPDATE_STATE_DIR/installed-manifest.txt}
TMPROOT=${TMPROOT:-/tmp}

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ensure_mihomo_speedtest_symlink() {
  # Копия install.sh:ensure_mihomo_speedtest_symlink() - символическая
  # ссылка не публикуется через манифест/транзакцию (см.
  # docs/superpowers/specs/2026-09-26-mihomo-speedtest-cli-design.md,
  # раздел 3), поэтому продублирована здесь так же, как install.sh
  # дублирует has_fast_group() из uninstall.sh. Сообщения - через echo/>&2,
  # а не через say() (тот пишет в stdout): apply у некоторых вызывающих
  # (см. tests/test_update_transaction.sh) читает stdout как чистый JSON
  # результата транзакции, и любая посторонняя строка там (даже успешная)
  # ломает разбор - эта функция вызывается на КАЖДЫЙ apply независимо от
  # состава компонентов, поэтому её сообщения не могут быть на стандартном
  # выводе, в отличие от initialize_web_auth() (та молчит, если веб-компонент
  # не установлен, и это уже терпимо существующими тестами).
  target=$1
  for bindir in "${2:-/opt/sbin}" "${3:-/opt/bin}"; do
    [ -d "$bindir" ] && [ -w "$bindir" ] || continue
    link=$bindir/mihomo-speedtest
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      echo "WARN: $link уже существует и не является символической ссылкой - не трогаю, пробую следующий каталог" >&2
      continue
    fi
    current=$(readlink "$link" 2>/dev/null) || current=""
    [ "$current" = "$target" ] && return 0
    if ln -sf "$target" "$link" 2>/dev/null; then
      echo "Команда доступна как: mihomo-speedtest (симлинк в $bindir)" >&2
      return 0
    fi
  done
  echo "WARN: Не удалось создать символическую ссылку mihomo-speedtest в /opt/sbin или /opt/bin - используйте полный путь: sh $target" >&2
  return 0
}

initialize_web_auth() {
  # $DIR здесь - каталог проверенного движка обновления (bootstrap-копия
  # update.sh/update_plan.awk/update_prepare.sh/update_transaction.sh), а не
  # каталог установки: компонент web (stats_auth.py) в bootstrap не входит
  # (bootstrap_header пропускает только FILE|updater|...). Реальный
  # установленный stats_auth.py нужно искать через target_file(), которая
  # уже доступна - update_prepare.sh подключён и prepare_init выполнен до
  # вызова initialize_web_auth() в единственной точке вызова (ветка apply).
  auth_dir=$(target_file /opt/etc/mihomo-speedtest)
  auth_py=$auth_dir/stats_auth.py
  [ -f "$auth_py" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    say 'WARN: Обновление применено, но Python 3 отсутствует; веб-интерфейс не запущен'
    return 0
  fi
  if ! setup_code=$(python3 "$auth_py" initialize --state-dir "$auth_dir/.stats-auth" --runtime-dir "${STATS_AUTH_RUNTIME_DIR:-/tmp/mihomo-speedtest-auth}"); then
    say "WARN: Обновление применено, но авторизация не инициализирована; выполните sh $auth_dir/stats_auth.sh reset"
    return 0
  fi
  if [ -n "$setup_code" ]; then
    say "Одноразовый код первичной настройки: $setup_code"
    say "Откройте http://<адрес роутера>:${STATS_HTTP_PORT:-8899}/setup и задайте логин и пароль"
  fi
}
manifest_field() { awk -F= -v k="$2" '$1==k{print $2; exit}' "$1"; }
sha256_tool() {
  if command -v sha256sum >/dev/null 2>&1; then echo sha256sum
  elif command -v openssl >/dev/null 2>&1; then echo openssl
  elif command -v busybox >/dev/null 2>&1 && printf '' | busybox sha256sum >/dev/null 2>&1; then echo busybox
  else return 1; fi
}
sha256_of() {
  case $SHA_TOOL in
    sha256sum) hash_output=$(sha256sum "$1") || die 'Ошибка вычисления SHA256' ;;
    openssl) hash_output=$(openssl dgst -sha256 "$1") || die 'Ошибка вычисления SHA256' ;;
    busybox) hash_output=$(busybox sha256sum "$1") || die 'Ошибка вычисления SHA256' ;;
  esac
  hash_value=$(printf '%s\n' "$hash_output" | awk '{if ($1 ~ /^[0-9a-f]{64}$/) print $1; else if ($NF ~ /^[0-9a-f]{64}$/) print $NF}')
  [ "${#hash_value}" = 64 ] || die 'Инструмент SHA256 вернул неверный результат'
  printf '%s\n' "$hash_value"
}
safe_path() {
  path_check=$1
  case $path_check in /*) ;; *) die 'Путь должен быть абсолютным' ;; esac
  while [ "$path_check" != / ]; do
    [ ! -L "$path_check" ] || die "Символическая ссылка в управляемом пути: $path_check"
    path_check=${path_check%/*}; [ -n "$path_check" ] || path_check=/
    if [ -e "$path_check" ] && [ ! -d "$path_check" ]; then die 'Родитель пути не является каталогом'; fi
  done
}
mode_of() {
  if mode_value=$(stat -c '%a' "$1" 2>/dev/null); then :
  elif mode_value=$(stat -f '%Lp' "$1" 2>/dev/null); then :
  else
    # Минимальный BusyBox stat не имеет форматирования; POSIX ls даёт rwx.
    mode_listing=$(ls -ld "$1") || die 'Не удалось прочитать режим файла'
    mode_value=$(printf '%s\n' "$mode_listing" | awk '
      function bit(ch, kind) {
        if (ch=="-") return 0
        if (kind==1 && ch=="r") return 4
        if (kind==2 && ch=="w") return 2
        if (kind==3 && ch ~ /^[xst]$/) return 1
        if (kind==3 && ch ~ /^[ST]$/) return 0
        bad=1; return 0
      }
      NR==1 {
        bits=substr($1,2,9)
        if (length(bits)!=9 || substr($1,1,1)!="-") bad=1
        for (i=1;i<=3;i++) {
          group=0
          for (j=1;j<=3;j++) group+=bit(substr(bits,(i-1)*3+j,1),j)
          value=value*10+group
        }
        u=substr(bits,3,1); g=substr(bits,6,1); o=substr(bits,9,1)
        if (u ~ /^[sS]$/) special+=4
        if (g ~ /^[sS]$/) special+=2
        if (o ~ /^[tT]$/) special+=1
        if (u ~ /^[tT]$/ || g ~ /^[tT]$/ || o ~ /^[sS]$/) bad=1
        if (!bad) {printf "%d\n", special*1000+value; ok=1}
      }
      END {exit !ok}
    ') || die 'Не удалось разобрать режим файла'
  fi
  case $mode_value in *[!0-7]*|'') die 'Неверный режим файла' ;; esac
  printf '%s\n' "$mode_value"
}
http_get() {
  if [ -n "${UPDATE_HTTP_CMD:-}" ]; then $UPDATE_HTTP_CMD "$1"
  elif command -v curl >/dev/null 2>&1; then
    case $1 in
      https://*) curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$UPDATE_HTTP_TIMEOUT" --max-filesize "$2" "$1" ;;
      http://*) curl -fsSL --proto '=http' --proto-redir '=http' --max-redirs 0 --max-time "$UPDATE_HTTP_TIMEOUT" --max-filesize "$2" "$1" ;;
      *) return 1 ;;
    esac
  else die 'Штатная загрузка требует curl с поддержкой HTTPS'; fi
}
download_to() {
  # ulimit ограничивает запись curl и подменённого транспорта.
  # В разных shell блок равен 512/1024 байтам; фактический размер проверяем ниже.
  write_limit=$3
  # Лимит касается всех файлов процесса транспорта, включая его журнал.
  # Минимум 256 КиБ допускает небольшой журнал даже при загрузке короткого файла.
  [ "$write_limit" -ge 262144 ] || write_limit=262144
  if (ulimit -f "$(( (write_limit + 511) / 512 ))"; http_get "$1" "$3") > "$2"; then
    :
  else
    download_status=$?
    die "Не удалось скачать файл обновления (код загрузчика: $download_status).
Адрес: $1
Повторите обновление через несколько минут. Если ошибка повторится, пришлите этот вывод для диагностики."
  fi
  download_size=$(wc -c < "$2" | tr -d ' ')
  [ "$download_size" -gt 0 ] && [ "$download_size" -le "$3" ] || die 'Пустой файл или превышен лимит загрузки'
}
check_download() {
  [ "$(wc -c < "$1" | tr -d ' ')" = "$2" ] || die 'Неверный размер файла релиза'
  [ "$(sha256_of "$1")" = "$3" ] || die 'Неверная сумма SHA256 файла релиза'
}
awk_syntax() {
  # Первый BEGIN предотвращает запуск пользовательского BEGIN, первый END
  # предотвращает выполнение остальных END. Весь файл предварительно разбирается.
  printf 'BEGIN { exit 0 }\nEND { exit 0 }\n' > "$WORK/awk-guard"
  awk -f "$WORK/awk-guard" -f "$1" /dev/null >/dev/null 2>&1 || die 'Файл не прошёл проверку синтаксиса AWK'
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
      if (NF!=8 || used[$3]++ || $4!="/opt/etc/mihomo-speedtest/" $3) bad()
      if ($3!="update.sh" && $3!="update_plan.awk" && $3!="update_prepare.sh" && $3!="update_transaction.sh") bad()
      if ($5 !~ /^[0-9]+$/ || $5+0<1 || $5+0>1048576 || $6 !~ /^[0-9a-f]{64}$/) bad()
      if ($3=="update_plan.awk") {if ($7!="0644" || $8!="awk") bad()}
      else if ($7!="0755" || $8!="sh") bad()
      row[++n]=$0
    }
    END {
      if (fmt!="2" || tag !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ || tag ~ /\.\./ || n!=4 ||
          !seen["RELEASE_VERSION"] || !seen["MIN_UPDATER_VERSION"] || !seen["CONFIG_SCHEMA_VERSION"]) exit 1
      for (i=1;i<=n;i++) print row[i]
    }
  ' "$MANIFEST_TMP" > "$WORK/bootstrap-files" || die 'Несовместимый bootstrap - обновите update.sh вручную; инструкция: release/manifest-format.md'
}
pinned_base() {
  case $UPDATE_RELEASE_BASE in
    */releases/latest/download) PINNED_BASE=${UPDATE_RELEASE_BASE%/latest/download}/download/$(manifest_field "$MANIFEST_TMP" RELEASE_TAG) ;;
    */releases/download/*) check_pinned_tag; PINNED_BASE=$UPDATE_RELEASE_BASE ;;
    *) die 'Подготовка требует источник .../releases/latest/download' ;;
  esac
}
check_pinned_tag() {
  # Закреплённая база .../releases/download/<T> обязана отдавать манифест
  # именно релиза T (канал dev и дочерний bootstrap-процесс).
  case $UPDATE_RELEASE_BASE in
    */releases/download/*)
      pinned_tag=${UPDATE_RELEASE_BASE##*/releases/download/}
      [ "$(manifest_field "$MANIFEST_TMP" RELEASE_TAG)" = "$pinned_tag" ] || die 'Манифест не соответствует выбранному релизу' ;;
  esac
}
read_update_channel() {
  # Окружение важнее файла настроек; в файле действует последняя строка.
  channel=${UPDATE_CHANNEL:-}
  if [ -z "$channel" ] && [ -f "$UPDATE_ENV_FILE" ] && [ -r "$UPDATE_ENV_FILE" ]; then
    channel=$(sed -n 's/^[[:space:]]*UPDATE_CHANNEL=//p' "$UPDATE_ENV_FILE" | tail -n 1 | tr -d "\"'[:space:]")
  fi
  case $channel in dev) echo dev ;; *) echo stable ;; esac
}
resolve_channel_base() {
  # Только для dev и только пока база не закреплена: дочерние движки
  # получают уже закреплённую (экспортированную) базу и API не запрашивают.
  # Маркеры дочернего движка проверяются отдельно: родитель v6 базу не
  # экспортирует и запускает child с манифестом stable-релиза.
  [ -z "${UPDATE_BOOTSTRAP_DIR:-}${UPDATE_VERIFIED_ENGINE_DIR:-}${UPDATE_RECOVERY_ENGINE_DIR:-}" ] || return 0
  [ "$(read_update_channel)" = dev ] || return 0
  case $UPDATE_RELEASE_BASE in */releases/latest/download) ;; *) return 0 ;; esac
  download_to "$UPDATE_RELEASES_API" "$WORK/releases.json" 1048576
  # Не первый релиз по дате, а наибольший тег x.y.z среди последних
  # релизов: стабильный hotfix (1.2.1), вышедший после dev 1.3.0, не должен
  # откатывать канал dev. Теги не вида x.y.z (старые v1..v26.x) пропускаются.
  dev_tag=$(awk '
    function newer(a, b,   x, y, i) {
      split(a, x, "."); split(b, y, ".")
      for (i = 1; i <= 3; i++) if (x[i] + 0 != y[i] + 0) return x[i] + 0 > y[i] + 0
      return 0
    }
    {
      s = $0
      while (match(s, /"tag_name"[ \t]*:[ \t]*"[^"]*"/)) {
        t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        sub(/^"tag_name"[ \t]*:[ \t]*"/, "", t); sub(/"$/, "", t)
        if (t ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ && (best == "" || newer(t, best))) best = t
      }
    }
    END { if (best != "") print best }' "$WORK/releases.json")
  printf '%s\n' "$dev_tag" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || die 'Не удалось определить последний релиз канала разработки'
  UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE%/latest/download}/download/$dev_tag
  export UPDATE_RELEASE_BASE
  validate_release_base
}
bootstrap_prepare() {
  bootstrap_header
  pinned_base
  mkdir "$WORK/bootstrap"
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    download_to "$PINNED_BASE/$src" "$WORK/bootstrap/$src" "$bytes"
    check_download "$WORK/bootstrap/$src" "$bytes" "$sum"
    case $check in
      sh) sh -n "$WORK/bootstrap/$src" || die 'Неверный синтаксис bootstrap' ;;
      awk) awk_syntax "$WORK/bootstrap/$src" ;;
    esac
    chmod "$mode" "$WORK/bootstrap/$src" || die 'Не удалось задать режим bootstrap'
  done < "$WORK/bootstrap-files"
  UPDATE_PINNED_MANIFEST="$MANIFEST_TMP" UPDATE_BOOTSTRAP_DIR="$WORK/bootstrap" \
    sh "$WORK/bootstrap/update.sh" "$@"
}
cached_plan_header() {
  [ "${#plan_id}" = 64 ] || die 'Неверный plan-id'
  case $plan_id in *[!0-9a-f]*) die 'Неверный plan-id' ;; esac
  cache_plan=$TMPROOT/mst-update-plans/$plan_id
  safe_path "$cache_plan"
  for cache_file in identity.txt manifest.txt; do
    safe_path "$cache_plan/$cache_file"
    [ -f "$cache_plan/$cache_file" ] || die 'Скачанное обновление не найдено; запустите обновление заново'
    cache_bytes=$(wc -c < "$cache_plan/$cache_file" | tr -d ' ')
    [ "$cache_bytes" -le 262144 ] || die 'Повреждён подготовленный план'
  done
  [ "$(sha256_of "$cache_plan/identity.txt")" = "$plan_id" ] || die 'Повреждён идентификатор плана'
  cache_manifest_sum=$(manifest_field "$cache_plan/identity.txt" MANIFEST)
  [ "$(sha256_of "$cache_plan/manifest.txt")" = "$cache_manifest_sum" ] || die 'Повреждён манифест плана'
  cp "$cache_plan/manifest.txt" "$MANIFEST_TMP" || die 'Не удалось прочитать манифест плана'
  bootstrap_header
}
bootstrap_verify() {
  cached_plan_header
  mkdir "$WORK/bootstrap"
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    safe_path "$cache_plan/engine/$src"
    [ -f "$cache_plan/engine/$src" ] || die 'Неполный движок плана'
    [ "$(mode_of "$cache_plan/engine/$src")" = "${mode#0}" ] || die 'Изменён режим движка плана'
    cp "$cache_plan/engine/$src" "$WORK/bootstrap/$src" || die 'Не удалось прочитать движок плана'
    check_download "$WORK/bootstrap/$src" "$bytes" "$sum"
    case $check in sh) sh -n "$WORK/bootstrap/$src" || die 'Неверный синтаксис движка плана' ;; awk) awk_syntax "$WORK/bootstrap/$src" ;; esac
    chmod "$mode" "$WORK/bootstrap/$src"
  done < "$WORK/bootstrap-files"
  set -- "--$cmd" "$plan_id" "--format=$format"
  [ "$confirm_local" != 1 ] || set -- "$@" --confirm-local
  [ "$confirm_config" != 1 ] || set -- "$@" --confirm-config
  [ "$full_config_diff" != 1 ] || set -- "$@" --full-config-diff
  UPDATE_VERIFIED_ENGINE_DIR="$WORK/bootstrap" UPDATE_VERIFIED_PLAN_ID="$plan_id" \
    sh "$WORK/bootstrap/update.sh" "$@"
}
lock_plans() {
  mkdir -p "$PLANS" || die 'Не удалось создать каталог планов'
  chmod 0700 "$PLANS" || die 'Не удалось защитить каталог планов'
  safe_path "$PLANS/.lock"
  if ! mkdir "$PLANS/.lock" 2>/dev/null; then
    lock_pid=$(cat "$PLANS/.lock/pid" 2>/dev/null) || die 'Операция уже выполняется'
    case $lock_pid in *[!0-9]*|''|0) die 'Неверная блокировка операции' ;; esac
    if kill -0 "$lock_pid" 2>/dev/null; then die 'Операция уже выполняется'; fi
    # Только один процесс может удалять устаревшую блокировку.
    safe_path "$PLANS/.lock.reap"
    mkdir "$PLANS/.lock.reap" 2>/dev/null || die 'Очистка блокировки уже выполняется; проверьте .lock.reap'
    REAP_LOCK=$PLANS/.lock.reap
    printf '%s\n' "$$" > "$REAP_LOCK/pid" || die 'Не удалось записать владельца очистки'
    lock_pid=$(cat "$PLANS/.lock/pid" 2>/dev/null) || die 'Блокировка изменилась; повторите команду'
    case $lock_pid in *[!0-9]*|''|0) die 'Неверная блокировка операции' ;; esac
    if kill -0 "$lock_pid" 2>/dev/null; then die 'Операция уже выполняется'; fi
    rm -rf "$PLANS/.lock" || die 'Не удалось удалить устаревшую блокировку'
    mkdir "$PLANS/.lock" || die 'Операция уже выполняется'
  fi
  OWN_LOCK=$PLANS/.lock
  printf '%s\n' "$$" > "$OWN_LOCK/pid" || die 'Не удалось записать владельца операции'
  if [ -n "$REAP_LOCK" ]; then
    rm -rf "$REAP_LOCK" || die 'Не удалось завершить очистку блокировки'
    REAP_LOCK=
  fi
}
transaction_result() {
  case $cmd in apply) result_status=applied ;; rollback-last) result_status=rolled-back ;; recover) result_status=recovered ;; esac
  if [ "$format" = json ]; then printf '{"status":"%s"}\n' "$result_status"
  else say "Операция завершена: $result_status"; fi
}
bootstrap_recovery() {
  recovery_state=$UPDATE_STATE_DIR
  if [ -n "${UPDATE_TARGET_ROOT:-}" ]; then
    recovery_root=$(CDPATH= cd -- "$UPDATE_TARGET_ROOT" && pwd -P) || die 'Корень установки недоступен'
    case $recovery_state in /opt/*) recovery_state=$recovery_root$recovery_state ;; esac
  fi
  safe_path "$recovery_state/transaction.txt"
  if [ "$cmd" = recover ] && [ ! -e "$recovery_state/transaction.txt" ]; then
    PLANS=$TMPROOT/mst-update-plans
    safe_path "$PLANS"
    lock_plans
    [ ! -e "$recovery_state/transaction.txt" ] || die 'Состояние восстановления изменилось'
    safe_path "$recovery_state/rollback.pending"
    safe_path "$recovery_state/transaction.new"
    # До публикации первого журнала назначения ещё не менялись.
    # Прерванное создание комплекта можно явно очистить без движка и сети.
    rm -rf "$recovery_state/rollback.pending" || die 'Не удалось очистить незавершённый комплект'
    rm -f "$recovery_state/transaction.new" || die 'Не удалось очистить временный журнал'
    transaction_result
    return
  fi
  recovery_bundle=$recovery_state/rollback
  if [ -e "$recovery_state/transaction.txt" ]; then
    [ -f "$recovery_state/transaction.txt" ] || die 'Неверный журнал транзакции'
    case $(cat "$recovery_state/transaction.txt") in
      CLEANUP_PENDING)
        [ "$cmd" = recover ] || die 'Сначала выполните --recover'
        PLANS=$TMPROOT/mst-update-plans
        safe_path "$PLANS"
        lock_plans
        [ "$(cat "$recovery_state/transaction.txt")" = CLEANUP_PENDING ] || die 'Состояние восстановления изменилось'
        safe_path "$recovery_state/rollback.pending"
        # Старые файлы уже восстановлены; engine может быть частично удалён.
        rm -rf "$recovery_state/rollback.pending" || die 'Не удалось завершить очистку комплекта'
        sync || die 'Не удалось сохранить очистку комплекта'
        rm -f "$recovery_state/transaction.txt" || die 'Не удалось завершить очистку журнала'
        sync || die 'Не удалось сохранить очистку журнала'
        transaction_result
        return ;;
      APPLY_PENDING) recovery_bundle=$recovery_state/rollback.pending ;;
      COMMIT) if [ -d "$recovery_state/rollback.pending" ]; then recovery_bundle=$recovery_state/rollback.pending; fi ;;
      ROLLBACK_SAVED) : ;;
      *) die 'Неизвестный журнал транзакции; восстановление заблокировано' ;;
    esac
  fi
  safe_path "$recovery_bundle/engine-manifest.txt"
  [ -f "$recovery_bundle/engine-manifest.txt" ] || die 'Комплект восстановления не найден'
  [ "$(wc -c < "$recovery_bundle/engine-manifest.txt" | tr -d ' ')" -le 262144 ] || die 'Повреждён манифест восстановления'
  cp "$recovery_bundle/engine-manifest.txt" "$MANIFEST_TMP"
  bootstrap_header
  mkdir "$WORK/recovery-engine"
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    safe_path "$recovery_bundle/engine/$src"
    [ -f "$recovery_bundle/engine/$src" ] || die 'Неполный движок восстановления'
    [ "$(mode_of "$recovery_bundle/engine/$src")" = "${mode#0}" ] || die 'Изменён режим движка восстановления'
    cp "$recovery_bundle/engine/$src" "$WORK/recovery-engine/$src" || die 'Не удалось прочитать движок восстановления'
    check_download "$WORK/recovery-engine/$src" "$bytes" "$sum"
    case $check in sh) sh -n "$WORK/recovery-engine/$src" || die 'Неверный синтаксис recovery-engine' ;; awk) awk_syntax "$WORK/recovery-engine/$src" ;; esac
    chmod "$mode" "$WORK/recovery-engine/$src"
  done < "$WORK/bootstrap-files"
  [ -f "$WORK/recovery-engine/update_transaction.sh" ] || die 'Движок не поддерживает транзакции'
  UPDATE_RECOVERY_ENGINE_DIR="$WORK/recovery-engine" \
    sh "$WORK/recovery-engine/update.sh" "--$cmd" "--format=$format"
}
usage() {
  cat <<'HELP'
Использование:
  update.sh --check
  update.sh --plan [--components=id1,id2,...] [--format=text|json]
  update.sh --prepare [--components=id1,id2,...] [--format=text|json]
  update.sh --verify-plan <plan-id> [--confirm-local] [--confirm-config] [--format=text|json]
  update.sh --show-config-diff <plan-id> [--full-config-diff] [--format=text|json]
  update.sh --discard-plan <plan-id>
  update.sh --apply <plan-id> [--confirm-local] [--confirm-config] [--format=text|json]
  update.sh --rollback-last [--format=text|json]
  update.sh --recover [--format=text|json]
HELP
}
cmd=plan
format=text
components=
plan_id=
confirm_local=0
confirm_config=0
full_config_diff=0
command_seen=0
while [ $# -gt 0 ]; do
  case $1 in
    --check|--plan|--prepare|--verify-plan|--discard-plan|--show-config-diff|--apply|--rollback-last|--recover)
      [ "$command_seen" = 0 ] || die 'Задайте один режим'
      command_seen=1; cmd=${1#--}
      case $cmd in verify-plan|discard-plan|show-config-diff|apply) shift; [ $# -gt 0 ] || die 'Не задан plan-id'; plan_id=$1 ;; esac ;;
    --format=text|--format=json) format=${1#--format=} ;;
    --components=*) components=${1#--components=} ;;
    --confirm-local) confirm_local=1 ;;
    --confirm-config) confirm_config=1 ;;
    --full-config-diff) full_config_diff=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die 'Неизвестный аргумент' ;;
  esac
  shift
done
case $cmd in
  verify-plan|discard-plan|show-config-diff|apply|rollback-last|recover) [ -z "$components" ] || die 'Выбор компонентов уже закреплён в plan-id' ;;
esac
if [ "$confirm_local" = 1 ] && [ "$cmd" != verify-plan ] && [ "$cmd" != apply ]; then die '--confirm-local применяется только при --verify-plan/--apply'; fi
if [ "$confirm_config" = 1 ] && [ "$cmd" != verify-plan ] && [ "$cmd" != apply ]; then die '--confirm-config применяется только при --verify-plan/--apply'; fi
if [ "$full_config_diff" = 1 ] && [ "$format" = json ]; then die 'Полный diff допускается только в текстовом формате'; fi
if [ "$full_config_diff" = 1 ] && [ "$cmd" != show-config-diff ]; then die '--full-config-diff применяется только при --show-config-diff'; fi
case $UPDATE_HTTP_TIMEOUT in *[!0-9]*|'') die 'Неверный таймаут загрузки' ;; esac
[ "$UPDATE_HTTP_TIMEOUT" -gt 0 ] || die 'Неверный таймаут загрузки'
validate_release_base() {
  case $UPDATE_RELEASE_BASE in *'@'*|*'|'*|*'?'*|*'#'*|*[[:space:]]*|*[[:cntrl:]]*) die 'Неверный URL источника' ;; esac
  url_authority=${UPDATE_RELEASE_BASE#*://}; url_authority=${url_authority%%/*}
  [ -n "$url_authority" ] || die 'Неверный URL источника'
  case $UPDATE_RELEASE_BASE in
    https://*) : ;;
    http://*)
      case $url_authority in localhost:*|127.0.0.1:*) ;; *) die 'HTTP допускается только для локального сервера' ;; esac
      url_port=${url_authority##*:}
      case $url_port in *[!0-9]*|'') die 'Неверный порт локального сервера' ;; esac
      [ "${#url_port}" -le 5 ] && [ "$url_port" -ge 1 ] && [ "$url_port" -le 65535 ] || die 'Неверный порт локального сервера' ;;
    *) die 'Источник требует HTTPS' ;;
  esac
}
# Исходная база проверяется до любых сетевых запросов (включая API канала
# dev); итоговая база канала dev проверяется повторно в resolve_channel_base.
validate_release_base
TMPROOT=$(CDPATH= cd -- "$TMPROOT" && pwd -P) || die 'TMPROOT недоступен'
case $TMPROOT in /opt|/opt/*|/) die 'Рабочий каталог должен находиться во временном разделе' ;; esac
WORK=$(mktemp -d "$TMPROOT/mst-update-work.XXXXXX")
KEEP_WORK=0
OWN_LOCK=
REAP_LOCK=
cleanup() {
  [ -z "${CONFIG_CHECK_PID:-}" ] || kill "$CONFIG_CHECK_PID" 2>/dev/null || :
  [ -z "${CONFIG_WATCHDOG_PID:-}" ] || kill "$CONFIG_WATCHDOG_PID" 2>/dev/null || :
  [ "$KEEP_WORK" = 1 ] || rm -rf "$WORK"
  [ -z "$OWN_LOCK" ] || rm -rf "$OWN_LOCK"
  [ -z "$REAP_LOCK" ] || rm -rf "$REAP_LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
MANIFEST_TMP=$WORK/manifest.txt
# Канал dev закрепляет базу на наибольшем теге x.y.z среди последних
# релизов GitHub (включая pre-release).
# Команды без загрузки релиза (discard-plan, rollback-last, recover) не трогаем.
case $cmd in check|plan|prepare|verify-plan|show-config-diff|apply) resolve_channel_base ;; esac
case $cmd in
  discard-plan)
    . "$DIR/update_prepare.sh"
    prepare_init
    discard_plan
    exit 0 ;;
  rollback-last|recover)
    SHA_TOOL=$(sha256_tool) || die 'Не найден инструмент SHA256'
    if [ -z "${UPDATE_RECOVERY_ENGINE_DIR:-}" ]; then bootstrap_recovery; exit 0; fi
    [ "$UPDATE_RECOVERY_ENGINE_DIR" = "$DIR" ] || die 'Неверный recovery-engine'
    . "$DIR/update_prepare.sh"
    prepare_init
    lock_plans
    . "$DIR/update_transaction.sh"
    if [ "$cmd" = recover ]; then transaction_recover; else transaction_rollback; fi
    transaction_result
    exit 0 ;;
  verify-plan|show-config-diff|apply)
    SHA_TOOL=$(sha256_tool) || die 'Не найден инструмент SHA256'
    if [ -z "${UPDATE_VERIFIED_ENGINE_DIR:-}" ]; then bootstrap_verify; exit 0; fi
    [ "$UPDATE_VERIFIED_ENGINE_DIR" = "$DIR" ] && [ "${UPDATE_VERIFIED_PLAN_ID:-}" = "$plan_id" ] || die 'Неверный движок проверки'
    cached_plan_header
    while IFS='|' read -r kind cid src dest bytes sum mode check; do
      [ ! -L "$DIR/$src" ] || die 'Символическая ссылка в движке проверки'
      check_download "$DIR/$src" "$bytes" "$sum"
    done < "$WORK/bootstrap-files"
    . "$DIR/update_prepare.sh"
    prepare_init
    # Прогресс-строки в этом блоке - см. комментарий у "Подготовка
    # обновления" выше (мини консоль /updates, задача веб-редизайна):
    # каждая - отдельная команда, ничего не гейтит, только диагностика.
    if [ "$cmd" = apply ]; then echo 'Проверка скачанного обновления...' >&2; fi
    verify_plan
    if [ "$cmd" = show-config-diff ]; then show_config_diff; fi
    if [ "$cmd" = apply ]; then
      echo 'Применение обновления: резервное копирование и запись файлов...' >&2
      . "$DIR/update_transaction.sh"
      transaction_apply
      echo 'Обновление установлено, финальные шаги...' >&2
      transaction_result
      ensure_mihomo_speedtest_symlink "$(target_file /opt/etc/mihomo-speedtest)/mihomo-speedtest.sh"
      initialize_web_auth
    fi
    exit 0 ;;
  *)
    if [ "$cmd" = prepare ] && [ -n "${UPDATE_BOOTSTRAP_DIR:-}" ]; then
      [ -f "${UPDATE_PINNED_MANIFEST:-}" ] && [ ! -L "$UPDATE_PINNED_MANIFEST" ] || die 'Отсутствует закреплённый манифест'
      cp "$UPDATE_PINNED_MANIFEST" "$MANIFEST_TMP"
    else
      download_to "$UPDATE_RELEASE_BASE/manifest.txt" "$MANIFEST_TMP" 262144
      check_pinned_tag
    fi ;;
esac
if [ "$cmd" = prepare ]; then
  SHA_TOOL=$(sha256_tool) || die 'Не найден инструмент SHA256'
  if [ -z "${UPDATE_BOOTSTRAP_DIR:-}" ]; then
    # Отдельная строка, а не хвостовая часть "&&"/"||" - мини консоль
    # раздела /updates (задача веб-редизайна) читает это через stderr
    # родительского процесса stats_update.sh (job.log); в stdout при
    # --format=json ничего не попадает.
    echo 'Подготовка обновления: загрузка файлов релиза...' >&2
    # Передаём только фиксированные, уже разобранные CLI-аргументы.
    bootstrap_prepare --prepare "--components=$components" "--format=$format"
    exit 0
  fi
  # Не подключаем helper, пока его сумма не сверена с закреплённым манифестом.
  [ "$UPDATE_BOOTSTRAP_DIR" = "$DIR" ] || die 'Неверный каталог bootstrap'
  bootstrap_header
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    [ ! -L "$DIR/$src" ] || die 'Символическая ссылка в bootstrap'
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
  # Версия показывается именем релиза (тегом), номер - в скобках.
  if [ -f "$INSTALLED_MANIFEST_PATH" ]; then installed_version=$(manifest_field "$INSTALLED_MANIFEST_PATH" RELEASE_VERSION); fi
  if [ -n "$installed_version" ]; then
    installed_tag=$(manifest_field "$INSTALLED_MANIFEST_PATH" RELEASE_TAG)
    say "Установлена версия релиза: ${installed_tag:-v$installed_version} (номер $installed_version)"
  else say 'Установленный релиз не отслеживается update.sh'; fi
  release_tag=$(manifest_field "$MANIFEST_TMP" RELEASE_TAG)
  say "Доступна версия релиза: ${release_tag:-v$(manifest_field "$MANIFEST_TMP" RELEASE_VERSION)} (номер $(manifest_field "$MANIFEST_TMP" RELEASE_VERSION), формат манифеста $(manifest_field "$MANIFEST_TMP" FORMAT_VERSION))"
  exit 0
fi
SHA_TOOL=$(sha256_tool) || die 'Не найден инструмент SHA256'
. "$DIR/update_prepare.sh"
prepare_init
assert_no_transaction
build_snapshot
# --plan: установленная версия новее манифеста (переключение dev -> stable)
# - то же дружелюбное сообщение, что и при подготовке; веб-проверка
# показывает ошибку --plan вместо кнопки "Обновить". --check остаётся
# информационным.
if [ "$cmd" = plan ]; then check_release_not_older; fi
if [ "$cmd" = prepare ]; then prepare_files; fi
print_plan
