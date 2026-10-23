#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/install-web-port.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/bin" "$WORK/runtime"

cat > "$WORK/bin/netstat" <<'EOF'
#!/bin/sh
[ "$BUSY_WEB_PORTS" != FAIL ] || exit 1
for port in $BUSY_WEB_PORTS; do
  printf 'tcp 0 0 0.0.0.0:%s 0.0.0.0:* LISTEN\n' "$port"
done
printf 'tcp 0 0 127.0.0.1:8901 127.0.0.1:443 ESTABLISHED\n'
EOF
chmod +x "$WORK/bin/netstat"

PATH="$WORK/bin:$PATH"; export PATH
DIR=$WORK
STATS_SERVICE_RUNTIME_DIR=$WORK/runtime
STATS_HTTP_BIND=127.0.0.1
BUSY_WEB_PORTS='18899 8899 8900'; export BUSY_WEB_PORTS
INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" . "$ROOT/install.sh"

select_web_port "$DIR/speedtest2.env"
[ "$STATS_HTTP_PORT" = 8901 ] || { echo "FAIL: ожидался порт 8901, выбран $STATS_HTTP_PORT" >&2; exit 1; }
SOURCES=new BLOCK=new MIN_SPEED=1 BLOCK_SOURCE=test write_env "$DIR/speedtest2.env"
grep -qxF "STATS_HTTP_PORT='8901'" "$DIR/speedtest2.env" || { echo 'FAIL: порт не сохранён' >&2; exit 1; }
[ "$(install_web_url)" = 'http://127.0.0.1:8901/stats' ] || { echo 'FAIL: ссылка показывает другой порт' >&2; exit 1; }
python3() { printf '123456\n'; }
setup_note=$(initialize_web_auth 2>&1)
case $setup_note in
  *'http://127.0.0.1:8901/setup'*) ;;
  *) echo "FAIL: установщик показал неверный адрес настройки: $setup_note" >&2; exit 1 ;;
esac

printf '%s\n' "$$" > "$STATS_SERVICE_RUNTIME_DIR/httpd.pid"
BUSY_WEB_PORTS='8899 8900 8901'
select_web_port "$DIR/speedtest2.env"
[ "$STATS_HTTP_PORT" = 8901 ] || { echo 'FAIL: своя служба принята за постороннюю' >&2; exit 1; }
rm "$STATS_SERVICE_RUNTIME_DIR/httpd.pid"
select_web_port "$DIR/speedtest2.env"
[ "$STATS_HTTP_PORT" = 8902 ] || { echo 'FAIL: занятый прежний порт не переназначен' >&2; exit 1; }

printf "STATS_HTTP_ENABLE=0\nSTATS_HTTP_PORT='9010'\n" > "$DIR/speedtest2.env"
unset STATS_HTTP_PORT
BUSY_WEB_PORTS=FAIL
select_web_port "$DIR/speedtest2.env"
[ "$STATS_HTTP_PORT" = 9010 ] || { echo 'FAIL: отключённая веб-служба потеряла свой порт' >&2; exit 1; }

echo 'OK: test_install_web_port.sh'
