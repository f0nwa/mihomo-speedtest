#!/bin/sh
set -eu
umask 077
DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BASE=$(mktemp -d)
BASE=$(CDPATH= cd -- "$BASE" && pwd -P)
trap 'rm -rf "$BASE"' EXIT HUP INT TERM
TARGET_ROOT=$BASE/root
TMPROOT=$BASE
WORK=$BASE/work
saved=$BASE/saved
MIHOMO_DIR=/opt/etc/mihomo
UPDATE_STATE_DIR=$TARGET_ROOT/opt/etc/mihomo/.update
INSTALLED_MANIFEST_PATH=$UPDATE_STATE_DIR/installed-manifest.txt
MANIFEST_TMP=$WORK/manifest.txt
PLAN_AWK=$DIR/updater/update_plan.awk
UPDATER_VERSION=4
SHA_TOOL=sha256sum
mkdir -p "$WORK" "$saved/files" "$TARGET_ROOT/opt/etc/mihomo" "$TARGET_ROOT/opt/etc/mihomo-speedtest" "$UPDATE_STATE_DIR"
say() { printf '%s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
awk '/^mode_of\(\) \{/ {copy=1} copy {print; if($0=="}") exit}' "$DIR/updater/update.sh" > "$WORK/mode-helper.sh"
. "$WORK/mode-helper.sh"
manifest_field() { awk -F= -v k="$2" '$1==k{print $2;exit}' "$1"; }
safe_path() { p=$1; while [ "$p" != / ]; do [ ! -L "$p" ] || die symlink; p=${p%/*}; [ -n "$p" ] || p=/; done; }
target_file() { printf '%s%s\n' "$TARGET_ROOT" "$1"; }
check_download() { [ "$(wc -c < "$1" | tr -d ' ')" = "$2" ] && [ "$(sha256_of "$1")" = "$3" ] || die hash; }
check_file_syntax() { :; }
check_space() { :; }
sync() { :; }
build_snapshot() { :; }
# config_path() (фактический файл config.yaml, в т.ч. цель ссылки на
# профиль) живёт в update_prepare.sh - берём только её, как mode_of() выше.
awk '/^config_path\(\) \{/ {copy=1} copy {print; if($0=="}") exit}' "$DIR/updater/update_prepare.sh" > "$WORK/config-path-helper.sh"
. "$WORK/config-path-helper.sh"
printf old > "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt"
printf new > "$saved/files/1"
chmod 644 "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt" "$saved/files/1"
sum=$(sha256_of "$saved/files/1")
cat > "$MANIFEST_TMP" <<MANIFEST
FORMAT_VERSION=2
RELEASE_VERSION=2
MIN_UPDATER_VERSION=4
CONFIG_SCHEMA_VERSION=1
RELEASE_TAG=v2
COMPONENT|core|Core
NOTE|core|Core updated
FILE|core|a.txt|/opt/etc/mihomo-speedtest/a.txt|3|$sum|0644|none
MANIFEST
for engine in update.sh update_plan.awk update_prepare.sh update_transaction.sh; do
  case $engine in *.sh) mode=0755; check=sh ;; *) mode=0644; check=awk ;; esac
  printf 'FILE|core|%s|/opt/etc/mihomo-speedtest/%s|%s|%s|%s|%s\n' "$engine" "$engine" "$(wc -c < "$DIR/updater/$engine" | tr -d ' ')" "$(sha256_of "$DIR/updater/$engine")" "$mode" "$check" >> "$MANIFEST_TMP"
done
printf 'COMPONENT|core|selected\nFILE|core|a.txt|/opt/etc/mihomo-speedtest/a.txt|3|%s|0644|none\n' "$sum" > "$WORK/records"
printf snapshot > "$WORK/snapshot.tsv"
plan_id=abc
# transaction_apply() (в сорсимом update_transaction.sh) снимает копию
# ТЕКУЩЕГО (якобы уже установленного) движка из "$DIR/$tx_engine" - на
# роутере $DIR всегда плоский (см. Глобальные ограничения плана
# реорганизации репозитория), в отличие от исходников репозитория выше по
# файлу. Подменяем $DIR на плоскую копию только на время sourcing/вызова,
# не трогая update_transaction.sh - переменная репозиторного корня выше
# по файлу (для сборки манифеста) уже отработала до этой строки.
REPO_DIR=$DIR
DIR=$(mktemp -d)
cp -p "$REPO_DIR/updater/update.sh" "$REPO_DIR/updater/update_plan.awk" \
   "$REPO_DIR/updater/update_prepare.sh" "$REPO_DIR/updater/update_transaction.sh" "$DIR/"
# Режимы как в манифесте (0755/0644), а не как в рабочем дереве: на
# некоторых дисках (сетевые, exFAT) файлы видны с правами 700/600.
chmod 755 "$DIR/update.sh" "$DIR/update_prepare.sh" "$DIR/update_transaction.sh"
chmod 644 "$DIR/update_plan.awk"
. "$REPO_DIR/updater/update_transaction.sh"
transaction_apply
[ "$(cat "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt")" = new ]
[ -d "$UPDATE_STATE_DIR/rollback" ]
[ ! -e "$UPDATE_STATE_DIR/transaction.txt" ]
transaction_rollback
[ "$(cat "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt")" = old ]
[ ! -e "$INSTALLED_MANIFEST_PATH" ]
echo 'PASS transaction core apply and rollback'
# Ошибка публикации после начала операции должна восстановить весь план.
reset_ram() { rm -rf "$WORK/tx-bundle" "$WORK/tx-files"; }
reset_ram
cp() {
  for cp_arg do cp_last=$cp_arg; done
  case $cp_last in */a.txt.mst-update-new)
    if [ ! -f "$BASE/cp-failed" ]; then : > "$BASE/cp-failed"; return 1; fi ;;
  esac
  command cp "$@"
}
rc=0
transaction_apply 2> "$BASE/failure.err" || rc=$?
[ "$rc" = 1 ]
[ "$(cat "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt")" = old ]
[ ! -e "$UPDATE_STATE_DIR/transaction.txt" ]
unset -f cp
echo 'PASS publication failure rolls back'
# Искусственная остановка в APPLY_PENDING: recover без сети.
command cp -pR "$UPDATE_STATE_DIR/rollback" "$UPDATE_STATE_DIR/rollback.pending"
printf new > "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt"
printf 'APPLY_PENDING\n' > "$UPDATE_STATE_DIR/transaction.txt"
transaction_recover
[ "$(cat "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt")" = old ]
[ ! -e "$UPDATE_STATE_DIR/transaction.txt" ]
echo 'PASS offline interrupted recovery'
# Повреждённый backup не должен разрешать ни первую запись, ни cleanup журнала.
command cp -pR "$UPDATE_STATE_DIR/rollback" "$UPDATE_STATE_DIR/rollback.pending"
# cp-R отделяет inode, не повреждая rollback оригинала.
printf corrupt > "$UPDATE_STATE_DIR/rollback.pending/backups/1"
printf 'APPLY_PENDING\n' > "$UPDATE_STATE_DIR/transaction.txt"
printf current > "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt"
rc=0
transaction_recover 2> "$BASE/corrupt.err" || rc=$?
[ "$rc" = 2 ]
[ "$(cat "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt")" = current ]
[ -f "$UPDATE_STATE_DIR/transaction.txt" ]
rm -rf "$UPDATE_STATE_DIR/rollback.pending"
rm "$UPDATE_STATE_DIR/transaction.txt"
echo 'PASS corrupt backup refuses recovery before writes'
# COMMIT после rename previous восстанавливается детерминированно.
command cp -pR "$UPDATE_STATE_DIR/rollback" "$UPDATE_STATE_DIR/rollback.pending"
mv "$UPDATE_STATE_DIR/rollback" "$UPDATE_STATE_DIR/rollback.previous"
printf 'COMMIT\n' > "$UPDATE_STATE_DIR/transaction.txt"
transaction_recover
[ -d "$UPDATE_STATE_DIR/rollback" ]
[ ! -e "$UPDATE_STATE_DIR/rollback.previous" ]
[ ! -e "$UPDATE_STATE_DIR/rollback.pending" ]
[ ! -e "$UPDATE_STATE_DIR/transaction.txt" ]
echo 'PASS interrupted commit promotion'
mkdir "$UPDATE_STATE_DIR/rollback.pending"
printf partial > "$UPDATE_STATE_DIR/rollback.pending/list.txt"
printf 'CLEANUP_PENDING\n' > "$UPDATE_STATE_DIR/transaction.txt"
transaction_recover
[ ! -e "$UPDATE_STATE_DIR/rollback.pending" ]
[ ! -e "$UPDATE_STATE_DIR/transaction.txt" ]
echo 'PASS interrupted rollback cleanup'
# Таймаут init не становится успехом и завершает потомка, игнорирующего TERM.
mkdir -p "$TARGET_ROOT/opt/etc/init.d"
ACTION_CHILD_PID=$BASE/init-child.pid
export ACTION_CHILD_PID
cat > "$TARGET_ROOT/opt/etc/init.d/S80speedtest-stats" <<'INIT'
#!/bin/sh
case $1 in
  restart)
    trap 'exit 0' TERM
    (trap '' TERM; while :; do sleep 1; done) &
    echo $! > "$ACTION_CHILD_PID"
    wait ;;
  check) exit 0 ;;
