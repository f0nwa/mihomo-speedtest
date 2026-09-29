#!/bin/sh
# CGI-обёртка "информация о системе" для футера веб-интерфейса (артборд
# "Панель управления" - FIRMWARE/UPTIME/CPU/MEM/mihomo core, см. CHANGELOG).
# Ставится install.sh в $DIR/stats_system.sh; копия внутри раздаваемого
# каталога (cgi-bin/system) пишется сама write_stats_system() из
# speedtest2.sh - править нужно этот файл, копия перезаписывается сама.
#
# Ни один из этих показателей раньше не собирался нигде в проекте:
# release_version - из уже существующего installed-manifest.txt (то же
# поле, что читает update.sh --plan для CLI-статуса); uptime/cpu/mem -
# из /proc; статус mihomo - pidof (тот же приём, что уже есть в
# installer/version_check.sh). Только GET/HEAD, без побочных эффектов -
# авторизация не отдельная, общий _authorize() в stats_httpd.py уже
# требует сессию для любого "/api/..." кроме публичных путей.
set -eu

DIR=${DIR:-/opt/etc/mihomo-speedtest}
MIHOMO_DIR=${MIHOMO_DIR:-/opt/etc/mihomo}
UPDATE_STATE_DIR=${UPDATE_STATE_DIR:-$MIHOMO_DIR/.update}
INSTALLED_MANIFEST_PATH=${INSTALLED_MANIFEST_PATH:-$UPDATE_STATE_DIR/installed-manifest.txt}
PROC_UPTIME=${PROC_UPTIME:-/proc/uptime}
PROC_STAT=${PROC_STAT:-/proc/stat}
PROC_MEMINFO=${PROC_MEMINFO:-/proc/meminfo}
# STAT_CMD - только для тестов (подменяет живое /proc/stat детерминированной
# последовательностью снимков), аналогично UPDATE_HTTP_CMD у update.sh.
STAT_CMD=${STAT_CMD:-}
CPU_SAMPLE_DELAY=${CPU_SAMPLE_DELAY:-0.2}
PIDOF_CMD=${PIDOF_CMD:-pidof}

release_version() {
  [ -f "$INSTALLED_MANIFEST_PATH" ] || { printf 'null'; return 0; }
  # Показываем имя релиза (тег без "v": 26.9.29), а без тега - номер.
  v=$(awk -F= '$1=="RELEASE_TAG"{t=$2} $1=="RELEASE_VERSION"{n=$2} END{sub(/^v/,"",t); print (t!="")?t:n}' "$INSTALLED_MANIFEST_PATH" 2>/dev/null || true)
  [ -n "$v" ] || { printf 'null'; return 0; }
  printf '"%s"' "$v"
}

uptime_seconds() {
  [ -f "$PROC_UPTIME" ] || { printf 'null'; return 0; }
  awk '{printf "%d", $1}' "$PROC_UPTIME"
}

cpu_line() {
  if [ -n "$STAT_CMD" ]; then "$STAT_CMD"; else cat "$PROC_STAT" 2>/dev/null; fi | awk '/^cpu /{print;exit}'
}

# Честный процент занятости CPU за короткий интервал (не мгновенный снимок
# и не средняя загрузка system-wide за всё время работы) - два замера
# накопительных счётчиков /proc/stat с паузой между ними, как принято для
# top-подобных инструментов. idle=$5 (idle) + $6 (iowait) - ожидание ввода-
# вывода не считается "занятостью" CPU.
cpu_percent() {
  [ -n "$STAT_CMD" ] || [ -f "$PROC_STAT" ] || { printf 'null'; return 0; }
  s1=$(cpu_line)
  [ -n "$s1" ] || { printf 'null'; return 0; }
  sleep "$CPU_SAMPLE_DELAY" 2>/dev/null || true
  s2=$(cpu_line)
  printf '%s\n%s\n' "$s1" "$s2" | awk '
    NR==1 { for (i=2;i<=NF;i++) t1+=$i; idle1=$5+$6 }
    NR==2 { for (i=2;i<=NF;i++) t2+=$i; idle2=$5+$6 }
    END {
      dt=t2-t1; di=idle2-idle1
      if (dt<=0) { printf "0"; exit }
      printf "%d", (100*(dt-di))/dt
    }'
}

mem_percent() {
  [ -f "$PROC_MEMINFO" ] || { printf 'null'; return 0; }
  awk '
    /^MemTotal:/ { total=$2 }
    /^MemAvailable:/ { avail=$2; have_avail=1 }
    /^MemFree:/ { free=$2 }
    END {
      if (total <= 0) { printf "null"; exit }
      if (!have_avail) { avail = free }
      printf "%d", (100 * (total - avail)) / total
    }' "$PROC_MEMINFO"
}

mihomo_active() {
  command -v "$PIDOF_CMD" >/dev/null 2>&1 || { printf 'null'; return 0; }
  if "$PIDOF_CMD" mihomo >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi
}

cmd_status() {
  printf '{"release_version":%s,"uptime_seconds":%s,"cpu_percent":%s,"mem_percent":%s,"mihomo_active":%s}\n' \
    "$(release_version)" "$(uptime_seconds)" "$(cpu_percent)" "$(mem_percent)" "$(mihomo_active)"
}

json_error() {
  echo "Content-Type: application/json; charset=utf-8"
  echo
  printf '{"error":"%s"}\n' "$1"
}

if [ -n "${REQUEST_METHOD:-}" ]; then
  case $REQUEST_METHOD in
    GET|HEAD)
      echo "Content-Type: application/json; charset=utf-8"
      echo
      cmd_status ;;
    *) json_error "method_not_allowed" ;;
  esac
else
  cmd_status
fi
