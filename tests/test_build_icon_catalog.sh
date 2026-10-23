#!/bin/sh
# Генератор каталога иконок: формат, ссылки и сохранность готового файла.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d /tmp/test-icon-catalog.XXXXXX)
trap 'rm -rf "$TMP"' EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
FIX=$ROOT/tests/fixtures/icon-catalog
OUT=$TMP/icon-catalog.tsv

python3 "$ROOT/release/build_icon_catalog.py" --fixtures "$FIX" --date 2026-10-23 --output "$OUT"
python3 - "$OUT" <<'PY'
import pathlib, sys
rows = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
assert rows[0] == '# собран: 2026-10-23', rows[0]
expected = [
    ['qure', 'disney+', 'Disney+', 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Disney%2B.png', ''],
    ['qure', 'youtube', 'YouTube', 'https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/YouTube.png', ''],
    ['dashboard', 'chatgpt', 'chatgpt', 'https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@main/png/chatgpt.png', 'OpenAI ChatGPT'],
    ['dashboard', 'netflix', 'netflix', 'https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@main/png/netflix.png', 'Netflix Streaming'],
]
actual = [line.split('\t') for line in rows[1:]]
assert actual == expected, (actual, expected)
assert all(len(row) == 5 for row in actual), actual
PY

printf 'старый каталог\n' > "$OUT"
mkdir "$TMP/bad"
cp "$FIX/qure.json" "$TMP/bad/qure.json"
cp "$FIX/dashboard-metadata.json" "$TMP/bad/dashboard-metadata.json"
if python3 "$ROOT/release/build_icon_catalog.py" --fixtures "$TMP/bad" --output "$OUT" >/dev/null 2>&1; then
  fail "нет ошибки при отсутствии дерева Dashboard"
fi
[ "$(cat "$OUT")" = 'старый каталог' ] || fail "старый каталог испорчен при отсутствии источника"
printf '{bad json' > "$TMP/bad/dashboard-tree.json"
if python3 "$ROOT/release/build_icon_catalog.py" --fixtures "$TMP/bad" --output "$OUT" >/dev/null 2>&1; then
  fail "нет ошибки при битом JSON"
fi
[ "$(cat "$OUT")" = 'старый каталог' ] || fail "старый каталог испорчен при битом JSON"
echo 'OK test_build_icon_catalog'