esac
INIT
UPDATE_ACTION_TIMEOUT=1
before=$(date +%s)
rc=0
tx_bounded_action restart || rc=$?
after=$(date +%s)
[ "$rc" != 0 ]
[ "$((after-before))" -le 5 ]
[ ! -e "$WORK/tx-action-children" ]
init_child=$(cat "$ACTION_CHILD_PID")
! kill -0 "$init_child" 2>/dev/null
echo 'PASS bounded init action timeout'
# Ошибка собственно восстановления отличается кодом 2 и сохраняет журнал.
command cp -pR "$UPDATE_STATE_DIR/rollback" "$UPDATE_STATE_DIR/rollback.pending"
printf changed > "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt"
printf 'APPLY_PENDING\n' > "$UPDATE_STATE_DIR/transaction.txt"
cp() {
  for cp_arg do cp_last=$cp_arg; done
  case $cp_last in *.mst-update-new) return 1 ;; esac
  command cp "$@"
}
rc=0
transaction_recover || rc=$?
[ "$rc" = 2 ]
[ -f "$UPDATE_STATE_DIR/transaction.txt" ]
unset -f cp
transaction_recover
[ "$(cat "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt")" = old ]
echo 'PASS rollback failure retains journal and can retry'
# Общее действие вызывается один раз и использует штатные restart/check.
ACTION_LOG=$BASE/actions.log
export ACTION_LOG
cat > "$TARGET_ROOT/opt/etc/init.d/S80speedtest-stats" <<'INIT'
#!/bin/sh
printf '%s\n' "$1" >> "$ACTION_LOG"
case $1 in restart|check) exit 0 ;; *) exit 1 ;; esac
INIT
mkdir "$BASE/action-bundle"
printf 'restart-web\n' > "$BASE/action-bundle/actions.txt"
tx_actions "$BASE/action-bundle"
[ "$(cat "$ACTION_LOG")" = "$(printf 'restart\ncheck')" ]
echo 'PASS one shared restart and native check'
# Сигнал сразу после атомарной публикации APPLY_PENDING ещё до tx_active=1.
reset_ram
mkdir "$BASE/signal-bin"
REAL_MV=$(command -v mv)
SIGNAL_MARKER=$BASE/signal-sent
export REAL_MV SIGNAL_MARKER
cat > "$BASE/signal-bin/mv" <<'MV'
#!/bin/sh
"$REAL_MV" "$@" || exit $?
for arg do last=$arg; done
case $last in */transaction.txt)
  if [ ! -f "$SIGNAL_MARKER" ]; then
    : > "$SIGNAL_MARKER"
    kill -TERM "$PPID"
  fi ;;
