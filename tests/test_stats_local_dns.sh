#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/stats-local-dns.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/bin" "$WORK/project"
FAKE_CONFIG=$WORK/config
FAKE_INTERFACE=$WORK/interface
FAKE_LOG=$WORK/commands
export FAKE_CONFIG FAKE_INTERFACE FAKE_LOG
DIR=$WORK/project
ENV=$DIR/speedtest2.env
export DIR ENV
PATH="$WORK/bin:$PATH"; export PATH
printf "STATS_HTTP_PORT='8901'\n" > "$ENV"
cp "$ROOT/installer/local_dns_check.sh" "$DIR/local_dns_check.sh"

cat > "$FAKE_INTERFACE" <<'EOF'
   interface-name: Home
          address: 192.168.10.1
             mask: 255.255.255.0
EOF

cat > "$WORK/bin/ndmc" <<'EOF'
#!/bin/sh
[ "$1" = -c ] || exit 2
case $2 in
  'show running-config') cat "$FAKE_CONFIG" ;;
  'show interface Home') cat "$FAKE_INTERFACE" ;;
  'ip host speedtest.home.arpa 192.168.10.1'|'ip host mi.home.arpa 192.168.10.1')
    printf '%s\n' "$2" >> "$FAKE_LOG"
    printf '%s\n' "$2" >> "$FAKE_CONFIG"
    ;;
  'no ip host speedtest.home.arpa 192.168.10.1'|'no ip host mi.home.arpa 192.168.10.1')
    printf '%s\n' "$2" >> "$FAKE_LOG"
    grep -vFx "${2#no }" "$FAKE_CONFIG" > "$FAKE_CONFIG.tmp"
    mv "$FAKE_CONFIG.tmp" "$FAKE_CONFIG"
    ;;
  'system configuration save')
    printf '%s\n' "$2" >> "$FAKE_LOG"
    [ "${FAIL_SAVE:-0}" != 1 ]
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$WORK/bin/ndmc"

reset_config() {
  cat > "$FAKE_CONFIG" <<EOF
ip dhcp pool _WEBADMIN
    range 192.168.10.33 192.168.10.152
    dns-server $1
    bind Home
    enable
!
service dns-proxy
EOF
  : > "$FAKE_LOG"
}

request() {
  method=$1
  body=${2:-}
  target=${3:-speedtest}
  if [ "$method" = POST ]; then
    printf '%s' "$body" | MST_LOCAL_DNS_TARGET="$target" REQUEST_METHOD=POST CONTENT_LENGTH=${#body} sh "$ROOT/web/stats_local_dns.sh"
  else
    MST_LOCAL_DNS_TARGET="$target" REQUEST_METHOD=GET sh "$ROOT/web/stats_local_dns.sh"
  fi
}

assert_has() {
  case $1 in *"$2"*) ;; *) echo "FAIL: ожидалось $2 в ответе: $1" >&2; exit 1 ;; esac
}

reset_config 192.168.10.1
OUT=$(request GET)
assert_has "$OUT" '"enabled":false'
assert_has "$OUT" '"available":true'

OUT=$(request POST enabled=1)
assert_has "$OUT" '"ok":true'
assert_has "$OUT" '"enabled":true'
assert_has "$OUT" 'http://speedtest.home.arpa:8901/stats'
[ "$(cat "$DIR/.local-dns-state")" = 192.168.10.1 ] || { echo 'FAIL: нет маркера своей записи' >&2; exit 1; }
grep -qxF 'ip host speedtest.home.arpa 192.168.10.1' "$FAKE_CONFIG" || { echo 'FAIL: DNS-запись не создана' >&2; exit 1; }
[ "$(grep -c '^system configuration save$' "$FAKE_LOG")" = 1 ] || { echo 'FAIL: конфигурация не сохранена' >&2; exit 1; }

request POST enabled=1 > /dev/null
[ "$(grep -c '^system configuration save$' "$FAKE_LOG")" = 1 ] || { echo 'FAIL: повторное включение переписало конфигурацию' >&2; exit 1; }

OUT=$(request GET '' mihomo)
assert_has "$OUT" '"enabled":false'
OUT=$(request POST enabled=1 mihomo)
assert_has "$OUT" '"ok":true'
assert_has "$OUT" 'http://mi.home.arpa:9090/ui/'
[ "$(cat "$DIR/.local-dns-mihomo-state")" = 192.168.10.1 ] || { echo 'FAIL: нет отдельного маркера Mihomo' >&2; exit 1; }
grep -qxF 'ip host mi.home.arpa 192.168.10.1' "$FAKE_CONFIG" || { echo 'FAIL: DNS-запись Mihomo не создана' >&2; exit 1; }
OUT=$(request GET)
assert_has "$OUT" '"enabled":true'
OUT=$(request POST enabled=0 mihomo)
assert_has "$OUT" '"ok":true'
[ ! -e "$DIR/.local-dns-mihomo-state" ] || { echo 'FAIL: маркер Mihomo не удалён' >&2; exit 1; }
grep -qxF 'ip host speedtest.home.arpa 192.168.10.1' "$FAKE_CONFIG" || { echo 'FAIL: отключение Mihomo удалило speedtest' >&2; exit 1; }
! grep -q '^ip host mi.home.arpa ' "$FAKE_CONFIG" || { echo 'FAIL: DNS-запись Mihomo не удалена' >&2; exit 1; }

