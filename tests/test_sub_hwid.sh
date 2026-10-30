#!/bin/sh
# HWID устройства для панелей подписок с лимитом устройств (Remnawave и
# т.п.): данные устройства (detect_ua.sh), распознавание заглушки, подбор UA
# с повтором под HWID, перенос признака x-hwid через existing_config.awk,
# render_config.awk, config_to_state.awk и migrate_config (конструктор).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOLS=$ROOT/config-tools
WORK=$(mktemp -d /tmp/test-sub-hwid.XXXXXX)
trap 'rm -rf "$WORK"' EXIT INT TERM
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
TAB=$(printf '\t')

# --- данные устройства: генерация, постоянство, проверка значений
SUB_DEVICE_FILE=$WORK/dev/sub-device.env
DETECT_UA_LIB_ONLY=1 . "$TOOLS/detect_ua.sh"
set +e
sub_device_load || fail "sub_device_load: $SUB_DEVICE_ERR"
h1=$SUB_HWID
printf '%s' "$h1" | grep -Eq '^[A-Za-z0-9]{16}$' || fail "HWID 16 символов: [$h1]"
[ "$SUB_DEVICE_OS/$SUB_OS_VER/$SUB_DEVICE_MODEL" = "Android/15/SM-A556B" ] || fail "умолчания устройства"
sub_device_load; [ "$SUB_HWID" = "$h1" ] || fail "HWID должен сохраняться"
printf 'SUB_HWID=bad hwid!\nSUB_DEVICE_MODEL=Pixel 8\nSUB_DEVICE_OS=i"OS\n' > "$SUB_DEVICE_FILE"
sub_device_load
[ "$SUB_HWID" != "bad hwid!" ] && sub_device_hwid_ok "$SUB_HWID" || fail "негодный HWID заменяется"
[ "$SUB_DEVICE_MODEL" = "Pixel 8" ] || fail "модель с пробелом допустима"
[ "$SUB_DEVICE_OS" = Android ] || fail "ОС с кавычкой - по умолчанию"
sub_device_hwid_ok 'short' && fail "HWID короче 10 не проходит"
sub_device_hwid_ok 'UE42LJXu4DbiCaBv' || fail "HWID из документации Remnawave"
sub_device_hwid_ok '270DD26E-160D-4257-B8AC-654800E12F24' || fail "HWID-UUID"
(SUB_DEVICE_FILE=/proc/nope/sub-device.env; sub_device_load) && fail "несохраняемый файл - ошибка"

# --- вид ответа: заглушка, лимит, happ://crypt
printf 'HTTP/1.1 200 OK\r\nx-hwid-not-supported: true\r\n\r\n' > "$WORK/h1"
printf 'mixed-port: 7890\nproxy-groups: []\nproxies: []\n' > "$WORK/b1"
case $(probe_kind "$WORK/h1" "$WORK/b1") in "заглушка:"*) ;; *) fail "заглушка по x-hwid-not-supported" ;; esac
printf 'HTTP/1.1 200 OK\r\nX-Hwid-Max-Devices-Reached: true\r\n\r\n' > "$WORK/h2"
case $(probe_kind "$WORK/h2" "$WORK/b1") in "лимит устройств"*) ;; *) fail "лимит устройств" ;; esac
case $(probe_kind "$WORK/none" "$WORK/b1") in "clash YAML, полный"*) ;; *) fail "без заголовков - по телу" ;; esac
printf 'happ://crypt3/AbCdEf\n' > "$WORK/b2"
case $(classify_body "$WORK/b2") in "зашифровано для Happ"*) ;; *) fail "happ://crypt не подходит" ;; esac

# --- ua_pick: заглушка -> повтор с HWID; обычная панель HWID не получает
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOC'
#!/bin/sh
out="" ua="" url="" hdr="" hwid=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;; -A) ua=$2; shift 2 ;; -D) hdr=$2; shift 2 ;;
    -H) case $2 in "x-hwid: "*) hwid=${2#x-hwid: } ;; esac; shift 2 ;;
    -w|-m|--proto|--proto-redir) shift 2 ;; -*) shift ;; *) url=$1; shift ;;
  esac
