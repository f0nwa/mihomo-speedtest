#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/web/stats_auth.py
WRAPPER=$ROOT/web/stats_auth.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/stats-auth-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

python3 - "$SCRIPT" <<'PY'
import importlib.util
import hashlib
import json
import os
import stat
import sys
import tempfile
import time
import unittest


script = sys.argv[1]
sys.argv = [sys.argv[0]]
spec = importlib.util.spec_from_file_location("stats_auth_under_test", script)
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)


class PasswordStateTests(unittest.TestCase):
    def test_iteration_calibration_scales_and_clamps(self):
        self.assertEqual(auth.choose_pbkdf2_iterations(0.01), 300000)
        self.assertEqual(auth.choose_pbkdf2_iterations(0.001), 600000)
        self.assertEqual(auth.choose_pbkdf2_iterations(1.0), 100000)

    def test_password_record_verifies_only_matching_password(self):
        record = auth.make_password_record(
            "секрет", iterations=100000, salt=b"0123456789abcdef"
        )
        self.assertEqual(record["algorithm"], "pbkdf2-hmac-sha256")
        self.assertEqual(record["iterations"], 100000)
        self.assertTrue(auth.verify_password("секрет", record))
        self.assertFalse(auth.verify_password("ошибка", record))

    def test_password_record_rejects_invalid_metadata(self):
        record = auth.make_password_record(
            "secret", iterations=100000, salt=b"0123456789abcdef"
        )
        mutations = [
            {**record, "algorithm": "md5"},
            {**record, "iterations": 99999},
            {**record, "iterations": 600001},
            {**record, "salt": "not base64!"},
            {**record, "digest": "not base64!"},
        ]
        for bad in mutations:
            with self.subTest(bad=bad):
                self.assertFalse(auth.verify_password("secret", bad))

    def test_credentials_are_atomic_strict_and_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = os.path.join(tmp, "state")
            written = auth.write_credentials(
                state, "admin", "секрет", iterations=100000
            )
            path = os.path.join(state, "credentials.json")
            self.assertEqual(stat.S_IMODE(os.stat(state).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            self.assertEqual(auth.load_credentials(state), written)
            self.assertEqual(written["version"], 1)
            self.assertEqual(written["username"], "admin")
            self.assertNotIn("секрет", json.dumps(written, ensure_ascii=False))
            self.assertFalse(
                [name for name in os.listdir(state) if name.startswith(".auth-")]
            )

    def test_corrupt_or_unknown_credentials_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = os.path.join(tmp, "state")
            os.mkdir(state, 0o700)
            path = os.path.join(state, "credentials.json")
            for payload in (
                "not-json",
                '{"version":2}',
                '{"version":1,"username":"","password":{}}',
            ):
                with self.subTest(payload=payload):
                    with open(path, "w", encoding="utf-8") as handle:
                        handle.write(payload)
                    self.assertIsNone(auth.load_credentials(state))


class SetupLifecycleTests(unittest.TestCase):
    def test_initialize_is_idempotent_and_preserves_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = os.path.join(tmp, "state")
            runtime = os.path.join(tmp, "runtime")
            code = auth.initialize_auth(state, runtime)
            self.assertEqual(len(code), 20)
            setup_path = os.path.join(state, "setup-code.sha256")
            with open(setup_path, "rb") as handle:
                first_hash = handle.read()
            self.assertIsNone(auth.initialize_auth(state, runtime))
            with open(setup_path, "rb") as handle:
                self.assertEqual(handle.read(), first_hash)

            auth.complete_setup(state, code, "admin", "secret", iterations=100000)
            credentials = auth.load_credentials(state)
            self.assertIsNone(auth.initialize_auth(state, runtime))
            self.assertEqual(auth.load_credentials(state), credentials)
            self.assertFalse(os.path.exists(setup_path))

    def test_reset_stores_only_hash_and_invalidates_old_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = os.path.join(tmp, "state")
            runtime = os.path.join(tmp, "runtime")
            auth.write_credentials(state, "old-admin", "old-secret", iterations=100000)
            sessions = os.path.join(runtime, "sessions")
            os.makedirs(sessions)
            with open(os.path.join(sessions, "old-session.json"), "w") as handle:
                handle.write("{}")

            code = auth.reset_auth(state, runtime)
            setup_path = os.path.join(state, "setup-code.sha256")
            with open(setup_path, "r", encoding="ascii") as handle:
                stored = handle.read().strip()

            self.assertEqual(len(code), 20)
            self.assertNotIn(code, stored)
            self.assertEqual(len(stored), 64)
            self.assertEqual(stat.S_IMODE(os.stat(setup_path).st_mode), 0o600)
            self.assertTrue(auth.verify_setup_code(state, code))
            self.assertFalse(auth.verify_setup_code(state, code + "X"))
            self.assertIsNone(auth.load_credentials(state))
            self.assertFalse(os.path.exists(sessions))

    def test_complete_setup_is_one_time_and_preserves_state_on_wrong_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = os.path.join(tmp, "state")
            runtime = os.path.join(tmp, "runtime")
            code = auth.reset_auth(state, runtime)
            setup_path = os.path.join(state, "setup-code.sha256")

            with self.assertRaises(ValueError):
                auth.complete_setup(
                    state, "wrong", "admin", "new-secret", iterations=100000
                )
            self.assertTrue(os.path.isfile(setup_path))
            self.assertIsNone(auth.load_credentials(state))

            credentials = auth.complete_setup(
                state, code, "admin", "new-secret", iterations=100000
            )
            self.assertEqual(auth.load_credentials(state), credentials)
            self.assertFalse(os.path.exists(setup_path))
            self.assertFalse(auth.verify_setup_code(state, code))

    def test_reset_keeps_credentials_when_new_hash_cannot_be_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = os.path.join(tmp, "state")
            runtime = os.path.join(tmp, "runtime")
            old = auth.write_credentials(
                state, "admin", "old-secret", iterations=100000
            )
            original = auth._atomic_write_text

            def fail_write(*args, **kwargs):
                raise OSError("read-only")

            auth._atomic_write_text = fail_write
            try:
                with self.assertRaises(OSError):
                    auth.reset_auth(state, runtime)
            finally:
                auth._atomic_write_text = original

            self.assertEqual(auth.load_credentials(state), old)
            self.assertFalse(auth.is_setup_pending(state))

    @unittest.skipUnless(hasattr(os, "fork"), "requires fork")
    def test_setup_code_is_consumed_by_only_one_fork(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = os.path.join(tmp, "state")
            runtime = os.path.join(tmp, "runtime")
            code = auth.reset_auth(state, runtime)
            start_read, start_write = os.pipe()
            result_read, result_write = os.pipe()
            children = []
            for index in range(8):
                pid = os.fork()
                if pid == 0:
                    os.close(start_write)
                    os.close(result_read)
                    os.read(start_read, 1)
                    try:
                        auth.complete_setup(
                            state, code, "admin%d" % index, "secret", iterations=100000
                        )
                    except ValueError:
                        result = b"0"
                    else:
                        result = b"1"
                    os.write(result_write, result)
                    os._exit(0)
                children.append(pid)
            os.close(start_read)
            os.close(result_write)
            os.write(start_write, b"12345678")
            os.close(start_write)
            results = b""
            while len(results) < 8:
                results += os.read(result_read, 8 - len(results))
            os.close(result_read)
            for pid in children:
                os.waitpid(pid, 0)
            self.assertEqual(results.count(b"1"), 1)


class SessionTests(unittest.TestCase):
    def test_session_uses_hashed_filename_and_private_ram_file(self):
        with tempfile.TemporaryDirectory() as runtime:
            issued = auth.create_session(runtime, "admin", now=100.0)
            self.assertRegex(issued["id"], r"^[A-Za-z0-9_-]{43}$")
            self.assertRegex(issued["csrf"], r"^[A-Za-z0-9_-]{43}$")
            filename = hashlib.sha256(issued["id"].encode("ascii")).hexdigest() + ".json"
            path = os.path.join(runtime, "sessions", filename)
            self.assertTrue(os.path.isfile(path))
            self.assertNotIn(issued["id"], path)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            session = auth.load_session(runtime, issued["id"], now=101.0, touch=False)
            self.assertEqual(session["username"], "admin")
            self.assertEqual(session["last_seen"], 100.0)
            self.assertTrue(auth.verify_csrf(session, issued["csrf"]))
            self.assertFalse(auth.verify_csrf(session, issued["csrf"] + "x"))

    def test_session_touch_expiry_destroy_and_clear(self):
        with tempfile.TemporaryDirectory() as runtime:
            first = auth.create_session(runtime, "admin", now=100.0)
            second = auth.create_session(runtime, "admin", now=200.0)
            touched = auth.load_session(runtime, first["id"], now=300.0)
            self.assertEqual(touched["last_seen"], 300.0)
            self.assertIsNotNone(
                auth.load_session(runtime, first["id"], now=43500.0, touch=False)
            )
            self.assertIsNone(
                auth.load_session(runtime, first["id"], now=43500.1, touch=False)
            )
            auth.destroy_session(runtime, second["id"])
            self.assertIsNone(auth.load_session(runtime, second["id"], now=201.0))

            third = auth.create_session(runtime, "admin", now=400.0)
            self.assertIsNotNone(auth.load_session(runtime, third["id"], now=401.0))
            auth.clear_sessions(runtime)
            self.assertIsNone(auth.load_session(runtime, third["id"], now=402.0))

    def test_corrupt_session_is_rejected_and_removed(self):
        with tempfile.TemporaryDirectory() as runtime:
            issued = auth.create_session(runtime, "admin", now=100.0)
            filename = hashlib.sha256(issued["id"].encode("ascii")).hexdigest() + ".json"
            path = os.path.join(runtime, "sessions", filename)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("not-json")
            self.assertIsNone(auth.load_session(runtime, issued["id"], now=101.0))
            self.assertFalse(os.path.exists(path))
            self.assertIsNone(auth.load_session(runtime, "../invalid", now=101.0))

    @unittest.skipUnless(hasattr(os, "fork"), "requires fork")
    def test_logout_wins_against_concurrent_session_touch(self):
        with tempfile.TemporaryDirectory() as runtime:
            issued = auth.create_session(runtime, "admin", now=100.0)
            ready_read, ready_write = os.pipe()
            continue_read, continue_write = os.pipe()
            loader = os.fork()
            if loader == 0:
                os.close(ready_read)
                os.close(continue_write)
                original = auth._atomic_write_json

                def paused_write(path, value, mode=0o600):
                    if os.path.basename(os.path.dirname(path)) == "sessions":
                        os.write(ready_write, b"1")
                        os.read(continue_read, 1)
                    return original(path, value, mode)

                auth._atomic_write_json = paused_write
                auth.load_session(runtime, issued["id"], now=200.0, touch=True)
                os._exit(0)

            os.close(ready_write)
            os.close(continue_read)
            self.assertEqual(os.read(ready_read, 1), b"1")
            destroyer = os.fork()
            if destroyer == 0:
                auth.destroy_session(runtime, issued["id"])
                os._exit(0)
            time.sleep(0.1)
            os.write(continue_write, b"1")
            os.close(continue_write)
            os.close(ready_read)
            os.waitpid(loader, 0)
            os.waitpid(destroyer, 0)
            self.assertIsNone(
                auth.load_session(runtime, issued["id"], now=201.0, touch=False)
            )

    def test_runtime_symlink_is_rejected_without_chmod_or_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "target")
            runtime = os.path.join(tmp, "runtime")
            os.mkdir(target, 0o755)
            os.symlink(target, runtime)
            with self.assertRaises(OSError):
                auth.create_session(runtime, "admin", now=100.0)
            self.assertEqual(stat.S_IMODE(os.stat(target).st_mode), 0o755)
            self.assertEqual(os.listdir(target), [])

    def test_sessions_symlink_is_rejected_before_loading(self):
        with tempfile.TemporaryDirectory() as tmp:
            runtime = os.path.join(tmp, "runtime")
            target = os.path.join(tmp, "target")
            os.mkdir(runtime, 0o700)
            os.mkdir(target, 0o755)
            os.symlink(target, os.path.join(runtime, "sessions"))
            session_id = "A" * 43
            filename = hashlib.sha256(session_id.encode("ascii")).hexdigest() + ".json"
            with open(os.path.join(target, filename), "w", encoding="utf-8") as handle:
                json.dump(
                    {
                        "version": 1,
                        "username": "admin",
                        "created_at": 100.0,
                        "last_seen": 100.0,
                        "csrf": "B" * 43,
                    },
                    handle,
                )
            with self.assertRaises(OSError):
                auth.load_session(runtime, session_id, now=101.0, touch=False)
            self.assertEqual(stat.S_IMODE(os.stat(target).st_mode), 0o755)


class RateLimitTests(unittest.TestCase):
    def test_rate_limit_blocks_sixth_attempt_and_recovers_after_window(self):
        with tempfile.TemporaryDirectory() as runtime:
            for now in (100, 101, 102, 103, 104):
                allowed, retry_after = auth.consume_rate_limit(
                    runtime, "login", "192.0.2.1", 5, 300, now=now
                )
                self.assertTrue(allowed)
                self.assertEqual(retry_after, 0)
            allowed, retry_after = auth.consume_rate_limit(
                runtime, "login", "192.0.2.1", 5, 300, now=105
            )
            self.assertFalse(allowed)
            self.assertEqual(retry_after, 295)
            allowed, retry_after = auth.consume_rate_limit(
                runtime, "login", "192.0.2.1", 5, 300, now=401
            )
            self.assertTrue(allowed)
            self.assertEqual(retry_after, 0)

    def test_rate_limit_keys_are_independent_and_corrupt_state_is_ignored(self):
        with tempfile.TemporaryDirectory() as runtime:
            self.assertEqual(
                auth.consume_rate_limit(runtime, "login", "a", 1, 60, now=10),
                (True, 0),
            )
            self.assertEqual(
                auth.consume_rate_limit(runtime, "setup", "a", 1, 60, now=10),
                (True, 0),
            )
            self.assertEqual(
                auth.consume_rate_limit(runtime, "login", "b", 1, 60, now=10),
                (True, 0),
            )
            rate_dir = os.path.join(runtime, "rate-limit")
            data_files = [name for name in os.listdir(rate_dir) if name.endswith(".json")]
            self.assertEqual(len(data_files), 3)
            identity = hashlib.sha256(b"login\0a").hexdigest() + ".json"
            with open(os.path.join(rate_dir, identity), "w") as handle:
                handle.write("corrupt")
            allowed, retry_after = auth.consume_rate_limit(
                runtime, "login", "a", 1, 60, now=11
            )
            self.assertTrue(allowed)
            self.assertEqual(retry_after, 0)

    @unittest.skipUnless(hasattr(os, "fork"), "requires fork")
    def test_rate_limit_is_shared_between_fork_processes(self):
        with tempfile.TemporaryDirectory() as runtime:
            start_read, start_write = os.pipe()
            result_read, result_write = os.pipe()
            children = []
            for _ in range(12):
                pid = os.fork()
                if pid == 0:
                    os.close(start_write)
                    os.close(result_read)
                    os.read(start_read, 1)
                    allowed, _ = auth.consume_rate_limit(
                        runtime, "login", "192.0.2.1", 5, 300, now=100
                    )
                    os.write(result_write, b"1" if allowed else b"0")
                    os._exit(0)
                children.append(pid)
            os.close(start_read)
            os.close(result_write)
            os.write(start_write, b"x" * len(children))
            os.close(start_write)
            results = b""
            while len(results) < len(children):
                results += os.read(result_read, len(children) - len(results))
            os.close(result_read)
            for pid in children:
                os.waitpid(pid, 0)
            self.assertEqual(results.count(b"1"), 5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
PY

INIT_STATE=$TEST_ROOT/init-state
INIT_RUNTIME=$TEST_ROOT/init-runtime
INIT_OUT=$(STATS_AUTH_PY=$SCRIPT STATS_AUTH_STATE_DIR=$INIT_STATE \
  STATS_AUTH_RUNTIME_DIR=$INIT_RUNTIME INITD_SCRIPT=$TEST_ROOT/no-init \
  sh "$WRAPPER" initialize)
INIT_CODE=$(printf '%s\n' "$INIT_OUT" | sed -n 's/^Одноразовый код: //p')
[ "${#INIT_CODE}" -eq 20 ] || {
  echo "FAIL: initialize не напечатал новый setup-код" >&2
  exit 1
}
INIT_HASH=$(cat "$INIT_STATE/setup-code.sha256")
INIT_OUT2=$(STATS_AUTH_PY=$SCRIPT STATS_AUTH_STATE_DIR=$INIT_STATE \
  STATS_AUTH_RUNTIME_DIR=$INIT_RUNTIME INITD_SCRIPT=$TEST_ROOT/no-init \
  sh "$WRAPPER" initialize)
[ -z "$INIT_OUT2" ] || {
  echo "FAIL: повторный initialize не должен повторно печатать потерянный код" >&2
  exit 1
}
[ "$(cat "$INIT_STATE/setup-code.sha256")" = "$INIT_HASH" ] || {
  echo "FAIL: повторный initialize заменил setup hash" >&2
  exit 1
}

FAKE_INIT=$TEST_ROOT/fake-init.sh
INIT_LOG=$TEST_ROOT/init.log
cat > "$FAKE_INIT" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$INIT_LOG"
SH
chmod +x "$FAKE_INIT"

STATE=$TEST_ROOT/state
RUNTIME=$TEST_ROOT/runtime
mkdir -p "$RUNTIME/sessions"
printf '{}\n' > "$RUNTIME/sessions/old.json"

OUT=$(INIT_LOG=$INIT_LOG DIR=$TEST_ROOT \
  STATS_AUTH_PY=$SCRIPT \
  STATS_AUTH_STATE_DIR=$STATE \
  STATS_AUTH_RUNTIME_DIR=$RUNTIME \
  INITD_SCRIPT=$FAKE_INIT \
  sh "$WRAPPER" reset)

CODE=$(printf '%s\n' "$OUT" | sed -n 's/^Одноразовый код: //p')
[ "${#CODE}" -eq 20 ] || {
  echo "FAIL: stats_auth.sh не напечатал 20-символьный одноразовый код" >&2
  exit 1
}
printf '%s\n' "$OUT" | grep -qF '/setup' || {
  echo "FAIL: stats_auth.sh не напечатал путь /setup" >&2
  exit 1
}
[ "$(cat "$INIT_LOG")" = restart ] || {
  echo "FAIL: stats_auth.sh должен вызвать init-скрипт ровно с restart" >&2
  exit 1
}
[ ! -e "$RUNTIME/sessions" ] || {
  echo "FAIL: stats_auth.sh reset не очистил старые сессии" >&2
  exit 1
}
python3 - "$STATE/setup-code.sha256" "$CODE" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    stored = handle.read().strip()
assert stored == hashlib.sha256(sys.argv[2].encode("ascii")).hexdigest()
assert sys.argv[2] not in stored
PY

UNKNOWN_STATE=$TEST_ROOT/unknown-state
if STATS_AUTH_PY=$SCRIPT STATS_AUTH_STATE_DIR=$UNKNOWN_STATE \
  STATS_AUTH_RUNTIME_DIR=$TEST_ROOT/unknown-runtime INITD_SCRIPT=$FAKE_INIT \
  sh "$WRAPPER" unknown >"$TEST_ROOT/unknown.out" 2>"$TEST_ROOT/unknown.err"; then
  echo "FAIL: неизвестная команда stats_auth.sh должна завершаться ошибкой" >&2
  exit 1
fi
[ ! -e "$UNKNOWN_STATE" ] || {
  echo "FAIL: неизвестная команда stats_auth.sh изменила состояние" >&2
  exit 1
}
grep -qF 'Использование:' "$TEST_ROOT/unknown.err" || {
  echo "FAIL: неизвестная команда stats_auth.sh не показала использование" >&2
  exit 1
}

if STATS_AUTH_PYTHON=$TEST_ROOT/no-python STATS_AUTH_PY=$SCRIPT \
  STATS_AUTH_STATE_DIR=$TEST_ROOT/no-python-state \
  STATS_AUTH_RUNTIME_DIR=$TEST_ROOT/no-python-runtime INITD_SCRIPT=$FAKE_INIT \
  sh "$WRAPPER" reset >"$TEST_ROOT/no-python.out" 2>"$TEST_ROOT/no-python.err"; then
  echo "FAIL: stats_auth.sh должен отклонить отсутствие Python" >&2
  exit 1
fi
grep -qF 'Python 3 не найден' "$TEST_ROOT/no-python.err" || {
  echo "FAIL: отсутствие Python не объяснено" >&2
  exit 1
}

if STATS_AUTH_PY=$TEST_ROOT/no-module.py \
  STATS_AUTH_STATE_DIR=$TEST_ROOT/no-module-state \
  STATS_AUTH_RUNTIME_DIR=$TEST_ROOT/no-module-runtime INITD_SCRIPT=$FAKE_INIT \
  sh "$WRAPPER" reset >"$TEST_ROOT/no-module.out" 2>"$TEST_ROOT/no-module.err"; then
  echo "FAIL: stats_auth.sh должен отклонить отсутствие stats_auth.py" >&2
  exit 1
fi
grep -qF 'stats_auth.py не найден' "$TEST_ROOT/no-module.err" || {
  echo "FAIL: отсутствие stats_auth.py не объяснено" >&2
  exit 1
}

FAIL_INIT=$TEST_ROOT/fail-init.sh
cat > "$FAIL_INIT" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$FAIL_INIT"
if STATS_AUTH_PY=$SCRIPT STATS_AUTH_STATE_DIR=$TEST_ROOT/restart-fail-state \
  STATS_AUTH_RUNTIME_DIR=$TEST_ROOT/restart-fail-runtime INITD_SCRIPT=$FAIL_INIT \
  sh "$WRAPPER" reset >"$TEST_ROOT/restart-fail.out" 2>"$TEST_ROOT/restart-fail.err"; then
  echo "FAIL: ошибка restart должна возвращаться владельцу" >&2
  exit 1
fi
grep -qF 'Одноразовый код:' "$TEST_ROOT/restart-fail.out" || {
  echo "FAIL: при ошибке restart владелец должен получить созданный код" >&2
  exit 1
}
grep -qF 'Не удалось перезапустить веб-службу' "$TEST_ROOT/restart-fail.err" || {
  echo "FAIL: ошибка restart не объяснена" >&2
  exit 1
}
[ -f "$TEST_ROOT/restart-fail-state/setup-code.sha256" ] || {
  echo "FAIL: ошибка restart не должна удалять новый setup hash" >&2
  exit 1
}

# --- Финальный обзор (C2b): дефолт DIR (без явного переопределения)
# должен указывать на каталог ПРОЕКТА /opt/etc/mihomo-speedtest, а не на
# каталог самой Mihomo /opt/etc/mihomo - см.
# docs/superpowers/specs/2026-09-25-install-dir-separation-design.md.
# STATS_AUTH_PY ($DIR/stats_auth.py) намеренно не переопределён и не
# существует на этой машине - естественная ошибка "не найден" утекает
# РЕЗОЛВНУТЫЙ путь, что здесь и проверяется (до исправления был бы
# /opt/etc/mihomo/stats_auth.py).
NODIR_ERR=$TEST_ROOT/nodir.err
if (unset DIR; sh "$WRAPPER" initialize) >"$TEST_ROOT/nodir.out" 2>"$NODIR_ERR"; then
  echo "FAIL: C2b: initialize без DIR и без реального stats_auth.py должен завершиться ошибкой" >&2
  exit 1
fi
grep -qF '/opt/etc/mihomo-speedtest/stats_auth.py' "$NODIR_ERR" || {
  echo "FAIL: C2b: DIR должен резолвиться в новый каталог проекта, получено: $(cat "$NODIR_ERR")" >&2
  exit 1
}
grep -qF '/opt/etc/mihomo/stats_auth.py' "$NODIR_ERR" && {
  echo "FAIL: C2b: DIR по умолчанию резолвится в старый каталог Mihomo вместо каталога проекта: $(cat "$NODIR_ERR")" >&2
  exit 1
}

echo "test_stats_auth.sh: OK (C2b regression covered)"
