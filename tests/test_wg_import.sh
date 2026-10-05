#!/bin/sh
# wg_import.awk: перевод WireGuard/AmneziaWG .conf (wg-quick) в ноды mihomo
# и вставка их в config.yaml (proxies: и группы Авто/Fallback/Manual).
# Прогон и под busybox awk, если он есть (на роутере - он).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/config-tools/wg_import.awk"
FASTWG="$ROOT/config-tools/fast_wg.awk"
TEMPLATE="$ROOT/config-tools/config.example.yaml"
FAILED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL[$AWK]: $1" >&2; FAILED=1; }
has() { grep -qxF -- "$1" "$2" || fail "нет строки '$1' ($3)"; }
hasnt() { ! grep -qF -- "$1" "$2" || fail "лишнее '$1' ($3)"; }

conf() {  # $1 имя файла, остальное - строки
  f="$WORK/$1.conf"; shift; printf '%s\n' "$@" > "$f"
}
conf plain '[Interface]' 'PrivateKey = AAA=' 'Address = 10.8.0.2/32, fd00::2/128' \
  'DNS = 1.1.1.1, home.lan' 'MTU = 1420' '' '[Peer]' 'PublicKey = BBB=' 'PresharedKey = CCC=' \
  'Endpoint = vpn.example.com:51820' 'AllowedIPs = 0.0.0.0/0, ::/0' 'PersistentKeepalive = 25'
conf awg '[Interface]' 'PrivateKey = AAA=' 'Address = 10.8.0.2/32' 'Jc = 4' 'Jmin = 40' 'Jmax = 70' \
  'S1 = 0' 'S2 = 0' 'H1 = 1' 'H2 = 2-5' 'H3 = 3' 'H4 = 4' 'I1 = <b 0xf6ab>' \
  '[Peer]' 'PublicKey = BBB=' 'Endpoint = 1.2.3.4:443' 'AllowedIPs = 0.0.0.0/0'
conf v6ep '[Interface]' 'PrivateKey = AAA=' 'Address = 10.8.0.2/32' \
  '[Peer]' 'PublicKey = BBB=' 'Endpoint = [2001:db8::1]:443' 'AllowedIPs = 0.0.0.0/0'
printf '\357\273\277# из Windows\r\n[interface]\r\nprivatekey=AAA=\r\n; адрес\r\naddress = 10.8.0.2/32, fd00::2/128\r\nDNS = 1.1.1.1, home.lan\r\nMTU = 1420\r\n[peer]\r\npublickey=BBB=\r\nPresharedKey = CCC=\r\nendpoint = vpn.example.com:51820\r\nAllowedIPs = 0.0.0.0/0, ::/0\r\nPersistentKeepalive = 25\r\n' > "$WORK/win.conf"
conf skip '[Interface]' 'PrivateKey = AAA=' 'Address = 10.8.0.2/32' 'ListenPort = 1' 'PostUp = iptables -A x' 'Foo = 1' \
  '[Peer]' 'PublicKey = BBB=' 'Endpoint = 1.2.3.4:443' 'AllowedIPs = 0.0.0.0/0'
conf nopriv '[Interface]' 'Address = 10.8.0.2/32' '[Peer]' 'PublicKey = BBB=' 'Endpoint = 1.2.3.4:443'
conf nopeer '[Interface]' 'PrivateKey = AAA=' 'Address = 10.8.0.2/32'
conf noep '[Interface]' 'PrivateKey = AAA=' '[Peer]' 'PublicKey = BBB='
conf twopeer '[Interface]' 'PrivateKey = AAA=' '[Peer]' 'PublicKey = BBB=' 'Endpoint = 1.2.3.4:1' '[Peer]' 'PublicKey = DDD=' 'Endpoint = 1.2.3.5:1'
conf badport '[Interface]' 'PrivateKey = AAA=' '[Peer]' 'PublicKey = BBB=' 'Endpoint = host:99999'
conf badmtu '[Interface]' 'PrivateKey = AAA=' 'MTU = abc' '[Peer]' 'PublicKey = BBB=' 'Endpoint = host:1'
conf badjc '[Interface]' 'PrivateKey = AAA=' 'Jc = 1;evil' '[Peer]' 'PublicKey = BBB=' 'Endpoint = host:1'
conf evil '[Interface]' "PrivateKey = x'], evil: [1" '[Peer]' 'PublicKey = BBB=' 'Endpoint = host:1'

