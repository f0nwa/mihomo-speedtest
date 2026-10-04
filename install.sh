#!/bin/sh
# Устанавливает speedtest2 на роутере: извлекает SOURCES и фильтры из
# config.yaml, калибрует порог скорости, ставит cron и делает пробный запуск.
# Запускать из каталога, где рядом лежат speedtest2.sh, prep.awk, providers.awk.
set -eu

DIR=${DIR:-/opt/etc/mihomo-speedtest}
BIN=${BIN:-/opt/sbin/mihomo}
API_MAIN=${API_MAIN:-127.0.0.1:9090}
SPEED_URL=${SPEED_URL:-"https://speed.cloudflare.com/__down?bytes=10485760"}
TMPROOT=${TMPROOT:-/tmp}
# По умолчанию - $DIR, а не текущий каталог: при "curl ... | sh" (см. ниже)
# рядом со скриптом физически ничего нет, а единственный осмысленный
# каталог, где могут (или должны появиться) остальные файлы проекта - это
# DIR, целевой каталог установки. При обычном сценарии (ручной перенос
# файлов, "cd /opt/etc/mihomo && sh install.sh") DIR и "." совпадают, так
# что поведение не меняется.
SELFDIR=${SELFDIR:-$DIR}
MIHOMO_DIR=${MIHOMO_DIR:-/opt/etc/mihomo}
CONFIG=${CONFIG:-$MIHOMO_DIR/config.yaml}
# Полные инструменты проекта, нужные для планирования обновления (тот же
# список используется ниже в install_files()).
PROJECT_TOOLS="migrate_config.sh migrate_config.awk config_diff.awk install.sh uninstall.sh version_check.sh setup.sh detect_ua.sh render_config.awk existing_config.awk config.example.yaml update.sh update_plan.awk update_prepare.sh update_transaction.sh providers.awk mihomo-speedtest.sh"
# Единый полный список всех файлов проекта под $SELFDIR/$DIR - источник
# истины и для триггера bootstrap ниже, и для финальной проверки полноты
# в main() (было два отдельных списка с двумя разными файлами-часовыми -
# см. CHANGELOG: install.sh не замечал недостающий migrate_config.sh,
# т.к. триггер смотрел только на version_check.sh/speedtest2.sh).
ALL_PROJECT_FILES="$PROJECT_TOOLS speedtest2.sh prep.awk render_stats.awk stats_cgi.sh stats_run.sh stats_update.sh stats_config.sh stats_xkeen.sh stats_httpd.py stats_auth.py stats_auth.sh stats_index.html stats_style.css stats_app.js stats_app_core.js stats_app_stats.js stats_app_settings.js stats_app_updates.js stats_app_log.js stats_app_config.js stats_app_xkeen.js stats_codemirror.js stats_codemirror.css node_stats_update.awk sub_convert.awk render_progress.awk stats_service.sh stats_init.sh"
INSTALLED_SCRIPT=${INSTALLED_SCRIPT:-$DIR/speedtest2.sh}
STATS_SERVICE_DEST=${STATS_SERVICE_DEST:-$DIR/stats_service.sh}
INITD_DIR=${INITD_DIR:-/opt/etc/init.d}
INITD_SCRIPT=${INITD_SCRIPT:-$INITD_DIR/S80speedtest-stats}
UPDATE_CHECK_SCRIPT=${UPDATE_CHECK_SCRIPT:-$DIR/stats_update.sh}
# Те же дефолты, что в update.sh - единое состояние обновлятора, которым
# пользуется и install.sh (пишет installed-manifest.txt после установки),
# и update.sh, и uninstall.sh (читает его же для полного сноса).
UPDATE_STATE_DIR=${UPDATE_STATE_DIR:-$DIR/.update}
INSTALLED_MANIFEST_PATH=${INSTALLED_MANIFEST_PATH:-$UPDATE_STATE_DIR/installed-manifest.txt}

# --- Bootstrap для однострочной установки ---------------------------------
# Позволяет ставить проект командой
#   curl -fsSL https://raw.githubusercontent.com/f0nwa/mihomo-speedtest/main/install.sh | sh
# (см. README.md/docs/guide.md, "Установка с нуля"). raw.githubusercontent
# отдаёт ТОЛЬКО сам install.sh - остального набора файлов проекта рядом со
# скриптом при таком запуске нет. Блок ниже срабатывает именно в этом
# случае (и в любом другом, где рядом с install.sh не оказалось
# version_check.sh - например, незавершённый перенос файлов) и скачивает
# остальные файлы с уже опубликованного релиза на GitHub, тем же способом,
# каким их получает update.sh при последующих обновлениях: манифест
# релиза (manifest.txt) и сам контент файлов - через закреплённый тег
# релиза (PINNED_BASE = .../releases/download/<RELEASE_TAG>/<файл>), с
# проверкой размера и SHA256 каждого файла по манифесту. Отдельного
# raw.githubusercontent-канала для содержимого файлов нет: это сознательный
# выбор в пользу переиспользования уже проверенной инфраструктуры
# релизов/манифеста, а не второй параллельный механизм раздачи (см.
# update.sh:bootstrap_header/pinned_base/bootstrap_prepare - тот же
# протокол, только там он берёт из манифеста строки FILE только
# компонента updater, а здесь - все компоненты, т.к. ставится весь проект).
#
# Обычный сценарий (файлы перенесены на роутер вручную, см. README) блок
# не трогает: version_check.sh уже лежит рядом, проверка ниже сразу
# проходит, никакой сети. Также не запускается при подключении install.sh
# как библиотеки (INSTALL_LIB_ONLY=1, см. tests/test_install.sh) - сорсинг
# файла не должен иметь сетевых побочных эффектов.

bootstrap_manifest_field() { awk -F= -v k="$2" '$1==k{print $2; exit}' "$1"; }

bootstrap_sha256_tool() {
  if command -v sha256sum >/dev/null 2>&1; then echo sha256sum
  elif command -v openssl >/dev/null 2>&1; then echo openssl
  elif command -v busybox >/dev/null 2>&1 && printf '' | busybox sha256sum >/dev/null 2>&1; then echo busybox
  else return 1; fi
}

bootstrap_sha256_of() {
  case $BOOTSTRAP_SHA_TOOL in
    sha256sum) hash_output=$(sha256sum "$1") || return 1 ;;
    openssl) hash_output=$(openssl dgst -sha256 "$1") || return 1 ;;
    busybox) hash_output=$(busybox sha256sum "$1") || return 1 ;;
  esac
  hash_value=$(printf '%s
' "$hash_output" | awk '{if ($1 ~ /^[0-9a-f]{64}$/) print $1; else if ($NF ~ /^[0-9a-f]{64}$/) print $NF}')
  [ "${#hash_value}" = 64 ] || return 1
  printf '%s
' "$hash_value"
}

bootstrap_http_get() {
  # Код возврата - код curl: по нему bootstrap_download_to() объясняет
  # причину отказа (bootstrap_curl_reason). BOOTSTRAP_PROXY непуст - качаем
  # через прокси (см. bootstrap_enable_proxy); TLS при этом сквозной.
  if [ -n "${UPDATE_HTTP_CMD:-}" ]; then $UPDATE_HTTP_CMD "$1"
  elif command -v curl >/dev/null 2>&1; then
    bhg_url=$1
    set -- --max-time "${UPDATE_HTTP_TIMEOUT:-30}" --max-filesize "$2"
    [ -z "${BOOTSTRAP_PROXY:-}" ] || set -- "$@" -x "$BOOTSTRAP_PROXY"
    case $bhg_url in
      https://*) curl -fsSL --proto '=https' --proto-redir '=https' "$@" "$bhg_url" 2>/dev/null ;;
      http://*) curl -fsSL --proto '=http' --proto-redir '=http' --max-redirs 0 "$@" "$bhg_url" 2>/dev/null ;;
      *) return 1 ;;
    esac
  else
    echo "Для установки нужен curl с поддержкой HTTPS" >&2
    return 1
  fi
}

