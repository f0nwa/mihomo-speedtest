#!/bin/sh
# mihomo-speedtest doctor: состояние (ядро, конфиг, веб-служба) и диагностика сети.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/doctor-test.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir "$T/d" "$T/m" "$T/bin"
cp "$ROOT/installer/netcheck.sh" "$T/d/"
printf '#!/bin/sh\n[ "${FAKE_WEB:-1}" = 1 ]\n' > "$T/d/stats_service.sh"
printf 'mixed-port: 7890\n' > "$T/m/config.yaml"
printf '#!/bin/sh\nexit "${FAKE_CFG_RC:-0}"\n' > "$T/bin/mihomo"
# curl: путь /version (ядро) и пробы сети различаются по аргументам
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
for a in "$@"; do last=$a; done
case "$last" in
  *9090/version) exit "${FAKE_CORE_RC:-0}" ;;
esac
host=${last#*://}; host=${host%%/*}
case "$host" in github.com|api.github.com|raw.githubusercontent.com|objects.githubusercontent.com)
  [ "${FAKE_GH:-ok}" = ok ] || { printf 000; exit 28; } ;;
esac
printf 200
STUB
chmod +x "$T/bin/mihomo" "$T/bin/curl"

run() {
  PATH="$T/bin:$PATH" DIR="$T/d" MIHOMO_DIR="$T/m" BIN="$T/bin/mihomo" NC_TIMEOUT=2 UI=plain UI_LOG=/dev/null \
    sh "$ROOT/mihomo-speedtest.sh" doctor 2>&1
}
out=$(run)
for e in 'Ядро mihomo отвечает' 'проходит проверку' 'Веб-служба статистики работает' 'Сеть в порядке'; do
  echo "$out" | grep -Fq "$e" || fail "нет «$e»: $out"
done
out=$(FAKE_CORE_RC=7 FAKE_CFG_RC=1 FAKE_WEB=0 FAKE_GH=bad run)
for e in 'не отвечает' 'не проходит mihomo -t' 'не запущена' 'GitHub напрямую'; do
  echo "$out" | grep -Fq "$e" || fail "нет «$e»: $out"
done
rm "$T/d/netcheck.sh"
out=$(run)
echo "$out" | grep -Fq 'Проверка соединений недоступна' || fail "без netcheck.sh: $out"
echo "OK test_doctor"