nodes() {  # $1 файл, $2 имя ноды -> блок ноды в $WORK/out, отчёт в $WORK/rep
  printf '%s\t%s\n' "$WORK/$1.conf" "$2" > "$WORK/list"; : > "$WORK/rep"
  $AWK -v MODE=nodes -v LIST="$WORK/list" -v REPORT="$WORK/rep" -f "$SCRIPT" /dev/null > "$WORK/out"
}
PLAIN_BLOCK="  - name: 'plain'
    type: wireguard
    server: 'vpn.example.com'
    port: 51820
    ip: '10.8.0.2'
    ipv6: 'fd00::2'
    private-key: 'AAA='
    public-key: 'BBB='
    pre-shared-key: 'CCC='
    allowed-ips: ['0.0.0.0/0', '::/0']
    dns: ['1.1.1.1']
    mtu: 1420
    persistent-keepalive: 25
    udp: true"

run_convert() {
  nodes plain plain
  [ "$(cat "$WORK/out")" = "$PLAIN_BLOCK" ] || { fail "plain: блок не совпал"; cat "$WORK/out" >&2; }
  nodes win plain
  [ "$(cat "$WORK/out")" = "$PLAIN_BLOCK" ] || { fail "win (BOM/CRLF/комментарии/регистр): блок не совпал"; cat "$WORK/out" >&2; }

  nodes awg awg
  has '    amnezia-wg-option:' "$WORK/out" "awg"
  [ "$(sed -n '/amnezia-wg-option:/,$p' "$WORK/out" | sed 1d | grep '^      ')" = "      jc: 4
      jmin: 40
      jmax: 70
      s1: 0
      s2: 0
      h1: 1
      h2: 2-5
      h3: 3
      h4: 4
      i1: '<b 0xf6ab>'" ] || { fail "awg: параметры"; cat "$WORK/out" >&2; }

  nodes v6ep v6ep
  has "    server: '2001:db8::1'" "$WORK/out" "v6 endpoint server"
  has '    port: 443' "$WORK/out" "v6 endpoint port"

  nodes skip skip
  has "  - name: 'skip'" "$WORK/out" "skip: блок есть"
  for k in ListenPort PostUp Foo; do has "SKIPPED_KEY|skip|$k" "$WORK/rep" "skip $k"; done

  for c in "nopriv|нет PrivateKey в [Interface]" "nopeer|нет [Peer]" "noep|нет Endpoint в [Peer]" \
           "twopeer|несколько [Peer] - поддерживается один" "badport|неверное число: Port" \
           "badmtu|неверное число: MTU" "badjc|неверное число: Jc"; do
    f=${c%%|*}; why=${c#*|}
    nodes "$f" "$f"
    [ ! -s "$WORK/out" ] || fail "$f: блок не должен печататься"
    has "ERROR|$f|$why" "$WORK/rep" "$f: причина"
  done

  nodes evil evil
  has "    private-key: 'x''], evil: [1'" "$WORK/out" "evil: значение целиком в кавычках"
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    { echo 'proxies:'; cat "$WORK/out"; } > "$WORK/evil.yaml"
    python3 -c "import yaml,sys; p=yaml.safe_load(open(sys.argv[1]))['proxies'][0]; assert p['private-key']==\"x'], evil: [1\" and 'evil' not in p, p" "$WORK/evil.yaml" \
      || fail "evil: YAML разобран не так"
  fi
}

imp() {  # $1 конфиг, далее пары файл:имя -> $WORK/new, $WORK/rep
  cfg=$1; shift; : > "$WORK/list"; : > "$WORK/rep"
  for p in "$@"; do printf '%s\t%s\n' "$WORK/${p%%:*}.conf" "${p#*:}" >> "$WORK/list"; done
  $AWK -v LIST="$WORK/list" -v REPORT="$WORK/rep" -f "$SCRIPT" "$cfg" > "$WORK/new"
}
GROUPS_RE="^  - name: '(🚀 Авто по пингу|🛡️Fallback-Stable|⚙️Manual)'"
group_line() {  # $1 файл, $2 группа -> строка proxies: [...] группы
  awk -v g="  - name: '$2'" '$0 == g { f = 1; next } f && /^    proxies:/ { print; exit } /^  - name:/ { f = 0 }' "$1"
}
run_insert() {
  imp "$TEMPLATE" plain:plain
  has 'ADDED|plain' "$WORK/rep" "plain: ADDED"
  awk '/^  # --- STATIC_PROXIES:END ---/{print prev} {prev=$0}' "$WORK/new" > "$WORK/before_end"
  has '    udp: true' "$WORK/before_end" "нода стоит прямо перед STATIC_PROXIES:END"
  has "  - name: 'plain'" "$WORK/new" "нода вставлена"
  for g in '🚀 Авто по пингу' '🛡️Fallback-Stable' '⚙️Manual'; do
    case "$(group_line "$WORK/new" "$g")" in *", 'plain']") ;; *) fail "plain не дописан в $g: $(group_line "$WORK/new" "$g")" ;; esac
    has "GROUP|$g" "$WORK/rep" "GROUP $g"
  done
  cp "$WORK/new" "$WORK/with_plain.yaml"

  # Имя с апострофом и эмодзи.
  imp "$TEMPLATE" "plain:Bob's 🇳🇱"
  has "  - name: 'Bob''s 🇳🇱'" "$WORK/new" "имя с апострофом"
  case "$(group_line "$WORK/new" '⚙️Manual')" in *", 'Bob''s 🇳🇱']") ;; *) fail "имя с апострофом в группе" ;; esac

  # Замена: другой PublicKey, нода одна, в группах один раз.
  sed 's/PublicKey = BBB=/PublicKey = NEW=/' "$WORK/plain.conf" > "$WORK/plain2.conf"
  imp "$WORK/with_plain.yaml" plain2:plain
  has 'REPLACED|plain' "$WORK/rep" "замена: REPLACED"
  has "    public-key: 'NEW='" "$WORK/new" "замена: новый ключ"
  hasnt "public-key: 'BBB='" "$WORK/new" "замена: старый ключ ушёл"
  [ "$(grep -c "^  - name: 'plain'\$" "$WORK/new")" = 1 ] || fail "замена: нода не одна"
  [ "$(group_line "$WORK/new" '⚙️Manual' | grep -o "'plain'" | wc -l | tr -d ' ')" = 1 ] || fail "замена: имя в группе не один раз"
  hasnt 'GROUP|' "$WORK/rep" "замена: группы не трогаются"

  # Повторный импорт идентичного файла - текст не меняется.
  imp "$WORK/with_plain.yaml" plain:plain
  cmp -s "$WORK/new" "$WORK/with_plain.yaml" || fail "повторный импорт меняет конфиг"
  has 'REPLACED|plain' "$WORK/rep" "повтор: REPLACED"

  # Существующая нода с именем в двойных кавычках.
  sed "s/^  - name: 'plain'\$/  - name: \"plain\"/" "$WORK/with_plain.yaml" > "$WORK/dq.yaml"
  imp "$WORK/dq.yaml" plain2:plain
  has 'REPLACED|plain' "$WORK/rep" "имя в двойных кавычках распознано"
  [ "$(grep -c '^  - name: .plain.$' "$WORK/new")" = 1 ] || fail "двойные кавычки: дубль ноды"

  # proxies: [] и конфиг без proxies:.
  printf 'mixed-port: 7890\nproxies: []\nproxy-groups:\n  - name: x\n    type: select\n    proxies: [DIRECT]\n' > "$WORK/empty.yaml"
  imp "$WORK/empty.yaml" plain:plain
  has 'proxies:' "$WORK/new" "proxies: [] -> блочный"
  hasnt 'proxies: []' "$WORK/new" "proxies: [] убран"
  has "  - name: 'plain'" "$WORK/new" "нода в бывшем пустом proxies"
  printf 'mixed-port: 7890\nproxy-providers:\n  a:\n    type: file\n    path: ./a.yaml\n' > "$WORK/noprox.yaml"
  imp "$WORK/noprox.yaml" plain:plain
  [ "$(awk '/^proxies:$/{p=NR} /^proxy-providers:/{q=NR} END{print (p && p<q) ? "ok" : "bad"}' "$WORK/new")" = ok ] \
    || fail "без proxies: секция не создана перед proxy-providers:"
  for g in '🚀 Авто по пингу' '🛡️Fallback-Stable' '⚙️Manual'; do has "GROUP_MISSING|$g" "$WORK/rep" "нет групп: $g"; done

  # Группа удалена / proxies: блочный - GROUP_MISSING, без ошибки.
  awk '/^  - name: .⚙️Manual.$/{skip=1; next} skip && /^  - name:/{skip=0} skip && /^$/{skip=0} !skip' "$TEMPLATE" > "$WORK/g1.yaml"
  python3 - "$WORK/g1.yaml" <<'PYX'