bootstrap_curl_reason() {
  case $1 in
    6) echo "не удалось определить адрес сервера (DNS)" ;;
    7) echo "не удалось подключиться к серверу" ;;
    28) echo "сервер не ответил вовремя (таймаут)" ;;
    35|52|56) echo "соединение оборвано (часто так выглядит блокировка у провайдера)" ;;
    51|58|60|77) echo "ошибка проверки сертификата (проверьте время на роутере и пакет ca-certificates)" ;;
    22) echo "сервер вернул ошибку HTTP (нет файла или лимит запросов GitHub)" ;;
    63) echo "файл больше заявленного размера" ;;
    5) echo "не удалось определить адрес прокси" ;;
    97) echo "прокси отказал в соединении" ;;
    *) echo "ошибка загрузки (код curl $1)" ;;
  esac
}

bootstrap_fetch_once() {
  write_limit=$3
  [ "$write_limit" -ge 262144 ] || write_limit=262144
  bfo_rc=0
  (ulimit -f "$(( (write_limit + 511) / 512 ))"; bootstrap_http_get "$1" "$3") > "$2" || bfo_rc=$?
  return "$bfo_rc"
}

bootstrap_retryable() {
  # Повторять имеет смысл только быстрые сетевые сбои: DNS, отказ в
  # соединении, обрыв. Таймаут (28) уже ждал UPDATE_HTTP_TIMEOUT - вместо
  # повтора сразу переходим к обходу через mihomo. Ошибки HTTP, размера и
  # сертификата повтор не исправит.
  case $1 in 6|7|35|52|56) return 0 ;; *) return 1 ;; esac
}

bootstrap_fetch_retry() {
  # До INSTALL_RETRIES попыток (по умолчанию 3) с паузой INSTALL_RETRY_DELAY
  # секунд (по умолчанию 2), растущей с номером попытки.
  bfr_max=${INSTALL_RETRIES:-3}
  case $bfr_max in ''|*[!0-9]*|0) bfr_max=1 ;; esac
  bfr_try=1
  while :; do
    bfr_rc=0
    bootstrap_fetch_once "$1" "$2" "$3" || bfr_rc=$?
    [ "$bfr_rc" -ne 0 ] || return 0
    bootstrap_retryable "$bfr_rc" && [ "$bfr_try" -lt "$bfr_max" ] || return "$bfr_rc"
    echo "Сбой загрузки ($(bootstrap_curl_reason "$bfr_rc")), повтор $((bfr_try + 1)) из $bfr_max..." >&2
    sleep $(( ${INSTALL_RETRY_DELAY:-2} * bfr_try ))
    bfr_try=$((bfr_try + 1))
  done
}

bootstrap_download_to() {
  bdt_rc=0
  bootstrap_fetch_retry "$1" "$2" "$3" || bdt_rc=$?
  if [ "$bdt_rc" -ne 0 ] && [ -z "${BOOTSTRAP_PROXY:-}" ]; then
    # Напрямую не вышло - один раз пробуем через mihomo, дальше все
    # файлы качаются через тот же прокси.
    echo "Не удалось скачать $1 напрямую: $(bootstrap_curl_reason "$bdt_rc")" >&2
    if bootstrap_enable_proxy; then
      bdt_rc=0
      bootstrap_fetch_retry "$1" "$2" "$3" || bdt_rc=$?
    else
      BOOTSTRAP_FAIL_HINT=1
      return 1
    fi
  fi
  if [ "$bdt_rc" -ne 0 ]; then
    if [ -n "${BOOTSTRAP_PROXY:-}" ]; then
      echo "Не удалось скачать $1 через прокси $BOOTSTRAP_PROXY: $(bootstrap_curl_reason "$bdt_rc")" >&2
    else
      echo "Не удалось скачать $1: $(bootstrap_curl_reason "$bdt_rc")" >&2
    fi
    BOOTSTRAP_FAIL_HINT=1
    return 1
  fi
  download_size=$(wc -c < "$2" | tr -d ' ')
  [ "$download_size" -gt 0 ] && [ "$download_size" -le "$3" ] || {
    echo "Пустой файл или превышен лимит загрузки: $1" >&2
    return 1
  }
}

# --- Обход блокировки GitHub через сам mihomo ------------------------------
# Собственный трафик роутера XKeen обычно не проксирует, и github.com /
# release-assets.githubusercontent.com может быть недоступен напрямую.
# mihomo при этом уже запущен, поэтому повторяем загрузку через него:
# 1) INSTALL_PROXY из окружения (http://..., socks5h://...) - как есть;
# 2) mixed-port / port / socks-port из config.yaml, если он уже открыт;
# 3) иначе временно открываем mixed-port через API (PATCH /configs, в
#    файл конфига не пишется) и закрываем его после загрузки
#    (bootstrap_disable_proxy). TLS через прокси сквозной, а SHA256
#    файлов сверяется по манифесту, так что безопасность та же.
BOOTSTRAP_TEMP_PORT=${INSTALL_TEMP_PROXY_PORT:-17890}

bootstrap_config_value() {
  # Однострочное значение ключа верхнего уровня config.yaml без кавычек.
  [ -f "$CONFIG" ] || return 0
  sed -n "s/^$1:[[:space:]]*['\"]\{0,1\}\([^'\"#[:space:]]*\).*/\1/p" "$CONFIG" | head -n 1
}

bootstrap_api_init() {
  bai_ctl=$(bootstrap_config_value external-controller)
  [ -n "$bai_ctl" ] || bai_ctl=$API_MAIN
  bai_port=${bai_ctl##*:}
  case $bai_port in ''|*[!0-9]*) return 1 ;; esac
  BOOTSTRAP_API="127.0.0.1:$bai_port"
  BOOTSTRAP_API_SECRET=$(bootstrap_config_value secret)
}

bootstrap_api_patch() {
  # $1 - тело JSON. secret передаём через -K из stdin, не в argv.
  command -v curl >/dev/null 2>&1 || return 1
  if [ -n "${BOOTSTRAP_API_SECRET:-}" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$BOOTSTRAP_API_SECRET" |
      curl -fsS -m 5 -K - -X PATCH -H 'Content-Type: application/json' \
        -d "$1" "http://$BOOTSTRAP_API/configs" >/dev/null 2>&1
  else
    curl -fsS -m 5 -X PATCH -H 'Content-Type: application/json' \
      -d "$1" "http://$BOOTSTRAP_API/configs" >/dev/null 2>&1
  fi
}

bootstrap_enable_proxy() {
  [ -z "${BOOTSTRAP_PROXY_TRIED:-}" ] || return 1
  BOOTSTRAP_PROXY_TRIED=1
  if [ -n "${INSTALL_PROXY:-}" ]; then
    BOOTSTRAP_PROXY=$INSTALL_PROXY
    echo "Пробую через прокси из INSTALL_PROXY: $BOOTSTRAP_PROXY" >&2
    return 0
  fi
  # INSTALL_PROXY_FALLBACK=0 - не трогать mihomo (тесты, ручной отказ).
  [ "${INSTALL_PROXY_FALLBACK:-1}" != 0 ] || return 1
  for bep_key in mixed-port port socks-port; do
    bep_port=$(bootstrap_config_value "$bep_key")
    case $bep_port in ''|0|*[!0-9]*) continue ;; esac
    case $bep_key in
      socks-port) BOOTSTRAP_PROXY="socks5h://127.0.0.1:$bep_port" ;;
      *) BOOTSTRAP_PROXY="http://127.0.0.1:$bep_port" ;;
    esac
    echo "Пробую через mihomo ($bep_key $bep_port из конфига)" >&2
    return 0
  done
  bootstrap_api_init || return 1
  if bootstrap_api_patch "{\"mixed-port\": $BOOTSTRAP_TEMP_PORT}"; then
    BOOTSTRAP_TEMP_PROXY_OPEN=1
    BOOTSTRAP_PROXY="http://127.0.0.1:$BOOTSTRAP_TEMP_PORT"
    echo "Пробую через mihomo: временно открыт mixed-port $BOOTSTRAP_TEMP_PORT (только на время загрузки)" >&2
    sleep 1
    return 0
  fi
  echo "Обойти через mihomo не вышло: API $BOOTSTRAP_API недоступен или mihomo не запущен" >&2
  return 1
}

