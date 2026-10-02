#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
AWK_SCRIPT=$ROOT/updater/update_plan.awk
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/update-plan-test.XXXXXX")
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

run_plan() {
  # $1=manifest $2=selected $3=format $4=localstate(может быть пусто) $5=installed(может быть пусто)
  awk -v MANIFEST="$1" -v SELECTED="$2" -v FORMAT="$3" -v LOCALSTATE="${4:-}" -v INSTALLED="${5:-}" -f "$AWK_SCRIPT"
}

SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHA_C=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00
SHA_OLD=1111111111111111111111111111111111111111111111111111111111111111
SHA_EDIT=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef

BASE=$TEST_ROOT/manifest.txt
cat > "$BASE" << EOF
FORMAT_VERSION=2
RELEASE_VERSION=1
RELEASE_TAG=v1
MIN_UPDATER_VERSION=1
CONFIG_SCHEMA_VERSION=1
COMPONENT|updater|Обновлятор
NOTE|updater|Заметка updater
COMPONENT|speedtest-runtime|Ядро спидтеста
NOTE|speedtest-runtime|Заметка speedtest-runtime
COMPONENT|web|Веб-интерфейс статистики
NOTE|web|Заметка web
DEPENDS|web|speedtest-runtime
FILE|updater|update.sh|/opt/etc/mihomo-speedtest/update.sh|1234|$SHA_A|0755|sh
FILE|speedtest-runtime|speedtest2.sh|/opt/etc/mihomo-speedtest/speedtest2.sh|2345|$SHA_B|0755|sh
FILE|web|stats_httpd.py|/opt/etc/mihomo-speedtest/stats_httpd.py|3456|$SHA_C|0644|py
ACTION|web|restart-web
ACTION|speedtest-runtime|restart-mihomo
EOF

# --- 1: строгий разбор корректного манифеста, автоподключение зависимости ---
OUT=$(run_plan "$BASE" web text)
assert_contains "speedtest-runtime (Ядро спидтеста) - добавлен как обязательная зависимость" "$OUT" "автовключение зависимости"
assert_contains "web (Веб-интерфейс статистики)" "$OUT" "выбранный компонент присутствует в плане"
assert_contains "restart-web restart-mihomo" "$OUT" "действия обоих компонентов объединены"

echo "test_update_plan.sh: часть 1 (разбор, зависимости) OK" >&2

# --- 2: без LOCALSTATE/INSTALLED все выбранные файлы отсутствуют ---
assert_contains "/opt/etc/mihomo-speedtest/stats_httpd.py [web]: отсутствует" "$OUT" "нет localstate - файл отсутствует"

# --- 3: LOCALSTATE без INSTALLED - только "актуален" или общее "отличается" ---
LOCAL1=$TEST_ROOT/local1.tsv
printf '/opt/etc/mihomo-speedtest/speedtest2.sh\t%s\n/opt/etc/mihomo-speedtest/stats_httpd.py\t%s\n' "$SHA_B" "$SHA_EDIT" > "$LOCAL1"
OUT=$(run_plan "$BASE" web text "$LOCAL1")
assert_contains "/opt/etc/mihomo-speedtest/speedtest2.sh [speedtest-runtime]: актуален" "$OUT" "sha совпадает с релизом - актуален"
assert_contains "/opt/etc/mihomo-speedtest/stats_httpd.py [web]: отличается (нет базового манифеста для точного диагноза)" "$OUT" "нет INSTALLED - общий диагноз, не 'локально изменён'"

echo "test_update_plan.sh: часть 2 (состояния без INSTALLED) OK" >&2

# --- 4: с INSTALLED - полные 5 состояний (новая версия vs локально изменён) ---
INSTALLED=$TEST_ROOT/installed.txt
printf 'FILE|speedtest-runtime|speedtest2.sh|/opt/etc/mihomo-speedtest/speedtest2.sh|100|%s|0755|sh\nFILE|web|stats_httpd.py|/opt/etc/mihomo-speedtest/stats_httpd.py|100|%s|0644|py\n' "$SHA_OLD" "$SHA_OLD" > "$INSTALLED"
LOCAL2=$TEST_ROOT/local2.tsv
printf '/opt/etc/mihomo-speedtest/speedtest2.sh\t%s\n/opt/etc/mihomo-speedtest/stats_httpd.py\t%s\n' "$SHA_OLD" "$SHA_EDIT" > "$LOCAL2"
OUT=$(run_plan "$BASE" web text "$LOCAL2" "$INSTALLED")
assert_contains "/opt/etc/mihomo-speedtest/speedtest2.sh [speedtest-runtime]: доступна новая версия" "$OUT" "не менялся, отличается от релиза - новая версия"
assert_contains "/opt/etc/mihomo-speedtest/stats_httpd.py [web]: локально изменён" "$OUT" "отличается и от релиза, и от installed - локально изменён"

