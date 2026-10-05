#!/bin/sh
# Прямые ссылки на WG-победителей, без промежуточных групп.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/config-tools/fast_wg.awk"
TEMPLATE="$ROOT/config-tools/config.example.yaml"
FAILED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; FAILED=1; }
has() { grep -qxF -- "$1" "$2" || fail "нет строки '$1' ($3)"; }
hasnt() { ! grep -qF -- "$1" "$2" || fail "лишнее '$1' ($3)"; }

# Шаблон без WG-нод (только Hysteria2) - группы и ссылки на неё нет.
awk -f "$SCRIPT" "$TEMPLATE" > "$WORK/none.yaml"
hasnt 'name: FAST-WG' "$WORK/none.yaml" "без WG-нод группа не создаётся"
hasnt "'FAST-WG" "$WORK/none.yaml" "без WG-нод ссылки в пуле нет"
grep -q '^  # --- FAST_WG:BEGIN ---' "$WORK/none.yaml" || fail "маркеры группы остаются"
grep -q '^    # --- FAST_WG_REF:BEGIN ---' "$WORK/none.yaml" || fail "маркеры ссылки остаются"
grep -q 'MST-FAST-WG' "$WORK/none.yaml" && fail "старое имя MST-FAST-WG"

# Две WG-ноды (одна AmneziaWG, имя в кавычках с апострофом) и hysteria2.
awk '
  /^  # --- STATIC_PROXIES:END ---/ {
    print "  - name: \"WG Bob'"'"'s\""
    print "    type: wireguard"
    print "    server: 1.2.3.4"
    print "  - name: AWG-NL"
    print "    type: \"wireguard\""
    print "    amnezia-wg-option:"
    print "      jc: 4"
  }
  { print }' "$TEMPLATE" > "$WORK/src.yaml"
awk -f "$SCRIPT" "$WORK/src.yaml" > "$WORK/wg.yaml"
hasnt "'FAST-WG" "$WORK/wg.yaml" "технические группы не создаются"
hasnt "proxies: ['WG Bob''s', 'AWG-NL']" "$WORK/wg.yaml" "до замера ноды не в быстром пуле"
printf "WG Bob's\nAWG-NL\n" > "$WORK/winners"
awk -v WINNERS="$WORK/winners" -f "$SCRIPT" "$WORK/wg.yaml" > "$WORK/won.yaml"
has "    proxies: ['WG Bob''s', 'AWG-NL']" "$WORK/won.yaml" "победители напрямую в пуле"
awk -f "$SCRIPT" "$WORK/won.yaml" > "$WORK/kept.yaml"
cmp -s "$WORK/won.yaml" "$WORK/kept.yaml" || fail "импорт/повторная обработка стирает победителей"
: > "$WORK/winners"
awk -v WINNERS="$WORK/winners" -f "$SCRIPT" "$WORK/won.yaml" > "$WORK/empty.yaml"
hasnt "proxies: ['WG Bob''s', 'AWG-NL']" "$WORK/empty.yaml" "следующий замер убирает проигравших"

# Повторный прогон ничего не меняет, а удаление WG-нод убирает группу.
awk -f "$SCRIPT" "$WORK/wg.yaml" > "$WORK/wg2.yaml"
cmp -s "$WORK/wg.yaml" "$WORK/wg2.yaml" || fail "повторный прогон меняет конфиг"
awk -f "$SCRIPT" "$WORK/none.yaml" > "$WORK/none2.yaml"
cmp -s "$WORK/none.yaml" "$WORK/none2.yaml" || fail "повторный прогон без WG меняет конфиг"
awk '/^  - name: "WG Bob/{skip=1} /^  - name: AWG-NL/{skip=1} /^  # --- STATIC_PROXIES:END/{skip=0} !skip' "$WORK/wg.yaml" > "$WORK/removed.yaml"
awk -f "$SCRIPT" "$WORK/removed.yaml" > "$WORK/removed2.yaml"
hasnt 'name: FAST-WG' "$WORK/removed2.yaml" "WG-ноды удалены - группы нет"
hasnt "'FAST-WG" "$WORK/removed2.yaml" "WG-ноды удалены - ссылки нет"

# Конфиг без маркеров (свой, не из шаблона) не трогается.
printf 'proxies:\n  - name: w\n    type: wireguard\nproxy-groups:\n  - name: x\n    type: select\n    proxies: [w]\n' > "$WORK/plain.yaml"
awk -f "$SCRIPT" "$WORK/plain.yaml" > "$WORK/plain2.yaml"
cmp -s "$WORK/plain.yaml" "$WORK/plain2.yaml" || fail "конфиг без маркеров изменён"

# Непарный маркер - отказ без вывода (иначе съели бы хвост конфига).
grep -v 'FAST_WG:END' "$WORK/src.yaml" > "$WORK/broken.yaml"
if awk -f "$SCRIPT" "$WORK/broken.yaml" > "$WORK/broken2.yaml" 2>/dev/null; then fail "непарный маркер принят"; fi
[ ! -s "$WORK/broken2.yaml" ] || fail "при отказе что-то выведено"

# busybox awk на роутере: если есть - тот же результат.
if command -v busybox >/dev/null 2>&1; then
  busybox awk -f "$SCRIPT" "$WORK/src.yaml" > "$WORK/bb.yaml"
  cmp -s "$WORK/wg.yaml" "$WORK/bb.yaml" || fail "busybox awk даёт другой результат"
fi

[ "$FAILED" = 0 ] && echo "OK: fast_wg" || exit 1
