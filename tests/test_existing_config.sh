#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/config-tools/existing_config.awk"
FAILED=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
T=$(printf '\t')

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAIL: '$1' != '$2' ($3)" >&2
    FAILED=1
  fi
}

cat > "$WORK/old_config.yaml" <<'EOFCONFIG'
proxy-providers:
  provider-a:
    type: http
    url: "https://sub1.example/AAA"
    path: ./proxy-providers/provider-a.yaml
  provider-b:
    type: http
    url: "https://sub2.example/BBB"
    path: ./proxy-providers/provider-b.yaml
  fast:
    type: file
    path: ./fast.yaml

proxies:
  - name: 'Real Node'
    type: hysteria2
    server: real.proxy.io
    password: "s3cr3t"

proxy-groups:
  - name: Test
    type: select
EOFCONFIG

awk -v urls_out="$WORK/urls.txt" -v proxies_out="$WORK/proxies.txt" -f "$SCRIPT" "$WORK/old_config.yaml"

assert_eq "$(wc -l < "$WORK/urls.txt" | tr -d ' ')" "2" "два URL"
grep -qF "https://sub1.example/AAA${T}${T}provider-a" "$WORK/urls.txt" || { echo "FAIL: sub1 (без UA) с именем provider-a отсутствует" >&2; FAILED=1; }
grep -qF "https://sub2.example/BBB${T}${T}provider-b" "$WORK/urls.txt" || { echo "FAIL: sub2 (без UA) с именем provider-b отсутствует" >&2; FAILED=1; }
grep -q 'fast.yaml' "$WORK/urls.txt" && { echo "FAIL: fast provider (type: file) must be excluded" >&2; FAILED=1; }

grep -q 'Real Node' "$WORK/proxies.txt" || { echo "FAIL: proxies block not extracted" >&2; FAILED=1; }

cat > "$WORK/placeholder_config.yaml" <<'EOFCONFIG2'
proxy-providers:
  provider-a:
    type: http
    url: "https://subscription-1.example.com/CHANGE_ME"
    path: ./proxy-providers/provider-a.yaml

proxies:
  - name: 'Template Node'
    server: proxy-node-1.example.com
    password: "CHANGE_ME"
EOFCONFIG2
rm -f "$WORK/urls2.txt" "$WORK/proxies2.txt"
awk -v urls_out="$WORK/urls2.txt" -v proxies_out="$WORK/proxies2.txt" -f "$SCRIPT" "$WORK/placeholder_config.yaml"
[ -s "$WORK/proxies2.txt" ] && { echo "FAIL: placeholder proxies block must not be offered" >&2; FAILED=1; }
grep -q 'CHANGE_ME' "$WORK/urls2.txt" || { echo "FAIL: url with CHANGE_ME should still be extracted as-is (не placeholder-фильтр для URL)" >&2; FAILED=1; }
grep -qF "${T}provider-a" "$WORK/urls2.txt" || { echo "FAIL: имя provider-a должно быть перенесено" >&2; FAILED=1; }

cat > "$WORK/healthcheck_config.yaml" <<'EOFCONFIG3'
proxy-providers:
  provider-a:
    type: http
    url: "https://subscription-1.example.com/CHANGE_ME"
    path: ./proxy-providers/provider-a.yaml
    health-check:
      enable: true
      url: "http://www.msftncsi.com/ncsi.txt"
      interval: 300
  provider-b:
    <<: *http-provider
    url: "https://subscription-2.example.com/CHANGE_ME"
    path: ./proxy-providers/provider-b.yaml
    health-check:
      enable: true
      url: "http://www.msftncsi.com/ncsi.txt"
      interval: 300
EOFCONFIG3
rm -f "$WORK/urls4.txt" "$WORK/proxies4.txt"
awk -v urls_out="$WORK/urls4.txt" -v proxies_out="$WORK/proxies4.txt" -f "$SCRIPT" "$WORK/healthcheck_config.yaml"
assert_eq "$(wc -l < "$WORK/urls4.txt" | tr -d ' ')" "2" "два URL, health-check.url не должен их перекрывать"
grep -qF "https://subscription-1.example.com/CHANGE_ME${T}${T}provider-a" "$WORK/urls4.txt" || { echo "FAIL: provider-a url/имя потеряны из-за health-check" >&2; FAILED=1; }
grep -qF "https://subscription-2.example.com/CHANGE_ME${T}${T}provider-b" "$WORK/urls4.txt" || { echo "FAIL: provider-b url/имя потеряны из-за health-check" >&2; FAILED=1; }
grep -q 'msftncsi' "$WORK/urls4.txt" && { echo "FAIL: health-check.url не должен попадать в список подписок" >&2; FAILED=1; }

