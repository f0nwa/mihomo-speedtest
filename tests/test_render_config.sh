#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/config-tools/render_config.awk"
TEMPLATE="$ROOT/config-tools/config.example.yaml"
FAILED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

assert_contains() {
  case "$2" in
    *"$1"*) ;;
    *) echo "FAIL: expected to find: $1" >&2; FAILED=1 ;;
  esac
}

assert_not_contains() {
  case "$2" in
    *"$1"*) echo "FAIL: expected NOT to find: $1" >&2; FAILED=1 ;;
  esac
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAIL: '$1' != '$2' ($3)" >&2
    FAILED=1
  fi
}

# Имена провайдеров теперь приходят третьим полем (их подбирает
# assign_provider_names() в setup.sh) - render_config.awk просто
# использует то, что дано, вместо генерации provider-1/2/3.
printf 'https://sub1.example/AAA\tclash.meta\tmyprov\n' > "$WORK/providers.txt"
OUT=$(awk -v providers_file="$WORK/providers.txt" -f "$SCRIPT" "$TEMPLATE")

assert_contains 'myprov:' "$OUT"
assert_not_contains 'provider-1:' "$OUT"
assert_not_contains 'provider-a:' "$OUT"
assert_not_contains 'provider-b:' "$OUT"
assert_not_contains 'provider-c:' "$OUT"
assert_contains 'url: "https://sub1.example/AAA"' "$OUT"
assert_contains 'path: ./proxy-providers/myprov.yaml' "$OUT"
assert_contains '- "clash.meta"' "$OUT"
assert_contains 'sub-names: &sub-names [myprov]' "$OUT"
assert_contains 'fast:' "$OUT"
assert_eq "$(printf '%s' "$OUT" | grep -c 'health-check: \*gstatic-health-check')" "1" "ровно один сгенерированный провайдер ссылается на health-check якорь"

printf 'https://sub1.example/AAA\tclash.meta\tmyprov\nhttps://sub2.example/BBB\tv2rayNG/1.8.0\tanotherprov\n' > "$WORK/providers2.txt"
OUT2=$(awk -v providers_file="$WORK/providers2.txt" -f "$SCRIPT" "$TEMPLATE")
assert_contains 'myprov:' "$OUT2"
assert_contains 'anotherprov:' "$OUT2"
assert_contains 'sub-names: &sub-names [myprov, anotherprov]' "$OUT2"

printf '  - name: '\''Imported Node'\''\n    type: hysteria2\n    server: real.example.com\n' > "$WORK/static.txt"
OUT3=$(awk -v providers_file="$WORK/providers.txt" -v static_file="$WORK/static.txt" -f "$SCRIPT" "$TEMPLATE")
assert_contains 'Imported Node' "$OUT3"
# Check that the original Hysteria2 proxy DEFINITIONS are removed (not just the references)
assert_not_contains "  - name: '🇩🇪 Hysteria2'" "$OUT3"
assert_not_contains "  - name: '🇳🇱 Hysteria2'" "$OUT3"

# Резерв «⚡ Самые быстрые + Fallback»
# (видимый пул + fallback на Fallback-Stable)
# должен сохраняться при рендере во всех сценариях: без импортов,
# с несколькими провайдерами, с импортированными статическими узлами. Пул теперь
# виден в дашборде как обычная группа, без hidden.
for rendered in "$OUT" "$OUT2" "$OUT3"; do
  assert_contains "name: '⚡ Быстрый пул'" "$rendered"
  assert_contains "name: '⚡ Самые быстрые + Fallback'" "$rendered"
  assert_contains "proxies: ['⚡ Быстрый пул', '🛡️Fallback-Stable']" "$rendered"
  assert_contains "proxies: ['⚡ Самые быстрые + Fallback', DIRECT" "$rendered"
  assert_not_contains "name: '⚡ Самые быстрые'" "$rendered"
  # hidden: true - только у служебной группы MST-SPEEDTEST (замер WG через
  # основное ядро), остальные видимы. WG-победители входят напрямую;
  # технические группы FAST-WG больше не генерируются.
  hidden_owner=$(printf '%s\n' "$rendered" | awk '/^  - name:/{g=$0} /hidden: true/{print g}')
  assert_eq "$hidden_owner" "  - name: MST-SPEEDTEST" "hidden только у служебных групп"
  assert_contains "  # --- FAST_WG:BEGIN ---" "$rendered"
  assert_contains "    # --- FAST_WG_REF:BEGIN ---" "$rendered"
  assert_not_contains "MST-FAST-WG" "$rendered"
  assert_contains '  - name: mst-speedtest' "$rendered"
  assert_contains '    proxy: MST-SPEEDTEST' "$rendered"
done

# Всё вне маркеров не должно меняться относительно шаблона за вычетом
# добавленных секций: количество строк 'rules:' и число строк с '- name:'
# групп сервисов совпадает между шаблоном и рендером.
TPL_RULES=$(grep -c '^rules:$' "$TEMPLATE")
OUT_RULES=$(printf '%s' "$OUT2" | grep -c '^rules:$')
assert_eq "$OUT_RULES" "$TPL_RULES" "rules: count preserved"

# Без dns_file (по умолчанию) итоговый config.yaml не должен содержать
# верхнеуровневый ключ dns: - шаблон сам по себе его не задаёт (маркеры
# STATIC_DNS упоминают "dns:" в тексте комментария, поэтому проверяем
# именно наличие строки-ключа, а не голую подстроку).
printf '%s\n' "$OUT" | grep -qx 'dns:' && { echo "FAIL: unexpected top-level dns: key without dns_file" >&2; FAILED=1; }

printf 'dns:
  enable: true
  nameserver:
    - 8.8.8.8
' > "$WORK/dns.txt"
OUT4=$(awk -v providers_file="$WORK/providers.txt" -v dns_file="$WORK/dns.txt" -f "$SCRIPT" "$TEMPLATE")
assert_contains 'dns:' "$OUT4"
assert_contains '8.8.8.8' "$OUT4"
assert_contains 'STATIC_DNS:BEGIN' "$OUT4"
assert_contains 'STATIC_DNS:END' "$OUT4"

# listeners_file: свои входы между маркерами STATIC_LISTENERS, служебный вход
# остаётся из шаблона; свой вход на порту служебного (7896) - отказ, код 3.
printf '  - name: my-socks\n    type: socks\n    port: 7777\n' > "$WORK/listeners.txt"
OUT5=$(awk -v providers_file="$WORK/providers.txt" -v listeners_file="$WORK/listeners.txt" -f "$SCRIPT" "$TEMPLATE")
between=$(printf '%s\n' "$OUT5" | awk '/STATIC_LISTENERS:BEGIN/{f=1;next} /STATIC_LISTENERS:END/{f=0} f')
assert_eq "$between" "$(printf '  - name: my-socks\n    type: socks\n    port: 7777')" "свои входы между маркерами"
assert_contains '  - name: mst-speedtest' "$OUT5"
printf '  - name: my-http\n    type: http\n    port: 7896\n' > "$WORK/listeners_bad.txt"
rc=0; awk -v providers_file="$WORK/providers.txt" -v listeners_file="$WORK/listeners_bad.txt" -f "$SCRIPT" "$TEMPLATE" > /dev/null 2>&1 || rc=$?
assert_eq "$rc" "3" "вход на порту 7896 - отказ"

if [ "$FAILED" = 1 ]; then
  echo "test_render_config.sh: FAILED" >&2
  exit 1
fi
echo "test_render_config.sh: OK"