echo "test_update_plan.sh: часть 3 (состояния с INSTALLED) OK" >&2

# --- 5: цикл зависимостей ---
CYCLIC=$TEST_ROOT/cyclic.txt
cat > "$CYCLIC" << EOF
FORMAT_VERSION=2
RELEASE_VERSION=1
RELEASE_TAG=v1
MIN_UPDATER_VERSION=1
CONFIG_SCHEMA_VERSION=1
COMPONENT|a|A
NOTE|a|Заметка a
COMPONENT|b|B
NOTE|b|Заметка b
DEPENDS|a|b
DEPENDS|b|a
EOF
if run_plan "$CYCLIC" a text >/dev/null 2>&1; then
  fail "цикл зависимостей должен быть отклонён"
fi

echo "test_update_plan.sh: часть 4 (цикл зависимостей) OK" >&2

# --- 6: запрещённые пути и назначения ---
for bad in \
  'FILE|x|f|/opt/etc/mihomo-speedtest/../../etc/passwd|10|'"$SHA_A"'|0644|sh' \
  'FILE|x|f|/etc/passwd|10|'"$SHA_A"'|0644|sh' \
  'FILE|x|f|relative/path|10|'"$SHA_A"'|0644|sh'
do
  BADF=$TEST_ROOT/bad.txt
  printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|X\n%s\n' "$bad" > "$BADF"
  if run_plan "$BADF" x text >/dev/null 2>&1; then
    fail "должен быть отклонён небезопасный путь: $bad"
  fi
done

echo "test_update_plan.sh: часть 5 (запрещённые пути) OK" >&2

# --- 7: дублирующееся назначение отклоняется ---
DUPF=$TEST_ROOT/dup.txt
cat > "$DUPF" << EOF
FORMAT_VERSION=2
RELEASE_VERSION=1
RELEASE_TAG=v1
MIN_UPDATER_VERSION=1
CONFIG_SCHEMA_VERSION=1
COMPONENT|x|X
NOTE|x|Заметка x
COMPONENT|y|Y
NOTE|y|Заметка y
FILE|x|a|/opt/etc/mihomo-speedtest/f|10|$SHA_A|0644|sh
FILE|y|b|/opt/etc/mihomo-speedtest/f|10|$SHA_B|0644|sh
EOF
if run_plan "$DUPF" x,y text >/dev/null 2>&1; then
  fail "дублирующееся назначение должно быть отклонено"
fi

echo "test_update_plan.sh: часть 6 (дублирующееся назначение) OK" >&2

# --- 8: неизвестное действие и неизвестный тип проверки отклоняются ---
BADACT=$TEST_ROOT/badact.txt
printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|X\nACTION|x|rm-rf\n' > "$BADACT"
if run_plan "$BADACT" x text >/dev/null 2>&1; then
  fail "неизвестное действие должно быть отклонено"
fi
BADCHK=$TEST_ROOT/badchk.txt
printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|X\nFILE|x|f|/opt/etc/mihomo-speedtest/f|10|%s|0644|weird\n' "$SHA_A" > "$BADCHK"
if run_plan "$BADCHK" x text >/dev/null 2>&1; then
  fail "неизвестный тип проверки должен быть отклонён"
fi

echo "test_update_plan.sh: часть 7 (неизвестное действие/проверка) OK" >&2

# --- 9: неверный размер/sha256/режим отклоняются ---
for field_bad in \
  'FILE|x|f|/opt/etc/mihomo-speedtest/f|abc|'"$SHA_A"'|0644|sh' \
  'FILE|x|f|/opt/etc/mihomo-speedtest/f|10|tooshort|0644|sh' \
  'FILE|x|f|/opt/etc/mihomo-speedtest/f|10|'"$SHA_A"'|9999|sh'
do
  BADFIELD=$TEST_ROOT/badfield.txt
  printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|X\n%s\n' "$field_bad" > "$BADFIELD"
  if run_plan "$BADFIELD" x text >/dev/null 2>&1; then
    fail "должно быть отклонено поле: $field_bad"
  fi
done

echo "test_update_plan.sh: часть 8 (неверные size/sha256/режим) OK" >&2