import sys,re
p=sys.argv[1];t=open(p).read()
t=re.sub(r"(  - name: '🛡️Fallback-Stable'\n(?:    .*\n)*?)    proxies: \[[^\n]*\]\n", lambda m: m.group(1)+"    proxies:\n      - DIRECT\n", t, count=1)
open(p,'w').write(t)
PYX
  imp "$WORK/g1.yaml" plain:plain
  has 'GROUP_MISSING|⚙️Manual' "$WORK/rep" "удалённая группа"
  has 'GROUP_MISSING|🛡️Fallback-Stable' "$WORK/rep" "блочный proxies:"
  has 'GROUP|🚀 Авто по пингу' "$WORK/rep" "остальные группы дописаны"

  # Плохой файл + хороший: хороший вставлен.
  imp "$TEMPLATE" noep:noep plain:plain
  has 'ERROR|noep|нет Endpoint в [Peer]' "$WORK/rep" "плохой файл"
  has 'ADDED|plain' "$WORK/rep" "хороший файл"
  hasnt "name: 'noep'" "$WORK/new" "плохой не вставлен"

  # Вместе с fast_wg.awk - валидный YAML без технических групп.
  $AWK -f "$FASTWG" "$WORK/with_plain.yaml" > "$WORK/full.yaml"
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c "
import yaml,sys
c=yaml.safe_load(open(sys.argv[1]))
g={x['name']:x for x in c['proxy-groups']}
assert not any(n.startswith('FAST-WG ') for n in g)
assert 'plain' not in g['⚡ Быстрый пул'].get('proxies', [])
assert 'plain' in g['⚙️Manual']['proxies']
assert [p for p in c['proxies'] if p['name']=='plain'][0]['port']==51820
" "$WORK/full.yaml" || fail "итоговый YAML"
  fi
}