done
echo "$ua${hwid:+ hwid}" >> "$CURL_LOG"
full='mixed-port: 7890
proxy-groups: []
proxies: []'
case $url in
  */limit)
    if [ -z "$hwid" ]; then printf 'x-hwid-not-supported: true\r\n' > "$hdr"; printf '%s\n' "$full" > "$out"
    else case $ua in Happ*) printf 'happ://crypt3/x\n' > "$out" ;; *) printf '%s\n' "$full" > "$out" ;; esac; fi ;;
  *) case $ua in FlClashX*) printf '%s\n' "$full" > "$out" ;; *) printf '[{"a":1}]' > "$out" ;; esac ;;
esac
printf 200
EOC
chmod +x "$WORK/bin/curl"
export CURL_LOG=$WORK/curl.log
rm -f "$SUB_DEVICE_FILE"
: > "$CURL_LOG"
PATH="$WORK/bin:$PATH" ua_pick https://p.test/limit "$WORK/body" "$WORK/rows"
[ "$UA_PICK_UA/$UA_PICK_QUALITY/$UA_PICK_HWID" = "FlClashX/0.3.2/full/1" ] || fail "ua_pick limit: $UA_PICK_UA/$UA_PICK_QUALITY/$UA_PICK_HWID"
[ "$(tr '\n' ',' < "$CURL_LOG")" = "Happ/4.11.0,Happ/4.11.0 hwid,FlClashX/0.3.2 hwid," ] || fail "ua_pick limit запросы: $(cat "$CURL_LOG")"
[ "$(wc -l < "$WORK/rows" | tr -d ' ')" = 3 ] || fail "ua_pick строки"
[ -f "$SUB_DEVICE_FILE" ] || fail "HWID создан, когда понадобился"
rm -f "$SUB_DEVICE_FILE"; : > "$CURL_LOG"
PATH="$WORK/bin:$PATH" ua_pick https://p.test/plain "$WORK/body"
[ "$UA_PICK_UA/$UA_PICK_HWID" = "FlClashX/0.3.2/0" ] || fail "ua_pick plain"
grep -q hwid "$CURL_LOG" && fail "обычной панели HWID не отправлен"
[ -f "$SUB_DEVICE_FILE" ] && fail "без нужды HWID не создаётся"
set -e

# --- existing_config.awk: признак x-hwid -> hwid_out
cat > "$WORK/old.yaml" <<'EOY'
proxy-providers:
  plain:
    type: http
    url: "https://a.test/1"
    header:
      User-Agent:
        - "clash.meta"
  limited:
    type: http
    url: "https://b.test/2"
    header:
      User-Agent:
        - "FlClashX/0.3.2"
      x-hwid:
        - "OldHwid0123456"
      x-device-os:
        - "Android"
    health-check:
      enable: true
EOY
awk -v urls_out="$WORK/urls" -v hwid_out="$WORK/hw" -f "$TOOLS/existing_config.awk" "$WORK/old.yaml"
[ "$(cat "$WORK/hw")" = "https://b.test/2" ] || fail "existing_config: hwid_out"
[ "$(sed -n 2p "$WORK/urls")" = "https://b.test/2${TAB}FlClashX/0.3.2${TAB}limited" ] || fail "existing_config: UA при x-hwid"
awk -v urls_out="$WORK/urls2" -f "$TOOLS/existing_config.awk" "$WORK/old.yaml" || fail "existing_config без hwid_out"

# --- render_config.awk: заголовки только отмеченным подпискам
printf 'https://a.test/1\tclash.meta\tplain\nhttps://b.test/2\tFlClashX/0.3.2\tlimited\n' > "$WORK/specs"
awk -v providers_file="$WORK/specs" -v hwid_file="$WORK/hw" -v hwid=NewHwid0123456 -v dev_os=Android \
  -v os_ver=15 -v dev_model="Pixel 8" -f "$TOOLS/render_config.awk" "$TOOLS/config.example.yaml" > "$WORK/r.yaml"
awk '/^  limited:/{p=1} /^  plain:/{p=0} p' "$WORK/r.yaml" | grep -q '^        - "NewHwid0123456"$' || fail "render: x-hwid"
grep -q '^      x-device-model:$' "$WORK/r.yaml" && grep -q '^        - "Pixel 8"$' "$WORK/r.yaml" || fail "render: модель"
[ "$(grep -c '^      x-hwid:$' "$WORK/r.yaml")" = 1 ] || fail "render: x-hwid только у одной подписки"
rc=0; awk -v providers_file="$WORK/specs" -v hwid_file="$WORK/hw" -f "$TOOLS/render_config.awk" \
  "$TOOLS/config.example.yaml" > /dev/null 2>&1 || rc=$?