cat > "$WORK/ua_config.yaml" <<'EOFCONFIG4'
proxy-providers:
  provider-a:
    type: http
    url: "https://sub1.example/AAA"
    path: ./proxy-providers/provider-a.yaml
    header:
      User-Agent:
        - "v2rayNG/1.8.0"
    health-check:
      enable: true
      url: "http://www.msftncsi.com/ncsi.txt"
      interval: 300
  provider-b:
    type: http
    url: "https://sub2.example/BBB"
    path: ./proxy-providers/provider-b.yaml
EOFCONFIG4
rm -f "$WORK/urls5.txt"
awk -v urls_out="$WORK/urls5.txt" -v proxies_out="" -f "$SCRIPT" "$WORK/ua_config.yaml"
grep -qF "https://sub1.example/AAA${T}v2rayNG/1.8.0${T}provider-a" "$WORK/urls5.txt" || { echo "FAIL: provider-a должен нести перенесённый UA и имя (URL<TAB>UA<TAB>NAME)" >&2; FAILED=1; }
grep -qF "https://sub2.example/BBB${T}${T}provider-b" "$WORK/urls5.txt" || { echo "FAIL: provider-b без header: должен остаться с пустым UA, но со своим именем" >&2; FAILED=1; }

: > "$WORK/empty.txt"
if awk -v urls_out="$WORK/urls3.txt" -f "$SCRIPT" "$WORK/empty.txt"; then
  [ -s "$WORK/urls3.txt" ] && { echo "FAIL: empty config should yield no urls" >&2; FAILED=1; }
else
  echo "FAIL: empty (valid, just no providers) config should not error" >&2
  FAILED=1
fi

cat > "$WORK/dns_config.yaml" <<'EOFCONFIG6'
routing-mark: 255
dns:
  enable: true
  nameserver:
    - 8.8.8.8
    - 1.1.1.1

proxy-providers:
  provider-a:
    type: http
    url: "https://sub1.example/AAA"
    path: ./proxy-providers/provider-a.yaml

proxies:
  - name: 'Real Node'
    type: hysteria2
EOFCONFIG6
rm -f "$WORK/urls6.txt" "$WORK/dns6.txt"
awk -v urls_out="$WORK/urls6.txt" -v proxies_out="" -v dns_out="$WORK/dns6.txt" -f "$SCRIPT" "$WORK/dns_config.yaml"
[ -s "$WORK/dns6.txt" ] || { echo "FAIL: dns block not extracted" >&2; FAILED=1; }
head -n1 "$WORK/dns6.txt" | grep -qx 'dns:' || { echo "FAIL: dns block must start with the 'dns:' line itself" >&2; FAILED=1; }
grep -q '8.8.8.8' "$WORK/dns6.txt" || { echo "FAIL: dns block content (nameserver) lost" >&2; FAILED=1; }
grep -q '1.1.1.1' "$WORK/dns6.txt" || { echo "FAIL: dns block content (nameserver) lost" >&2; FAILED=1; }
grep -qF "https://sub1.example/AAA${T}${T}provider-a" "$WORK/urls6.txt" || { echo "FAIL: dns block should not interfere with proxy-providers parsing" >&2; FAILED=1; }

rm -f "$WORK/urls7.txt" "$WORK/dns7.txt"
awk -v urls_out="$WORK/urls7.txt" -v dns_out="$WORK/dns7.txt" -f "$SCRIPT" "$WORK/old_config.yaml"
[ -s "$WORK/dns7.txt" ] && { echo "FAIL: dns_out must stay empty when the source config has no dns: block" >&2; FAILED=1; }

cat > "$WORK/rendered_config.yaml" <<'EOFCONFIG8'
proxy-providers:
  provider-a:
    type: http
    url: "https://sub1.example/AAA"
    path: ./proxy-providers/provider-a.yaml

proxies:
  # --- STATIC_PROXIES:BEGIN --- (необязательно: свои Hysteria2/AmneziaWG-ноды)
  - name: 'Real Node'
    type: hysteria2
    server: real.proxy.io
    password: "s3cr3t"
  # --- STATIC_PROXIES:END ---

