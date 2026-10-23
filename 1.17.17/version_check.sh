#!/bin/sh
# version_check.sh - общая библиотека проверки версий и наличия процесса
# mihomo. Подключается из install.sh/setup.sh как `. ./version_check.sh`.
# Библиотека не имеет побочных эффектов при подключении - все проверки
# запускаются явно вызывающим кодом (check_mihomo_process, check_versions).

# Захардкожено намеренно (не ${VAR:-default}) - это фиксирует жёсткий,
# не обходимый через переменные окружения минимум (см. AGENTS.md). Если
# бы использовался fallback-синтаксис, `MIN_XKEEN_VERSION=0 sh setup.sh`
# клиента отключал бы проверку целиком. Тесты по-прежнему могут
# переопределять эти переменные ПОСЛЕ подключения файла - на конкретный
# вызов check_versions (`MIN_XKEEN_VERSION=2.1 check_versions`), это не
# затрагивается: присваивание ниже фиксирует значение только в момент
# подключения (`. version_check.sh`), а не при каждом вызове.
MIN_XKEEN_VERSION=2.0
MIN_MIHOMO_VERSION=1.19.29
MIN_KEENETICOS_VERSION=5.1.4

version_ge() {
  # version_ge КАНДИДАТ МИНИМУМ - код возврата 0, если КАНДИДАТ >= МИНИМУМ.
  # Версия дополняется нулями до 4 сегментов по 5 цифр и сравнивается как
  # строка - без зависимости от `sort -V`, не гарантированного в BusyBox.
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
  echo "version_check: Процесс mihomo не найден - выполните 'xkeen -mihomo', затем 'xkeen -restart'" >&2
  return 1
}

# Вывод `xkeen -v` разбираем терпимо: формат строк меняется между релизами
# (в 2.1 строка с версией не совпала с "Версия XKeen"), вывод может идти в
# stderr, версия может быть с префиксом "v". Берём первую строку со словом
# XKeen (без Mihomo/Xray) и первое число вида N.N[.N] в ней.
xkeen_v_output() {
  xkeen -v 2>&1
}

# Запасной источник: версия пакета в opkg. Может отставать от реальной
# (после самообновления XKeen opkg показывал 2.0 при `xkeen -v` = 2.1),
# поэтому используется только если `xkeen -v` не удалось разобрать.
xkeen_version_opkg() {
  opkg list-installed xkeen 2>/dev/null | awk '$1 == "xkeen" && match($0, /[0-9]+\.[0-9]+(\.[0-9]+)*/) {
    print substr($0, RSTART, RLENGTH); exit
  }'
}

