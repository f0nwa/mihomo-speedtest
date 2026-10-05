#!/bin/sh
# Шаблон config.example.yaml хранится собранным: участки между маркерами
# SERVICE_* - результат render_services.awk из services.default.tsv.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOLS="$ROOT/config-tools"
TEMPLATE="$TOOLS/config.example.yaml"
FIXTURE="$ROOT/tests/fixtures/config.example.pre-constructor.yaml"
FAILED=0
WORK=$(mktemp -d /tmp/svc-sync.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; FAILED=1; }

# test_template_in_sync
if ! awk -v services_file="$TOOLS/services.default.tsv" -f "$TOOLS/render_services.awk" "$TEMPLATE" > "$WORK/rendered.yaml"; then
  fail "сборка шаблона из services.default.tsv завершилась с ошибкой"
elif ! cmp -s "$WORK/rendered.yaml" "$TEMPLATE"; then
  fail "config.example.yaml не совпадает со сборкой - пересоберите шаблон:
  awk -v services_file=config-tools/services.default.tsv -f config-tools/render_services.awk config-tools/config.example.yaml > /tmp/t && cat /tmp/t > config-tools/config.example.yaml"
fi

# test_same_content_as_before: без строк-комментариев и пустых строк
strip() { grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$'; }
strip "$FIXTURE" > "$WORK/before.txt"
strip "$TEMPLATE" > "$WORK/after.txt"
if ! cmp -s "$WORK/before.txt" "$WORK/after.txt"; then
  fail "содержимое шаблона изменилось относительно фикстуры:"
  diff "$WORK/before.txt" "$WORK/after.txt" | head -20 >&2 || true
fi

MARKERS="SERVICE_GROUPS:BEGIN SERVICE_GROUPS:END SERVICE_PROVIDERS:BEGIN SERVICE_PROVIDERS:END SERVICE_RULES:BEGIN SERVICE_RULES:END"

# test_markers_survive_render_config
printf 'https://sub1.example/AAA\tclash.meta\tmyprov\n' > "$WORK/providers.txt"
awk -v providers_file="$WORK/providers.txt" -f "$TOOLS/render_config.awk" "$TEMPLATE" > "$WORK/rc.yaml" || fail "render_config.awk с ошибкой"
for m in $MARKERS; do
  grep -q "# --- $m ---" "$WORK/rc.yaml" || fail "render_config.awk потерял маркер $m"
done

# test_markers_survive_migrate
if sh "$TOOLS/migrate_config.sh" --source "$FIXTURE" --template "$TEMPLATE" \
    --output "$WORK/mig.yaml" --report "$WORK/mig.report" > "$WORK/mig.out" 2>&1; then
  for m in $MARKERS; do
    grep -q "# --- $m ---" "$WORK/mig.yaml" || fail "миграция потеряла маркер $m"
  done
else
  fail "миграция фикстуры на новый шаблон с ошибкой: $(cat "$WORK/mig.out")"
fi

[ "$FAILED" = 0 ] && echo "OK test_services_template_sync"
exit "$FAILED"