bootstrap_disable_proxy() {
  [ -n "${BOOTSTRAP_TEMP_PROXY_OPEN:-}" ] || return 0
  bootstrap_api_patch '{"mixed-port": 0}' ||
    echo "Не удалось закрыть временный mixed-port $BOOTSTRAP_TEMP_PORT - закроется при перезапуске mihomo" >&2
  BOOTSTRAP_TEMP_PROXY_OPEN=
}

bootstrap_fail_hint() {
  [ -n "${BOOTSTRAP_FAIL_HINT:-}" ] || return 0
  cat >&2 <<'EOF'

Не удалось скачать релиз с GitHub. Что можно сделать:
  - в XKeen включить проксирование трафика самого роутера и проверить, что
    github.com и *.githubusercontent.com идут через стабильную ноду;
  - указать прокси вручную (например, mixed-port mihomo):
      curl -fsSL https://raw.githubusercontent.com/f0nwa/mihomo-speedtest/main/install.sh | INSTALL_PROXY=http://127.0.0.1:7890 sh
  - скопировать файлы проекта на роутер вручную (см. README.md).
EOF
}

bootstrap_check_download() {
  [ "$(wc -c < "$1" | tr -d ' ')" = "$2" ] || { echo "Неверный размер файла релиза: $1" >&2; return 1; }
  [ "$(bootstrap_sha256_of "$1")" = "$3" ] || { echo "Неверная сумма SHA256 файла релиза: $1" >&2; return 1; }
}

bootstrap_awk_syntax() {
  printf 'BEGIN { exit 0 }\nEND { exit 0 }\n' > "$BOOTSTRAP_WORK/awk-guard"
  awk -f "$BOOTSTRAP_WORK/awk-guard" -f "$1" /dev/null >/dev/null 2>&1 || {
    echo "Файл не прошёл проверку синтаксиса AWK: $1" >&2
    return 1
  }
}

bootstrap_header() {
  # Тот же протокол разбора, что update.sh:bootstrap_header, но берёт ВСЕ
  # строки FILE (все компоненты), а не только updater - первичная
  # установка ставит весь проект, а не только обновлятор.
  awk -F'|' '
    function bad(){exit 1}
    /^[A-Z_]+=/ {
      if (split($0,h,"=") != 2 || seen[h[1]]++) bad()
      if (h[1]=="FORMAT_VERSION") fmt=h[2]
      if (h[1]=="RELEASE_TAG") tag=h[2]
      if (h[1] ~ /^(RELEASE_VERSION|MIN_UPDATER_VERSION|CONFIG_SCHEMA_VERSION)$/ && h[2] !~ /^[0-9]+$/) bad()
      next
    }
    $1=="FILE" {
      if (NF!=8 || used[$3]++) bad()
      if ($3 !~ /^[A-Za-z0-9_.-]+$/) bad()
      if ($5 !~ /^[0-9]+$/ || $5+0<1 || $5+0>10485760 || $6 !~ /^[0-9a-f]{64}$/) bad()
      if ($7 !~ /^[0-7]{3,4}$/) bad()
      if ($8 !~ /^(sh|awk|py|none)$/) bad()
      row[++n]=$0
    }
    END {
      if (fmt!="2" || tag !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ || tag ~ /\.\./ || n<1 ||
          !seen["RELEASE_VERSION"] || !seen["MIN_UPDATER_VERSION"] || !seen["CONFIG_SCHEMA_VERSION"]) exit 1
      for (i=1;i<=n;i++) print row[i]
    }
  ' "$BOOTSTRAP_MANIFEST" > "$BOOTSTRAP_WORK/files" || {
    echo "Манифест релиза не прошёл проверку - установка остановлена" >&2
    return 1
  }
}

bootstrap_pinned_base() {
  case $UPDATE_RELEASE_BASE in
    */releases/latest/download)
      BOOTSTRAP_PINNED_BASE=${UPDATE_RELEASE_BASE%/latest/download}/download/$(bootstrap_manifest_field "$BOOTSTRAP_MANIFEST" RELEASE_TAG) ;;
    *) echo "Для установки нужен источник вида .../releases/latest/download" >&2; return 1 ;;
  esac
}

bootstrap_selfinstall() {
  BOOTSTRAP_SHA_TOOL=$(bootstrap_sha256_tool) || {
    echo "Не найден инструмент SHA256 (sha256sum/openssl/busybox) - установка остановлена" >&2
    return 1
  }
  bootstrap_tmproot=${TMPROOT:-/tmp}
  BOOTSTRAP_WORK=$(mktemp -d "$bootstrap_tmproot/mst-install-bootstrap.XXXXXX") || return 1
  BOOTSTRAP_MANIFEST=$BOOTSTRAP_WORK/manifest.txt

  echo "Рядом нет файлов проекта - скачиваю релиз с GitHub ($UPDATE_RELEASE_BASE)" >&2

  bootstrap_download_to "$UPDATE_RELEASE_BASE/manifest.txt" "$BOOTSTRAP_MANIFEST" 262144 || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
  bootstrap_header || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
  bootstrap_pinned_base || { rm -rf "$BOOTSTRAP_WORK"; return 1; }

  mkdir -p "$DIR" || { echo "Не удалось создать $DIR" >&2; rm -rf "$BOOTSTRAP_WORK"; return 1; }

  # Проход 1: скачать и проверить всё во временном каталоге. Ничего не
  # пишем в DIR, пока не убедимся, что весь набор цел - иначе отказ на
  # середине списка оставил бы в DIR наполовину установленный проект.
  # Счётчик N/TOTAL печатается перед каждым файлом - иначе на медленной
  # сети скачивание полного набора (см. release/components.txt) выглядит
  # как зависший скрипт: единственная строка "скачиваю релиз..." выше не
  # даёт никакой обратной связи до самого конца.
  bootstrap_total=$(wc -l < "$BOOTSTRAP_WORK/files" | tr -d ' ')
  bootstrap_idx=0
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    bootstrap_idx=$((bootstrap_idx + 1))
    echo "Скачиваю файл $bootstrap_idx/$bootstrap_total: $src" >&2
    bootstrap_download_to "$BOOTSTRAP_PINNED_BASE/$src" "$BOOTSTRAP_WORK/$src" "$bytes" || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
    bootstrap_check_download "$BOOTSTRAP_WORK/$src" "$bytes" "$sum" || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
    case $check in
      sh) sh -n "$BOOTSTRAP_WORK/$src" || { echo "Неверный синтаксис sh: $src" >&2; rm -rf "$BOOTSTRAP_WORK"; return 1; } ;;
      awk) bootstrap_awk_syntax "$BOOTSTRAP_WORK/$src" || { rm -rf "$BOOTSTRAP_WORK"; return 1; } ;;
    esac
  done < "$BOOTSTRAP_WORK/files"

  # Проход 2: весь набор проверен - переносим в DIR.
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    mv "$BOOTSTRAP_WORK/$src" "$DIR/$src" || { echo "Не удалось записать $DIR/$src" >&2; rm -rf "$BOOTSTRAP_WORK"; return 1; }
    chmod "$mode" "$DIR/$src" || { echo "Не удалось задать режим $DIR/$src" >&2; return 1; }
  done < "$BOOTSTRAP_WORK/files"

  # Тег - хвост BOOTSTRAP_PINNED_BASE (.../download/<RELEASE_TAG>), берём
  # ДО удаления временного каталога с манифестом ниже.
  bootstrap_tag=${BOOTSTRAP_PINNED_BASE##*/}

  # Сохраняем сам манифест релиза как installed-manifest.txt - тот же файл
  # и формат, что пишет update_transaction.sh после обновления (см.
  # update.sh:INSTALLED_MANIFEST_PATH). Это единый источник истины о том,
  # что реально установлено - его читает uninstall.sh при полном сносе
  # проекта, вместо отдельного захардкоженного списка. Неудача записи не
  # должна валить установку - при её отсутствии uninstall.sh просто
  # использует запасной список (см. uninstall.sh:FALLBACK_PROJECT_FILES).
  if mkdir -p "$UPDATE_STATE_DIR" 2>/dev/null; then
    bootstrap_manifest_tmp="$UPDATE_STATE_DIR/.installed-manifest.$$.tmp"
    if cp "$BOOTSTRAP_MANIFEST" "$bootstrap_manifest_tmp" 2>/dev/null; then
      chmod 0600 "$bootstrap_manifest_tmp" 2>/dev/null || true
      mv "$bootstrap_manifest_tmp" "$INSTALLED_MANIFEST_PATH" 2>/dev/null || rm -f "$bootstrap_manifest_tmp"
    fi
  fi

  rm -rf "$BOOTSTRAP_WORK"
  echo "Файлы проекта загружены и проверены (тег $bootstrap_tag)" >&2
  SELFDIR=$DIR
}

