#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/config-tools/setup.sh"
FAILED=0

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAIL: '$1' != '$2' ($3)" >&2
    FAILED=1
  fi
}

# setup.sh сорсит version_check.sh через $SELFDIR при подключении (даже
# под SETUP_LIB_ONLY=1). Дефолт SELFDIR=. не годится - рабочий каталог
# этого теста не обязательно каталог tests/, а корень репозитория (см.
# инструкцию запуска "sh tests/test_setup.sh"). Указываем реальный
# каталог, где лежит version_check.sh; отдельные сценарии ниже (WORK3,
# WORK4 и т.п.) переопределяют SELFDIR локально в своих подшеллах под
# свои нужды.
SELFDIR=$(mktemp -d)
cp "$ROOT"/install.sh "$ROOT"/uninstall.sh "$ROOT"/*/*.sh "$ROOT"/*/*.awk "$ROOT"/*/*.py "$ROOT"/*/*.html "$ROOT"/*/*.css "$ROOT"/*/*.js "$ROOT"/*/*.yaml "$SELFDIR/" 2>/dev/null

SETUP_LIB_ONLY=1 . "$SCRIPT"
unset SETUP_LIB_ONLY

WORK=$(mktemp -d)
DIR="$WORK" CONFIG="$WORK/config.yaml" SUB_URLS='https://sub1.example/AAA https://sub2.example/BBB' \
  collect_subscriptions > "$WORK/collected.txt"
assert_eq "$(wc -l < "$WORK/collected.txt" | tr -d ' ')" "2" "две ссылки из SUB_URLS"
grep -q '^https://sub1.example/AAA$' "$WORK/collected.txt" || { echo "FAIL: sub1 missing" >&2; FAILED=1; }
rm -rf "$WORK"
unset SUB_URLS DIR CONFIG

WORK=$(mktemp -d)
cat > "$WORK/config.yaml" <<'EOF'
proxy-providers:
  provider-a:
    type: http
    url: "https://old1.example/AAA"
    path: ./proxy-providers/provider-a.yaml
  provider-b:
    type: http
    url: "https://old2.example/BBB"
    path: ./proxy-providers/provider-b.yaml
EOF
OUT=$(printf '1\n\n' | DIR="$WORK" CONFIG="$WORK/config.yaml" SELFDIR="$SELFDIR" collect_subscriptions)
assert_eq "$OUT" "$(printf 'https://old2.example/BBB\t\tprovider-b')" "удалили подписку №1, оставили №2, новых не добавили (имя provider-b перенесено третьим полем)"
rm -rf "$WORK"
unset SUB_URLS DIR CONFIG

FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/curl" <<'EOF'
#!/bin/sh
# Фиктивный curl: разбирает -A UA и -o OUT из аргументов, эмулирует
# панель, которая отдаёт полный clash YAML только под UA "clash.meta".
ua=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -A) ua=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -m) shift 2 ;;
    -s) shift ;;
    *) shift ;;
  esac
done
if [ "$ua" = "clash.meta" ]; then
  printf 'mixed-port: 7890\nproxy-groups: []\nproxies: []\n' > "$out"
else
  printf '{"v": 2}' > "$out"
fi
printf '200'
EOF
chmod +x "$FAKEBIN/curl"

WORK2=$(mktemp -d)
printf 'https://sub1.example/AAA\n' > "$WORK2/urls.txt"
PATH="$FAKEBIN:$PATH" build_provider_specs "$WORK2/urls.txt" > "$WORK2/specs.txt"
grep -q "$(printf 'https://sub1.example/AAA\tclash.meta')" "$WORK2/specs.txt" || { echo "FAIL: expected clash.meta to be picked" >&2; FAILED=1; }
rm -rf "$FAKEBIN" "$WORK2"

# URL<TAB>UA (перенесённый из старого конфига header: User-Agent:) должен
# приниматься как есть, без вызова curl/pick_ua вообще - подсовываем
# заведомо неработающий curl, чтобы убедиться, что он не вызывается.
FAKEBIN_UA=$(mktemp -d)
cat > "$FAKEBIN_UA/curl" <<'EOF'
#!/bin/sh
echo "curl не должен вызываться для строки с уже известным UA" >&2
exit 1
EOF
chmod +x "$FAKEBIN_UA/curl"

WORK_UA=$(mktemp -d)
printf 'https://sub1.example/AAA\tv2rayNG/1.8.0\n' > "$WORK_UA/urls.txt"
PATH="$FAKEBIN_UA:$PATH" build_provider_specs "$WORK_UA/urls.txt" > "$WORK_UA/specs.txt" 2>"$WORK_UA/specs.err"
grep -q "$(printf 'https://sub1.example/AAA\tv2rayNG/1.8.0')" "$WORK_UA/specs.txt" || { echo "FAIL: сохранённый UA должен перейти в specs как есть" >&2; FAILED=1; }
grep -q 'не должен вызываться' "$WORK_UA/specs.err" && { echo "FAIL: build_provider_specs не должен запускать detect_ua для строки с уже известным UA" >&2; FAILED=1; }
rm -rf "$FAKEBIN_UA" "$WORK_UA"

# Список на выбор (drop-prompt) должен явно показывать перенесённый UA.
WORK_LIST=$(mktemp -d)
cat > "$WORK_LIST/config.yaml" <<'EOF'
proxy-providers:
  provider-a:
    type: http
    url: "https://old1.example/AAA"
    path: ./proxy-providers/provider-a.yaml
    header:
      User-Agent:
        - "v2rayNG/1.8.0"
EOF
LIST_OUT=$(DIR="$WORK_LIST" CONFIG="$WORK_LIST/config.yaml" SELFDIR="$SELFDIR" collect_subscriptions < /dev/null 2>&1 >/dev/null)
case "$LIST_OUT" in
  *"1) https://old1.example/AAA (свой UA: v2rayNG/1.8.0, имя: provider-a)"*) ;;
  *) echo "FAIL: список подписок должен показывать перенесённый UA и имя: $LIST_OUT" >&2; FAILED=1 ;;
esac
rm -rf "$WORK_LIST"

# Панель вроде v2ray/xray (например Durev VPN) отдаёт один и тот же
# base64-список ссылок (vless://...) для любого UA - это валидный
# для mihomo формат (см. classify_body), и build_provider_specs должен
# принять первый же проверенный UA, а не исключать подписку.
FAKEBIN_V2RAY=$(mktemp -d)
cat > "$FAKEBIN_V2RAY/curl" <<'EOF'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -A) shift 2 ;;
    -w) shift 2 ;;
    -m) shift 2 ;;
    -s) shift ;;
    *) shift ;;
  esac
done
printf 'dmxlc3M6Ly9iMzM2N2IzYy05YmQyLTUwMTAtYTliOC03NzM4ODQxY2FmMTJAYXV0by5leGFtcGxlLmNvbTo4NDQz' > "$out"
printf '200'
EOF
chmod +x "$FAKEBIN_V2RAY/curl"

WORK_V2RAY=$(mktemp -d)
printf 'https://durev.example/sub/XXXX\n' > "$WORK_V2RAY/urls.txt"
PATH="$FAKEBIN_V2RAY:$PATH" build_provider_specs "$WORK_V2RAY/urls.txt" > "$WORK_V2RAY/specs.txt" 2>"$WORK_V2RAY/specs.err"
grep -q 'durev.example/sub/XXXX' "$WORK_V2RAY/specs.txt" || { echo "FAIL: v2ray base64-подписка должна приниматься, а не исключаться" >&2; cat "$WORK_V2RAY/specs.err" >&2; FAILED=1; }
grep -qE 'WARN|исключена' "$WORK_V2RAY/specs.err" && { echo "FAIL: не должно быть WARN/исключения для валидной v2ray-подписки" >&2; cat "$WORK_V2RAY/specs.err" >&2; FAILED=1; }
rm -rf "$FAKEBIN_V2RAY" "$WORK_V2RAY"

FAKEBIN3=$(mktemp -d)
WORK3=$(mktemp -d)
mkdir -p "$WORK3/proxy-providers"

cat > "$FAKEBIN3/pidof" <<'EOF'
#!/bin/sh
[ "$1" = "mihomo" ] && exit 0
exit 1
EOF
cat > "$FAKEBIN3/xkeen" <<'EOF'
#!/bin/sh
case "$1" in
  -v) printf 'Версия XKeen 2.0 Stable (время сборки: 2026-06-06 08:53:30 MSK)\n  Ядро проксирования Mihomo версии 1.19.29\n' ;;
  -restart) exit 0 ;;
esac
EOF
cat > "$FAKEBIN3/ndmc" <<'EOF'
#!/bin/sh
printf '  version: (unassigned)\n  ndm.core.version: "5.1.4 (KeeneticOS)"\n'
EOF
cat > "$FAKEBIN3/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *9090/version) printf '{"version":"1.19.29"}'; exit 0 ;;
  esac
done
ua=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -A) ua=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && printf 'mixed-port: 7890\nproxy-groups: []\nproxies: []\n' > "$out"
printf '200'
EOF
cat > "$FAKEBIN3/mihomo" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKEBIN3"/*

cp "$ROOT/installer/version_check.sh" "$ROOT/installer/ui.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" \
   "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/setup.sh" "$WORK3/"
cat > "$WORK3/install.sh" <<'EOF'
#!/bin/sh
echo "install.sh (заглушка): запущен" >&2
exit 0
EOF
# setup.sh должен запускать install.sh через оболочку, даже если при переносе
# файлов исполняемый бит install.sh был потерян.
chmod 644 "$WORK3/install.sh"
chmod +x "$WORK3/setup.sh"

# < /dev/null: assign_provider_names() спросит подтверждение имени
# (новая подписка без импорта - коллизий нет, пустой ответ = имя по
# домену), EOF безопасно принимается как "Enter" - см. assign_provider_names().
PATH="$FAKEBIN3:$PATH" DIR="$WORK3" BIN=mihomo CONFIG="$WORK3/config.yaml" \
    TEMPLATE="$ROOT/config-tools/config.example.yaml" SELFDIR="$WORK3" API_MAIN=127.0.0.1:9090 \
    SUB_URLS='https://sub1.example/AAA' SKIP_CONFIRM=1 sh "$WORK3/setup.sh" \
    >"$WORK3/run.log" 2>&1 < /dev/null || { echo "FAIL: full run should succeed" >&2; cat "$WORK3/run.log" >&2; FAILED=1; }
grep -q 'install.sh (заглушка): запущен' "$WORK3/run.log" || { echo "FAIL: install.sh not invoked" >&2; FAILED=1; }
[ -f "$WORK3/config.yaml" ] || { echo "FAIL: config.yaml not written" >&2; FAILED=1; }
# Имя провайдера теперь по домену ссылки (sub1.example -> "sub1"), а не
# сгенерированный provider-1 - см. docs/plans/2026-09-07-provider-naming-design.md.
grep -q 'sub1:' "$WORK3/config.yaml" || { echo "FAIL: имя провайдера по домену (sub1) отсутствует в сгенерированном конфиге" >&2; FAILED=1; }
grep -q 'provider-1:' "$WORK3/config.yaml" && { echo "FAIL: провайдер не должен называться provider-1" >&2; FAILED=1; }

cat > "$FAKEBIN3/mihomo" <<'EOF'
#!/bin/sh
echo "test: invalid config field xyz" >&2
exit 1
EOF
chmod +x "$FAKEBIN3/mihomo"
cp "$WORK3/config.yaml" "$WORK3/config.yaml.before"
# SUB_URLS убран во втором прогоне: config.yaml уже содержит подписку
# sub1 из первого прогона (импортируется заново с уже известными UA и
# именем), повторное добавление того же URL через SUB_URLS создавало бы
# у assign_provider_names неразрешимую коллизию имён без интерактивного
# ввода (два источника претендуют на одно и то же доменное имя "sub1").
if UI_LOG="$WORK3/ui.log" PATH="$FAKEBIN3:$PATH" DIR="$WORK3" BIN=mihomo CONFIG="$WORK3/config.yaml" \
    TEMPLATE="$ROOT/config-tools/config.example.yaml" SELFDIR="$WORK3" API_MAIN=127.0.0.1:9090 \
    SKIP_CONFIRM=1 sh "$WORK3/setup.sh" \
    >"$WORK3/run2.log" 2>&1 < /dev/null; then
  echo "FAIL: run should fail when mihomo -t rejects the rendered config" >&2
  FAILED=1
fi
cmp -s "$WORK3/config.yaml" "$WORK3/config.yaml.before" || { echo "FAIL: existing config.yaml must stay untouched when validation fails" >&2; FAILED=1; }
grep -q 'test: invalid config field xyz' "$WORK3/run2.log" || { echo "FAIL: mihomo -t output must be shown, not swallowed" >&2; FAILED=1; }
rejected_path=$(sed -n 's/^Непринятый конфиг оставлен в \(.*\) для разбора.*$/\1/p' "$WORK3/run2.log")
[ -n "$rejected_path" ] || { echo "FAIL: path to the rejected rendered config not reported" >&2; FAILED=1; }
[ -n "$rejected_path" ] && [ -f "$rejected_path" ] || { echo "FAIL: rejected rendered config was deleted instead of kept for inspection" >&2; FAILED=1; }
[ -n "$rejected_path" ] && rm -f "$rejected_path"

rm -rf "$FAKEBIN3" "$WORK3"

FAKEBIN4=$(mktemp -d)
WORK4=$(mktemp -d)
cat > "$WORK4/config.yaml" <<'EOF'
dns:
  enable: true
  nameserver:
    - 8.8.8.8

proxy-providers:
  provider-a:
    type: http
    url: "https://old1.example/AAA"
    path: ./proxy-providers/provider-a.yaml

proxies:
  - name: 'Real Node'
    type: hysteria2
    server: real.proxy.io
    password: "s3cr3t"

listeners:
  - name: my-socks
    type: socks
    port: 7777
EOF
cat > "$FAKEBIN4/pidof" <<'EOF'
#!/bin/sh
[ "$1" = "mihomo" ] && exit 0
exit 1
EOF
cat > "$FAKEBIN4/xkeen" <<'EOF'
#!/bin/sh
case "$1" in
  -v) printf 'Версия XKeen 2.0 Stable (время сборки: 2026-06-06 08:53:30 MSK)\n  Ядро проксирования Mihomo версии 1.19.29\n' ;;
  -restart) exit 0 ;;
esac
EOF
cat > "$FAKEBIN4/ndmc" <<'EOF'
#!/bin/sh
printf '  version: (unassigned)\n  ndm.core.version: "5.1.4 (KeeneticOS)"\n'
EOF
cat > "$FAKEBIN4/mihomo" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$FAKEBIN4/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *9090/version) exit 1 ;;
  esac
done
ua=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -A) ua=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && printf 'mixed-port: 7890\nproxy-groups: []\nproxies: []\n' > "$out"
printf '200'
EOF
chmod +x "$FAKEBIN4"/*
cp "$ROOT/installer/version_check.sh" "$ROOT/installer/ui.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" \
   "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/setup.sh" "$WORK4/"
cat > "$WORK4/install.sh" <<'EOF'
#!/bin/sh
echo "install.sh не должен запускаться" >&2
exit 1
EOF
chmod +x "$WORK4/install.sh" "$WORK4/setup.sh"

# Порядок ответов на stdin: (1) drop-prompt импорта - Enter, оставить
# provider-a; (2,3) assign_provider_names - Enter дважды, принять имя
# provider-a (перенесено) и имя по домену sub2 (для новой подписки);
# (4) подтверждение переноса блока proxies - "Y".
if printf '\n\n\nY\n' | env PATH="$FAKEBIN4:$PATH" DIR="$WORK4" BIN=mihomo CONFIG="$WORK4/config.yaml" \
    TEMPLATE="$ROOT/config-tools/config.example.yaml" SELFDIR="$WORK4" API_MAIN=127.0.0.1:9090 \
    SUB_URLS='https://sub2.example/BBB' SKIP_CONFIRM=1 sh "$WORK4/setup.sh" >"$WORK4/run.log" 2>&1; then
  echo "FAIL: run should fail when API never comes up after restart" >&2
  FAILED=1
fi
grep -q 'mihomo не поднялся после xkeen -restart' "$WORK4/run.log" || { echo "FAIL: missing API-timeout diagnostic" >&2; FAILED=1; }
grep -q 'install.sh не должен запускаться' "$WORK4/run.log" && { echo "FAIL: install.sh must not run when API never comes up" >&2; FAILED=1; }
grep -q 'Real Node' "$WORK4/config.yaml" || { echo "FAIL: static proxies block (confirmed Y) should still be merged into config.yaml even though the run later fails on the API wait" >&2; FAILED=1; }
grep -q '8.8.8.8' "$WORK4/config.yaml" || { echo "FAIL: dns block from old config.yaml should be transferred into the new config.yaml" >&2; FAILED=1; }
grep -q '^  - name: my-socks$' "$WORK4/config.yaml" || { echo "FAIL: свой вход my-socks должен переноситься в новый config.yaml" >&2; FAILED=1; }
[ "$(grep -c '^  - name: mst-speedtest$' "$WORK4/config.yaml")" = 1 ] || { echo "FAIL: служебный вход mst-speedtest должен быть ровно один" >&2; FAILED=1; }

# Сквозной сценарий имён провайдеров (Задача 4 плана provider-naming):
# импортированная подписка сохраняет старое имя (provider-a, принято
# Enter'ом), новая подписка из SUB_URLS получает имя по домену ссылки
# (sub2.example -> "sub2", тоже принято Enter'ом) - ни одна не должна
# называться provider-N.
grep -q 'provider-a:' "$WORK4/config.yaml" || { echo "FAIL: имя provider-a (перенесено при импорте) отсутствует в сгенерированном конфиге" >&2; FAILED=1; }
grep -q 'sub2:' "$WORK4/config.yaml" || { echo "FAIL: имя sub2 (по домену новой подписки) отсутствует в сгенерированном конфиге" >&2; FAILED=1; }
grep -q 'provider-1:' "$WORK4/config.yaml" && { echo "FAIL: провайдер не должен называться provider-1" >&2; FAILED=1; }
grep -q 'provider-2:' "$WORK4/config.yaml" && { echo "FAIL: провайдер не должен называться provider-2" >&2; FAILED=1; }

rm -rf "$FAKEBIN4" "$WORK4"

# Портция 2 плана "DNS-guard": xkeen_ui_dns_protection_active() (см.
# tests/test_dns_guard.sh) подключена в main() перед перезаписью
# config.yaml. Общий фейковый ndmc для всех трёх сценариев ниже: сообщает
# оба признака активной защиты Xkeen UI (opkg dns-override + "no
# name-servers" на WAN) вперемешку со строками, нужными check_versions()
# (все фейковые ndmc в этом файле игнорируют сам аргумент команды и всегда
# печатают один и тот же вывод - см. существующие FAKEBIN2/3/4 выше).
FAKEBIN5=$(mktemp -d)
cat > "$FAKEBIN5/pidof" <<'EOF'
#!/bin/sh
[ "$1" = "mihomo" ] && exit 0
exit 1
EOF
cat > "$FAKEBIN5/xkeen" <<'EOF'
#!/bin/sh
case "$1" in
  -v) printf 'Версия XKeen 2.0 Stable (время сборки: 2026-06-06 08:53:30 MSK)\n  Ядро проксирования Mihomo версии 1.19.29\n' ;;
  -restart) exit 0 ;;
esac
EOF
cat > "$FAKEBIN5/ndmc" <<'EOF'
#!/bin/sh
printf '  version: (unassigned)\n  ndm.core.version: "5.1.4 (KeeneticOS)"\n'
printf 'interface ISP\n\tip dhcp client no name-servers\n!\nopkg dns-override\n!\n'
EOF
cat > "$FAKEBIN5/mihomo" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$FAKEBIN5/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *9090/version) printf '{"version":"1.19.29"}'; exit 0 ;;
  esac
done
ua=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -A) ua=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && printf 'mixed-port: 7890\nproxy-groups: []\nproxies: []\n' > "$out"
printf '200'
EOF
chmod +x "$FAKEBIN5"/*

# Сценарий "отказ": защита активна, подтверждения нет ("n") - установка
# должна остановиться ДО первого же вопроса про подписки, config.yaml не
# должен появиться, install.sh не должен запускаться.
WORK5A=$(mktemp -d)
cp "$ROOT/installer/version_check.sh" "$ROOT/installer/ui.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" \
   "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/setup.sh" "$WORK5A/"
cat > "$WORK5A/install.sh" <<'EOF'
#!/bin/sh
echo "install.sh не должен запускаться" >&2
exit 1
EOF
chmod +x "$WORK5A/install.sh" "$WORK5A/setup.sh"
if printf 'n\n' | env PATH="$FAKEBIN5:$PATH" DIR="$WORK5A" BIN=mihomo CONFIG="$WORK5A/config.yaml" \
    TEMPLATE="$ROOT/config-tools/config.example.yaml" SELFDIR="$WORK5A" API_MAIN=127.0.0.1:9090 \
    SUB_URLS='https://sub1.example/AAA' sh "$WORK5A/setup.sh" >"$WORK5A/run.log" 2>&1; then
  echo "FAIL: run should abort when DNS-guard confirmation is declined" >&2
  FAILED=1
fi
grep -q 'Установка отменена' "$WORK5A/run.log" || { echo "FAIL: missing DNS-guard cancellation message" >&2; FAILED=1; }
grep -q 'install.sh не должен запускаться' "$WORK5A/run.log" && { echo "FAIL: install.sh must not run after DNS-guard decline" >&2; FAILED=1; }
[ -f "$WORK5A/config.yaml" ] && { echo "FAIL: config.yaml must not be written after DNS-guard decline" >&2; FAILED=1; }
rm -rf "$WORK5A"

# Сценарий "обход DNS-guard": та же активная защита, но
# SKIP_DNS_GUARD_CHECK=1 - именно этот абзац показываться не должен, но
# общее предупреждение+подтверждение (см. confirm_config_replace()) всё
# равно задаётся - SKIP_DNS_GUARD_CHECK отключает только проверку Xkeen
# UI, не весь вопрос целиком (для этого есть отдельный SKIP_CONFIRM).
WORK5B=$(mktemp -d)
cp "$ROOT/installer/version_check.sh" "$ROOT/installer/ui.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" \
   "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/setup.sh" "$WORK5B/"
cat > "$WORK5B/install.sh" <<'EOF'
#!/bin/sh
echo "install.sh (заглушка): запущен" >&2
exit 0
EOF
chmod +x "$WORK5B/install.sh" "$WORK5B/setup.sh"
if ! printf 'y\n' | env PATH="$FAKEBIN5:$PATH" DIR="$WORK5B" BIN=mihomo CONFIG="$WORK5B/config.yaml" \
    TEMPLATE="$ROOT/config-tools/config.example.yaml" SELFDIR="$WORK5B" API_MAIN=127.0.0.1:9090 \
    SUB_URLS='https://sub1.example/AAA' SKIP_DNS_GUARD_CHECK=1 sh "$WORK5B/setup.sh" \
    >"$WORK5B/run.log" 2>&1; then
  echo "FAIL: run with SKIP_DNS_GUARD_CHECK=1 should succeed after confirming the general warning" >&2
  cat "$WORK5B/run.log" >&2
  FAILED=1
fi
grep -q 'Похоже, на роутере сейчас активна' "$WORK5B/run.log" && { echo "FAIL: SKIP_DNS_GUARD_CHECK=1 must suppress the DNS-guard paragraph" >&2; FAILED=1; }
grep -q 'config.yaml будет создан заново или полностью заменён' "$WORK5B/run.log" || { echo "FAIL: SKIP_DNS_GUARD_CHECK=1 must NOT suppress the general confirmation" >&2; FAILED=1; }
[ -f "$WORK5B/config.yaml" ] || { echo "FAIL: config.yaml should be written when the guard is skipped and the general confirmation is accepted" >&2; FAILED=1; }
rm -rf "$WORK5B"

# Сценарий "подтверждение": та же активная защита, ответ "y" - установка
# должна пройти как обычно, предупреждение должно быть показано.
WORK5C=$(mktemp -d)
cp "$ROOT/installer/version_check.sh" "$ROOT/installer/ui.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" \
   "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/setup.sh" "$WORK5C/"
cat > "$WORK5C/install.sh" <<'EOF'
#!/bin/sh
echo "install.sh (заглушка): запущен" >&2
exit 0
EOF
chmod +x "$WORK5C/install.sh" "$WORK5C/setup.sh"
if ! printf 'y\n' | env PATH="$FAKEBIN5:$PATH" DIR="$WORK5C" BIN=mihomo CONFIG="$WORK5C/config.yaml" \
    TEMPLATE="$ROOT/config-tools/config.example.yaml" SELFDIR="$WORK5C" API_MAIN=127.0.0.1:9090 \
    SUB_URLS='https://sub1.example/AAA' sh "$WORK5C/setup.sh" \
    >"$WORK5C/run.log" 2>&1; then
  echo "FAIL: run should succeed after DNS-guard confirmation (y)" >&2
  cat "$WORK5C/run.log" >&2
  FAILED=1
fi
grep -q 'Похоже, на роутере сейчас активна' "$WORK5C/run.log" || { echo "FAIL: DNS-guard warning was not shown" >&2; FAILED=1; }
grep -q 'install.sh (заглушка): запущен' "$WORK5C/run.log" || { echo "FAIL: install.sh not invoked after confirmation" >&2; FAILED=1; }
[ -f "$WORK5C/config.yaml" ] || { echo "FAIL: config.yaml should be written after confirmation" >&2; FAILED=1; }
rm -rf "$WORK5C"

rm -rf "$FAKEBIN5"

# --- Финальный обзор (C1b): mihomo -t должен проверять отрендеренный
# конфиг относительно MIHOMO_DIR (каталог самой Mihomo), а не DIR
# (каталог проекта speedtest2-stats) - см.
# docs/superpowers/specs/2026-09-25-install-dir-separation-design.md.
# До исправления setup.sh передавал сюда "$DIR".
FAKEBIN6=$(mktemp -d)
WORK6=$(mktemp -d)
mkdir -p "$WORK6/proxy-providers"

cat > "$FAKEBIN6/pidof" <<'EOF'
#!/bin/sh
[ "$1" = "mihomo" ] && exit 0
exit 1
EOF
cat > "$FAKEBIN6/xkeen" <<'EOF'
#!/bin/sh
case "$1" in
  -v) printf 'Версия XKeen 2.0 Stable (время сборки: 2026-06-06 08:53:30 MSK)
  Ядро проксирования Mihomo версии 1.19.29
' ;;
  -restart) exit 0 ;;
esac
EOF
cat > "$FAKEBIN6/ndmc" <<'EOF'
#!/bin/sh
printf '  version: (unassigned)
  ndm.core.version: "5.1.4 (KeeneticOS)"
'
EOF
cat > "$FAKEBIN6/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *9090/version) printf '{"version":"1.19.29"}'; exit 0 ;;
  esac
done
ua=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -A) ua=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && printf 'mixed-port: 7890
proxy-groups: []
proxies: []
' > "$out"
printf '200'
EOF

MIHOMO_ARG_LOG6=$(mktemp "${TMPDIR:-/tmp}/setup-mihomo-arg.XXXXXX")
cat > "$FAKEBIN6/mihomo" <<EOF
#!/bin/sh
echo "\$@" > "$MIHOMO_ARG_LOG6"
exit 0
EOF
chmod +x "$FAKEBIN6"/*

cp "$ROOT/installer/version_check.sh" "$ROOT/installer/ui.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" \
   "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/setup.sh" "$WORK6/"
cat > "$WORK6/install.sh" <<'EOF'
#!/bin/sh
echo "install.sh (заглушка): запущен" >&2
exit 0
EOF
chmod +x "$WORK6/install.sh" "$WORK6/setup.sh"

# Каталог самой Mihomo нарочно ОТЛИЧАЕТСЯ от DIR - суть регрессии C1b:
# если setup.sh перепутает их местами, в логе окажется "-d $WORK6" вместо
# "-d $MIHOMO_HOME6".
MIHOMO_HOME6=$(mktemp -d)

PATH="$FAKEBIN6:$PATH" DIR="$WORK6" MIHOMO_DIR="$MIHOMO_HOME6" BIN=mihomo CONFIG="$WORK6/config.yaml" \
    TEMPLATE="$ROOT/config-tools/config.example.yaml" SELFDIR="$WORK6" API_MAIN=127.0.0.1:9090 \
    SUB_URLS='https://sub1.example/AAA' SKIP_CONFIRM=1 sh "$WORK6/setup.sh" \
    >"$WORK6/run.log" 2>&1 < /dev/null || { echo "FAIL: C1b full run should succeed" >&2; cat "$WORK6/run.log" >&2; FAILED=1; }

[ -f "$MIHOMO_ARG_LOG6" ] || { echo "FAIL: setup.sh не вызвал \$BIN (mihomo -t) - регрессионный тест C1b не может ничего проверить" >&2; FAILED=1; }
if [ -f "$MIHOMO_ARG_LOG6" ]; then
  grep -qF -- "-d $MIHOMO_HOME6 " "$MIHOMO_ARG_LOG6" \
    || { echo "FAIL: setup.sh передал mihomo -t не тот -d: ожидался MIHOMO_DIR ($MIHOMO_HOME6), получено: $(cat "$MIHOMO_ARG_LOG6")" >&2; FAILED=1; }
  grep -qF -- "-d $WORK6 " "$MIHOMO_ARG_LOG6" \
    && { echo "FAIL: setup.sh передал mihomo -t каталог DIR ($WORK6) вместо MIHOMO_DIR - регрессия C1b" >&2; FAILED=1; }
fi

rm -rf "$FAKEBIN6" "$WORK6" "$MIHOMO_HOME6" "$MIHOMO_ARG_LOG6"

# --- Общее предупреждение+подтверждение перед заменой config.yaml
# (confirm_config_replace(), без активного DNS-guard Xkeen UI) - владелец
# попросил безусловное предупреждение о том, что config.yaml будет
# создан/заменён и в него попадут вспомогательные прокси-группы, самым
# первым шагом main(), до сбора подписок. ---
FAKEBIN7=$(mktemp -d)
WORK7=$(mktemp -d)
mkdir -p "$WORK7/proxy-providers"

cat > "$FAKEBIN7/pidof" <<'EOF'
#!/bin/sh
[ "$1" = "mihomo" ] && exit 0
exit 1
EOF
cat > "$FAKEBIN7/xkeen" <<'EOF'
#!/bin/sh
case "$1" in
  -v) printf 'Версия XKeen 2.0 Stable (время сборки: 2026-06-06 08:53:30 MSK)
  Ядро проксирования Mihomo версии 1.19.29
' ;;
  -restart) exit 0 ;;
esac
EOF
cat > "$FAKEBIN7/ndmc" <<'EOF'
#!/bin/sh
printf '  version: (unassigned)
  ndm.core.version: "5.1.4 (KeeneticOS)"
'
EOF
cat > "$FAKEBIN7/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *9090/version) printf '{"version":"1.19.29"}'; exit 0 ;;
  esac
done
ua=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -A) ua=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && printf 'mixed-port: 7890
proxy-groups: []
proxies: []
' > "$out"
printf '200'
EOF
cat > "$FAKEBIN7/mihomo" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKEBIN7"/*

cp "$ROOT/installer/version_check.sh" "$ROOT/installer/ui.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" \
   "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/setup.sh" "$WORK7/"
cat > "$WORK7/install.sh" <<'EOF'
#!/bin/sh
echo "install.sh (заглушка): запущен" >&2
exit 0
EOF
chmod +x "$WORK7/install.sh" "$WORK7/setup.sh"

# Без ответа (EOF на stdin, DNS-guard не активен - FAKEBIN7 его не
# симулирует) - установка должна остановиться ДО первого же вопроса про
# подписки, config.yaml не должен появиться, install.sh не должен
# запускаться. Предупреждение про замену конфига и вспомогательные
# прокси-группы должно быть показано, абзац про Xkeen UI - нет.
if PATH="$FAKEBIN7:$PATH" DIR="$WORK7" BIN=mihomo CONFIG="$WORK7/config.yaml" \
    TEMPLATE="$ROOT/config-tools/config.example.yaml" SELFDIR="$WORK7" API_MAIN=127.0.0.1:9090 \
    SUB_URLS='https://sub1.example/AAA' sh "$WORK7/setup.sh" \
    >"$WORK7/run.log" 2>&1 < /dev/null; then
  echo "FAIL: run should abort when the general confirmation gets no answer" >&2
  cat "$WORK7/run.log" >&2
  FAILED=1
fi
grep -q 'config.yaml будет создан заново или полностью заменён' "$WORK7/run.log" \
  || { echo "FAIL: missing general config-replace warning" >&2; FAILED=1; }
grep -q 'вспомогательные группы автоматического выбора прокси' "$WORK7/run.log" \
  || { echo "FAIL: warning must mention the auxiliary proxy-selection groups" >&2; FAILED=1; }
grep -q 'Похоже, на роутере сейчас активна' "$WORK7/run.log" \
  && { echo "FAIL: DNS-guard paragraph must not appear when the guard is not active" >&2; FAILED=1; }
grep -q 'Установка отменена' "$WORK7/run.log" || { echo "FAIL: missing cancellation message" >&2; FAILED=1; }
grep -q 'install.sh (заглушка): запущен' "$WORK7/run.log" && { echo "FAIL: install.sh must not run before confirmation" >&2; FAILED=1; }
[ -f "$WORK7/config.yaml" ] && { echo "FAIL: config.yaml must not be written before confirmation" >&2; FAILED=1; }

# С ответом "y" - установка должна пройти как обычно.
if ! printf 'y\n' | env PATH="$FAKEBIN7:$PATH" DIR="$WORK7" BIN=mihomo CONFIG="$WORK7/config.yaml" \
    TEMPLATE="$ROOT/config-tools/config.example.yaml" SELFDIR="$WORK7" API_MAIN=127.0.0.1:9090 \
    SUB_URLS='https://sub1.example/AAA' sh "$WORK7/setup.sh" \
    >"$WORK7/run2.log" 2>&1; then
  echo "FAIL: run should succeed after confirming the general warning (y)" >&2
  cat "$WORK7/run2.log" >&2
  FAILED=1
fi
grep -q 'install.sh (заглушка): запущен' "$WORK7/run2.log" || { echo "FAIL: install.sh not invoked after confirmation" >&2; FAILED=1; }
[ -f "$WORK7/config.yaml" ] || { echo "FAIL: config.yaml should be written after confirmation" >&2; FAILED=1; }

rm -rf "$FAKEBIN7" "$WORK7"

# --- Task 9: оформление мастера (ui.sh) в plain-режиме ---
FAKEBIN8=$(mktemp -d)
WORK8=$(mktemp -d)
mkdir -p "$WORK8/proxy-providers"
cat > "$FAKEBIN8/pidof" <<'EOF'
#!/bin/sh
[ "$1" = "mihomo" ] && exit 0
exit 1
EOF
cat > "$FAKEBIN8/xkeen" <<'EOF'
#!/bin/sh
case "$1" in
  -v) printf 'Версия XKeen 2.0 Stable (время сборки: 2026-06-06 08:53:30 MSK)\n  Ядро проксирования Mihomo версии 1.19.29\n' ;;
  -restart) echo "xkeen: перезапуск ядра (вывод для журнала)"; exit 0 ;;
esac
EOF
cat > "$FAKEBIN8/ndmc" <<'EOF'
#!/bin/sh
printf '  version: (unassigned)\n  ndm.core.version: "5.1.4 (KeeneticOS)"\n'
EOF
cat > "$FAKEBIN8/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *9090/version) printf '{"version":"1.19.29"}'; exit 0 ;;
  esac
done
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && printf 'mixed-port: 7890\nproxy-groups: []\nproxies: []\n' > "$out"
printf '200'
EOF
cat > "$FAKEBIN8/mihomo" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKEBIN8"/*
cp "$ROOT/installer/version_check.sh" "$ROOT/installer/ui.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" \
   "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/setup.sh" "$WORK8/"
cat > "$WORK8/install.sh" <<'EOF'
#!/bin/sh
echo "install.sh (заглушка): UI_CONTINUE=${UI_CONTINUE:-} FROM_TEMPLATE=${MST_CONFIG_FROM_TEMPLATE:-}" >&2
exit 0
EOF
cat > "$WORK8/config.yaml" <<'EOF'
proxy-providers:
  provider-a:
    type: http
    url: "https://old1.example/AAA"
    path: ./proxy-providers/provider-a.yaml

proxies:
  - name: 'Real Node'
    type: hysteria2
    server: real.proxy.io
    password: "s3cr3t"
EOF
cp "$WORK8/config.yaml" "$WORK8/config.orig"

run8() {
  # $1 = лог; ответы: Enter (drop), Enter (имя), Y (перенос proxies)
  printf '\n\nY\n' | env PATH="$FAKEBIN8:$PATH" UI=plain UI_LOG="$WORK8/ui.log" DIR="$WORK8" BIN=mihomo \
    CONFIG="$WORK8/config.yaml" TEMPLATE="$ROOT/config-tools/config.example.yaml" SELFDIR="$WORK8" \
    API_MAIN=127.0.0.1:9090 SKIP_CONFIRM=1 "$@" sh "$WORK8/setup.sh"
}
run8 env >"$WORK8/run.log" 2>&1 || { echo "FAIL: setup (ui) run should succeed" >&2; cat "$WORK8/run.log" >&2; FAILED=1; }
grep -q '^== MIHOMO-SPEEDTEST — Настройка нового роутера ==$' "$WORK8/run.log" || { echo "FAIL: standalone setup must show full banner with subtitle" >&2; FAILED=1; }
# Ввод идёт из pipe без эха, поэтому строка шага может склеиться с
# предыдущим приглашением - якоря ^ нет.
steps=$(grep -oE ' 0[1-4]/04  ?[^ ]+' "$WORK8/run.log" | sed 's/^ *//; s/  */ /' | tr '\n' ' ')
assert_eq "$steps" "01/04 Подписки 02/04 User-Agent 03/04 Имена 04/04 Конфиг " "шаги мастера по порядку"
grep -q '^\[??\] .*\[Y/n\]' "$WORK8/run.log" || { echo "FAIL: вопрос о переносе proxies должен идти через [??]" >&2; FAILED=1; }
grep -q 'Перезапуск ядра' "$WORK8/run.log" || { echo "FAIL: нет шага «Перезапуск ядра»" >&2; FAILED=1; }
grep -q 'xkeen: перезапуск ядра' "$WORK8/run.log" && { echo "FAIL: вывод xkeen не должен попадать на экран" >&2; FAILED=1; }
# И не в журнал: демон, запущенный xkeen, унаследовал бы дескриптор журнала
# и писал бы в него вечно (restart_core глушит вывод в /dev/null).
grep -q 'xkeen: перезапуск ядра' "$WORK8/ui.log" && { echo "FAIL: вывод xkeen не должен попадать в UI_LOG" >&2; FAILED=1; }
grep -q 'UI_CONTINUE=1 FROM_TEMPLATE=1' "$WORK8/run.log" || { echo "FAIL: install.sh должен получить UI_CONTINUE=1 и MST_CONFIG_FROM_TEMPLATE=1" >&2; FAILED=1; }
grep -q "$(printf '\033')" "$WORK8/run.log" && { echo "FAIL: в plain-выводе не должно быть ESC" >&2; FAILED=1; }

