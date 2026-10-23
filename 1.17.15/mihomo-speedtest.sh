#!/bin/sh
set -eu
DIR=${DIR:-/opt/etc/mihomo-speedtest}
INITD_SCRIPT=${INITD_SCRIPT:-/opt/etc/init.d/S80speedtest-stats}

usage() {
  cat >&2 <<'EOF'
Использование: mihomo-speedtest <команда> [аргументы]

Команды:
  install       Переустановить/восстановить проект (sh install.sh)
  uninstall     Удалить проект (sh uninstall.sh [аргументы])
  update        Обновить проект: проверка, вопросы и установка
  setup         Мастер настройки config.yaml (sh setup.sh)
  recalibrate   Пересчитать порог скорости (install.sh --recalibrate)
  stop-web      Остановить веб-интерфейс статистики навсегда (до start-web)
  start-web     Включить веб-интерфейс статистики обратно
  restart-web   Перезапустить веб-интерфейс статистики (отключённый остаётся отключённым)
  status        Показать состояние веб-службы статистики
  run           Запустить спидтест сейчас (sh speedtest2.sh --force [аргументы])
  reset-password Сбросить пароль веб-интерфейса (sh stats_auth.sh reset)
  show-url      Показать адрес веб-интерфейса без перезапуска
  version       Показать установленную версию релиза (офлайн)
  doctor        Проверить ядро, конфиг, веб-службу и соединения (GitHub напрямую и через mihomo)
EOF
}

# doctor: лёгкая диагностика состояния и сети (то же, что при установке и
# обновлении, но по запросу). Ничего не меняет.
doctor() {
  API_MAIN=${API_MAIN:-127.0.0.1:9090}
  MIHOMO_DIR=${MIHOMO_DIR:-/opt/etc/mihomo}
  CONFIG=${CONFIG:-$MIHOMO_DIR/config.yaml}
  BIN=${BIN:-/opt/sbin/mihomo}
  [ ! -f "$DIR/ui.sh" ] || . "$DIR/ui.sh"
  if ! command -v ui_ok >/dev/null 2>&1; then
    ui_ok() { printf '[OK] %s\n' "$1" >&2; }
    ui_warn() { printf '[!] %s\n' "$1" >&2; }
  fi
  ver=$(sed -n 's/^RELEASE_VERSION=//p' "$DIR/.update/installed-manifest.txt" 2>/dev/null | head -1)
  ui_ok "Проект: ${ver:+релиз $ver}${ver:-версия неизвестна} ($DIR)"
  if curl -s -m 2 "http://$API_MAIN/version" >/dev/null 2>&1; then
    ui_ok "Ядро mihomo отвечает на $API_MAIN"
  else
    ui_warn "Ядро mihomo не отвечает на $API_MAIN - запустите: xkeen -start (или xkeen -restart)"
  fi
  if [ ! -f "$CONFIG" ]; then
    ui_warn "Нет $CONFIG - выполните: mihomo-speedtest setup"
  elif [ -x "$BIN" ]; then
    if "$BIN" -t -d "$MIHOMO_DIR" -f "$CONFIG" >/dev/null 2>&1; then
      ui_ok "config.yaml проходит проверку mihomo -t"
    else
      ui_warn "config.yaml не проходит mihomo -t - проверьте: $BIN -t -d $MIHOMO_DIR -f $CONFIG"
    fi
  fi
  if sh "$DIR/stats_service.sh" status >/dev/null 2>&1; then
    ui_ok "Веб-служба статистики работает"
  else
    ui_warn "Веб-служба статистики не запущена - mihomo-speedtest restart-web"
  fi
  if [ -f "$DIR/netcheck.sh" ] && command -v curl >/dev/null 2>&1; then
    . "$DIR/netcheck.sh"
    NC_CONFIG=${NC_CONFIG:-$CONFIG}
    export NC_CONFIG
    nc_diagnose || :
  else
    ui_warn "Проверка соединений недоступна (нет netcheck.sh или curl) - обновите проект: mihomo-speedtest update"
  fi
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case "$cmd" in
  install)     exec sh "$DIR/install.sh" "$@" ;;
  uninstall)   exec sh "$DIR/uninstall.sh" "$@" ;;
  update)
    if [ "$#" -eq 0 ]; then
      [ -t 0 ] || exec sh "$DIR/update.sh" --check
      exec sh "$DIR/update_interactive.sh"
    fi
    exec sh "$DIR/update.sh" "$@" ;;
  setup)       exec sh "$DIR/setup.sh" "$@" ;;
  recalibrate) exec sh "$DIR/install.sh" --recalibrate ;;
  stop-web)    exec sh "$DIR/install.sh" --stop-web ;;
  start-web)   exec sh "$DIR/install.sh" --start-web ;;
  restart-web) exec "$INITD_SCRIPT" restart ;;
  status)      exec sh "$DIR/stats_service.sh" status ;;
  run)         exec sh "$DIR/speedtest2.sh" --force "$@" ;;
  reset-password) exec sh "$DIR/stats_auth.sh" reset ;;
  show-url)    exec sh "$DIR/install.sh" --show-url ;;
  version)     exec sh "$DIR/install.sh" --version ;;
  doctor)      doctor ;;
  ''|help|--help|-h) usage; exit 0 ;;
  *) echo "Неизвестная команда: $cmd" >&2; usage; exit 2 ;;
esac