bootstrap_needed() {
  for bf in $ALL_PROJECT_FILES; do
    [ -f "$SELFDIR/$bf" ] || return 0
  done
  return 1
}

# Лёгкие действия (--stop-web/--start-web/--show-url/--version) - чисто
# локальные операции (флаг STATS_HTTP_ENABLE в speedtest2.env, чтение уже
# сохранённого installed-manifest.txt, init.d-скрипт) - им не нужен ни
# полный набор файлов проекта, ни сеть. Раньше бутстрап-проверка выше
# запускалась безусловно, до разбора аргументов (см. case в самом низу
# файла) - поэтому "mihomo-speedtest stop-web" на роутере с неполным $DIR
# неожиданно тащил весь релиз с GitHub вместо простого локального
# переключения (см. CHANGELOG).
bootstrap_skip_for_action() {
  case "${1:-}" in
    --stop-web | --start-web | --show-url | --version) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "${INSTALL_LIB_ONLY:-0}" != 1 ] && ! bootstrap_skip_for_action "${1:-}" && bootstrap_needed; then
  UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE:-https://github.com/f0nwa/mihomo-speedtest/releases/latest/download}
  UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE%/}
  [ -z "${INSTALL_PROXY:-}" ] || bootstrap_enable_proxy
  # Прерывание (Ctrl+C) не должно оставить открытым временный mixed-port.
  trap 'bootstrap_disable_proxy; exit 130' INT TERM
  bootstrap_rc=0
  bootstrap_selfinstall || bootstrap_rc=$?
  trap - INT TERM
  bootstrap_disable_proxy
  BOOTSTRAP_PROXY=
  [ "$bootstrap_rc" -eq 0 ] || {
    bootstrap_fail_hint
    echo "Автоматическая установка не удалась. Скопируйте файлы проекта на роутер вручную (см. README.md) и запустите sh install.sh снова" >&2
    exit 1
  }
fi

. "$SELFDIR/version_check.sh"

# Минимальный гео-фильтр, если в конфиге его нет: только российские ноды
# (подстроки без учёта регистра, см. prep.awk).
MIN_BLOCK='🇷🇺|Russia|Россия|RU-|RU_|Moscow|Москва|MSK|SPB|СПб'

normalize_block() {
  # BLOCK - список подстрок через | (см. prep.awk), не regex: убираем
  # пробелы вокруг | и по краям и префикс "(?i)" у кусков (след копирования
  # exclude-filter из config.yaml). Та же функция есть в web/stats_cgi.sh.
  printf '%s\n' "$1" | sed -e 's/[[:space:]]*|[[:space:]]*/|/g' \
    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e 's/^(?i)//' -e 's/|(?i)/|/g'
}

warn_regex_block() {
  # Куски BLOCK с символами регулярных выражений (\ ^ $ * + ? ( ) [ ] { }):
  # в спидтесте они ищутся буквально, так что такой кусок почти наверняка
  # ничего не отсечёт. Установку не останавливает - только предупреждает
  # (то же правило, что замечание в веб-форме, stats_app_settings.js:geoWarnings()).
  bad=$(printf '%s\n' "$1" | awk -F'|' '{
    for (i = 1; i <= NF; i++) if ($i ~ /[][\\^$*+?(){}]/) printf "  %s\n", $i
  }')
  [ -n "$bad" ] || return 0
  {
    echo "ВНИМАНИЕ: гео-фильтр спидтеста (BLOCK) - не регулярное выражение, а список"
    echo "слов через |: нода пропускается, если её имя содержит любое из них."
    echo "Эти куски похожи на регулярное выражение и будут искаться буквально,"
    echo "поэтому, скорее всего, ничего не отсекут:"
    printf '%s\n' "$bad"
    echo "Поправьте фильтр в веб-интерфейсе (Настройки -> «Какие ноды не проверять»)"
    echo "или переустановите с BLOCK='слово1|слово2' sh install.sh."
  } >&2
}

resolve_block() {
  resolve_block_raw || return 1
  BLOCK=$(normalize_block "$BLOCK")
  if [ -z "$BLOCK" ]; then
    echo "Пустой фильтр недопустим. Повторите с BLOCK='...' sh install.sh" >&2
    return 1
  fi
  warn_regex_block "$BLOCK"
  return 0
}

resolve_block_raw() {
  if [ -n "${BLOCK:-}" ]; then
    BLOCK_SOURCE="переменная окружения"
    return 0
  fi

  count=${BLOCK_COUNT:-0}

  if [ "$count" -eq 1 ]; then
    BLOCK=$BLOCK_1
    BLOCK_SOURCE="из конфига"
    return 0
  fi

  if [ "$count" -gt 1 ]; then
    echo "Найдено несколько разных гео-фильтров:" >&2
    i=1
    while [ "$i" -le "$count" ]; do
      eval "val=\$BLOCK_$i"
      echo "  $i) $val" >&2
      i=$((i + 1))
    done
    printf 'Введите номер варианта или свой фильтр: ' >&2
    read -r choice || choice=""
    case $choice in
      ''|*[!0-9]*)
        BLOCK=$choice
        BLOCK_SOURCE="введён вручную"
        ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
          eval "BLOCK=\$BLOCK_$choice"
          BLOCK_SOURCE="из конфига (вариант $choice)"
        else
          echo "Номер вне диапазона" >&2
          BLOCK=""
        fi
        ;;
    esac
    if [ -z "$BLOCK" ]; then
      echo "Пустой или неверный фильтр недопустим. Повторите с BLOCK='...' sh install.sh" >&2
      return 1
    fi
    return 0
  fi

  # Фильтра в конфиге нет (или parser его не нашёл). Не отказываем, а
  # предлагаем выбор: минимальный (только российские ноды), стандартный
  # (якорь &geofilter из config.example.yaml - тот же, что мастер setup.sh
  # пишет в новый конфиг) или свой. Enter и отсутствие ответа (нет
  # терминала) - минимальный: он всегда есть и решает главную задачу.
  default=$(default_block)
  echo "Гео-фильтр (exclude-filter) не найден в конфиге." >&2
  echo "Без него спидтест может выбрать российскую ноду, выигравшую замер по пингу." >&2
  echo "  1) минимальный - только российские ноды: $MIN_BLOCK" >&2
  if [ -n "$default" ]; then
    echo "  2) стандартный из config.example.yaml - Россия, ряд дальних стран, служебные группы" >&2
  fi
  printf 'Введите номер, свой фильтр (слова через |) или Enter для 1: ' >&2
  read -r input || { input=""; echo >&2; }
  case $input in
    ''|1)
      BLOCK=$MIN_BLOCK
      BLOCK_SOURCE="минимальный"
      ;;
    2)
      if [ -n "$default" ]; then
        BLOCK=$default
        BLOCK_SOURCE="стандартный из config.example.yaml"
      else
        BLOCK=$input
        BLOCK_SOURCE="введён вручную"
      fi
      ;;
    *)
      BLOCK=$input
      BLOCK_SOURCE="введён вручную"
      ;;
  esac
  return 0
}

default_block() {
  # Значение якоря &geofilter из config.example.yaml (лежит рядом с
  # install.sh, входит в PROJECT_TOOLS). Пусто, если файла или якоря нет.
  [ -f "$SELFDIR/config.example.yaml" ] || return 0
  sed -n "s/.*exclude-filter:[[:space:]]*&geofilter[[:space:]]*'\([^']*\)'.*/\1/p" \
    "$SELFDIR/config.example.yaml" | head -n 1
}