# Приход из install.sh (UI_CONTINUE=1): вместо рамки - строка раздела.
cp "$WORK8/config.orig" "$WORK8/config.yaml"
run8 env UI_CONTINUE=1 >"$WORK8/run_c.log" 2>&1 || { echo "FAIL: setup (UI_CONTINUE) run should succeed" >&2; FAILED=1; }
grep -q '^== Настройка нового роутера ==$' "$WORK8/run_c.log" || { echo "FAIL: при UI_CONTINUE=1 нужна строка раздела" >&2; FAILED=1; }
grep -q 'MIHOMO-SPEEDTEST' "$WORK8/run_c.log" && { echo "FAIL: при UI_CONTINUE=1 баннер не повторяется" >&2; FAILED=1; }

# mihomo -t падает: [!!] + хвост на экране, полный вывод в UI_LOG.
cat > "$FAKEBIN8/mihomo" <<'EOF'
#!/bin/sh
echo "l1" >&2; echo "l2" >&2; echo "l3" >&2; echo "test: invalid config field xyz" >&2
exit 1
EOF
cp "$WORK8/config.orig" "$WORK8/config.yaml"
if run8 env >"$WORK8/run_f.log" 2>&1; then echo "FAIL: mihomo -t failure must fail the run" >&2; FAILED=1; fi
grep -q '^ *\[!!\] ' "$WORK8/run_f.log" || { echo "FAIL: mihomo -t неудача должна дать [!!]" >&2; FAILED=1; }
grep -q 'test: invalid config field xyz' "$WORK8/run_f.log" || { echo "FAIL: хвост вывода mihomo -t на экране" >&2; FAILED=1; }
grep -q '^l1$' "$WORK8/ui.log" || { echo "FAIL: полный вывод mihomo -t в UI_LOG" >&2; FAILED=1; }
grep -q 'Непринятый конфиг оставлен в' "$WORK8/run_f.log" || { echo "FAIL: сообщение о непринятом конфиге" >&2; FAILED=1; }
rj=$(sed -n 's/^Непринятый конфиг оставлен в \(.*\) для разбора.*$/\1/p' "$WORK8/run_f.log")
[ -z "$rj" ] || rm -f "$rj"
rm -rf "$FAKEBIN8" "$WORK8"

