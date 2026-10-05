#!/bin/sh
# pty-тесты live-режима installer/ui.sh: спиннер, обрезка по ширине, Ctrl+C.
# Нужен `script` (util-linux или BSD); без него тест пропускается.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LIB=$ROOT/installer/ui.sh
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v script >/dev/null 2>&1 || { echo "SKIP: нет script"; exit 0; }

T=$(mktemp -d "${TMPDIR:-/tmp}/ui-live.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
ESC=$(printf '\033')

# Форма вызова script: util-linux (-qec CMD) или macOS/BSD (-q /dev/null sh -c CMD).
if script -qec true /dev/null </dev/null >/dev/null 2>&1; then PTY=linux
elif script -q /dev/null true </dev/null >/dev/null 2>&1; then PTY=bsd
else echo "SKIP: script не работает"; exit 0
fi

# pty_run СКРИПТ ВЫВОД - выполнить sh СКРИПТ под pty, но не дольше 20 с.
pty_run() {
  _to=
  command -v timeout >/dev/null 2>&1 && _to='timeout 20'
  if [ "$PTY" = linux ]; then
    $_to script -qec "sh $1" /dev/null </dev/null >"$2" 2>&1 || :
  else
    $_to script -q /dev/null sh "$1" </dev/null >"$2" 2>&1 || :
  fi
}

test_live_escapes() {
  cat > "$T/e.sh" <<EOS
TERM=xterm; export TERM
. "$LIB"
UI_LOG=$T/e.log
ui_init
ui_run T sleep 1
ui_ok X
EOS
  pty_run "$T/e.sh" "$T/e.out"
  grep -q "${ESC}\[32m" "$T/e.out" || fail "live: нет зелёного цвета"
  grep -q "${ESC}\[?25l" "$T/e.out" || fail "live: курсор не скрыт"
  grep -Eq '⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏' "$T/e.out" || fail "live: нет кадров спиннера"
}

test_live_narrow() {
  # Подпись из 70 символов на терминале в 40 колонок должна быть обрезана.
  cat > "$T/n.sh" <<EOS
TERM=xterm; export TERM
stty cols 40
. "$LIB"
UI_LOG=$T/n.log
ui_init
ui_run xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxTAILMARK sleep 1
# Полоса с длинной подписью: заголовок + счётчик + полоса + подпись
# не должны вылезать за 40 колонок (раньше выходило 45 символов).
ui_progress "Файлы релиза" 12 31 "web/stats_app_settings.js"
ui_progress "Файлы релиза" 123 456 "web/stats_app_settings.js"
ui_progress_end
EOS
  pty_run "$T/n.sh" "$T/n.out"
  grep -q 'xxxx' "$T/n.out" || fail "narrow: нет вывода спиннера"
  grep -q '12/31' "$T/n.out" || fail "narrow: нет строки ui_progress"
  ! grep -q TAILMARK "$T/n.out" || fail "narrow: подпись не обрезана"
  # Каждый кадр между \r (без ESC-последовательностей) не длиннее ширины.
  # Считаем символы, а не байты: continuation-байты UTF-8 отбрасываем.
  m=$(tr '\r' '\n' < "$T/n.out" | sed "s/${ESC}\[[0-9;?]*[A-Za-z]//g" \
      | LC_ALL=C tr -d '\200-\277' | LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
  [ "$m" -le 40 ] || fail "narrow: строка длиной $m > 40"
}

test_live_int() {
  # Ctrl+C посреди ui_run: курсор возвращён, дочерний процесс убит, хук выполнен.
  # INT шлём из самого скрипта: у фоновых процессов теста INT игнорируется.
  cat > "$T/i.sh" <<EOS
TERM=xterm; export TERM
. "$LIB"
UI_LOG=$T/i.log
ui_init
ui_on_exit 'echo HOOKRAN >&2'
( sleep 1; kill -INT \$\$ ) &
ui_run T sleep 37
EOS
  pty_run "$T/i.sh" "$T/i.out"
  grep -q "${ESC}\[?25h" "$T/i.out" || fail "int: курсор не возвращён"
  grep -q HOOKRAN "$T/i.out" || fail "int: хук ui_on_exit не выполнен"
  if pgrep -f 'sleep 37' >/dev/null 2>&1; then
    pkill -f 'sleep 37' 2>/dev/null || :
    fail "int: sleep 37 остался жить"
  fi
}

test_live_escapes
test_live_narrow
test_live_int
echo "OK: test_ui_live"
