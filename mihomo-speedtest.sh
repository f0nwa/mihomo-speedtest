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
EOF
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
  ''|help|--help|-h) usage; exit 0 ;;
  *) echo "Неизвестная команда: $cmd" >&2; usage; exit 2 ;;
esac
