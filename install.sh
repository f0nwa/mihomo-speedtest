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
PROJECT_TOOLS="migrate_config.sh migrate_config.awk config_diff.awk install.sh uninstall.sh version_check.sh VERSIONS setup.sh detect_ua.sh render_config.awk existing_config.awk config.example.yaml update.sh update_plan.awk update_prepare.sh update_transaction.sh providers.awk"
# Единый полный список всех файлов проекта под $SELFDIR/$DIR - источник
# истины и для триггера bootstrap ниже, и для финальной проверки полноты
# в main() (было два отдельных списка с двумя разными файлами-часовыми -
# см. CHANGELOG: install.sh не замечал недостающий migrate_config.sh,
# т.к. триггер смотрел только на version_check.sh/speedtest2.sh).
ALL_PROJECT_FILES="$PROJECT_TOOLS speedtest2.sh prep.awk render_stats.awk stats_cgi.sh stats_run.sh stats_update.sh stats_httpd.py stats_auth.py stats_auth.sh stats_index.html stats_style.css stats_app.js stats_chart.js node_stats_update.awk sub_convert.awk render_progress.awk stats_service.sh stats_init.sh"
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
  if [ -n "${UPDATE_HTTP_CMD:-}" ]; then $UPDATE_HTTP_CMD "$1"
  elif command -v curl >/dev/null 2>&1; then
    case $1 in
      https://*) curl -fsSL --proto '=https' --proto-redir '=https' --max-time "${UPDATE_HTTP_TIMEOUT:-15}" --max-filesize "$2" "$1" 2>/dev/null ;;
      http://*) curl -fsSL --proto '=http' --proto-redir '=http' --max-redirs 0 --max-time "${UPDATE_HTTP_TIMEOUT:-15}" --max-filesize "$2" "$1" 2>/dev/null ;;
      *) return 1 ;;
    esac
  else
    echo "install.sh: для установки нужен curl с поддержкой HTTPS" >&2
    return 1
  fi
}

bootstrap_download_to() {
  write_limit=$3
  [ "$write_limit" -ge 262144 ] || write_limit=262144
  if ! (ulimit -f "$(( (write_limit + 511) / 512 ))"; bootstrap_http_get "$1" "$3") > "$2"; then
    echo "install.sh: не удалось скачать $1 - проверьте сеть и сертификаты роутера" >&2
    return 1
  fi
  download_size=$(wc -c < "$2" | tr -d ' ')
  [ "$download_size" -gt 0 ] && [ "$download_size" -le "$3" ] || {
    echo "install.sh: пустой файл или превышен лимит загрузки: $1" >&2
    return 1
  }
}

bootstrap_check_download() {
  [ "$(wc -c < "$1" | tr -d ' ')" = "$2" ] || { echo "install.sh: неверный размер файла релиза: $1" >&2; return 1; }
  [ "$(bootstrap_sha256_of "$1")" = "$3" ] || { echo "install.sh: неверная сумма SHA256 файла релиза: $1" >&2; return 1; }
}

bootstrap_awk_syntax() {
  printf 'BEGIN { exit 0 }\nEND { exit 0 }\n' > "$BOOTSTRAP_WORK/awk-guard"
  awk -f "$BOOTSTRAP_WORK/awk-guard" -f "$1" /dev/null >/dev/null 2>&1 || {
    echo "install.sh: файл не прошёл проверку синтаксиса AWK: $1" >&2
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
    echo "install.sh: манифест релиза не прошёл проверку - установка остановлена" >&2
    return 1
  }
}

bootstrap_pinned_base() {
  case $UPDATE_RELEASE_BASE in
    */releases/latest/download)
      BOOTSTRAP_PINNED_BASE=${UPDATE_RELEASE_BASE%/latest/download}/download/$(bootstrap_manifest_field "$BOOTSTRAP_MANIFEST" RELEASE_TAG) ;;
    *) echo "install.sh: для установки нужен источник вида .../releases/latest/download" >&2; return 1 ;;
  esac
}

