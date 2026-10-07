#!/bin/sh
# Проверки web/stats_files.py (логика файлового менеджера, без HTTP).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

command -v python3 >/dev/null 2>&1 || {
  echo "test_stats_files.sh: python3 недоступен, пропущено" >&2
  echo "test_stats_files.sh: OK (пропущено)"
  exit 0
}

python3 -I "$ROOT/tests/stats_files_check.py" || {
  echo "FAIL: stats_files_check.py" >&2
  exit 1
}
echo "test_stats_files.sh: OK"