printf "STATS_HTTP_PORT='8902'\n" > "$ENV"
OUT=$(request GET)
assert_has "$OUT" 'http://speedtest.home.arpa:8902/stats'

sed 's/dns-server 192\.168\.10\.1$/dns-server 192.168.10.11 192.168.10.1/' "$FAKE_CONFIG" > "$FAKE_CONFIG.tmp"
mv "$FAKE_CONFIG.tmp" "$FAKE_CONFIG"
OUT=$(request GET)
assert_has "$OUT" '"enabled":true'
assert_has "$OUT" '"available":false'

OUT=$(request POST enabled=0)
assert_has "$OUT" '"ok":true'
assert_has "$OUT" '"enabled":false'
[ ! -e "$DIR/.local-dns-state" ] || { echo 'FAIL: маркер не удалён' >&2; exit 1; }
! grep -q '^ip host speedtest.home.arpa ' "$FAKE_CONFIG" || { echo 'FAIL: DNS-запись не удалена' >&2; exit 1; }
[ "$(grep -c '^system configuration save$' "$FAKE_LOG")" = 4 ] || { echo 'FAIL: удаление не сохранено' >&2; exit 1; }

reset_config '192.168.10.11 192.168.10.1'
OUT=$(request POST enabled=1)
assert_has "$OUT" '"ok":false'
assert_has "$OUT" 'дополнительный DNS'
[ ! -s "$FAKE_LOG" ] || { echo 'FAIL: при стороннем DNS изменён роутер' >&2; exit 1; }

reset_config 192.168.10.1
printf '%s\n' 'ip host speedtest.home.arpa 192.168.10.55' >> "$FAKE_CONFIG"
OUT=$(request POST enabled=1)
assert_has "$OUT" '"ok":false'
[ ! -s "$FAKE_LOG" ] || { echo 'FAIL: чужая DNS-запись изменена' >&2; exit 1; }

reset_config 192.168.10.1
printf '%s\n' 'ip host speedtest.home.arpa 192.168.10.1' >> "$FAKE_CONFIG"
OUT=$(request POST enabled=1)
assert_has "$OUT" '"ok":false'
[ ! -s "$FAKE_LOG" ] || { echo 'FAIL: присвоена существующая запись без маркера' >&2; exit 1; }

reset_config 192.168.10.1
printf '%s\n' 'ip host mi.home.arpa 192.168.10.1' >> "$FAKE_CONFIG"
OUT=$(request POST enabled=1 mihomo)
assert_has "$OUT" '"ok":false'
[ ! -s "$FAKE_LOG" ] || { echo 'FAIL: присвоена существующая запись Mihomo без маркера' >&2; exit 1; }

reset_config 192.168.10.1
FAIL_SAVE=1; export FAIL_SAVE
OUT=$(request POST enabled=1)
assert_has "$OUT" '"ok":false'
[ ! -e "$DIR/.local-dns-state" ] || { echo 'FAIL: маркер сохранён после ошибки роутера' >&2; exit 1; }
! grep -q '^ip host speedtest.home.arpa ' "$FAKE_CONFIG" || { echo 'FAIL: не откатили запись после ошибки сохранения' >&2; exit 1; }
unset FAIL_SAVE

reset_config 192.168.10.1
LOCAL_DNS_STATE_FILE=/dev/null/state; export LOCAL_DNS_STATE_FILE
OUT=$(request POST enabled=1)
assert_has "$OUT" '"ok":false'
! grep -q '^ip host speedtest.home.arpa ' "$FAKE_CONFIG" || { echo 'FAIL: не откатили запись после ошибки записи маркера' >&2; exit 1; }
unset LOCAL_DNS_STATE_FILE

reset_config 192.168.10.1
printf '%s\n' '192.168.10.1' > "$DIR/.local-dns-state"
printf '%s\n' 'ip host speedtest.home.arpa 192.168.10.55' >> "$FAKE_CONFIG"
OUT=$(request POST enabled=0)
assert_has "$OUT" '"ok":false'
grep -qxF 'ip host speedtest.home.arpa 192.168.10.55' "$FAKE_CONFIG" || { echo 'FAIL: удалена чужая запись' >&2; exit 1; }
[ ! -s "$FAKE_LOG" ] || { echo 'FAIL: при конфликте изменён роутер' >&2; exit 1; }

echo 'OK: test_stats_local_dns.sh'