bootstrap_selfinstall() {
  BOOTSTRAP_SHA_TOOL=$(bootstrap_sha256_tool) || {
    echo "install.sh: не найден инструмент SHA256 (sha256sum/openssl/busybox) - установка остановлена" >&2
    return 1
  }
  bootstrap_tmproot=${TMPROOT:-/tmp}
  BOOTSTRAP_WORK=$(mktemp -d "$bootstrap_tmproot/mst-install-bootstrap.XXXXXX") || return 1
  BOOTSTRAP_MANIFEST=$BOOTSTRAP_WORK/manifest.txt

  echo "install.sh: рядом нет файлов проекта - скачиваю релиз с GitHub ($UPDATE_RELEASE_BASE)" >&2

  bootstrap_download_to "$UPDATE_RELEASE_BASE/manifest.txt" "$BOOTSTRAP_MANIFEST" 262144 || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
  bootstrap_header || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
  bootstrap_pinned_base || { rm -rf "$BOOTSTRAP_WORK"; return 1; }

  mkdir -p "$DIR" || { echo "install.sh: не удалось создать $DIR" >&2; rm -rf "$BOOTSTRAP_WORK"; return 1; }

  # Проход 1: скачать и проверить всё во временном каталоге. Ничего не
  # пишем в DIR, пока не убедимся, что весь набор цел - иначе отказ на
  # середине списка оставил бы в DIR наполовину установленный проект.
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    bootstrap_download_to "$BOOTSTRAP_PINNED_BASE/$src" "$BOOTSTRAP_WORK/$src" "$bytes" || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
    bootstrap_check_download "$BOOTSTRAP_WORK/$src" "$bytes" "$sum" || { rm -rf "$BOOTSTRAP_WORK"; return 1; }
    case $check in
      sh) sh -n "$BOOTSTRAP_WORK/$src" || { echo "install.sh: неверный синтаксис sh: $src" >&2; rm -rf "$BOOTSTRAP_WORK"; return 1; } ;;
      awk) bootstrap_awk_syntax "$BOOTSTRAP_WORK/$src" || { rm -rf "$BOOTSTRAP_WORK"; return 1; } ;;
    esac
  done < "$BOOTSTRAP_WORK/files"

  # Проход 2: весь набор проверен - переносим в DIR.
  while IFS='|' read -r kind cid src dest bytes sum mode check; do
    mv "$BOOTSTRAP_WORK/$src" "$DIR/$src" || { echo "install.sh: не удалось записать $DIR/$src" >&2; rm -rf "$BOOTSTRAP_WORK"; return 1; }
    chmod "$mode" "$DIR/$src" || { echo "install.sh: не удалось задать режим $DIR/$src" >&2; return 1; }
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
  echo "install.sh: файлы проекта загружены и проверены (тег $bootstrap_tag)" >&2
  SELFDIR=$DIR
}

bootstrap_needed() {
  for bf in $ALL_PROJECT_FILES; do
    [ -f "$SELFDIR/$bf" ] || return 0
  done
  return 1
}

if [ "${INSTALL_LIB_ONLY:-0}" != 1 ] && bootstrap_needed; then
  UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE:-https://github.com/f0nwa/mihomo-speedtest/releases/latest/download}
  UPDATE_RELEASE_BASE=${UPDATE_RELEASE_BASE%/}
  bootstrap_selfinstall || {
    echo "install.sh: автоматическая установка не удалась. Скопируйте файлы проекта на роутер вручную (см. README.md) и запустите sh install.sh снова" >&2
    exit 1
  }
fi

. "$SELFDIR/version_check.sh"

