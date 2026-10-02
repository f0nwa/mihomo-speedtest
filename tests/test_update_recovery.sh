#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PYTEST'
import pathlib,sys,unittest,shutil,subprocess,os,json,time
ROOT=pathlib.Path(sys.argv[1])
code=(ROOT/'tests/test_update_transaction.sh').read_text().split("<<'PYTEST'\n",1)[1].rsplit('\nPYTEST',1)[0].split('result=unittest.TextTestRunner',1)[0]
exec(compile(code,'transaction_fixture','exec'))
class Recovery(Transaction):
 def wrapper(self,name,body):
  bindir=self.root/'bin';bindir.mkdir(exist_ok=True)
  real=shutil.which(name)
  path=bindir/name
  path.write_text('#!/bin/sh\nreal="'+real+'"\n'+body);path.chmod(0o755)
  self.env['PATH']=str(bindir)+':'+os.environ['PATH']
 def test_recover_after_kill_during_publication(self):
  path=self.old();old=(self.state/'installed-manifest.txt').read_bytes();d,p=self.prepare()
  marker=self.root/'kill-once';self.env['FAULT_MARKER']=str(marker)
  self.wrapper('mv', '\nfor arg do\n case "$arg" in */opt/etc/mihomo-speedtest/a.sh) if [ ! -e "$FAULT_MARKER" ]; then "$real" "$@" || exit; touch "$FAULT_MARKER"; kill -KILL "$PPID"; exit 0; fi ;; esac\ndone\nexec "$real" "$@"\n')
  self.cli('--apply',d['plan_id'],ok=False)
  self.assertTrue((self.state/'transaction.txt').exists())
  self.env['UPDATE_HTTP_CMD']='/no-network'
  self.cli('--recover');self.assertEqual(path.read_bytes(),b'#!/bin/sh\nexit 7\n')
  self.assertEqual((self.state/'installed-manifest.txt').read_bytes(),old)
  self.assertFalse((self.state/'transaction.txt').exists())
 def test_recover_completes_cleanup_without_bundle(self):
  self.state.mkdir();(self.state/'transaction.txt').write_text('CLEANUP_PENDING\n')
  self.cli('--recover');self.assertFalse((self.state/'transaction.txt').exists())
 def test_recover_commit_after_bundle_promotion(self):
  self.old();self.apply();(self.state/'transaction.txt').write_text('COMMIT\n')
  current=(self.target/'opt/etc/mihomo-speedtest/a.sh').read_bytes()
  self.cli('--recover');self.assertEqual((self.target/'opt/etc/mihomo-speedtest/a.sh').read_bytes(),current)
  self.assertFalse((self.state/'transaction.txt').exists())
 def test_recover_removes_orphan_before_first_mutation(self):
  path=self.old();d,p=self.prepare();marker=self.root/'kill-journal';self.env['FAULT_MARKER']=str(marker)
  self.wrapper('mv','for arg do\n case "$arg" in */.update/transaction.txt) if [ ! -e "$FAULT_MARKER" ]; then touch "$FAULT_MARKER"; kill -KILL "$PPID"; exit 1; fi ;; esac\ndone\nexec "$real" "$@"\n')
  self.cli('--apply',d['plan_id'],ok=False)
  self.assertEqual(path.read_bytes(),b'#!/bin/sh\nexit 7\n')
  self.assertTrue((self.state/'rollback.pending').exists());self.assertFalse((self.state/'transaction.txt').exists())
  self.cli('--recover');self.assertFalse((self.state/'rollback.pending').exists())
  self.cli('--apply',d['plan_id'])
 def test_term_after_initial_journal_keeps_recovery_available(self):
  path=self.old();d,p=self.prepare();marker=self.root/'term-once';self.env['FAULT_MARKER']=str(marker)
  self.wrapper('mv','for arg do\n case "$arg" in */.update/transaction.txt) if [ ! -e "$FAULT_MARKER" ]; then "$real" "$@" || exit; touch "$FAULT_MARKER"; kill -TERM "$PPID"; exit 0; fi ;; esac\ndone\nexec "$real" "$@"\n')
  self.cli('--apply',d['plan_id'],ok=False)
  self.cli('--recover');self.assertEqual(path.read_bytes(),b'#!/bin/sh\nexit 7\n')
  self.assertFalse((self.state/'transaction.txt').exists())
 def test_recover_cleanup_with_partially_deleted_engine(self):
  self.state.mkdir();partial=self.state/'rollback.pending/engine';partial.mkdir(parents=True)
  (partial/'update_transaction.sh').write_text('partial cleanup\n')
  (self.state/'transaction.txt').write_text('CLEANUP_PENDING\n')
  self.env['UPDATE_HTTP_CMD']='/no-network';self.cli('--recover')
  self.assertFalse((self.state/'rollback.pending').exists());self.assertFalse((self.state/'transaction.txt').exists())
 def test_failed_copy_leaves_original_and_old_manifest(self):
  path=self.old();old=(self.state/'installed-manifest.txt').read_bytes();d,p=self.prepare()
  marker=self.root/'cp-once';self.env['FAULT_MARKER']=str(marker)
  self.wrapper('cp','last=\nfor arg do last=$arg; done\ncase "$last" in */opt/etc/mihomo/.*) if [ ! -e "$FAULT_MARKER" ]; then touch "$FAULT_MARKER"; exit 1; fi ;; esac\nexec "$real" "$@"\n')
  self.cli('--apply',d['plan_id'],ok=False)
  self.assertEqual(path.read_bytes(),b'#!/bin/sh\nexit 7\n')
  self.assertEqual((self.state/'installed-manifest.txt').read_bytes(),old)
 def test_recovery_rejects_corrupted_backup_without_writes(self):
  self.old();self.apply();bundle=self.state/'rollback'
  candidates=[p for p in bundle.rglob('*') if p.is_file() and p.read_bytes()==b'#!/bin/sh\nexit 7\n']
  self.assertTrue(candidates);candidates[0].write_bytes(b'broken')
  before=self.snapshot();self.cli('--rollback-last',ok=False);self.assertEqual(self.snapshot(),before)
 def test_restore_uses_saved_engine_when_installed_helper_broken(self):
  path=self.old();self.apply()
  for name in ['update_prepare.sh','update_transaction.sh']:
   (self.target/'opt/etc/mihomo-speedtest'/name).write_text('broken helper\n')
  self.env['UPDATE_HTTP_CMD']='/no-network';self.cli('--rollback-last')
  self.assertEqual(path.read_bytes(),b'#!/bin/sh\nexit 7\n')
# Запускаются только дополнительные сценарии восстановления.
names=[n for n in Recovery.__dict__ if n.startswith('test_')]
suite=unittest.TestSuite(Recovery(n) for n in names)
result=unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(not result.wasSuccessful())
PYTEST
