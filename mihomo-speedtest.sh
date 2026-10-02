#!/bin/sh
set -eu
DIR=${DIR:-/opt/etc/mihomo-speedtest}

usage() {
  cat >&2 <<'EOF'
Использование: mihomo-speedtest <команда> [аргументы]

Команды:
  install       Переустановить/восстановить проект (sh install.sh)
  uninstall     Удалить проект (sh uninstall.sh [аргументы])
  update        Проверить/применить обновление (sh update.sh <--check|--plan|--apply ...>)
  setup         Мастер настройки config.yaml (sh setup.sh)
  recalibrate   Пересчитать порог скорости (install.sh --recalibrate)
  stop-web      Остановить веб-интерфейс статистики навсегда (до start-web)
  start-web     Включить веб-интерфейс статистики обратно
  show-url      Показать адрес веб-интерфейса без перезапуска
  version       Показать установленную версию релиза (офлайн)
EOF
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case "$cmd" in
  install)     exec sh "$DIR/install.sh" "$@" ;;
  uninstall)   exec sh "$DIR/uninstall.sh" "$@" ;;
  update)      exec sh "$DIR/update.sh" "$@" ;;
  setup)       exec sh "$DIR/setup.sh" "$@" ;;
  recalibrate) exec sh "$DIR/install.sh" --recalibrate ;;
  stop-web)    exec sh "$DIR/install.sh" --stop-web ;;
  start-web)   exec sh "$DIR/install.sh" --start-web ;;
  show-url)    exec sh "$DIR/install.sh" --show-url ;;
  version)     exec sh "$DIR/install.sh" --version ;;
  ''|help|--help|-h) usage; exit 0 ;;
  *) echo "Неизвестная команда: $cmd" >&2; usage; exit 2 ;;
esac
