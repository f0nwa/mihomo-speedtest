#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import pathlib, subprocess, tempfile, os, unittest, time, shutil
ROOT=pathlib.Path(__import__('sys').argv[1])
class Core(unittest.TestCase):
 def runsh(self,body,env=None):
  with tempfile.TemporaryDirectory() as d:
   e=dict(os.environ,ROOT=str(ROOT),WORK=d,TARGET_ROOT=d,UPDATE_STATE_DIR=d+'/state',INSTALLED_MANIFEST_PATH=d+'/state/installed',UPDATER_VERSION='6',MIHOMO_DIR='/opt/etc/mihomo',PYTHON_EXE=__import__('sys').executable);e.update(env or {})
   return subprocess.run(['sh','-c','target_file(){ printf "%s%s" "$TARGET_ROOT" "$1"; }; safe_path(){ :; }; die(){ printf "ERROR: %s\\n" "$*" >&2; exit 1; }; . "$ROOT/updater/update_prepare.sh"; . "$ROOT/updater/update_transaction.sh"; '+body],env=e,capture_output=True,text=True)
 def test_typed_paths(self):
  r=self.runsh('tx_record_destination CONFIG active-config; tx_record_destination SCHEMA config-schema-version; tx_record_destination HASH config-sha256; ! tx_record_destination CONFIG evil')
  self.assertEqual(r.returncode,0,r.stderr);self.assertIn('/opt/etc/mihomo/config.yaml',r.stdout)
 def test_restart_and_health(self):
  r=self.runsh('mkdir "$WORK/b"; printf "restart-mihomo\\n" > "$WORK/b/actions.txt"; tx_actions "$WORK/b"',dict(UPDATE_XKEEN_BIN=shutil.which('true'),UPDATE_HEALTH_CMD=shutil.which('true')))
  self.assertEqual(r.returncode,0,r.stderr)
 def test_health_parser_keeps_token_out_of_output(self):
  r=self.runsh("printf 'external-controller: 0.0.0.0:9090\\nsecret: \"private-token\"\\n' > \"$WORK/config\"; tx_health_config \"$WORK/config\"; grep -q '127.0.0.1:9090/version' \"$WORK/tx-curl-config\"; \"$PYTHON_EXE\" -c 'import os,sys;sys.exit((os.stat(sys.argv[1]).st_mode & 0o777) != 0o600)' \"$WORK/tx-curl-config\"")
  self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('private-token',r.stdout+r.stderr)
 def test_health_parser_rejects_remote_endpoint(self):
  r=self.runsh("printf 'external-controller: remote.example:9090\\n' > \"$WORK/config\"; tx_health_config \"$WORK/config\"")
  self.assertNotEqual(r.returncode,0)
 def test_health_parser_rejects_ambiguous_single_quote(self):
  r=self.runsh("printf \"external-controller: 127.0.0.1:9090\\nsecret: 'foo''bar'\\n\" > \"$WORK/config\"; tx_health_config \"$WORK/config\"")
  self.assertNotEqual(r.returncode,0)
 def test_default_health_rejects_invalid_timeout(self):
  r=self.runsh('tx_mihomo_health',dict(UPDATE_HEALTH_TIMEOUT='bad'))
  self.assertNotEqual(r.returncode,0)
 def test_default_health_waits_for_controller_readiness(self):
  r=self.runsh("mkdir -p \"$WORK/bin\" \"$TARGET_ROOT/opt/etc/mihomo\"; printf 'external-controller: 127.0.0.1:9090\\n' > \"$TARGET_ROOT/opt/etc/mihomo/config.yaml\"; printf '#!/bin/sh\\nexit 0\\n' > \"$WORK/bin/pidof\"; printf '#!/bin/sh\\nif [ ! -e \"$WORK/ready\" ]; then touch \"$WORK/ready\"; exit 1; fi\\nexit 0\\n' > \"$WORK/bin/curl\"; chmod +x \"$WORK/bin/pidof\" \"$WORK/bin/curl\"; PATH=\"$WORK/bin:$PATH\"; tx_mihomo_health",dict(UPDATE_HEALTH_TIMEOUT='3'))
  self.assertEqual(r.returncode,0,r.stderr)
 def test_restart_timeout_stops_descendant(self):
  r=self.runsh("printf '#!/bin/sh\\nsleep 20 &\\necho $! > \"$WORK/childpid\"\\nwait\\n' > \"$WORK/restart\"; chmod +x \"$WORK/restart\"; tx_bounded_command 1 \"$WORK/restart\"; test $? -ne 0 || exit 1; child=$(cat \"$WORK/childpid\"); ! kill -0 \"$child\" 2>/dev/null")
  self.assertEqual(r.returncode,0,r.stderr)
 def test_restart_timeout_kills_term_ignoring_descendant(self):
  r=self.runsh("printf '%s\\n' '#!/bin/sh' \"trap 'exit 0' TERM\" 'trap \"\" TERM; while :; do sleep 1; done & echo $! > \"$WORK/childpid\"' 'wait' > \"$WORK/restart\"; chmod +x \"$WORK/restart\"; tx_bounded_command 1 \"$WORK/restart\"; rc=$?; child=$(cat \"$WORK/childpid\"); kill -0 \"$child\" 2>/dev/null && exit 1; [ \"$rc\" -ne 0 ]")
  self.assertEqual(r.returncode,0,r.stderr)
 def test_default_health_disables_curlrc_and_proxy(self):
  r=self.runsh("mkdir -p \"$WORK/bin\" \"$TARGET_ROOT/opt/etc/mihomo\"; printf 'external-controller: 127.0.0.1:9090\\n' > \"$TARGET_ROOT/opt/etc/mihomo/config.yaml\"; printf '#!/bin/sh\\nexit 0\\n' > \"$WORK/bin/pidof\"; printf '#!/bin/sh\\n[ \"$1\" = -q ] || exit 1\\ngrep -q \"noproxy = \\\"\\\\*\\\"\"\\n' > \"$WORK/bin/curl\"; chmod +x \"$WORK/bin/pidof\" \"$WORK/bin/curl\"; PATH=\"$WORK/bin:$PATH\"; tx_default_health")
  self.assertEqual(r.returncode,0,r.stderr)
 def test_restart_timeout_cannot_be_hidden_by_term_success(self):
  r=self.runsh("printf '%s\\n' '#!/bin/sh' \"trap 'exit 0' TERM\" 'while :; do :; done' > \"$WORK/restart\"; chmod +x \"$WORK/restart\"; tx_bounded_command 1 \"$WORK/restart\"")
  self.assertNotEqual(r.returncode,0)
 def test_default_health_timeout_cannot_be_hidden_by_term_success(self):
  r=self.runsh('tx_default_health(){ trap "exit 0" TERM; while :; do :; done; }; tx_mihomo_health',dict(UPDATE_HEALTH_TIMEOUT='1'))
  self.assertNotEqual(r.returncode,0)
 def test_cancellation_does_not_wait_for_term_ignoring_command(self):
  start=time.monotonic()
  r=self.runsh("printf '#!/bin/sh\\ntrap \"\" TERM\\nwhile :; do :; done\\n' > \"$WORK/restart\"; chmod +x \"$WORK/restart\"; tx_bounded_command 10 \"$WORK/restart\" & worker=$!; sleep 1; tx_cancel_action_children; wait \"$worker\"")
  self.assertNotEqual(r.returncode,0);self.assertLess(time.monotonic()-start,5)
 def test_unwritable_work_state_fails_closed(self):
  start=time.monotonic()
  r=self.runsh("helper=$(mktemp /tmp/tx-work-failure.XXXXXX); printf '%s\\n' '#!/bin/sh' \\\"trap 'exit 0' TERM\\\" 'while :; do :; done' > \\\"$helper\\\"; chmod +x \\\"$helper\\\"; (sleep 1; chmod 0500 \\\"$WORK\\\") & tx_bounded_command 2 \\\"$helper\\\"; rc=$?; chmod 0700 \\\"$WORK\\\"; rm -f \\\"$helper\\\"; exit $rc")
  self.assertNotEqual(r.returncode,0);self.assertLess(time.monotonic()-start,7)
 def test_bounded_command_does_not_limit_file_size_of_services(self):
  # Перезапуск веб-службы и XKeen идёт через tx_bounded_command: лимит
  # ulimit -f наследовали бы долгоживущие демоны (stats_httpd.py, mihomo),
  # и всё, что они запускают, падало бы с "File size limit exceeded".
  r=self.runsh('ulimit -f > "$WORK/parent"; tx_bounded_command 5 sh -c \'ulimit -f > "$WORK/child"; head -c 100000 /dev/zero > "$WORK/big"\' && cmp "$WORK/parent" "$WORK/child" && [ "$(wc -c < "$WORK/big")" -eq 100000 ]')
  self.assertEqual(r.returncode,0,r.stderr)
 def test_health_failure(self):
  r=self.runsh('mkdir "$WORK/b"; printf "restart-mihomo\\n" > "$WORK/b/actions.txt"; tx_actions "$WORK/b"',dict(UPDATE_XKEEN_BIN=shutil.which('true'),UPDATE_HEALTH_CMD=shutil.which('false')))
  self.assertNotEqual(r.returncode,0)
 def test_health_timeout(self):
  r=self.runsh('printf "#!/bin/sh\\nsleep 10\\n" > "$WORK/health"; chmod +x "$WORK/health"; UPDATE_HEALTH_CMD="$WORK/health"; tx_mihomo_health',dict(UPDATE_HEALTH_TIMEOUT='1'))
  self.assertNotEqual(r.returncode,0)
unittest.main(argv=["test"])
PY