resolve_block() {
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
          echo "install.sh: номер вне диапазона" >&2
          BLOCK=""
        fi
        ;;
    esac
    if [ -z "$BLOCK" ]; then
      echo "install.sh: пустой или неверный фильтр недопустим. Повторите с BLOCK='...' sh install.sh" >&2
      return 1
    fi
    return 0
  fi

  attempt=1
  while [ "$attempt" -le 3 ]; do
    echo "Гео-фильтр не найден в конфиге." >&2
    printf 'Введите фильтр: ' >&2
    read -r input || input=""
    if [ -n "$input" ]; then
      BLOCK=$input
      BLOCK_SOURCE="введён вручную"
      return 0
    fi
    echo "install.sh: пустой фильтр не принимается (попытка $attempt из 3)" >&2
    attempt=$((attempt + 1))
  done
  echo "install.sh: фильтр обязателен - без него подписка может подставить российскую ноду, которая выиграет замер по пингу. Установка остановлена." >&2
  return 1
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
  # Ежедневная фоновая проверка обновлений (см. docs/superpowers/specs/
  # 2026-09-15-managed-project-updates-design.md, "Веб-флоу") - отдельная
  # от install_cron() cron-строка и отдельный бэкап-файл (cron-update.bak,
  # не cron.bak), чтобы обе функции не затирали бэкап друг друга при
  # последовательном вызове из main(). Время (5:17) - не критично, выбрано
  # так, чтобы не совпадать с минутой "0" cron-строки speedtest2.sh.
  cron_line="17 5 * * * $UPDATE_CHECK_SCRIPT check"
  current=$(crontab -l 2>/dev/null || true)
  if printf '%s\n' "$current" | grep -qF "$UPDATE_CHECK_SCRIPT"; then
    return 0
  fi
  printf '%s\n' "$current" > "$TMPROOT/cron-update.bak"
  { [ -n "$current" ] && printf '%s\n' "$current"; echo "$cron_line"; } | crontab -
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
  # статические файлы SPA-shell (см. docs/plans/2026-09-12-web-spa-migration-design.md)
  # веб-сервиса статистики - копируются в раздаваемый каталог сами,
  # write_stats_static() из speedtest2.sh; исполняемый бит не нужен.
  # stats_chart.js - вендоренная UMD-сборка Chart.js для графика по нодам
  # (buildNodeChart() в stats_app.js), не наш код, ставится так же.
  atomic_install "$SELFDIR/stats_index.html" "$DIR/stats_index.html" || return 1
  atomic_install "$SELFDIR/stats_style.css" "$DIR/stats_style.css" || return 1
  atomic_install "$SELFDIR/stats_app.js" "$DIR/stats_app.js" || return 1
  atomic_install "$SELFDIR/stats_chart.js" "$DIR/stats_chart.js" || return 1
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
    [ -n "${EXTYPE:-}" ] && printf "EXTYPE='%s'\n" "$EXTYPE"
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
  } > "$tmp"
  mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

