#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/delay-selection-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

MST_LIB_ONLY=1 . "$ROOT/speedtest-runtime/speedtest2.sh"

# Числовая задержка второго, только что запущенного ядра не сопоставима
# с пингом рабочего Mihomo. Даже если в старом speedtest2.env осталось
# MAX_PING_MS, живые ноды нельзя отбрасывать по абсолютному порогу.
MAX_PING_MS=300
MAX_TESTED=2
printf '%s\n' \
  '1800 n0001' \
  '1200 n0002' \
  '0 n0003' \
  '1500 n0004' > "$TEST_ROOT/alive.txt"

select_candidates "$TEST_ROOT/alive.txt" "$TEST_ROOT/candidates.txt"

[ "$(wc -l < "$TEST_ROOT/candidates.txt" | tr -d ' ')" = 2 ] \
  || fail "живые ноды отброшены по непоказательному абсолютному пингу"
[ "$(sed -n '1p' "$TEST_ROOT/candidates.txt")" = '1200 n0002' ] \
  || fail "кандидаты не отсортированы по времени ответа"
[ "$(sed -n '2p' "$TEST_ROOT/candidates.txt")" = '1500 n0004' ] \
  || fail "MAX_TESTED не ограничил отсортированный список"

# Проверка доступности большого пула должна строить отдельные группы не
# более чем по 10 нод. Изменение обратно на одну include-all-группу должно
# сломать этот тест по составу delay_groups.txt.
WORK=$TEST_ROOT/batches
mkdir -p "$WORK"
: > "$WORK/all.yaml"
i=1
while [ "$i" -le 23 ]; do
  printf 'n%04d\tNode %d\n' "$i" "$i" >> "$WORK/map.txt"
  i=$((i + 1))
done

if ! command -v write_test_config >/dev/null 2>&1; then
  fail "write_test_config не реализует пакетные группы delay-check"
fi
write_test_config

# Соединения тестового ядра должны обходить перехват OUTPUT в XKeen,
# иначе доступные в рабочем ядре ноды получают таймауты в speedtest.
ruby -ryaml -e '
  abort "missing XKeen bypass mark" unless YAML.load_file(ARGV.fetch(0))["routing-mark"] == 255
' "$WORK/config.yaml" || fail "тестовое ядро не защищено от перехвата XKeen"

[ "$(sed -n '1p' "$WORK/delay_groups.txt")" = D0001 ] \
  || fail "первая пакетная группа не создана"
[ "$(sed -n '2p' "$WORK/delay_groups.txt")" = D0002 ] \
  || fail "вторая пакетная группа не создана"
[ "$(sed -n '3p' "$WORK/delay_groups.txt")" = D0003 ] \
  || fail "неполная последняя пакетная группа не создана"
[ "$(wc -l < "$WORK/delay_groups.txt" | tr -d ' ')" = 3 ] \
  || fail "23 ноды должны быть разбиты на три группы"
ruby -ryaml -e '
  groups = YAML.load_file(ARGV.fetch(0)).fetch("proxy-groups")
  sizes = groups.select { |g| g.fetch("name").start_with?("D") }
                .map { |g| g.fetch("proxies").length }
  abort "wrong delay batch sizes: #{sizes.inspect}" unless sizes == [10, 10, 3]
' "$WORK/config.yaml" \
  || fail "пакетные группы должны содержать 10, 10 и 3 ноды"

RUN_LOG=$WORK/run.log
: > "$RUN_LOG"
curl() {
  out=
  url=
  while [ "$#" -gt 0 ]; do
    case $1 in
      -o) shift; out=$1 ;;
      http://*) url=$1 ;;
    esac
    shift
  done
  case $url in
    */D0001/*) printf '%s\n' '{"n0001":1800,"n0002":1200}' > "$out" ;;
    */D0002/*) printf '%s\n' '{"n0011":900}' > "$out" ;;
    */D0003/*) printf '%s\n' '{"n0021":1500}' > "$out" ;;
    *) return 22 ;;
  esac
}

fetch_delays || fail "пакетная проверка доступности завершилась ошибкой"
[ "$(wc -l < "$WORK/alive.txt" | tr -d ' ')" = 4 ] \
  || fail "результаты пакетных проверок не объединены"
[ "$(sed -n '1p' "$WORK/alive.txt")" = '900 n0011' ] \
  || fail "объединённые результаты не отсортированы"

# Один неудачный пакет не должен выбрасывать результаты остальных: при
# большом смешанном пуле отдельная десятка может целиком не ответить.
curl() {
  out=
  url=
  while [ "$#" -gt 0 ]; do
    case $1 in
      -o) shift; out=$1 ;;
      http://*) url=$1 ;;
    esac
    shift
  done
  case $url in
    */D0001/*) printf '%s\n' '{"n0001":1800}' > "$out" ;;
    */D0002/*) return 22 ;;
    */D0003/*) printf '%s\n' '{"n0021":1500}' > "$out" ;;
    *) return 22 ;;
  esac
}

fetch_delays || fail "один неудачный пакет остановил весь delay-check"
[ "$(wc -l < "$WORK/alive.txt" | tr -d ' ')" = 2 ] \
  || fail "частичные успешные результаты пакетной проверки потеряны"

echo "test_delay_selection.sh: OK"
