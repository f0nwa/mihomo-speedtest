#!/bin/sh
# Тесты installer/ui.sh: plain-режим, определение режима, лог.
# live-режим без pty не проверяется - его покрывают pty-тесты следующих задач.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LIB=$ROOT/installer/ui.sh
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$LIB" ] || fail "нет installer/ui.sh"
sh -n "$LIB" || fail "ui.sh не проходит sh -n"

T=$(mktemp -d "${TMPDIR:-/tmp}/ui-test.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

# ui_init вызывается только внутри подшелла: позже он ставит trap EXIT,
# который не должен затирать trap очистки этого файла.
ESC=$(printf '\033')

test_plain_no_escape() {
  (
    . "$LIB"
    UI=plain UI_LOG=$T/p.log
    export UI UI_LOG
    ui_init
    ui_banner A B; ui_kv Режим Новая; ui_step 1 6 X; ui_ok Y 3; ui_fail Z
    ui_warn W; printf 'l1\nl2\n' | ui_note warn; ui_done D; ui_abort
  ) 2>"$T/err" || fail "plain: ненулевой код"
  ! grep -q "$ESC" "$T/err" || fail "plain: найден ESC"
  grep -q '^== A — B ==$' "$T/err" || fail "plain: баннер"
  grep -q '^  Режим:' "$T/err" || fail "plain: ui_kv"
  grep -q '^ 01/06  X' "$T/err" || fail "plain: ui_step"
  grep -q '\[OK\] Y 3 с' "$T/err" || fail "plain: ui_ok"
  grep -q '\[!!\] Z' "$T/err" || fail "plain: ui_fail"
  grep -q '\[!\] W' "$T/err" || fail "plain: ui_warn"
  grep -q '| l2' "$T/err" || fail "plain: ui_note"
  grep -q '\[OK\] D' "$T/err" || fail "plain: ui_done"
  grep -q 'остановлена на шаге 01/06' "$T/err" || fail "plain: ui_abort"
  grep -q "Подробности: $T/p.log" "$T/err" || fail "plain: ui_abort лог"
}

test_mode_detect() {
  m=$( . "$LIB"; UI_LOG=$T/m.log; unset UI NO_COLOR; ui_init 2>/dev/null; echo "$UI_MODE" )
  [ "$m" = plain ] || fail "не tty -> plain, получено $m"
  m=$( . "$LIB"; UI_LOG=$T/m.log; NO_COLOR=1; ui_init 2>/dev/null; echo "$UI_MODE" )
  [ "$m" = plain ] || fail "NO_COLOR -> plain"
  m=$( . "$LIB"; UI_LOG=$T/m.log; TERM=dumb; ui_init 2>/dev/null; echo "$UI_MODE" )
  [ "$m" = plain ] || fail "TERM=dumb -> plain"
  m=$( . "$LIB"; UI_LOG=$T/m.log; UI=plain; ui_init 2>/dev/null; echo "$UI_MODE" )
  [ "$m" = plain ] || fail "UI=plain -> plain"
}

test_log_written() {
  ( . "$LIB"; UI_LOG=$T/i.log; ui_init 2>/dev/null; ui_log hello )
  grep -q 'hello' "$T/i.log" || fail "ui_log не записал строку"
  grep -q '=====' "$T/i.log" || fail "нет разделителя в логе"
  grep -Eq '^[0-9]{2}:[0-9]{2}:[0-9]{2} hello' "$T/i.log" || fail "нет времени в строке лога"
}

test_log_unwritable() {
  # stderr целиком в файл: недоступный лог не должен ничего печатать
  r=$( . "$LIB"; UI_LOG=/nonexistent/ro/x.log; ui_init; ui_log x; echo "$UI_LOG" ) 2>"$T/ul.err" \
    || fail "недоступный лог не должен ронять установку"
  [ "$r" = /dev/null ] || fail "UI_LOG должен стать /dev/null, получено $r"
  [ ! -s "$T/ul.err" ] || fail "недоступный лог утёк в stderr: $(cat "$T/ul.err")"
}

test_log_trim() {
  i=0; : > "$T/big.log"
  while [ "$i" -lt 6000 ]; do
    echo "строка лога номер $i с наполнителем для объёма xxxxxxxxxxxxxxxx" >> "$T/big.log"
    i=$((i + 1))
  done
  [ "$(wc -c < "$T/big.log")" -gt 262144 ] || fail "тестовый лог слишком мал"
  ( . "$LIB"; UI_LOG=$T/big.log; ui_init 2>/dev/null )
  n=$(wc -l < "$T/big.log")
  [ "$n" -le 301 ] || fail "лог не обрезан: $n строк"
  grep -q 'номер 5999 ' "$T/big.log" || fail "обрезка потеряла хвост"
}

test_continue_section() {
  out=$( . "$LIB"; UI_LOG=$T/c.log; UI=plain; UI_CONTINUE=1; ui_init; ui_banner A Установка 2>&1 )
  [ "$out" = "== Установка ==" ] || fail "UI_CONTINUE: получено '$out'"
}

test_run_rc() {
  rc=0
  (
    . "$LIB"
    UI=plain UI_LOG=$T/r.log
    export UI UI_LOG
    ui_init
    rc=0; ui_run T sh -c 'echo out; exit 3' || rc=$?
    echo "$rc" > "$T/r.rc"
  ) 2>"$T/r.err" || fail "run_rc: подшелл упал"
  [ "$(cat "$T/r.rc")" = 3 ] || fail "ui_run должен вернуть код команды (3), получено $(cat "$T/r.rc")"
  grep -q out "$T/r.log" || fail "вывод команды не попал в лог"
  grep -q '\[!!\] T' "$T/r.err" || fail "run_rc: нет [!!] T"
  grep -q 'out' "$T/r.err" || fail "run_rc: нет хвоста вывода"
  grep -q 'Подробности:' "$T/r.err" || fail "run_rc: нет Подробности"
  ! grep -q "$ESC" "$T/r.err" || fail "run_rc: ESC в plain"
}

test_run_ok() {
  (
    . "$LIB"
    UI=plain UI_LOG=$T/o.log
    export UI UI_LOG
    ui_init
    ui_run T true
  ) 2>"$T/o.err" || fail "run_ok: ненулевой код"
  grep -q '\[OK\] T' "$T/o.err" || fail "run_ok: нет [OK] T"
}

test_run_stdin_isolated() {
  (
    . "$LIB"
    UI=plain UI_LOG=$T/s.log
    export UI UI_LOG
    ui_init
    printf 'answer\n' | { ui_run T sh -c 'read x; echo "got:$x"'; read y; echo "after:$y" >&2; }
  ) 2>"$T/s.err" || fail "stdin: ненулевой код"
  grep -q 'after:answer' "$T/s.err" || fail "ui_run съел stdin вызывающего"
  ! grep -q 'got:answer' "$T/s.log" || fail "команда прочитала stdin вызывающего"
}

test_run_tick() {
  (
    . "$LIB"
    UI=plain UI_LOG=$T/k.log UI_TICK=1
    export UI UI_LOG UI_TICK
    ui_init
    ui_run T sleep 3
  ) 2>"$T/k.err" || fail "tick: ненулевой код"
  n=$(grep -c '^\[\.\.\] T ещё выполняется, ждите\.\.\.$' "$T/k.err" || :)
  [ "$n" -ge 2 ] || fail "tick: ожидалось >=2 тиков, получено $n"
}

test_term_rc() {
  # SIGTERM: код выхода 143 (128+15), как без ui_init; INT - 130.
  # Отдельный sh-процесс: kill $$ в подшелле убил бы сам тест.
  cat > "$T/term.sh" <<EOS
. "$LIB"
UI=plain UI_LOG=$T/term.log
ui_init
ui_on_exit 'echo TERMHOOK >&2'
kill -TERM \$\$
sleep 5
EOS
  rc=0; sh "$T/term.sh" 2>"$T/term.err" || rc=$?
  [ "$rc" = 143 ] || fail "TERM: ожидался код 143, получен $rc"
  grep -q TERMHOOK "$T/term.err" || fail "TERM: хук ui_on_exit не выполнен"
  sed 's/-TERM/-INT/' "$T/term.sh" > "$T/int.sh"
  rc=0; sh "$T/int.sh" 2>/dev/null || rc=$?
  [ "$rc" = 130 ] || fail "INT: ожидался код 130, получен $rc"
}

test_progress_plain() {
  (
    . "$LIB"
    UI=plain UI_LOG=$T/g.log
    export UI UI_LOG
    ui_init
    i=1
    while [ "$i" -le 25 ]; do ui_progress Копирование "$i" 25 файл; i=$((i + 1)); done
    ui_progress_end
  ) 2>"$T/g.err" || fail "progress: ненулевой код"
  [ "$(wc -l < "$T/g.err" | tr -d ' ')" = 4 ] || fail "progress: ожидалось 4 строки: $(cat "$T/g.err")"
  for k in 1 10 20 25; do
    grep -q "^\[\.\.\] Копирование $k/25 файл$" "$T/g.err" || fail "progress: нет строки для $k"
  done
}

test_on_exit_hooks() {
  rm -f "$T/hook.f"
  (
    . "$LIB"
    UI=plain UI_LOG=$T/h.log
    export UI UI_LOG
    ui_init
    ui_on_exit "echo h1 >>$T/hook.f"
    ui_on_exit "echo h2 >>$T/hook.f"
    exit 0
  ) 2>/dev/null
  [ "$(cat "$T/hook.f")" = "h1
h2" ] || fail "on_exit: хуки не по порядку/не один раз: $(cat "$T/hook.f")"
}

test_menu_plain() {
  (
    . "$LIB"
    UI=plain UI_LOG=$T/m2.log
    export UI UI_LOG
    ui_init
    ui_menu "Выбор" 2 "один" "два"
  ) 2>"$T/mn.err" || fail "menu: ненулевой код"
  grep -q '| Выбор' "$T/mn.err" || fail "menu: нет заголовка"
  grep -q ' 1) один' "$T/mn.err" || fail "menu: нет пункта 1"
  grep -q ' 2) два  (по умолчанию)' "$T/mn.err" || fail "menu: нет пометки по умолчанию"
  ! grep -q '1) один  (по умолчанию)' "$T/mn.err" || fail "menu: пометка не у того пункта"
}

test_ask_plain() {
  (
    . "$LIB"
    UI=plain UI_LOG=$T/a.log
    export UI UI_LOG
    ui_init
    ui_ask "Введите номер"
  ) 2>"$T/ak.err" || fail "ask: ненулевой код"
  [ "$(cat "$T/ak.err")" = "[??] Введите номер: " ] || fail "ask: получено '$(cat "$T/ak.err")'"
  [ "$(wc -l < "$T/ak.err" | tr -d ' ')" = 0 ] || fail "ask: не должно быть перевода строки"
}

test_plain_no_escape
test_mode_detect
test_log_written
test_log_unwritable
test_log_trim
test_continue_section
test_run_rc
test_run_ok
test_run_stdin_isolated
test_run_tick
test_term_rc
test_progress_plain
test_on_exit_hooks
test_menu_plain
test_ask_plain
echo "OK: test_ui"
