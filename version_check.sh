#!/bin/sh
# version_check.sh — общая библиотека проверки версий и наличия процесса
# mihomo. Подключается из install.sh/setup.sh как `. ./version_check.sh`.
# Библиотека не имеет побочных эффектов при подключении — все проверки
# запускаются явно вызывающим кодом (check_mihomo_process, check_versions).

# Захардкожено намеренно (не ${VAR:-default}) — это фиксирует жёсткий,
# не обходимый через переменные окружения минимум (см. AGENTS.md). Если
# бы использовался fallback-синтаксис, `MIN_XKEEN_VERSION=0 sh setup.sh`
# клиента отключал бы проверку целиком. Тесты по-прежнему могут
# переопределять эти переменные ПОСЛЕ подключения файла — на конкретный
# вызов check_versions (`MIN_XKEEN_VERSION=2.1 check_versions`), это не
# затрагивается: присваивание ниже фиксирует значение только в момент
# подключения (`. version_check.sh`), а не при каждом вызове.
MIN_XKEEN_VERSION=2.0
MIN_MIHOMO_VERSION=1.19.29
MIN_KEENETICOS_VERSION=5.1.4

version_ge() {
  # version_ge КАНДИДАТ МИНИМУМ — код возврата 0, если КАНДИДАТ >= МИНИМУМ.
  # Версия дополняется нулями до 4 сегментов по 5 цифр и сравнивается как
  # строка — без зависимости от `sort -V`, не гарантированного в BusyBox.
  # Хвост после первого не цифро-точечного символа отбрасывается
  # ("2.0 Stable" -> "2.0").
  awk -v a="$1" -v b="$2" '
    function pad(s,    n, arr, i, out) {
      gsub(/[^0-9.].*$/, "", s)
      n = split(s, arr, ".")
      out = ""
      for (i = 1; i <= 4; i++) out = out sprintf("%05d", (i <= n ? arr[i] + 0 : 0))
      return out
    }
    BEGIN { exit !(pad(a) >= pad(b)) }
  '
}

check_mihomo_process() {
  if command -v pidof >/dev/null 2>&1; then
    if pidof mihomo >/dev/null 2>&1; then
      return 0
    fi
  else
    if ps w 2>/dev/null | grep -v grep | grep -q '[m]ihomo'; then
      return 0
    fi
  fi
  echo "version_check: процесс mihomo не найден — выполните 'xkeen -mihomo', затем 'xkeen -restart'" >&2
  return 1
}

xkeen_version() {
  xkeen -v 2>/dev/null | awk '{ gsub(/\033\[[0-9;]*m/, "") } /Версия XKeen/ { print $3; exit }'
}

mihomo_version() {
  xkeen -v 2>/dev/null | awk '{ gsub(/\033\[[0-9;]*m/, "") } /Mihomo версии/ { print $NF; exit }'
}

keeneticos_version() {
  ndmc -c show version 2>/dev/null | grep -F 'version' | grep -oE '[0-9]+\.[0-9.]*[0-9]' | head -1
}

check_versions() {
  ok=1

  found=$(xkeen_version)
  if [ -z "$found" ] || ! version_ge "$found" "$MIN_XKEEN_VERSION"; then
    echo "version_check: версия XKeen ниже минимума: обнаружено '${found:-не найдено}', нужно не ниже $MIN_XKEEN_VERSION" >&2
    ok=0
  fi

  found=$(mihomo_version)
  if [ -z "$found" ] || ! version_ge "$found" "$MIN_MIHOMO_VERSION"; then
    echo "version_check: версия ядра Mihomo ниже минимума: обнаружено '${found:-не найдено}', нужно не ниже $MIN_MIHOMO_VERSION" >&2
    ok=0
  fi

  found=$(keeneticos_version)
  if [ -z "$found" ] || ! version_ge "$found" "$MIN_KEENETICOS_VERSION"; then
    echo "version_check: версия KeeneticOS ниже минимума: обнаружено '${found:-не найдено}', нужно не ниже $MIN_KEENETICOS_VERSION" >&2
    ok=0
  fi

  [ "$ok" = 1 ]
}