# --- 10: JSON валиден и содержит все компоненты/файлы/действия ---
OUT_JSON=$(run_plan "$BASE" web json "$LOCAL1")
command -v python3 >/dev/null 2>&1 && python3 - "$OUT_JSON" << 'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
assert d["release_version"] == "1"
assert {c["id"] for c in d["components"]} == {"web", "speedtest-runtime"}
assert len(d["files"]) == 2
assert set(d["actions"]) == {"restart-web", "restart-mihomo"}
print("json ok", file=sys.stderr)
PYEOF

echo "test_update_plan.sh: часть 9 (JSON) OK" >&2

# --- 11: экранирование спецсимволов в JSON (кавычки, обратный слэш) ---
ESCF=$TEST_ROOT/esc.txt
printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|Компонент "X" с \\ обратным слэшем\n' > "$ESCF"
OUT_ESC=$(run_plan "$ESCF" x json)
command -v python3 >/dev/null 2>&1 && python3 - "$OUT_ESC" << 'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
assert d["components"][0]["title"] == 'Компонент "X" с \\ обратным слэшем'
print("json escape ok", file=sys.stderr)
PYEOF

echo "test_update_plan.sh: часть 10 (экранирование JSON) OK" >&2

# --- 12: неизвестный SELECTED-компонент отклоняется ---
if run_plan "$BASE" no-such-component text >/dev/null 2>&1; then
  fail "выбор неизвестного компонента должен быть отклонён"
fi

echo "test_update_plan.sh: часть 11 (неизвестный выбранный компонент) OK" >&2

# --- 13: src - запрещены абсолютный путь, ".." и пустое значение ---
for bad_src in '/abs/path' 'sub/../evil' ''; do
  BADSRC=$TEST_ROOT/badsrc.txt
  printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|X\nFILE|x|%s|/opt/etc/mihomo-speedtest/f|10|%s|0644|sh\n' "$bad_src" "$SHA_A" > "$BADSRC"
  if run_plan "$BADSRC" x text >/dev/null 2>&1; then
    fail "должен быть отклонён небезопасный src: '$bad_src'"
  fi
done

echo "test_update_plan.sh: часть 12 (запрещённый src) OK" >&2

# --- 14: dest - пустой сегмент "//", сегмент ".", завершающий "/" ---
for bad_dest in '/opt/etc/mihomo-speedtest//f' '/opt/etc/mihomo-speedtest/./f' '/opt/etc/mihomo-speedtest/dir/'; do
  BADDEST=$TEST_ROOT/baddest.txt
  printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|X\nFILE|x|f|%s|10|%s|0644|sh\n' "$bad_dest" "$SHA_A" > "$BADDEST"
  if run_plan "$BADDEST" x text >/dev/null 2>&1; then
    fail "должен быть отклонён некорректный dest: '$bad_dest'"
  fi
done

echo "test_update_plan.sh: часть 13 (нормализация dest) OK" >&2

# --- 15: config.yaml не может быть файлом релиза ---
CFGF=$TEST_ROOT/cfg.txt
printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|X\nFILE|x|f|/opt/etc/mihomo/config.yaml|10|%s|0644|sh\n' "$SHA_A" > "$CFGF"
if run_plan "$CFGF" x text >/dev/null 2>&1; then
  fail "config.yaml не должен приниматься как файл релиза"
fi

echo "test_update_plan.sh: часть 14 (config.yaml защищён) OK" >&2

# --- 16: служебный каталог /opt/etc/mihomo-speedtest/.update/ не может быть перезаписан релизом ---
UPDF=$TEST_ROOT/updatedir.txt
printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|X\nFILE|x|f|/opt/etc/mihomo-speedtest/.update/state|10|%s|0644|sh\n' "$SHA_A" > "$UPDF"
if run_plan "$UPDF" x text >/dev/null 2>&1; then
  fail "/opt/etc/mihomo-speedtest/.update/ не должен приниматься как целевой каталог"
fi

echo "test_update_plan.sh: часть 15 (.update/ защищён) OK" >&2

# --- 17: /opt/etc/init.d/ - только явный allowlist (S80speedtest-stats разрешён, остальное - нет) ---
INITBAD=$TEST_ROOT/initbad.txt
printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|X\nFILE|x|f|/opt/etc/init.d/S01evil|10|%s|0755|sh\n' "$SHA_A" > "$INITBAD"
if run_plan "$INITBAD" x text >/dev/null 2>&1; then
  fail "/opt/etc/init.d/S01evil не входит в allowlist и должен быть отклонён"
fi