xkeen_version() {
  _xv=$(xkeen_v_output | awk '
    { gsub(/\033\[[0-9;]*[A-Za-z]/, ""); gsub(/\r/, "") }
    { l = tolower($0) }
    l ~ /xkeen/ && l !~ /mihomo|xray/ && match($0, /[0-9]+\.[0-9]+(\.[0-9]+)*/) {
      print substr($0, RSTART, RLENGTH); exit
    }')
  [ -n "$_xv" ] || _xv=$(xkeen_version_opkg)
  printf '%s\n' "$_xv"
}

mihomo_version() {
  xkeen_v_output | awk '
    { gsub(/\033\[[0-9;]*[A-Za-z]/, ""); gsub(/\r/, "") }
    tolower($0) ~ /mihomo/ && match($0, /[0-9]+\.[0-9]+(\.[0-9]+)*/) {
      print substr($0, RSTART, RLENGTH); exit
    }'
}

# Версию KeeneticOS берём не из любой строки со словом "version" - в выводе
# `ndmc -c show version` их несколько, и это разные версии (ndw3: 5.1.17 -
# версия компонента, ndw4: 5.1.C.4.1 - сборка с буквой канала). Источники
# по убыванию надёжности:
#   1. title: 5.1.4                  - человекочитаемая версия прошивки;
#   2. release: 5.01.C.4.0-1         - N.NN.<канал>.<патч>.<сборка>-<ревизия>;
#   3. ndw4 -> version: 5.1.C.6.0    - тот же шаблон, только внутри блока ndw4;
#   4. ndm.core.version: "5.1.4 ..." - старый формат вывода.
# title без патч-сегмента (например "5.1" у предрелизной сборки) считается
# неполным, и тогда берётся версия, собранная из release/ndw4. Пример
# вывода обоих форматов - в tests/test_version_check.sh.
keeneticos_version() {
  ndmc -c show version 2>/dev/null | awk '
    function from_build(s,    t, a) {
      # "5.01.C.4.0-1" / "5.1.C.6.0" -> "5.1.4" / "5.1.6"
      if (!match(s, /[0-9]+\.[0-9]+\.[A-Za-z]+\.[0-9]+/)) return ""
      split(substr(s, RSTART, RLENGTH), a, ".")
      return (a[1] + 0) "." (a[2] + 0) "." (a[4] + 0)
    }
    function plain(s) {
      return match(s, /[0-9]+(\.[0-9]+)+/) ? substr(s, RSTART, RLENGTH) : ""
    }
    function value(s) {
      sub(/^[ \t]*[^:]*:[ \t]*"?/, "", s)
      return s
    }
    { sub(/\r$/, "") }
    /^[ \t]*[A-Za-z0-9_.]+:[ \t]*$/ { blk = $0; gsub(/[ \t:]/, "", blk); next }
    /^[ \t]*title:/   { title = plain(value($0)); next }
    /^[ \t]*release:/ { rel = from_build(value($0)); next }
    /^[ \t]*version:/ && blk == "ndw4" { ndw4 = from_build(value($0)); next }
    /^[ \t]*ndm\.core\.version:/ { legacy = plain(value($0)); next }
    END {
      if (split(title, p, ".") >= 3) r = title
      else if (rel != "")            r = rel
      else if (ndw4 != "")           r = ndw4
      else if (title != "")          r = title
      else                           r = legacy
      if (r != "") print r
    }'
}

xkeen_ui_dns_protection_active() {
  # Определяет, похоже ли, что сторонняя панель Xkeen UI сейчас держит
  # DNS роутера через свою "Защищённую DNS Mihomo" (или DNS-over-VLESS -
  # оба её ассистента одинаково флипают эти два переключателя вместе).
  # Используется в setup.sh перед перезаписью config.yaml: хотя
  # существующий dns: и переносится как есть (existing_config.awk), панель
  # хранит хэш ВСЕГО файла на момент включения своей защиты - после
  # перезаписи хэш расходится, и её кнопка "Восстановить" затирает то, что
  # применил setup.sh. Контракт и обоснование каждого сценария - в
  # tests/test_dns_guard.sh.
  #
  # Код возврата 0 - похоже, что активна (оба признака сразу, или ndmc
  # недоступен и проверить нельзя - при сомнении лучше лишний раз
  # предупредить, чем молча перезаписать чужой DNS-конфиг). Код возврата 1 -
  # точно не активна.
  #
  # Проверка на "WAN-интерфейс" намеренно упрощена до поиска подстроки по
  # всему выводу "show running-config", без разбора блоков interface -
  # ложное срабатывание не страшно, пропуск - да.
  out=$(ndmc -c show running-config 2>/dev/null) || return 0
  printf '%s\n' "$out" | grep -qiE '^[[:space:]]*opkg dns-override[[:space:]]*$' || return 1
  printf '%s\n' "$out" | grep -qi 'no name-servers' || return 1
  return 0
}

# Найденные версии остаются в VC_XKEEN / VC_MIHOMO / VC_KOS (пусто - не
# найдено): install.sh показывает их в шапке установки, не вызывая
# xkeen -v и ndmc второй раз.
check_versions() {
  ok=1

  found=$(xkeen_version)
  VC_XKEEN=$found
  if [ -z "$found" ] || ! version_ge "$found" "$MIN_XKEEN_VERSION"; then
    echo "version_check: Версия XKeen ниже минимума: обнаружено '${found:-не найдено}', нужно не ниже $MIN_XKEEN_VERSION" >&2
    if [ -z "$found" ]; then
      echo "version_check: вывод 'xkeen -v' не распознан, сырой вывод:" >&2
      xkeen_v_output | sed 's/^/version_check:   | /' >&2
    fi
    ok=0
  fi

  found=$(mihomo_version)
  VC_MIHOMO=$found
  if [ -z "$found" ] || ! version_ge "$found" "$MIN_MIHOMO_VERSION"; then
    echo "version_check: Версия ядра Mihomo ниже минимума: обнаружено '${found:-не найдено}', нужно не ниже $MIN_MIHOMO_VERSION" >&2
    ok=0
  fi

  found=$(keeneticos_version)
  VC_KOS=$found
  if [ -z "$found" ] || ! version_ge "$found" "$MIN_KEENETICOS_VERSION"; then
    echo "version_check: Версия KeeneticOS ниже минимума: обнаружено '${found:-не найдено}', нужно не ниже $MIN_KEENETICOS_VERSION" >&2
    ok=0
  fi

  [ "$ok" = 1 ]
}