recalibrate_env() {
  dst=$1
  new_min=$2
  [ -f "$dst" ] || { echo "install.sh: $dst не найден, сначала обычная установка" >&2; return 1; }
  dstdir=${dst%/*}
  dstbase=${dst##*/}
  tmp=$dstdir/.$dstbase.$$
  awk -v v="$new_min" -v q="'" '
    /^MIN_SPEED=/ { print "MIN_SPEED=" q v q; done = 1; next }
    { print }
    END { if (!done) print "MIN_SPEED=" q v q }
  ' "$dst" > "$tmp"
  mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
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

compute_min_speed() {
  # $1 = CHANNEL (байт/с прямого замера).
  # Дублирует compute_threshold() из speedtest2.sh на числах, прочитанных
  # оттуда же через read_speedtest_const; 0.25/524288 ниже - fallback
  # ТОЛЬКО если строки MIN_RATIO=/MIN_FLOOR= не найдены в speedtest2.sh
  # (они ДОЛЖНЫ совпадать с дефолтами в его шапке).
  channel=$1
  ratio=$(read_speedtest_const MIN_RATIO 0.25)
  floor=$(read_speedtest_const MIN_FLOOR 524288)
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
    echo "install.sh: python3 не найден, а opkg недоступен - веб-интерфейс не будет запущен. Поставьте python3 вручную, выполните sh $DIR/stats_auth.sh initialize и затем $INITD_SCRIPT restart" >&2
    return 1
  fi

  echo "install.sh: python3 не найден, пробую поставить через opkg install python3..." >&2
  if ! opkg install python3 >/dev/null 2>&1; then
    echo "install.sh: opkg install python3 не удался с первого раза, обновляю список пакетов (opkg update) и пробую ещё раз..." >&2
    opkg update >/dev/null 2>&1 || true
    opkg install python3 >/dev/null 2>&1 || true
  fi

  if have_python3; then
    echo "install.sh: python3 успешно установлен через opkg" >&2
    return 0
  else
    echo "install.sh: не удалось автоматически поставить python3 через opkg - веб-интерфейс не будет запущен. Поставьте python3 вручную, выполните sh $DIR/stats_auth.sh initialize и затем $INITD_SCRIPT restart" >&2
    return 1
  fi
}

initialize_web_auth() {
  code=$(python3 "$DIR/stats_auth.py" initialize \
    --state-dir "$DIR/.stats-auth" \
    --runtime-dir "${STATS_AUTH_RUNTIME_DIR:-/tmp/mihomo-speedtest-auth}") || return 1
  if [ -n "$code" ]; then
    echo "install.sh: одноразовый код первичной настройки: $code" >&2
    echo "install.sh: откройте http://<адрес роутера>:${STATS_HTTP_PORT:-8899}/setup и задайте логин и пароль" >&2
  fi
}

main() {
  check_mihomo_process && check_versions || return 1

  if [ ! -f "$CONFIG" ]; then
    # Новый роутер: config.yaml ещё нет. Вместо отказа передаём управление
    # мастеру настройки (setup.sh, который сам в конце вызывает install.sh
    # ещё раз - см. setup.sh) - это второй из двух сценариев однострочной
    # установки (см. bootstrap-блок в начале файла): "конфиг уже настроен"
    # обрабатывается штатным продолжением main() ниже, "конфига нет" - тут.
    [ -f "$SELFDIR/setup.sh" ] || { echo "install.sh: $CONFIG не найден и $SELFDIR/setup.sh недоступен для настройки" >&2; return 1; }
    echo "install.sh: $CONFIG не найден - похоже, это установка на новом роутере. Запускаю мастер настройки (setup.sh)" >&2
    # Под "curl ... | sh" стандартный ввод занят телом самого install.sh -
    # без переоткрытия от терминала интерактивные read -r в setup.sh сразу
    # получат EOF вместо ответов пользователя. Если stdin уже терминал
    # (обычный "sh install.sh" после ручного переноса файлов) - трогать
    # не нужно; если терминала нет вовсе - оставляем как есть, setup.sh
    # сам корректно откажет на первом read.
    # "exec < /dev/tty" сам по себе фатален для sh при неудаче (нет
    # управляющего терминала - это нормально для не-интерактивных
    # запусков), даже с последующим "|| true" - POSIX требует, чтобы shell
    # завершился при ошибке редиректа у голого exec без команды. Поэтому
    # сначала пробуем открыть /dev/tty в отдельном подшелле: его неудача
    # убивает только подшелл, а не install.sh.
    if [ ! -t 0 ] && (exec < /dev/tty) 2>/dev/null; then
      exec < /dev/tty
    fi
    export SELFDIR DIR CONFIG
    exec sh "$SELFDIR/setup.sh"
  fi
  for f in $ALL_PROJECT_FILES; do
    [ -f "$SELFDIR/$f" ] || {
      echo "install.sh: $SELFDIR/$f не найден рядом с install.sh" >&2
      return 1
    }
  done
  "$BIN" -t -d "$MIHOMO_DIR" -f "$CONFIG" >/dev/null 2>&1 || {
    echo "install.sh: $CONFIG не проходит mihomo -t" >&2
    return 1
  }

  if ! PARSED=$(awk -v CONFIG="$CONFIG" -v CONFDIR="$MIHOMO_DIR" -f "$SELFDIR/providers.awk" "$CONFIG"); then
    echo "install.sh: providers.awk не смог разобрать $CONFIG" >&2
    return 1
  fi
  eval "$PARSED"

  for src in $SOURCES; do
    [ -f "$src" ] && continue
    name=$(basename "$src" .yaml)
    curl -f -s -m 10 -X PUT "http://$API_MAIN/providers/proxies/$name" >/dev/null 2>&1 || true
    sleep 3
    [ -f "$src" ] || {
      echo "install.sh: кэш $src не появился, сначала чините подписку $name" >&2
      return 1
    }
  done

  resolve_block || return 1
  echo "install.sh: фильтр ($BLOCK_SOURCE): $BLOCK" >&2

  CHANNEL=$(measure_channel)
  if [ "$CHANNEL" -gt 0 ] 2>/dev/null; then
    MIN_SPEED=$(compute_min_speed "$CHANNEL")
    echo "install.sh: канал $((CHANNEL/1048576)) МБ/с, порог $((MIN_SPEED/1048576)) МБ/с" >&2
  else
    # MIN_SPEED в шапке speedtest2.sh - не в кавычках (число), в отличие
    # от BLOCK; читаем тем же read_speedtest_const, что и MIN_RATIO/MIN_FLOOR.
    MIN_SPEED=$(read_speedtest_const MIN_SPEED 1048576)
    echo "install.sh: прямой замер канала не удался, порог из дефолта: $MIN_SPEED" >&2
  fi

  write_env "$DIR/speedtest2.env" || {
    echo "install.sh: не удалось записать speedtest2.env" >&2
    return 1
  }
  install_files || {
    echo "install.sh: не удалось установить файлы" >&2
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
    echo "install.sh: WARN - не удалось инициализировать авторизацию, веб-интерфейс не запущен" >&2
  fi
  if [ "$web_ready" = 1 ] && [ -x "$INITD_SCRIPT" ]; then
    if "$INITD_SCRIPT" restart >/dev/null 2>&1; then
      echo "install.sh: веб-сервис статистики запущен ($INITD_SCRIPT restart)" >&2
    else
      echo "install.sh: WARN - $INITD_SCRIPT restart не удался, веб-сервис статистики не поднят - проверьте вручную" >&2
    fi
  elif [ "$web_ready" = 1 ]; then
    echo "install.sh: WARN - $INITD_SCRIPT не найден после установки, веб-сервис статистики не запущен" >&2
  else
    [ ! -x "$INITD_SCRIPT" ] || "$INITD_SCRIPT" stop >/dev/null 2>&1 || true
    echo "install.sh: CLI, speedtest и обновлятор установлены; веб-интерфейс отключён до установки Python 3" >&2
  fi

  if [ "${SKIP_TRIAL:-0}" != 1 ]; then
    "$DIR/speedtest2.sh" || true
    echo "install.sh: пробный запуск завершён, хвост журнала:" >&2
    tail -5 "$DIR/speedtest.log" 2>/dev/null >&2 || true
  fi

  echo "install.sh: установка завершена" >&2
}

recalibrate_main() {
  ENVFILE=${ENVFILE:-$DIR/speedtest2.env}
  [ -f "$ENVFILE" ] || {
    echo "install.sh: $ENVFILE не найден, сначала обычная установка" >&2
    return 1
  }
  CHANNEL=$(measure_channel)
  if [ "$CHANNEL" -gt 0 ] 2>/dev/null; then
    NEW_MIN=$(compute_min_speed "$CHANNEL")
  else
    echo "install.sh: прямой замер канала не удался, MIN_SPEED не изменён" >&2
    return 1
  fi
  recalibrate_env "$ENVFILE" "$NEW_MIN" || return 1
  echo "install.sh: MIN_SPEED пересчитан: $((NEW_MIN/1048576)) МБ/с" >&2
}

if [ "${INSTALL_LIB_ONLY:-0}" != 1 ]; then
  if [ "${1:-}" = "--recalibrate" ]; then
    recalibrate_main
  else
    main "$@"
  fi
fi