INITOK=$TEST_ROOT/initok.txt
printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|X\nFILE|x|f|/opt/etc/init.d/S80speedtest-stats|10|%s|0755|sh\n' "$SHA_A" > "$INITOK"
OUT=$(run_plan "$INITOK" x text)
assert_contains "/opt/etc/init.d/S80speedtest-stats [x]: отсутствует" "$OUT" "разрешённый служебный путь принят"

echo "test_update_plan.sh: часть 16 (allowlist /opt/etc/init.d/) OK" >&2

# --- 18: версии заголовка манифеста должны быть целыми числами ---
for bad_header in \
  'FORMAT_VERSION=abc' \
  'FORMAT_VERSION=2;x'
do
  BADHDR=$TEST_ROOT/badhdr.txt
  printf '%s\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nCOMPONENT|x|X\nNOTE|x|Заметка x\n' "$bad_header" > "$BADHDR"
  if run_plan "$BADHDR" x text >/dev/null 2>&1; then
    fail "нечисловая версия заголовка должна быть отклонена: $bad_header"
  fi
done

# Формат 1 (локальный прототип) больше не поддерживается - даже с полным
# набором метаданных формата 2 он отклоняется целиком.
FMT1=$TEST_ROOT/fmt1.txt
printf 'FORMAT_VERSION=1\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nCOMPONENT|x|X\nNOTE|x|Заметка x\n' > "$FMT1"
if ERR_FMT1=$(run_plan "$FMT1" x text 2>&1 >/dev/null); then
  fail "манифест формата 1 должен быть отклонён"
fi
assert_contains "Неподдерживаемый FORMAT_VERSION: 1" "$ERR_FMT1" "формат 1 отклоняется явной ошибкой"

echo "test_update_plan.sh: часть 17 (валидация версий заголовка) OK" >&2

# --- 19: 5-е состояние "removed" - файл, управлявшийся installed-манифестом, но
#          отсутствующий в новом релизе, помечается как удаляемый ---
REMBASE=$TEST_ROOT/rem_base.txt
cat > "$REMBASE" << EOF
FORMAT_VERSION=2
RELEASE_VERSION=2
RELEASE_TAG=v2
MIN_UPDATER_VERSION=1
CONFIG_SCHEMA_VERSION=1
COMPONENT|web|Веб-интерфейс статистики
NOTE|web|Заметка web
FILE|web|stats_httpd.py|/opt/etc/mihomo-speedtest/stats_httpd.py|3456|$SHA_C|0644|py
EOF
REMINSTALLED=$TEST_ROOT/rem_installed.txt
printf 'FILE|web|stats_httpd.py|/opt/etc/mihomo-speedtest/stats_httpd.py|100|%s|0644|py\nFILE|web|helper.sh|/opt/etc/mihomo-speedtest/helper.sh|100|%s|0755|sh\n' "$SHA_OLD" "$SHA_OLD" > "$REMINSTALLED"
OUT=$(run_plan "$REMBASE" web text "" "$REMINSTALLED")
assert_contains "/opt/etc/mihomo-speedtest/helper.sh [web]: больше не используется новым релизом (можно удалить)" "$OUT" "removed в text-выводе"

OUT_JSON=$(run_plan "$REMBASE" web json "" "$REMINSTALLED")
command -v python3 >/dev/null 2>&1 && python3 - "$OUT_JSON" << 'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
removed = [f for f in d["files"] if f["dest"] == "/opt/etc/mihomo-speedtest/helper.sh"]
assert len(removed) == 1, removed
assert removed[0]["state"] == "removed"
assert removed[0]["component"] == "web"
print("removed state ok", file=sys.stderr)
PYEOF

echo "test_update_plan.sh: часть 18 (состояние removed) OK" >&2

# --- 20: \r в текстовом поле манифеста не ломает валидность JSON ---
CRF=$TEST_ROOT/cr.txt
printf 'FORMAT_VERSION=2\nRELEASE_VERSION=1\nRELEASE_TAG=v1\nMIN_UPDATER_VERSION=1\nCONFIG_SCHEMA_VERSION=1\nNOTE|x|Заметка x\nCOMPONENT|x|Заголовок\rсо вставкой CR\n' > "$CRF"
OUT_CR=$(run_plan "$CRF" x json)
command -v python3 >/dev/null 2>&1 && python3 - "$OUT_CR" << 'PYEOF'
import json, sys
json.loads(sys.argv[1])
print("cr escape ok", file=sys.stderr)
PYEOF

echo "test_update_plan.sh: часть 19 (экранирование carriage-return в JSON) OK" >&2

echo "test_update_plan.sh: OK"
