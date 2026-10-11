#!/bin/sh
# uninstall.sh: uninstall_state() сообщает о ядре, бэкапе для отката и о том,
# что не удаляется; ничего не меняет.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-state.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
export UI_LOG=/dev/null UI=plain
mkdir "$T/bin" "$T/m"
printf '#!/bin/sh\nexit "${STUB_CURL_RC:-0}"\n' > "$T/bin/curl"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/xkeen"
chmod +x "$T/bin/curl" "$T/bin/xkeen"

state() { # аргументы: окружение
  ( PATH="$T/bin:$PATH"; DIR="$T/none" CONFIG="$T/m/config.yaml" MIHOMO_DIR="$T/m" export DIR CONFIG MIHOMO_DIR
    UNINSTALL_LIB_ONLY=1 . "$ROOT/uninstall.sh"; uninstall_state ) 2>&1
}
printf 'mixed-port: 7890\n' > "$T/m/config.yaml"

out=$(state)
echo "$out" | grep -q 'Ядро mihomo запущено' || fail "ядро: $out"
echo "$out" | grep -q 'Бэкапов setup.sh' || fail "нет бэкапа: $out"
echo "$out" | grep -q 'mihomo, XKeen и ваши подписки не удаляются' || fail "нет строки про сохраняемое: $out"

: > "$T/m/config.yaml.2026-01-01_000000.bak"
out=$(STUB_CURL_RC=7 state)
echo "$out" | grep -q 'не отвечает' || fail "ядро не запущено: $out"
echo "$out" | grep -q 'Бэкап для отката найден' || fail "бэкап не найден: $out"

out=$(SKIP_CONFIG_REVERT=1 state)
echo "$out" | grep -q 'SKIP_CONFIG_REVERT=1' || fail "SKIP: $out"

rm "$T/m/config.yaml"
out=$(state)
echo "$out" | grep -q 'config.yaml не найден' || fail "нет config: $out"
echo "OK test_uninstall_state"