esac
MV
chmod +x "$BASE/signal-bin/mv"
oldpath=$PATH
PATH=$BASE/signal-bin:$PATH
export PATH
rc=0
transaction_apply 2> "$BASE/signal.err" || rc=$?
PATH=$oldpath
export PATH
[ "$rc" = 1 ]
[ "$(cat "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt")" = old ]
[ ! -e "$UPDATE_STATE_DIR/transaction.txt" ]
[ ! -e "$UPDATE_STATE_DIR/rollback.pending" ]
echo 'PASS signal immediately after journal rename'
# Первая установка службы не запускается, пока протокол rollback/stop
# новой службы не реализован: отказ раньше постоянных записей.
reset_ram
rm "$TARGET_ROOT/opt/etc/init.d/S80speedtest-stats"
command cp "$WORK/records" "$BASE/base-records"
command cp "$MANIFEST_TMP" "$BASE/base-manifest"
command cp "$saved/files/1" "$saved/files/2"
chmod 0644 "$saved/files/2"
printf 'FILE|core|stats_new.py|/opt/etc/mihomo-speedtest/stats_new.py|3|%s|0644|none\nACTION|restart-web\n' "$sum" >> "$WORK/records"
printf 'FILE|core|stats_new.py|/opt/etc/mihomo-speedtest/stats_new.py|3|%s|0644|none\nACTION|core|restart-web\n' "$sum" >> "$MANIFEST_TMP"
rc=0
transaction_apply 2> "$BASE/first-web.err" || rc=$?
[ "$rc" = 1 ]
[ ! -e "$TARGET_ROOT/opt/etc/mihomo-speedtest/stats_new.py" ]
[ ! -e "$UPDATE_STATE_DIR/rollback.pending" ]
[ ! -e "$UPDATE_STATE_DIR/transaction.txt" ]
command cp "$BASE/base-records" "$WORK/records"
command cp "$BASE/base-manifest" "$MANIFEST_TMP"
echo 'PASS first web installation rejects before writes'
# Пользовательский путь STATE не может перекрывать payload либо его staging.
normal_installed=$INSTALLED_MANIFEST_PATH
for collision in "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt" "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt.mst-update-new"; do
  reset_ram
  INSTALLED_MANIFEST_PATH=$collision
  rc=0
  transaction_apply 2> "$BASE/collision.err" || rc=$?
  [ "$rc" = 1 ]
  [ "$(cat "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt")" = old ]
  [ ! -e "$UPDATE_STATE_DIR/rollback.pending" ]
  [ ! -e "$UPDATE_STATE_DIR/transaction.txt" ]