reopen_tty() {
  # Под "curl ... | sh" стандартный ввод занят телом самого install.sh -
  # без переоткрытия от терминала интерактивные read -r сразу получат EOF
  # вместо ответов пользователя. Если stdin уже терминал (обычный
  # "sh install.sh") - трогать не нужно; если терминала нет вовсе -
  # оставляем как есть.
  # "exec < /dev/tty" сам по себе фатален для sh при неудаче (нет
  # управляющего терминала - это нормально для не-интерактивных
  # запусков), даже с последующим "|| true" - POSIX требует, чтобы shell
  # завершился при ошибке редиректа у голого exec без команды. Поэтому
  # сначала пробуем открыть /dev/tty в отдельном подшелле: его неудача
  # убивает только подшелл, а не install.sh.
  if [ ! -t 0 ] && (exec < /dev/tty) 2>/dev/null; then
    exec < /dev/tty
  fi
}

install_cron() {
  cron_line="0 */3 * * * $INSTALLED_SCRIPT"
  current=$(crontab -l 2>/dev/null || true)
  if printf '%s\n' "$current" | grep -qF "$INSTALLED_SCRIPT"; then
    return 0
  fi
  printf '%s\n' "$current" > "$TMPROOT/cron.bak"
  { [ -n "$current" ] && printf '%s\n' "$current"; echo "$cron_line"; } | crontab -
}

install_update_check_cron() {
  # Фоновая проверка обновлений раз в UPDATE_CHECK_HOURS часов (по
  # умолчанию 12, поле "Проверять обновления" в настройках веб-интерфейса;
  # см. cmd_cron_sync() в web/stats_update.sh - та же формула, здесь
  # продублирована: install.sh не подключает stats_update.sh). Отдельная
  # от install_cron() cron-строка и отдельный бэкап-файл (cron-update.bak,
  # не cron.bak), чтобы обе функции не затирали бэкап друг друга при
  # последовательном вызове из main(). Минута 17 выбрана так, чтобы не
  # совпадать с минутой "0" cron-строки speedtest2.sh. Уже стоящую строку
  # с другой частотой (например, старую ежедневную "17 5") заменяет.
  hours=$(sed -n "s/^UPDATE_CHECK_HOURS=['\"]\{0,1\}\([0-9]*\)['\"]\{0,1\}\$/\1/p" "${ENVFILE:-$DIR/speedtest2.env}" 2>/dev/null | tail -n 1)
  case $hours in
    24) cron_line="17 5 * * * $UPDATE_CHECK_SCRIPT check" ;;
    1) cron_line="17 * * * * $UPDATE_CHECK_SCRIPT check" ;;
    2|3|4|6|8|12) cron_line="17 */$hours * * * $UPDATE_CHECK_SCRIPT check" ;;
    *) cron_line="17 */12 * * * $UPDATE_CHECK_SCRIPT check" ;;
  esac
  current=$(crontab -l 2>/dev/null || true)
  if [ "$(printf '%s\n' "$current" | grep -F "$UPDATE_CHECK_SCRIPT")" = "$cron_line" ]; then
    return 0
  fi
  printf '%s\n' "$current" > "$TMPROOT/cron-update.bak"
  rest=$(printf '%s\n' "$current" | grep -vF "$UPDATE_CHECK_SCRIPT" || true)
  { [ -n "$rest" ] && printf '%s\n' "$rest"; echo "$cron_line"; } | crontab -
}

atomic_install() {
  src=$1
  dst=$2
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  if ! cp "$src" "$tmp"; then rm -f "$tmp"; return 1; fi
  case $src in *.sh) mode=0755 ;; *) mode=0644 ;; esac
  if ! chmod "$mode" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
}

ensure_mihomo_speedtest_symlink() {
  # $1 - путь к mihomo-speedtest.sh, $2/$3 - каталоги-кандидаты для ссылки
  # (по умолчанию /opt/sbin и /opt/bin - см. вызов ниже; параметризовано
  # ради тестируемости без системных путей). Публикация символической
  # ссылки через манифест/транзакцию обновлятора невозможна (см.
  # docs/superpowers/specs/2026-09-26-mihomo-speedtest-cli-design.md,
  # раздел 3) - функция продублирована здесь, в update.sh и в uninstall.sh
  # по образцу уже существующего дублирования has_fast_group().
  target=$1
  for bindir in "${2:-/opt/sbin}" "${3:-/opt/bin}"; do
    [ -d "$bindir" ] && [ -w "$bindir" ] || continue
    link=$bindir/mihomo-speedtest
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      echo "WARN - $link уже существует и не является символической ссылкой - не трогаю, пробую следующий каталог" >&2
      continue
    fi
    current=$(readlink "$link" 2>/dev/null) || current=""
    [ "$current" = "$target" ] && return 0
    if ln -sf "$target" "$link" 2>/dev/null; then
      echo "Команда доступна как: mihomo-speedtest (симлинк в $bindir)" >&2
      return 0
    fi
  done
  echo "WARN - не удалось создать символическую ссылку mihomo-speedtest в /opt/sbin или /opt/bin - используйте полный путь: sh $target" >&2
  return 0
}

# PROJECT_TOOLS определён выше, рядом с DIR/SELFDIR (нужен и bootstrap-
# триггеру, который срабатывает раньше этого места файла).
install_files() {
  for project_file in $PROJECT_TOOLS; do
    atomic_install "$SELFDIR/$project_file" "$DIR/$project_file" || return 1
  done
  atomic_install "$SELFDIR/speedtest2.sh" "$DIR/speedtest2.sh" || return 1
  chmod +x "$DIR/speedtest2.sh"
  atomic_install "$SELFDIR/prep.awk" "$DIR/prep.awk" || return 1
  atomic_install "$SELFDIR/render_stats.awk" "$DIR/render_stats.awk" || return 1
  atomic_install "$SELFDIR/stats_cgi.sh" "$DIR/stats_cgi.sh" || return 1
  chmod +x "$DIR/stats_cgi.sh"
  atomic_install "$SELFDIR/stats_run.sh" "$DIR/stats_run.sh" || return 1
  chmod +x "$DIR/stats_run.sh"
  atomic_install "$SELFDIR/stats_update.sh" "$DIR/stats_update.sh" || return 1
  chmod +x "$DIR/stats_update.sh"
  atomic_install "$SELFDIR/stats_config.sh" "$DIR/stats_config.sh" || return 1
  chmod +x "$DIR/stats_config.sh"
  atomic_install "$SELFDIR/stats_xkeen.sh" "$DIR/stats_xkeen.sh" || return 1
  chmod +x "$DIR/stats_xkeen.sh"
  # статические файлы SPA-shell (см. docs/plans/2026-09-12-web-spa-migration-design.md)
  # веб-сервиса статистики - stats_httpd.py раздаёт их прямо из $DIR;
  # исполняемый бит не нужен.
  atomic_install "$SELFDIR/stats_index.html" "$DIR/stats_index.html" || return 1
  atomic_install "$SELFDIR/stats_style.css" "$DIR/stats_style.css" || return 1
  atomic_install "$SELFDIR/stats_app.js" "$DIR/stats_app.js" || return 1
  for m in core stats settings updates log config xkeen; do
    atomic_install "$SELFDIR/stats_app_$m.js" "$DIR/stats_app_$m.js" || return 1
  done
  # stats_codemirror.js/.css - вендоренный CodeMirror 5 для вкладки "Конфиг".
  atomic_install "$SELFDIR/stats_codemirror.js" "$DIR/stats_codemirror.js" || return 1
  atomic_install "$SELFDIR/stats_codemirror.css" "$DIR/stats_codemirror.css" || return 1
  # обязательный веб-сервер на python3 (см. docs/guide.md, "Обязательная
  # авторизация веб-интерфейса") - запускается start_backend() в
  # stats_service.sh (порция 3, независимая служба); исполняемый бит не
  # нужен, он вызывается как "python3 stats_httpd.py", а не напрямую.
  # stats_auth.py - ядро авторизации (импортируется stats_httpd.py),
  # stats_auth.sh - сброс логина и пароля по SSH (sh stats_auth.sh reset).
  atomic_install "$SELFDIR/stats_httpd.py" "$DIR/stats_httpd.py" || return 1
  atomic_install "$SELFDIR/stats_auth.py" "$DIR/stats_auth.py" || return 1
  atomic_install "$SELFDIR/stats_auth.sh" "$DIR/stats_auth.sh" || return 1
  # вызывается напрямую через "awk -f", как prep.awk/render_stats.awk -
  # исполняемый бит не нужен.
  atomic_install "$SELFDIR/node_stats_update.awk" "$DIR/node_stats_update.awk" || return 1
  # вызывается напрямую через "awk -f" в speedtest2.sh - исполняемый бит не нужен.
  atomic_install "$SELFDIR/sub_convert.awk" "$DIR/sub_convert.awk" || return 1
  # прогресс скоростного теста по нодам текущего прогона (write_progress()
  # в speedtest2.sh) - вызывается напрямую через "awk -f", исполняемый бит
  # не нужен.
  atomic_install "$SELFDIR/render_progress.awk" "$DIR/render_progress.awk" || return 1
  # независимая служба веб-интерфейса статистики (порция 3, см.
  # docs/superpowers/specs/2026-09-15-independent-stats-service-design.md) -
  # supervisor ставится рядом с остальными файлами в $DIR, а сам
  # init-скрипт - прямо в каталог автозапуска Entware, чтобы rc.unslung
  # подхватил его при следующей загрузке /opt без отдельного шага.
  atomic_install "$SELFDIR/stats_service.sh" "$STATS_SERVICE_DEST" || return 1
  chmod +x "$STATS_SERVICE_DEST"
  mkdir -p "$INITD_DIR" 2>/dev/null || true
  atomic_install "$SELFDIR/stats_init.sh" "$INITD_SCRIPT" || return 1
  chmod +x "$INITD_SCRIPT"
  ensure_mihomo_speedtest_symlink "$DIR/mihomo-speedtest.sh"
}