run_review_fixes() {
  # R1: без маркера STATIC_PROXIES:END - замена последней записи + новая нода
  printf 'proxies:\n  - name: "plain"\n    type: wireguard\n    server: old\nproxy-groups:\n  - name: x\n    type: select\n    proxies: [DIRECT]\n' > "$WORK/nomark.yaml"
  imp "$WORK/nomark.yaml" plain:plain v6ep:new
  [ "$(grep -c '^proxies:' "$WORK/new")" = 1 ] || fail "R1: второй ключ proxies:"
  [ "$(awk '/^proxies:/{p=1} /^proxy-groups:/{p=0} p && /^  - name:/' "$WORK/new" | wc -l | tr -d ' ')" = 2 ] || fail "R1: обе ноды в секции proxies:"
  # R2: комментарии в конце строки
  conf inl '[Interface] # мой' 'PrivateKey = AAA= # ключ' 'Address = 10.8.0.2/32' '[Peer] # сервер' 'PublicKey = BBB=' \
    'Endpoint = 1.2.3.4:51820 # дом' 'AllowedIPs = 0.0.0.0/0 # всё'
  nodes inl inl
  has "    private-key: 'AAA='" "$WORK/out" "R2: ключ без комментария"
  has "    port: 51820" "$WORK/out" "R2: порт"
  has "    allowed-ips: ['0.0.0.0/0']" "$WORK/out" "R2: allowed-ips"
  # R3: имя с запятой - повторный импорт не дублирует в группах
  imp "$TEMPLATE" "plain:a, b"
  cp "$WORK/new" "$WORK/comma.yaml"
  imp "$WORK/comma.yaml" "plain:a, b"
  cmp -s "$WORK/new" "$WORK/comma.yaml" || fail "R3: имя с запятой дописано повторно"
}

AWK=awk; run_convert; run_insert; run_review_fixes
if command -v busybox >/dev/null 2>&1; then AWK="busybox awk"; run_convert; run_insert; run_review_fixes; fi

[ "$FAILED" = 0 ] && echo "OK: wg_import" || exit 1