[ "$rc" = 4 ] || fail "render: без HWID при отмеченной подписке - код 4 ($rc)"

# --- конструктор: config_to_state (4-е поле) -> migrate_config (заголовки)
mkdir "$WORK/st"
awk -v defaults="$TOOLS/services.default.tsv" -v template="$TOOLS/config.example.yaml" -v out_dir="$WORK/st" \
  -v report="$WORK/rep" -f "$TOOLS/config_to_state.awk" "$WORK/r.yaml"
[ "$(sed -n 1p "$WORK/st/subscriptions.tsv")" = "https://a.test/1${TAB}clash.meta${TAB}plain" ] || fail "state: обычная подписка - 3 поля"
[ "$(sed -n 2p "$WORK/st/subscriptions.tsv")" = "https://b.test/2${TAB}FlClashX/0.3.2${TAB}limited${TAB}1" ] || fail "state: признак HWID"
printf 'SUB_HWID=StateHwid012345\nSUB_DEVICE_MODEL=ELP-NX1\n' > "$WORK/dev/sub-device.env"
if SUB_DEVICE_FILE="$WORK/dev/sub-device.env" sh "$TOOLS/constructor_build.sh" --state "$WORK/st" --source "$WORK/r.yaml" \
    --output "$WORK/b.yaml" --report "$WORK/brep" > "$WORK/blog" 2>&1; then
  awk '/^  limited:/{p=1} /^  plain:/{p=0} /^  fast:/{p=0} p' "$WORK/b.yaml" > "$WORK/lim"
  grep -q '^        - "StateHwid012345"$' "$WORK/lim" || fail "build: HWID из данных устройства"
  grep -q '^        - "ELP-NX1"$' "$WORK/lim" || fail "build: модель"
  grep -q '^        - "FlClashX/0.3.2"$' "$WORK/lim" || fail "build: UA"
  [ "$(grep -c '^      x-hwid:$' "$WORK/b.yaml")" = 1 ] || fail "build: x-hwid только у одной подписки"
else
  fail "constructor_build: $(cat "$WORK/blog")"
fi
# без признака - без заголовков устройства (старое состояние из 3 полей)
sed "s/${TAB}1\$//" "$WORK/st/subscriptions.tsv" > "$WORK/st/s2" && mv "$WORK/st/s2" "$WORK/st/subscriptions.tsv"
rm -f "$WORK/b.yaml"
SUB_DEVICE_FILE=/proc/nope/sub-device.env sh "$TOOLS/constructor_build.sh" --state "$WORK/st" --source "$WORK/r.yaml" \
  --output "$WORK/b.yaml" --report "$WORK/brep2" > "$WORK/blog" 2>&1 || fail "build без HWID: $(cat "$WORK/blog")"
grep -q 'x-hwid' "$WORK/b.yaml" && fail "build: снят признак - нет x-hwid"

# --- setup.sh: подбор отмечает подписку с лимитом устройств в HWID_URLS
SD=$WORK/selfdir; mkdir "$SD"
cp "$TOOLS"/*.sh "$TOOLS"/*.awk "$ROOT"/installer/*.sh "$SD/"
printf 'https://p.test/limit\nhttps://p.test/plain\n' > "$WORK/in"
: > "$WORK/hwu"
( unset SUB_DEVICE_FILE; SETUP_LIB_ONLY=1 SELFDIR=$SD DIR=$WORK/sdir; . "$SD/setup.sh"
  HWID_URLS=$WORK/hwu; PATH="$WORK/bin:$PATH" build_provider_specs "$WORK/in" ) > "$WORK/specs2" 2>/dev/null \
  || fail "setup: build_provider_specs"
[ "$(cat "$WORK/hwu")" = "https://p.test/limit" ] || fail "setup: HWID_URLS: $(cat "$WORK/hwu")"
[ "$(cut -f2 "$WORK/specs2" | tr '\n' ,)" = "FlClashX/0.3.2,FlClashX/0.3.2," ] || fail "setup: UA"
[ -f "$WORK/sdir/sub-device.env" ] || fail "setup: HWID создан в DIR"

[ "$FAILED" = 0 ] && echo "OK test_sub_hwid"
exit "$FAILED"