format_mbit() {
  # байт/с -> Мбит/с с одним знаком, как в журнале speedtest2.sh
  LC_ALL=C awk -v speed="$1" 'BEGIN { printf "%.1f", speed / 125000 }'
}

write_env() {
  dst=$1
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  {
    echo "# создано install.sh $(date '+%F %T')"
    echo "# фильтр: $BLOCK_SOURCE"
    printf "SOURCES='%s'\n" "$SOURCES"
    # EXTYPE из окружения установщика - как раньше; иначе сохраняем то,
    # что пользователь задал в веб-настройках.
    if [ -n "${EXTYPE:-}" ]; then
      printf "EXTYPE='%s'\n" "$EXTYPE"
    else
      sed -n '/^EXTYPE=/p' "$dst" 2>/dev/null | tail -1
    fi
    printf "BLOCK='%s'\n" "$BLOCK"
    printf "MIN_SPEED='%s'\n" "$MIN_SPEED"
    # При повторной установке сохраняем пользовательские лимиты отбора.
    for limit_key in MAX_TESTED TOPN ENOUGH MIN_WINNERS; do
      saved_limit=$(sed -n "/^$limit_key=/p" "$dst" 2>/dev/null | tail -1)
      if [ -n "$saved_limit" ]; then
        printf '%s\n' "$saved_limit"
      else
        case $limit_key in
          MAX_TESTED) limit_default=40 ;;
          TOPN) limit_default=15 ;;
          ENOUGH) limit_default=20 ;;
          MIN_WINNERS) limit_default=3 ;;
        esac
        printf "%s='%s'\n" "$limit_key" "$(read_speedtest_const "$limit_key" "$limit_default")"
      fi
    done
    # Остальные поля веб-настроек (stats_cgi.sh) при переустановке тоже не
    # сбрасываем к умолчаниям: пишем прежнюю строку, если она была. Список
    # явный, чтобы удалённые из проекта настройки (например MAX_PING_MS)
    # по-прежнему вычищались переустановкой.
    for keep_key in SIZE DL_TIMEOUT MIN_RATIO MIN_FLOOR STABILITY_WINDOW STABILITY_DROP_AFTER \
        HISTORY_KEEP_RUNS HISTORY_KEEP_DAYS STATS_NODE_CAP UPDATE_CHECK_HOURS UPDATE_CHANNEL; do
      sed -n "/^$keep_key=/p" "$dst" 2>/dev/null | tail -1
    done
    # STATS_HTTP_ENABLE - персистентный флаг stop-web/start-web (см.
    # docs/superpowers/specs/2026-09-26-mihomo-speedtest-cli-design.md,
    # раздел 4): фиксированный дефолт '1', а не число из read_speedtest_const -
    # у read_speedtest_const's awk-парсера свой формат под NAME=число, а не
    # под NAME=${NAME:-1}, как объявлен STATS_HTTP_ENABLE в speedtest2.sh.
    # Без кавычек - web/stats_init.sh:stats_enabled() читает эту переменную
    # наивным sed-разбором (s/^STATS_HTTP_ENABLE=//p), не полноценным ".",
    # и кавычки попали бы в значение буквально (val="'1'" != "1") - служба
    # решила бы, что флаг выключен, хотя он включён. В отличие от прочих
    # полей этого файла (BLOCK, лимиты и т.п.), которые читает только
    # обычный "." - там кавычки безопасны и стилистически единообразны.
    saved_web_enable=$(sed -n '/^STATS_HTTP_ENABLE=/p' "$dst" 2>/dev/null | tail -1)
    if [ -n "$saved_web_enable" ]; then
      printf '%s\n' "$saved_web_enable"
    else
      printf "STATS_HTTP_ENABLE=1\n"
    fi
  } > "$tmp" && mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

