#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
GEN=$ROOT/release/generate_manifest.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/generate-manifest-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  case "$2" in
    *"$1"*) ;;
    *) fail "expected to find: $1 (context: $3)" ;;
  esac
}

# --- 1: настоящая декларация components.txt проекта генерируется и проходит самопроверку ---
OUT=$(sh "$GEN" 42 5 3)
assert_contains "RELEASE_VERSION=42" "$OUT" "версия релиза из аргумента"
assert_contains "MIN_UPDATER_VERSION=5" "$OUT" "минимальная версия update.sh из аргумента"
assert_contains "CONFIG_SCHEMA_VERSION=3" "$OUT" "версия схемы конфига из аргумента"
assert_contains "COMPONENT|updater|" "$OUT" "компонент updater объявлен"
assert_contains "COMPONENT|web|" "$OUT" "компонент web объявлен"
assert_contains "DEPENDS|web|speedtest-runtime" "$OUT" "web зависит от speedtest-runtime"
assert_contains "FILE|updater|update.sh|/opt/etc/mihomo-speedtest/update.sh|" "$OUT" "update.sh в манифесте"
assert_contains "FILE|installer|ui.sh|/opt/etc/mihomo-speedtest/ui.sh|" "$OUT" "ui.sh в манифесте компонента installer"
assert_contains "FILE|installer|update_interactive.sh|/opt/etc/mihomo-speedtest/update_interactive.sh|" "$OUT" "диалог обновления поставляется с командой"
assert_contains "DEPENDS|config-tools|installer" "$OUT" "setup.sh (config-tools) подключает ui.sh из installer"

echo "test_generate_manifest.sh: часть 1 (реальная декларация) OK" >&2

# --- 2: сгенерированный sha256 совпадает с sha256sum/shasum реального файла ---
if command -v sha256sum >/dev/null 2>&1; then
  REAL_SHA=$(sha256sum "$ROOT/updater/update.sh" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  REAL_SHA=$(shasum -a 256 "$ROOT/updater/update.sh" | awk '{print $1}')
else
  REAL_SHA=""
fi
if [ -n "$REAL_SHA" ]; then
  assert_contains "$REAL_SHA" "$OUT" "sha256 update.sh в манифесте совпадает с sha256sum"
fi

echo "test_generate_manifest.sh: часть 2 (sha256 совпадает) OK" >&2

# --- 3: неверные версии в аргументах отклоняются ---
if sh "$GEN" abc 1 1 >/dev/null 2>&1; then fail "release_version=abc должен быть отклонён"; fi
if sh "$GEN" 1 abc 1 >/dev/null 2>&1; then fail "min_updater_version=abc должен быть отклонён"; fi
if sh "$GEN" 1 1 abc >/dev/null 2>&1; then fail "config_schema_version=abc должен быть отклонён"; fi
if sh "$GEN" 1 1 >/dev/null 2>&1; then fail "нехватка аргументов должна быть отклонена"; fi

echo "test_generate_manifest.sh: часть 3 (валидация аргументов) OK" >&2

# --- 4: отсутствующий файл в components.txt останавливает генерацию ---
BADCOMP=$TEST_ROOT/components-missing.txt
cat > "$BADCOMP" << EOF
COMPONENT|x|X
FILE|x|no-such-file.sh|/opt/etc/mihomo/no-such-file.sh|0755|sh
EOF
if COMPONENTS="$BADCOMP" sh "$GEN" 1 1 1 >/dev/null 2>&1; then
  fail "отсутствующий исходный файл должен останавливать генерацию"
fi

echo "test_generate_manifest.sh: часть 4 (отсутствующий файл) OK" >&2

# --- 5: неизвестная строка в components.txt останавливает генерацию ---
BADLINE=$TEST_ROOT/components-badline.txt
printf 'COMPONENT|x|X\nWHATEVER|x|y\n' > "$BADLINE"
if COMPONENTS="$BADLINE" sh "$GEN" 1 1 1 >/dev/null 2>&1; then
  fail "нераспознанная строка должна останавливать генерацию"
fi

echo "test_generate_manifest.sh: часть 5 (нераспознанная строка) OK" >&2

# --- 6: самопроверка ловит невалидный манифест (что произведёт декларация с плохим путём) ---
BADPATH=$TEST_ROOT/components-badpath.txt
cat > "$BADPATH" << EOF
COMPONENT|x|X
FILE|x|update.sh|/etc/passwd|0755|sh
EOF
if COMPONENTS="$BADPATH" sh "$GEN" 1 1 1 >/dev/null 2>&1; then
  fail "самопроверка через update_plan.awk должна отклонить запрещённый целевой путь"
fi

echo "test_generate_manifest.sh: часть 6 (самопроверка ловит плохой путь) OK" >&2

# --- 7: каждый файл из ALL_PROJECT_FILES (install.sh) должен быть
#     объявлен хотя бы одной строкой FILE| в components.txt.
#     components.txt независимо поддерживает свой список файлов проекта -
#     ровно так уже дважды забывали добавить сюда новый файл
#     (VERSIONS/version_check.sh при выделении installer/, затем
#     stats_system.sh при добавлении футера), и он молча не попадал в
#     реальный релиз на GitHub, хотя install.sh формально знал о нём.
#     Самый тяжёлый случай - именно stats_system.sh: полный "curl | sh"
#     бутстрап на чистом роутере скачивал релиз и тут же падал с "не
#     найден рядом с install.sh", потому что файла не было в манифесте
#     вообще (см. CHANGELOG).
ALL_FILES=$(INSTALL_LIB_ONLY=1 SELFDIR="$ROOT/installer" sh -c '. "'"$ROOT"'/install.sh"; printf "%s" "$ALL_PROJECT_FILES"')
[ -n "$ALL_FILES" ] || fail "не удалось получить ALL_PROJECT_FILES из install.sh"
for pf in $ALL_FILES; do
  case "$OUT" in
    *"/$pf|"* | *"|$pf|"*) ;;
    *) fail "components.txt: файл '$pf' есть в ALL_PROJECT_FILES (install.sh), но не объявлен ни одной строкой FILE| в release/components.txt" ;;
  esac
done

echo "test_generate_manifest.sh: часть 7 (components.txt покрывает весь ALL_PROJECT_FILES) OK" >&2

echo "test_generate_manifest.sh: OK"