# --- Первая установка без нод: подписку можно пропустить. Ядро не запущено
# (pidof его не видит), setup.sh не требует процесс, собирает конфиг без
# нод, не гоняет mihomo -t и не перезапускает ядро - веб-интерфейс
# (install.sh) поднимется до запуска ядра, ноды добавят оттуда.
FAKEBIN9=$(mktemp -d)
WORK9=$(mktemp -d)
MARK9=$(mktemp -d)
cat > "$FAKEBIN9/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$FAKEBIN9/xkeen" <<EOF
#!/bin/sh
case "\$1" in
  -v) printf 'Версия XKeen 2.0 Stable (время сборки: 2026-06-06 08:53:30 MSK)
  Ядро проксирования Mihomo версии 1.19.29
' ;;
  -restart) echo restart > "$MARK9/restart" ;;
esac
EOF
cat > "$FAKEBIN9/ndmc" <<'EOF'
#!/bin/sh
printf '  version: (unassigned)
  ndm.core.version: "5.1.4 (KeeneticOS)"
'
EOF
cat > "$FAKEBIN9/mihomo" <<EOF
#!/bin/sh
echo "\$@" > "$MARK9/mihomo"
exit 0
EOF
chmod +x "$FAKEBIN9"/*
cp "$ROOT/installer/version_check.sh" "$ROOT/installer/ui.sh" "$ROOT/config-tools/detect_ua.sh" "$ROOT/config-tools/render_config.awk" "$ROOT/config-tools/fast_wg.awk" \
   "$ROOT/config-tools/existing_config.awk" "$ROOT/config-tools/setup.sh" "$WORK9/"
cat > "$WORK9/install.sh" <<'EOF'
#!/bin/sh
echo "install.sh (заглушка): запущен" >&2
exit 0
EOF
chmod +x "$WORK9/install.sh" "$WORK9/setup.sh"
run_setup9() {
  # $1 - файл со входом, остальное - дополнительное окружение; конфиг каждый раз новый
  [ "${KEEP_CONFIG9:-}" = 1 ] || rm -f "$WORK9/config.yaml"
  rm -f "$MARK9/restart" "$MARK9/mihomo"
  inp=$1; shift
  env PATH="$FAKEBIN9:$PATH" DIR="$WORK9" MIHOMO_DIR="$WORK9/mh" BIN=mihomo CONFIG="$WORK9/config.yaml" \
    TEMPLATE="$ROOT/config-tools/config.example.yaml" SELFDIR="$WORK9" API_MAIN=127.0.0.1:9090 \
    SKIP_CONFIRM=1 "$@" sh "$WORK9/setup.sh" >"$WORK9/run.log" 2>&1 < "$inp"
}
check_nonodes9() {
  [ -f "$WORK9/config.yaml" ] || { echo "FAIL: ($1) config.yaml не создан" >&2; FAILED=1; return; }
  grep -q 'sub-names: &sub-names \[\]' "$WORK9/config.yaml" || { echo "FAIL: ($1) sub-names должен быть пустым" >&2; FAILED=1; }
  grep -q '^  provider-a:' "$WORK9/config.yaml" && { echo "FAIL: ($1) в конфиге остались подписки шаблона" >&2; FAILED=1; }
  [ ! -e "$MARK9/restart" ] || { echo "FAIL: ($1) ядро перезапускалось без нод" >&2; FAILED=1; }
  [ ! -e "$MARK9/mihomo" ] || { echo "FAIL: ($1) mihomo -t запускался на конфиге без нод" >&2; FAILED=1; }
  grep -q 'ядро не запускалось' "$WORK9/run.log" || { echo "FAIL: ($1) нет сообщения, что ядро не запускалось" >&2; cat "$WORK9/run.log" >&2; FAILED=1; }
  grep -q 'install.sh (заглушка): запущен' "$WORK9/run.log" || { echo "FAIL: ($1) install.sh не запущен после мастера" >&2; FAILED=1; }
}
# а) Enter на вопросе о подписке (терминал) - пропуск
printf '\n' > "$WORK9/in_enter"
run_setup9 "$WORK9/in_enter" || { echo "FAIL: пропуск подписки по Enter должен завершаться успешно" >&2; cat "$WORK9/run.log" >&2; FAILED=1; }
check_nonodes9 "Enter"
# б) SKIP_SUBSCRIPTION=1 - то же без вопросов (неинтерактивно)
run_setup9 /dev/null SKIP_SUBSCRIPTION=1 || { echo "FAIL: SKIP_SUBSCRIPTION=1 должен завершаться успешно" >&2; cat "$WORK9/run.log" >&2; FAILED=1; }
check_nonodes9 "SKIP_SUBSCRIPTION"
# в) нет ввода вовсе (EOF) и конфига нет: мягкий режим - конфиг без нод, как
# при Enter (раньше отказ после трёх попыток)
run_setup9 /dev/null || { echo "FAIL: без ввода и без конфига мастер должен собрать конфиг без нод" >&2; cat "$WORK9/run.log" >&2; FAILED=1; }
check_nonodes9 "EOF без конфига"
grep -q 'Ввода нет' "$WORK9/run.log" || { echo "FAIL: нет предупреждения, что ввода нет" >&2; FAILED=1; }
# г) конфиг со своей нодой (есть что терять): подписку не прошла проверку - отказ
# без вопроса, существующий конфиг не заменяется пустым (см. ниже, сценарий д)
PIDOK9=$(mktemp -d)
printf '#!/bin/sh\nexit 0\n' > "$PIDOK9/pidof"; chmod +x "$PIDOK9/pidof"
write_content9() {
  printf 'proxies:\n  - name: Own1\n    type: ss\n    server: 5.6.7.8\n    port: 2\n    cipher: aes-128-gcm\n    password: q\n' > "$WORK9/config.yaml"
  cp "$WORK9/config.yaml" "$WORK9/config.before"
}
# д) подписка не прошла проверку (ни один User-Agent не подошёл)
CURLFAIL9=$(mktemp -d)
cat > "$CURLFAIL9/curl" <<'CURLEOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -o ] && { shift; : > "$1"; }; shift; done
exit 22
CURLEOF
chmod +x "$CURLFAIL9/curl"
run_failed_sub9() { run_setup9 "$1" SUB_URLS=http://sub.fail.test/x PATH="$CURLFAIL9:$FAKEBIN9:$PATH"; }
#   Enter на вопросе «собрать без нод?» (по умолчанию да)
printf '\n' > "$WORK9/in_enter"
run_failed_sub9 "$WORK9/in_enter" || { echo "FAIL: подписка не прошла проверку - по умолчанию конфиг без нод" >&2; cat "$WORK9/run.log" >&2; FAILED=1; }
check_nonodes9 "подписка не прошла, Enter"
grep -q 'не подобран рабочий User-Agent' "$WORK9/run.log" || { echo "FAIL: нет причины, почему подписка исключена" >&2; FAILED=1; }
#   нет ввода (EOF) - тоже мягко
run_failed_sub9 /dev/null || { echo "FAIL: подписка не прошла и ввода нет - конфиг без нод" >&2; FAILED=1; }
check_nonodes9 "подписка не прошла, EOF"
#   ответ n - прежний отказ, конфиг не создан
printf 'n\n' > "$WORK9/in_no"
rc9=0; run_failed_sub9 "$WORK9/in_no" || rc9=$?
[ "$rc9" != 0 ] || { echo "FAIL: ответ n - мастер должен отказать" >&2; FAILED=1; }
grep -q 'Ни одна подписка не прошла проверку' "$WORK9/run.log" || { echo "FAIL: нет отказа 'Ни одна подписка не прошла проверку'" >&2; FAILED=1; }
[ ! -f "$WORK9/config.yaml" ] || { echo "FAIL: при отказе config.yaml создан" >&2; FAILED=1; }
#   конфиг со своей нодой - при непройденной подписке прежний отказ без вопроса
write_content9
rc9=0; KEEP_CONFIG9=1 run_setup9 "$WORK9/in_enter" SUB_URLS=http://sub.fail.test/x PATH="$CURLFAIL9:$PIDOK9:$FAKEBIN9:$PATH" || rc9=$?
[ "$rc9" != 0 ] || { echo "FAIL: существующий конфиг не должен заменяться пустым при непройденной подписке" >&2; FAILED=1; }
cmp -s "$WORK9/config.before" "$WORK9/config.yaml" || { echo "FAIL: существующий config.yaml изменён" >&2; FAILED=1; }
rm -rf "$PIDOK9" "$CURLFAIL9"
# е) заготовка XKeen (порты и listeners, ни подписок, ни нод) - как без
# конфига: нет требования запущенного mihomo (pidof здесь его не видит),
# подписка спрашивается; свои входы переносятся, старый файл остаётся в бэкапе.
write_stub9() {
  cat > "$WORK9/config.yaml" <<'STUBEOF'
find-process-mode: off # снижает нагрузку на роутер
# Не открывайте external-controller в LAN без secret

listeners:
  - name: tproxy
    type: tproxy
    port: 1181
    udp: true

  - name: redir
    type: redir
    port: 1182

# Руководство по конфигурации Mihomo
STUBEOF
  cp "$WORK9/config.yaml" "$WORK9/stub.before"
  rm -f "$WORK9"/config.yaml.*.bak
}
check_stub9() {
  stub_label=$1
  [ -f "$WORK9/config.yaml" ] || { echo "FAIL: ($stub_label) config.yaml пропал" >&2; FAILED=1; return; }
  grep -q 'sub-names: &sub-names \[\]' "$WORK9/config.yaml" || { echo "FAIL: ($stub_label) конфиг должен быть без нод" >&2; FAILED=1; }
  grep -q 'name: tproxy' "$WORK9/config.yaml" && grep -q 'name: redir' "$WORK9/config.yaml" || { echo "FAIL: ($stub_label) входы tproxy/redir из заготовки потеряны" >&2; FAILED=1; }
  grep -q 'find-process-mode: off' "$WORK9/config.yaml" || { echo "FAIL: ($stub_label) find-process-mode потерян" >&2; FAILED=1; }
  set -- "$WORK9"/config.yaml.*.bak
  { [ -f "$1" ] && cmp -s "$1" "$WORK9/stub.before"; } || { echo "FAIL: заготовка не сохранена в бэкап" >&2; FAILED=1; }
  grep -q 'Процесс mihomo не найден' "$WORK9/run.log" && { echo "FAIL: для заготовки процесс mihomo не требуется" >&2; FAILED=1; }
  grep -q 'install.sh (заглушка): запущен' "$WORK9/run.log" || { echo "FAIL: ($stub_label) install.sh не запущен после мастера" >&2; FAILED=1; }
}
STUBENV9=""
#   Enter на вопросе о подписке
write_stub9; printf '\n' > "$WORK9/in_enter"
KEEP_CONFIG9=1 run_setup9 "$WORK9/in_enter" $STUBENV9 || { echo "FAIL: заготовка, Enter: мастер должен завершиться успешно" >&2; cat "$WORK9/run.log" >&2; FAILED=1; }
check_stub9 "заготовка, Enter"
#   нет ввода (curl | sh без терминала) - мягко
write_stub9
KEEP_CONFIG9=1 run_setup9 /dev/null $STUBENV9 || { echo "FAIL: заготовка, нет ввода: конфиг без нод, а не отказ" >&2; cat "$WORK9/run.log" >&2; FAILED=1; }
check_stub9 "заготовка, EOF"
#   подписка не прошла проверку (ни один UA) - предложение собрать без нод, Enter = да
CURLFAIL9=$(mktemp -d)
cat > "$CURLFAIL9/curl" <<'CURLEOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -o ] && { shift; : > "$1"; }; shift; done
exit 22
CURLEOF
chmod +x "$CURLFAIL9/curl"
write_stub9
KEEP_CONFIG9=1 run_setup9 "$WORK9/in_enter" $STUBENV9 SUB_URLS=http://sub.fail.test/x PATH="$CURLFAIL9:$FAKEBIN9:$PATH" || { echo "FAIL: заготовка, подписка не прошла: конфиг без нод" >&2; cat "$WORK9/run.log" >&2; FAILED=1; }
check_stub9 "заготовка, подписка не прошла"
rm -rf "$CURLFAIL9"
rm -rf "$FAKEBIN9" "$WORK9" "$MARK9"

if [ "$FAILED" = 1 ]; then
  echo "test_setup.sh: FAILED" >&2
  exit 1
fi
echo "test_setup.sh: OK (шаг 1, C1b regression covered)"