recalibrate_env() {
  dst=$1
  new_min=$2
  [ -f "$dst" ] || { echo "$dst не найден, сначала обычная установка" >&2; return 1; }
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  awk -v v="$new_min" -v q="'" '
    /^MIN_SPEED=/ { print "MIN_SPEED=" q v q; done = 1; next }
    { print }
    END { if (!done) print "MIN_SPEED=" q v q }
  ' "$dst" > "$tmp" && mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

read_speedtest_const() {
  # Читает числовую константу вида "ИМЯ=значение  # комментарий" из
  # шапки speedtest2.sh. Используется, чтобы MIN_RATIO/MIN_FLOOR не
  # дублировались magic-числами в install.sh (см. compute_threshold()
  # в speedtest2.sh - источник истины для этой арифметики).
  name=$1
  default=$2
  val=$(awk -v n="$name" '
    $0 ~ "^" n "=" {
      v = $0
      sub("^" n "=", "", v)
      sub(/[ \t]*#.*/, "", v)
      gsub(/[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$SELFDIR/speedtest2.sh" 2>/dev/null) || val=""
  if [ -n "$val" ]; then
    echo "$val"
  else
    echo "$default"
  fi
}

env_number() {
  # Число NAME из уже существующего speedtest2.env (в кавычках или без);
  # возврат 1, если файла/строки нет или значение не число.
  en_val=$(sed -n "s/^$1=['\"]\{0,1\}\([0-9.]*\)['\"]\{0,1\}\$/\1/p" "${ENVFILE:-$DIR/speedtest2.env}" 2>/dev/null | tail -1)
  case $en_val in ''|*[!0-9.]*|.*|*.*.*) return 1 ;; esac
  printf '%s\n' "$en_val"
}

compute_min_speed() {
  # $1 = CHANNEL (байт/с прямого замера).
  # Дублирует compute_threshold() из speedtest2.sh на числах, прочитанных
  # оттуда же через read_speedtest_const; 0.25/524288 ниже - fallback
  # ТОЛЬКО если строки MIN_RATIO=/MIN_FLOOR= не найдены в speedtest2.sh
  # (они ДОЛЖНЫ совпадать с дефолтами в его шапке).
  # Если пользователь уже менял долю канала/минимум в веб-настройках
  # (переустановка, recalibrate), считаем по его значениям.
  channel=$1
  ratio=$(env_number MIN_RATIO) || ratio=$(read_speedtest_const MIN_RATIO 0.25)
  floor=$(env_number MIN_FLOOR) || floor=$(read_speedtest_const MIN_FLOOR 524288)
  awk -v c="$channel" -v r="$ratio" -v f="$floor" 'BEGIN {
    t = int(c * r)
    print (t > f) ? t : f
  }'
}

measure_channel() {
  METRICS=$(curl -s -m 15 -o /dev/null -w '%{http_code} %{speed_download}' \
            "$SPEED_URL" 2>/dev/null) || METRICS=""
  status=${METRICS%% *}
  raw=${METRICS#* }
  case $status in
    2[0-9][0-9]) echo "${raw%%.*}" ;;
    *) echo 0 ;;
  esac
}

have_python3() {
  command -v python3 >/dev/null 2>&1
}

have_opkg() {
  command -v opkg >/dev/null 2>&1
}

ensure_python3() {
  # Полная авторизация реализована в stats_httpd.py, поэтому незащищённого
  # BusyBox fallback больше нет. Неудача не отменяет CLI и speedtest, но
  # веб-службу после такой установки запускать нельзя.
  have_python3 && return 0

  if ! have_opkg; then
    echo "python3 не найден, а opkg недоступен - веб-интерфейс не будет запущен. Поставьте python3 вручную, выполните sh $DIR/stats_auth.sh initialize и затем $INITD_SCRIPT restart" >&2
    return 1
  fi

  echo "python3 не найден, пробую поставить через opkg install python3..." >&2
  if ! opkg install python3 >/dev/null 2>&1; then
    echo "opkg install python3 не удался с первого раза, обновляю список пакетов (opkg update) и пробую ещё раз..." >&2
    opkg update >/dev/null 2>&1 || true
    opkg install python3 >/dev/null 2>&1 || true
  fi

  if have_python3; then
    echo "python3 успешно установлен через opkg" >&2
    return 0
  else
    echo "Не удалось автоматически поставить python3 через opkg - веб-интерфейс не будет запущен. Поставьте python3 вручную, выполните sh $DIR/stats_auth.sh initialize и затем $INITD_SCRIPT restart" >&2
    return 1
  fi
}

initialize_web_auth() {
  code=$(python3 "$DIR/stats_auth.py" initialize \
    --state-dir "$DIR/.stats-auth" \
    --runtime-dir "${STATS_AUTH_RUNTIME_DIR:-/tmp/mihomo-speedtest-auth}") || return 1
  if [ -n "$code" ]; then
    echo "Одноразовый код первичной настройки: $code" >&2
    host=$(advertise_host "${STATS_HTTP_BIND:-0.0.0.0}")
    [ -n "$host" ] || host="<адрес роутера>"
    echo "Откройте http://$host:${STATS_HTTP_PORT:-8899}/setup и задайте логин и пароль" >&2
  fi
}

advertise_host() {
  # $1 = STATS_HTTP_BIND. Копия stats_httpd_advertise_host() из
  # speedtest-runtime/speedtest2.sh (см. её комментарий там) - install.sh
  # не подключает speedtest2.sh как библиотеку, поэтому логика
  # продублирована буквально, по образцу уже существующего дублирования
  # has_fast_group() между install.sh/uninstall.sh. STATS_HTTPD_IP_CMD
  # задаётся дефолтом инлайн (а не отдельной верхнеуровневой переменной,
  # как в speedtest2.sh) - install.sh этой переменной не объявляет.
  case "$1" in
    0.0.0.0|"") ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  command -v "${STATS_HTTPD_IP_CMD:-ip}" >/dev/null 2>&1 || return 0
  "${STATS_HTTPD_IP_CMD:-ip}" -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | awk '
        function is_private(ip,    o, n) {
          n = split(ip, o, ".")
          if (n != 4) return 0
          if (o[1] == 10) return 1
          if (o[1] == 192 && o[2] == 168) return 1
          if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 1
          return 0
        }
        !got_any { first = $0; got_any = 1 }
        is_private($0) && !got_priv { priv = $0; got_priv = 1 }
        END {
          if (got_priv) print priv
          else if (got_any) print first
        }
      '
}

print_web_url() {
  envfile=${ENVFILE:-$DIR/speedtest2.env}
  if [ ! -f "$envfile" ]; then
    echo "$envfile не найден - сначала выполните установку (mihomo-speedtest install)" >&2
    return 1
  fi
  . "$envfile"
  if [ "${STATS_HTTP_ENABLE:-1}" != 1 ]; then
    echo "Веб-сервис статистики отключён (mihomo-speedtest start-web - включить)" >&2
    return 0
  fi
  host=$(advertise_host "${STATS_HTTP_BIND:-0.0.0.0}")
  [ -n "$host" ] || host="<не удалось определить IP - смотрите ip addr на роутере>"
  echo "Веб-интерфейс статистики: http://$host:${STATS_HTTP_PORT:-8899}/stats" >&2
}

show_url_main() {
  print_web_url
  # if/then, а не "&&" отдельной командой функции: check возвращает
  # ненулевой статус, когда служба остановлена (это его штатное поведение),
  # а такая функция, вызванная простой командой (например, из case-
  # диспетчера конца файла), под set -eu обрывалась бы здесь, не доходя до
  # "return 0" (найдено финальным обзором ветки 2026-09-26 - см. ledger
  # плана).
  if [ -x "$INITD_SCRIPT" ]; then
    "$INITD_SCRIPT" check || true
  fi
  return 0
}

set_env_flag() {
  # $1=имя, $2=значение - точечная атомарная замена одной строки в
  # $DIR/speedtest2.env без потери остальных (тот же приём, что
  # web/stats_cgi.sh:set_env_var(), продублирован здесь - install.sh не
  # подключает stats_cgi.sh). БЕЗ кавычек вокруг значения (в отличие от
  # set_env_var()) - единственный вызывающий на сегодня, STATS_HTTP_ENABLE,
  # читает web/stats_init.sh:stats_enabled() наивным sed-разбором без
  # снятия кавычек (см. комментарий в write_env()); в кавычках значение
  # '1' != 1 сломало бы проверку.
  name=$1; val=$2
  envfile=${ENVFILE:-$DIR/speedtest2.env}
  [ -f "$envfile" ] || { echo "$envfile не найден, сначала обычная установка" >&2; return 1; }
  tmp="$envfile.$$"
  { grep -v "^$name=" "$envfile"; printf "%s=%s\n" "$name" "$val"; } > "$tmp" \
    && mv "$tmp" "$envfile" || { rm -f "$tmp"; echo "Не удалось записать $envfile" >&2; return 1; }
}

stop_web_main() {
  set_env_flag STATS_HTTP_ENABLE 0 || return 1
  [ -x "$INITD_SCRIPT" ] && "$INITD_SCRIPT" stop >/dev/null 2>&1
  echo "Веб-сервис статистики остановлен и отключён - при переустановке/обновлении проекта он не будет запускаться автоматически (mihomo-speedtest start-web - включить обратно)" >&2
  return 0
}

start_web_main() {
  set_env_flag STATS_HTTP_ENABLE 1 || return 1
  if [ -x "$INITD_SCRIPT" ] && "$INITD_SCRIPT" restart >/dev/null 2>&1; then
    print_web_url
  else
    echo "WARN - $INITD_SCRIPT restart не удался, веб-сервис статистики не поднят - проверьте вручную" >&2
  fi
}

# Читает $INSTALLED_MANIFEST_PATH (тот же файл, что пишет
# bootstrap_selfinstall и читает update.sh --check) и печатает установленную
# версию релиза. Чисто локальная команда: не трогает сеть и не требует
# полного набора файлов проекта (см. bootstrap_skip_for_action выше).
version_main() {
  installed_version=
  if [ -f "$INSTALLED_MANIFEST_PATH" ]; then
    installed_version=$(bootstrap_manifest_field "$INSTALLED_MANIFEST_PATH" RELEASE_VERSION)
  fi
  if [ -n "$installed_version" ]; then
    installed_tag=$(bootstrap_manifest_field "$INSTALLED_MANIFEST_PATH" RELEASE_TAG)
    echo "Версия релиза: ${installed_tag:-v$installed_version} (номер $installed_version)" >&2
  else
    echo "Установленный релиз не отслеживается" >&2
  fi
  return 0
}

# Пробный прогон speedtest2.sh при установке/переустановке может занимать
# от десятков секунд до нескольких минут (зависит от числа нод), а сам
# speedtest2.sh обычным ходом ничего не пишет в консоль - весь его лог
# идёт в файл (см. log() в speedtest-runtime/speedtest2.sh). Без обратной
# связи это выглядит как зависший install.sh. Фоновый "тик" каждые
# TRIAL_HEARTBEAT_INTERVAL секунд - самый надёжный вариант для POSIX sh:
# не портит вывод при логировании в файл или по SSH с задержкой, в
# отличие от анимации через \r.
run_trial_with_heartbeat() {
  trial_heartbeat_interval=${TRIAL_HEARTBEAT_INTERVAL:-8}
  (
    while :; do
      sleep "$trial_heartbeat_interval"
      echo "Пробный прогон ещё выполняется, ждите..." >&2
    done
  ) &
  trial_heartbeat_pid=$!
  "$DIR/speedtest2.sh" || true
  kill "$trial_heartbeat_pid" 2>/dev/null || true
  wait "$trial_heartbeat_pid" 2>/dev/null || true
}

# Хвост журнала пробного прогона - в stderr, как и весь вывод install.sh.
# Порядок редиректов важен: ">&2 2>/dev/null", а не наоборот. При
# "2>/dev/null >&2" stdout копировался с уже перенаправленного в
# /dev/null fd 2, и хвост журнала молча пропадал.
print_trial_log_tail() {
  echo "Пробный запуск завершён, хвост журнала:" >&2
  tail -5 "$DIR/speedtest.log" >&2 2>/dev/null || true
}

main() {
  check_mihomo_process && check_versions || return 1

  if [ ! -f "$CONFIG" ]; then
    # Новый роутер: config.yaml ещё нет. Вместо отказа передаём управление
    # мастеру настройки (setup.sh, который сам в конце вызывает install.sh
    # ещё раз - см. setup.sh) - это второй из двух сценариев однострочной
    # установки (см. bootstrap-блок в начале файла): "конфиг уже настроен"
    # обрабатывается штатным продолжением main() ниже, "конфига нет" - тут.
    [ -f "$SELFDIR/setup.sh" ] || { echo "$CONFIG не найден и $SELFDIR/setup.sh недоступен для настройки" >&2; return 1; }
    echo "$CONFIG не найден - похоже, это установка на новом роутере. Запускаю мастер настройки (setup.sh)" >&2
    # Интерактивные read -r в setup.sh должны читать терминал, а не тело
    # install.sh под "curl ... | sh" (см. reopen_tty()).
    reopen_tty
    export SELFDIR DIR CONFIG
    exec sh "$SELFDIR/setup.sh"
  fi
  for f in $ALL_PROJECT_FILES; do
    [ -f "$SELFDIR/$f" ] || {
      echo "$SELFDIR/$f не найден рядом с install.sh" >&2
      return 1
    }
  done
  "$BIN" -t -d "$MIHOMO_DIR" -f "$CONFIG" >/dev/null 2>&1 || {
    echo "$CONFIG не проходит mihomo -t" >&2
    return 1
  }

  if ! PARSED=$(awk -v CONFIG="$CONFIG" -v CONFDIR="$MIHOMO_DIR" -f "$SELFDIR/providers.awk" "$CONFIG"); then
    echo "providers.awk не смог разобрать $CONFIG" >&2
    return 1
  fi
  eval "$PARSED"

  for src in $SOURCES; do
    [ -f "$src" ] && continue
    name=$(basename "$src" .yaml)
    curl -f -s -m 10 -X PUT "http://$API_MAIN/providers/proxies/$name" >/dev/null 2>&1 || true
    sleep 3
    [ -f "$src" ] || {
      echo "Кэш $src не появился, сначала чините подписку $name" >&2
      return 1
    }
  done

  # Вопросы resolve_block() тоже должны читать терминал, а не тело
  # install.sh под "curl ... | sh" - иначе read сразу получает EOF.
  reopen_tty
  resolve_block || return 1
  echo "Фильтр ($BLOCK_SOURCE): $BLOCK" >&2

  CHANNEL=$(measure_channel)
  if [ "$CHANNEL" -gt 0 ] 2>/dev/null; then
    MIN_SPEED=$(compute_min_speed "$CHANNEL")
    echo "Канал $(format_mbit "$CHANNEL") Мбит/с, порог $(format_mbit "$MIN_SPEED") Мбит/с" >&2
  else
    # MIN_SPEED в шапке speedtest2.sh - не в кавычках (число), в отличие
    # от BLOCK; читаем тем же read_speedtest_const, что и MIN_RATIO/MIN_FLOOR.
    MIN_SPEED=$(read_speedtest_const MIN_SPEED 1048576)
    echo "Прямой замер канала не удался, порог из дефолта: $(format_mbit "$MIN_SPEED") Мбит/с" >&2
  fi

  write_env "$DIR/speedtest2.env" || {
    echo "Не удалось записать speedtest2.env" >&2
    return 1
  }
  install_files || {
    echo "Не удалось установить файлы" >&2
    return 1
  }
  install_cron
  install_update_check_cron

  # Ставим python3 (если получится) ДО запуска веб-службы: без него
  # stats_httpd.py не запустится, а резервного сервера без пароля больше
  # нет - веб-интерфейс тогда просто не поднимается (см. ensure_python3).
  web_ready=1
  ensure_python3 || web_ready=0

  # Порция 3 (см. design): веб-интерфейс статистики поднимается независимо
  # от пробного прогона speedtest - "restart", а не "start", чтобы при
  # переустановке (изменился порт/bind/логин в $CONFIG или окружении)
  # уже запущенная служба сразу подхватила свежий speedtest2.env, а не
  # промолчала как "уже запущена" на старых настройках.
  if [ "$web_ready" = 1 ] && ! initialize_web_auth; then
    web_ready=0
    echo "WARN - не удалось инициализировать авторизацию, веб-интерфейс не запущен" >&2
  fi
  if [ "$web_ready" = 1 ] && [ -x "$INITD_SCRIPT" ]; then
    if "$INITD_SCRIPT" restart >/dev/null 2>&1; then
      echo "Веб-сервис статистики запущен ($INITD_SCRIPT restart)" >&2
      print_web_url
    else
      echo "WARN - $INITD_SCRIPT restart не удался, веб-сервис статистики не поднят - проверьте вручную" >&2
    fi
  elif [ "$web_ready" = 1 ]; then
    echo "WARN - $INITD_SCRIPT не найден после установки, веб-сервис статистики не запущен" >&2
  else
    [ ! -x "$INITD_SCRIPT" ] || "$INITD_SCRIPT" stop >/dev/null 2>&1 || true
    echo "CLI, speedtest и обновлятор установлены; веб-интерфейс отключён до установки Python 3" >&2
  fi

  if [ "${SKIP_TRIAL:-0}" != 1 ]; then
    run_trial_with_heartbeat
    print_trial_log_tail
  fi

  echo "Установка завершена" >&2
}

recalibrate_main() {
  ENVFILE=${ENVFILE:-$DIR/speedtest2.env}
  [ -f "$ENVFILE" ] || {
    echo "$ENVFILE не найден, сначала обычная установка" >&2
    return 1
  }
  CHANNEL=$(measure_channel)
  if [ "$CHANNEL" -gt 0 ] 2>/dev/null; then
    NEW_MIN=$(compute_min_speed "$CHANNEL")
  else
    echo "Прямой замер канала не удался, MIN_SPEED не изменён" >&2
    return 1
  fi
  recalibrate_env "$ENVFILE" "$NEW_MIN" || return 1
  echo "Порог пересчитан: $(format_mbit "$NEW_MIN") Мбит/с" >&2
}

if [ "${INSTALL_LIB_ONLY:-0}" != 1 ]; then
  case "${1:-}" in
    --recalibrate) recalibrate_main ;;
    --stop-web) stop_web_main ;;
    --start-web) start_web_main ;;
    --show-url) show_url_main ;;
    --version) version_main ;;
    *) main "$@" ;;
  esac
  # Явный выход обязателен: под "curl ... | sh" reopen_tty() переключает
  # stdin процесса sh на /dev/tty, и без exit оболочка после main стала бы
  # читать "продолжение скрипта" с терминала - установка как будто висит
  # без приглашения консоли, а набранное выполнилось бы как команды.
  exit $?
fi