done
INSTALLED_MANIFEST_PATH=$normal_installed
echo 'PASS state path collisions reject before writes'
# Ошибка flush до публикации APPLY_PENDING не разрешает замену payload.
reset_ram
sync() { return 1; }
rc=0
transaction_apply 2> "$BASE/sync.err" || rc=$?
[ "$rc" = 1 ]
[ "$(cat "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt")" = old ]
[ ! -e "$UPDATE_STATE_DIR/rollback.pending" ]
[ ! -e "$UPDATE_STATE_DIR/transaction.txt" ]
sync() { :; }
echo 'PASS sync failure rejects target mutation'
# Смесь нового выбранного и старого пропущенного компонента должна проверять
# CONFLICT для всех реально установленных компонентов до первой записи.
reset_ram
printf old > "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt"
oldsum=$(sha256_of "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt")
cat > "$INSTALLED_MANIFEST_PATH" <<OLD
FORMAT_VERSION=2
RELEASE_VERSION=1
MIN_UPDATER_VERSION=4
CONFIG_SCHEMA_VERSION=1
RELEASE_TAG=v1
COMPONENT|core|Core
NOTE|core|Old core
FILE|core|a.txt|/opt/etc/mihomo-speedtest/a.txt|3|$oldsum|0644|none
COMPONENT|other|Other
NOTE|other|Old other
FILE|other|b.txt|/opt/etc/mihomo-speedtest/b.txt|3|$oldsum|0644|none
OLD
cat >> "$MANIFEST_TMP" <<NEW
COMPONENT|other|Other
NOTE|other|New other
FILE|other|b.txt|/opt/etc/mihomo-speedtest/b.txt|3|$sum|0644|none
CONFLICT|other|core
NEW
rc=0
transaction_apply 2> "$BASE/conflict.err" || rc=$?
[ "$rc" = 1 ]
[ "$(cat "$TARGET_ROOT/opt/etc/mihomo-speedtest/a.txt")" = old ]
[ ! -e "$UPDATE_STATE_DIR/transaction.txt" ]
echo 'PASS installed mixture conflict rejects before writes'