# --- Провайдеры прокси ---
proxy-providers2:
  ignore-me:
    type: http
EOFCONFIG8
rm -f "$WORK/urls8.txt" "$WORK/proxies8.txt"
awk -v urls_out="$WORK/urls8.txt" -v proxies_out="$WORK/proxies8.txt" -f "$SCRIPT" "$WORK/rendered_config.yaml"
grep -q 'Real Node' "$WORK/proxies8.txt" || { echo "FAIL: нода не перенесена из уже отрендеренного config.yaml" >&2; FAILED=1; }
grep -q 'STATIC_PROXIES' "$WORK/proxies8.txt" && { echo "FAIL: маркеры STATIC_PROXIES:BEGIN/END не должны попадать в proxies_out (иначе render_config.awk продублирует их при следующей установке)" >&2; FAILED=1; }
grep -q 'Провайдеры прокси' "$WORK/proxies8.txt" && { echo "FAIL: служебный комментарий после STATIC_PROXIES:END не должен попадать в proxies_out" >&2; FAILED=1; }

# Повторный прогон на уже (гипотетически) продублированном файле - на входе
# already две пары маркеров, на выходе должна остаться только одна нода без
# единого маркера: обрезка должна съедать все накопленные ранее дубликаты,
# а не плодить их дальше.
cat > "$WORK/doubled_config.yaml" <<'EOFCONFIG9'
proxies:
  # --- STATIC_PROXIES:BEGIN --- (необязательно: свои Hysteria2/AmneziaWG-ноды)
  # --- STATIC_PROXIES:BEGIN --- (необязательно: свои Hysteria2/AmneziaWG-ноды)
  - name: 'Real Node'
    type: hysteria2
    server: real.proxy.io

# --- Провайдеры прокси ---
  # --- STATIC_PROXIES:END ---

# --- Провайдеры прокси ---
  # --- STATIC_PROXIES:END ---

proxy-providers:
  provider-a:
    type: http
    url: "https://sub1.example/AAA"
EOFCONFIG9
rm -f "$WORK/urls9.txt" "$WORK/proxies9.txt"
awk -v urls_out="$WORK/urls9.txt" -v proxies_out="$WORK/proxies9.txt" -f "$SCRIPT" "$WORK/doubled_config.yaml"
grep -q 'Real Node' "$WORK/proxies9.txt" || { echo "FAIL: нода не перенесена из уже задублированного config.yaml" >&2; FAILED=1; }
[ "$(grep -c 'STATIC_PROXIES' "$WORK/proxies9.txt")" = "0" ] || { echo "FAIL: маркеры из уже задублированного config.yaml не должны переноситься дальше" >&2; FAILED=1; }

# listeners_out: свои входы переносятся (без маркеров, комментариев и
# служебного входа mst-speedtest замера WG через основное ядро).
cat > "$WORK/listeners_config.yaml" <<'EOFLISTEN'
proxies:
  - name: 'Real Node'
    type: hysteria2
listeners:
  # --- STATIC_LISTENERS:BEGIN --- (свои входы)
  - name: my-socks
    type: socks
    port: 7777
  # --- STATIC_LISTENERS:END ---
  # Служебный вход
  - name: mst-speedtest
    type: mixed
    port: 7896
    proxy: MST-SPEEDTEST
rules:
  - MATCH,DIRECT
EOFLISTEN
rm -f "$WORK/listen9.txt"
awk -v urls_out=/dev/null -v listeners_out="$WORK/listen9.txt" -f "$SCRIPT" "$WORK/listeners_config.yaml"
[ "$(cat "$WORK/listen9.txt" 2>/dev/null)" = "$(printf '  - name: my-socks\n    type: socks\n    port: 7777')" ] \
  || { echo "FAIL: listeners_out must hold only user listeners: [$(cat "$WORK/listen9.txt" 2>/dev/null)]" >&2; FAILED=1; }
rm -f "$WORK/listen10.txt"
awk -v urls_out=/dev/null -v listeners_out="$WORK/listen10.txt" -f "$SCRIPT" "$WORK/dns_config.yaml"
[ -s "$WORK/listen10.txt" ] && { echo "FAIL: listeners_out must stay empty without user listeners" >&2; FAILED=1; }

if [ "$FAILED" = 1 ]; then
  echo "test_existing_config.sh: FAILED" >&2
  exit 1
fi
echo "test_existing_config.sh: OK"
