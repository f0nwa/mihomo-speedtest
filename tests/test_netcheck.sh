#!/bin/sh
# installer/netcheck.sh: пробы соединений, классификация результата, вердикт и
# советы. curl подменён заглушкой по таблице "ключ код_возврата http_код"
# (ключ - "хост" для прямого пути и "хост@proxy" через прокси).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LIB=$ROOT/installer/netcheck.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/netcheck-test.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
eq() { [ "$1" = "$2" ] || fail "$3: ожидалось '$2', получено '$1'"; }

[ -f "$LIB" ] || { echo "FAIL: нет installer/netcheck.sh" >&2; exit 1; }

mkdir "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
# Последний аргумент - адрес; -x ПРОКСИ - путь через прокси.
proxy=
while [ $# -gt 1 ]; do
  [ "$1" = -x ] && proxy=$2
  shift
done
url=$1
host=${url#*://}; host=${host%%/*}
key=$host; [ -z "$proxy" ] || key="$host@proxy"
[ -z "${STUB_DELAY:-}" ] || sleep "$STUB_DELAY"
rc=0; code=200
while read -r k r c; do
  if [ "$k" = "$key" ]; then rc=$r; code=$c; fi
done < "$STUB_RULES"
printf '%s' "$code"
exit "$rc"
STUB
chmod +x "$T/bin/curl"
PATH="$T/bin:$PATH"
STUB_RULES=$T/rules
NC_TIMEOUT=2
export PATH STUB_RULES NC_TIMEOUT
NC_CONFIG=$T/nonexistent.yaml
export NC_CONFIG

# shellcheck disable=SC1090
. "$LIB"

# ----- классификация одного результата -----
eq "$(nc_classify 0 200)" ok "200"
eq "$(nc_classify 0 301)" ok "301"
eq "$(nc_classify 0 404)" ok "404 - достучались"
eq "$(nc_classify 0 403)" http403 "403"
eq "$(nc_classify 0 451)" http451 "451"
eq "$(nc_classify 6 000)" dns "curl 6"
eq "$(nc_classify 7 000)" refused "curl 7"
eq "$(nc_classify 28 000)" timeout "curl 28"
eq "$(nc_classify 35 000)" tls "curl 35"
eq "$(nc_classify 60 000)" tls "curl 60"
eq "$(nc_classify 56 000)" reset "curl 56"
eq "$(nc_classify 99 000)" fail:99 "прочие коды"
eq "$(nc_classify 0 000)" fail:0 "пустой ответ"

run_case() {
  # $1 - содержимое таблицы заглушки; результат: вердикт в $T/verdict
  printf '%s\n' "$1" > "$STUB_RULES"
  nc_run
  nc_verdict > "$T/verdict"
  nc_cleanup
}
GH_DIRECT_FAIL="github.com 28 000
api.github.com 28 000
raw.githubusercontent.com 28 000
objects.githubusercontent.com 28 000"

# 1. Всё доступно
run_case ""
eq "$(cat "$T/verdict")" ok "всё доступно"
printf '' > "$STUB_RULES"
nc_diagnose > "$T/out" 2>&1 && : || fail "nc_diagnose должен вернуть 0, когда сеть в порядке"
grep -q 'Сеть в порядке' "$T/out" || fail "нет фразы «Сеть в порядке»: $(cat "$T/out")"

grep -q 'не проверялся' "$T/out" && fail "когда напрямую всё доступно, строка про непроверенный прокси не нужна"
# 2. Нет интернета вообще
run_case "1.1.1.1 28 000
www.gstatic.com 28 000
www.cloudflare.com 28 000
$GH_DIRECT_FAIL"
eq "$(cat "$T/verdict")" no-internet "нет интернета"

# 3. Интернет есть, имена не резолвятся
run_case "www.gstatic.com 6 000
www.cloudflare.com 6 000
github.com 6 000
api.github.com 6 000
raw.githubusercontent.com 6 000
objects.githubusercontent.com 6 000"
eq "$(cat "$T/verdict")" dns "DNS"

# 4. Ошибки TLS на GitHub
run_case "github.com 35 000
api.github.com 35 000
raw.githubusercontent.com 35 000
objects.githubusercontent.com 35 000"
eq "$(cat "$T/verdict")" tls "TLS"

# 5. GitHub режется, через mihomo доступен
printf 'mixed-port: 7890\n' > "$T/cfg.yaml"
NC_CONFIG=$T/cfg.yaml
run_case "$GH_DIRECT_FAIL"
eq "$(cat "$T/verdict")" blocked-proxy-ok "GitHub режется, прокси работает"
# 6. ... и через mihomo не работает
run_case "$GH_DIRECT_FAIL
github.com@proxy 28 000
raw.githubusercontent.com@proxy 28 000"
eq "$(cat "$T/verdict")" blocked-proxy-fail "через прокси тоже таймаут"
# 7. ... mihomo не запущен (порт закрыт)
run_case "$GH_DIRECT_FAIL
github.com@proxy 7 000
raw.githubusercontent.com@proxy 7 000
www.gstatic.com@proxy 7 000"
eq "$(cat "$T/verdict")" blocked-core-down "порт mihomo закрыт"
# 8. ... прокси не настроен
NC_CONFIG=$T/nonexistent.yaml
run_case "$GH_DIRECT_FAIL"
eq "$(cat "$T/verdict")" blocked-no-proxy "прокси не настроен"
# NC_PROXY из окружения заменяет конфиг
NC_PROXY=http://127.0.0.1:9999 run_case "$GH_DIRECT_FAIL"
eq "$(cat "$T/verdict")" blocked-proxy-ok "NC_PROXY"
# 9. HTTP 403/451 от GitHub
run_case "github.com 0 451
api.github.com 0 451"
eq "$(cat "$T/verdict")" provider-block "451"
# 10. Часть хостов GitHub недоступна
run_case "objects.githubusercontent.com 28 000"
eq "$(cat "$T/verdict")" partial "частичная блокировка"

# ----- прокси из конфига -----
printf 'log-level: info\nmixed-port: 7890\n' > "$T/c1.yaml"
eq "$(NC_CONFIG=$T/c1.yaml nc_proxy_url)" "http://127.0.0.1:7890" "mixed-port"
printf 'port: 7891\n' > "$T/c2.yaml"
eq "$(NC_CONFIG=$T/c2.yaml nc_proxy_url)" "http://127.0.0.1:7891" "port"
printf 'socks-port: 7892\n' > "$T/c3.yaml"
eq "$(NC_CONFIG=$T/c3.yaml nc_proxy_url)" "socks5h://127.0.0.1:7892" "socks-port"
printf 'mixed-port: 0\n' > "$T/c4.yaml"
eq "$(NC_CONFIG=$T/c4.yaml nc_proxy_url)" "" "порт 0 - прокси нет"
eq "$(NC_CONFIG=$T/nonexistent.yaml nc_proxy_url)" "" "нет конфига"
eq "$(NC_PROXY=http://h:1 NC_CONFIG=$T/c1.yaml nc_proxy_url)" "http://h:1" "NC_PROXY сильнее конфига"

# ----- сводка и советы: человеческим языком, без кодов curl -----
printf '%s\n' "$GH_DIRECT_FAIL" > "$STUB_RULES"
NC_CONFIG=$T/cfg.yaml
nc_diagnose > "$T/out" 2>&1 && fail "при блокировке nc_diagnose должен вернуть не 0" || :
grep -q 'GitHub напрямую' "$T/out" || fail "в сводке нет «GitHub напрямую»: $(cat "$T/out")"
grep -q 'через mihomo' "$T/out" || fail "в сводке нет «через mihomo»: $(cat "$T/out")"
grep -q 'таймаут' "$T/out" || fail "причина должна быть словами (таймаут): $(cat "$T/out")"
grep -q 'проксирование трафика' "$T/out" || fail "нет совета про проксирование трафика роутера: $(cat "$T/out")"
grep -q 'INSTALL_PROXY' "$T/out" || fail "нет совета про INSTALL_PROXY"
grep -q 'код curl\|curl 28' "$T/out" && fail "в выводе не должно быть голых кодов curl"
for v in no-internet dns tls blocked-proxy-fail blocked-core-down blocked-no-proxy provider-block partial ok; do
  [ -n "$(nc_advice_for "$v")" ] || fail "нет совета для вердикта $v"
done

# ----- параллельность: 10 проб по 1 с укладываются в таймаут, не в 10 с -----
printf '' > "$STUB_RULES"
NC_CONFIG=$T/cfg.yaml
start=$(date +%s)
STUB_DELAY=1 nc_run
end=$(date +%s)
nc_cleanup
[ $((end - start)) -le 4 ] || fail "пробы идут не параллельно: $((end - start)) с"

# ----- подключение библиотеки без побочных эффектов -----
out=$(sh -c '. "$1"; echo loaded' _ "$LIB" 2>&1)
eq "$out" loaded "подключение библиотеки молчит"

[ "$FAILED" = 0 ] && echo "OK test_netcheck"
exit "$FAILED"
