#!/bin/sh
# reset_config.sh: полная замена конфига шаблоном, из старого берутся только
# подписки (с User-Agent) и свои ноды.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d /tmp/test-reset-config.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }

TOOLS=$WORK/tools
mkdir "$TOOLS"
for f in reset_config.sh constructor_build.sh config.example.yaml services.default.tsv render_services.awk \
    config_to_state.awk migrate_config.sh migrate_config.awk fast_wg.awk; do
  cp "$ROOT/config-tools/$f" "$TOOLS/$f" 2>/dev/null || true
done
SCRIPT=$TOOLS/reset_config.sh

# Чужой конфиг: dns, listeners, secret, свои группы и правила (в том числе на
# несуществующую группу - такой конфиг не проходит mihomo -t), две подписки,
# провайдер type: file, fast и две свои ноды.
cat > "$WORK/source.yaml" <<'Y'
log-level: debug
secret: topsecret
external-controller: 0.0.0.0:9099
dns:
  enable: true
  nameserver: [9.9.9.9]
listeners:
  - name: my-in
    type: mixed
    port: 7000
proxy-providers:
  blancvpn:
    type: http
    url: "https://sub.example/AAA"
    header:
      User-Agent:
        - "clash.meta"
    path: ./x.yaml
  second:
    type: http
    url: "https://sub2.example/BBB"
  filep:
    type: file
    path: ./p.yaml
  fast:
    type: file
    path: ./fast.yaml
proxies:
  - name: node1
    type: ss
    server: 1.2.3.4
    port: 1
    cipher: aes-128-gcm
    password: p1
  - name: node2
    type: ss
    server: 5.6.7.8
    port: 2
    cipher: aes-128-gcm
    password: p2
proxy-groups:
  - name: Mine
    type: select
    use: [blancvpn]
  - name: FaceTime
    type: url-test
rules:
  - DOMAIN-SUFFIX,x.y,Mine
  - DOMAIN-SUFFIX,facetime.apple.com,FaceTime
  - MATCH,Ghost
Y

# test_reset_keeps_only_subs_and_nodes
if sh "$SCRIPT" --source "$WORK/source.yaml" --output "$WORK/out.yaml" --report "$WORK/report" \
    --state-out "$WORK/state" > "$WORK/log" 2>&1; then
  grep -q 'https://sub.example/AAA' "$WORK/out.yaml" || fail "подписка 1 потеряна"
  grep -q 'https://sub2.example/BBB' "$WORK/out.yaml" || fail "подписка 2 потеряна"
  grep -q 'clash.meta' "$WORK/out.yaml" || fail "User-Agent подписки потерян"
  grep -q 'name: node1' "$WORK/out.yaml" && grep -q 'name: node2' "$WORK/out.yaml" || fail "свои ноды потеряны"
  for gone in topsecret 'name: Mine' FaceTime my-in Ghost 9.9.9.9 'filep:'; do
    grep -q -- "$gone" "$WORK/out.yaml" && fail "в замене остались данные старого конфига: $gone"
  done
  grep -q '^dns:' "$WORK/out.yaml" && fail "dns: должен быть из шаблона (без него)"
  grep -q 'name: mst-speedtest' "$WORK/out.yaml" || fail "служебный вход шаблона пропал"
  grep -q '^RESET|kept-subscriptions|2$' "$WORK/report" || fail "отчёт: kept-subscriptions"
  grep -q '^RESET|kept-nodes|2$' "$WORK/report" || fail "отчёт: kept-nodes"
  grep -q '^REVIEW|file-provider-dropped|filep$' "$WORK/report" || fail "отчёт: file-provider-dropped"
  grep -q 'file-provider-dropped|fast' "$WORK/report" && fail "fast не должен попадать в отчёт как потерянный"
  [ "$(wc -l < "$WORK/state/subscriptions.tsv" | tr -d ' ')" = 2 ] || fail "состояние: две подписки"
  [ -f "$WORK/state/proxies.yaml" ] || fail "состояние: нет proxies.yaml"
  [ -f "$WORK/state/services.tsv" ] && [ ! -s "$WORK/state/services.tsv" ] || fail "состояние: services.tsv должен быть пустым"
  [ ! -e "$WORK/state/user-rules.txt" ] || fail "состояние: чужие правила не переносятся"
else
  fail "замена: $(cat "$WORK/log")"
fi

# test_reset_subs_only: без своих нод
sed -e '/^proxies:/,/^proxy-groups:/{/^proxy-groups:/!d}' "$WORK/source.yaml" > "$WORK/subs-only.yaml"
if sh "$SCRIPT" --source "$WORK/subs-only.yaml" --output "$WORK/out2.yaml" --report "$WORK/report2" \
    --state-out "$WORK/state2" > "$WORK/log2" 2>&1; then
  grep -q '^RESET|kept-nodes|0$' "$WORK/report2" || fail "без нод: kept-nodes должен быть 0"
  grep -q 'node1' "$WORK/out2.yaml" && fail "без нод: node1 появился"
else
  fail "замена только с подписками: $(cat "$WORK/log2")"
fi

# test_reset_nodes_only: ноды без подписок - можно
sed -e '/^proxy-providers:/,/^proxies:/{/^proxies:/!d}' "$WORK/source.yaml" > "$WORK/nodes-only.yaml"
if sh "$SCRIPT" --source "$WORK/nodes-only.yaml" --output "$WORK/out3.yaml" --report "$WORK/report3" \
    --state-out "$WORK/state3" > "$WORK/log3" 2>&1; then
  grep -q '^RESET|kept-subscriptions|0$' "$WORK/report3" || fail "только ноды: kept-subscriptions должен быть 0"
  grep -q '^RESET|kept-nodes|2$' "$WORK/report3" || fail "только ноды: kept-nodes"
else
  fail "замена только с нодами: $(cat "$WORK/log3")"
fi

# test_reset_nothing_to_keep: ни подписок, ни нод - отказ, OUT не создаётся
printf 'log-level: info\nrules:\n  - MATCH,DIRECT\n' > "$WORK/empty.yaml"
rc=0; sh "$SCRIPT" --source "$WORK/empty.yaml" --output "$WORK/out4.yaml" --report "$WORK/report4" \
  --state-out "$WORK/state4" > /dev/null 2> "$WORK/err4" || rc=$?
[ "$rc" = 1 ] || fail "нечего переносить: код $rc вместо 1"
grep -q 'ERROR: нет ни подписок, ни нод' "$WORK/err4" || fail "нечего переносить: нет понятной причины: $(cat "$WORK/err4")"
[ ! -e "$WORK/out4.yaml" ] || fail "нечего переносить: кандидат создан"

# test_reset_bad_source: нет файла и слишком большой файл
rc=0; sh "$SCRIPT" --source "$WORK/nope.yaml" --output "$WORK/out5.yaml" --report "$WORK/report5" \
  --state-out "$WORK/state5" > /dev/null 2> "$WORK/err5" || rc=$?
[ "$rc" = 1 ] || fail "нет источника: код $rc вместо 1"
grep -q '^ERROR:' "$WORK/err5" || fail "нет источника: нет ERROR:"
head -c 1048577 /dev/zero | tr '\0' 'a' > "$WORK/big.yaml"
rc=0; sh "$SCRIPT" --source "$WORK/big.yaml" --output "$WORK/out6.yaml" --report "$WORK/report6" \
  --state-out "$WORK/state6" > /dev/null 2> "$WORK/err6" || rc=$?
[ "$rc" = 1 ] || fail "большой источник: код $rc вместо 1"

[ "$FAILED" = 0 ] || exit 1
echo "OK test_reset_config"
