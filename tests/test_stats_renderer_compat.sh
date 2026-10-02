#!/bin/sh
set -eu

# Обновление только speedtest-runtime должно оставлять /api/stats валидным
# JSON со старым web. Фикстура: render_stats.awk из коммита
# 8a7c66db4959e6e5757c911739528fcde471ab7a, с заменой длинных тире на дефисы.
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-renderer-compat.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

MST_LIB_ONLY=1 . "$ROOT/speedtest-runtime/speedtest2.sh"
WORK=$TEST_ROOT/work
RUN_LOG=$WORK/run.log
STATS_JSON=$TEST_ROOT/www/stats.json
STATS_HTML=$TEST_ROOT/www/stats.html
LAST=$TEST_ROOT/last.txt
HISTORY_RUNS=$TEST_ROOT/runs.tsv
HISTORY_NODES=$TEST_ROOT/nodes.tsv
HISTORY_STABILITY=$TEST_ROOT/stability.tsv
mkdir -p "$WORK" "$TEST_ROOT/www"
: > "$HISTORY_RUNS"

for RENDER_STATS in "$ROOT/tests/fixtures/render_stats_before_html_removal.awk" "$ROOT/web/render_stats.awk"; do
  printf 'stale' > "$STATS_JSON"
  render_stats
  python3 - "$STATS_JSON" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    data = json.load(source)
assert data['runs']['count'] == 0
assert data['last_run'] is None
assert data['last_measurement'] == []
assert data['node_history']['top'] == []
PY
done
echo 'test_stats_renderer_compat.sh: OK'
