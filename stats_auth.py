#!/usr/bin/env python3
"""Ядро авторизации веб-интерфейса mihomo-speedtest.

Модуль хранит постоянные учётные данные отдельно от RAM-сессий. HTTP-маршруты
подключаются в следующей порции; этот файл уже задаёт строгий формат состояния
и криптографические операции для них и для SSH-сброса.
"""

import base64
import binascii
import contextlib
import errno
import fcntl
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import shutil
import stat
import sys
import tempfile
import time


AUTH_VERSION = 1
PASSWORD_ALGORITHM = "pbkdf2-hmac-sha256"
PBKDF2_SAMPLE_ITERATIONS = 10000
PBKDF2_TARGET_SECONDS = 0.3
PBKDF2_MIN_ITERATIONS = 100000
PBKDF2_MAX_ITERATIONS = 600000
CREDENTIALS_FILE = "credentials.json"
SETUP_CODE_FILE = "setup-code.sha256"
SETUP_CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
SETUP_CODE_LENGTH = 20
SESSION_VERSION = 1
SESSION_IDLE_SECONDS = 12 * 60 * 60
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")


def choose_pbkdf2_iterations(elapsed_seconds):
    """Масштабировать пробу 10 000 итераций к цели 300 мс и ограничить её."""
    if not isinstance(elapsed_seconds, (int, float)) or elapsed_seconds <= 0:
        return PBKDF2_MAX_ITERATIONS
    scaled = int(PBKDF2_SAMPLE_ITERATIONS * PBKDF2_TARGET_SECONDS / elapsed_seconds)
    return max(PBKDF2_MIN_ITERATIONS, min(PBKDF2_MAX_ITERATIONS, scaled))


def calibrate_pbkdf2_iterations():
    salt = b"mihomo-pbkdf2-calibration"
    started = time.perf_counter()
    hashlib.pbkdf2_hmac(
        "sha256", b"calibration", salt, PBKDF2_SAMPLE_ITERATIONS
    )
    return choose_pbkdf2_iterations(time.perf_counter() - started)


def _b64encode(raw):
    return base64.b64encode(raw).decode("ascii")


def _b64decode(value):
    if not isinstance(value, str):
        raise ValueError("base64 value must be text")
    return base64.b64decode(value.encode("ascii"), validate=True)


def make_password_record(password, iterations=None, salt=None):
    if not isinstance(password, str) or not password:
        raise ValueError("password must be non-empty text")
    if iterations is None:
        iterations = calibrate_pbkdf2_iterations()
    if not isinstance(iterations, int) or isinstance(iterations, bool):
        raise ValueError("iterations must be an integer")
    if not PBKDF2_MIN_ITERATIONS <= iterations <= PBKDF2_MAX_ITERATIONS:
        raise ValueError("iterations outside allowed range")
    if salt is None:
        salt = secrets.token_bytes(16)
    if not isinstance(salt, bytes) or len(salt) < 16:
        raise ValueError("salt must contain at least 16 bytes")
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, iterations
    )
    return {
        "algorithm": PASSWORD_ALGORITHM,
        "iterations": iterations,
        "salt": _b64encode(salt),
        "digest": _b64encode(digest),
    }


def verify_password(password, record):
    try:
        if not isinstance(password, str) or not isinstance(record, dict):
            return False
        if record.get("algorithm") != PASSWORD_ALGORITHM:
            return False
        iterations = record.get("iterations")
        if not isinstance(iterations, int) or isinstance(iterations, bool):
            return False
        if not PBKDF2_MIN_ITERATIONS <= iterations <= PBKDF2_MAX_ITERATIONS:
            return False
        salt = _b64decode(record.get("salt"))
        expected = _b64decode(record.get("digest"))
        if len(salt) < 16 or len(expected) != hashlib.sha256().digest_size:
            return False
        actual = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), salt, iterations
        )
        return hmac.compare_digest(actual, expected)
    except (UnicodeError, ValueError, TypeError, binascii.Error):
        return False


def _ensure_private_dir(path):
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        raise OSError(errno.ENOTDIR, "небезопасный auth-каталог", path)
    if info.st_uid != os.geteuid():
        raise OSError(errno.EPERM, "auth-каталог принадлежит другому пользователю", path)
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
            raise OSError(errno.EAGAIN, "auth-каталог изменился", path)
        os.fchmod(descriptor, 0o700)
    finally:
        os.close(descriptor)


@contextlib.contextmanager
def _exclusive_lock(directory, filename):
    _ensure_private_dir(directory)
    path = os.path.join(directory, filename)
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise OSError(errno.EINVAL, "небезопасный auth lock", path)
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _fsync_dir(path):
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    except OSError:
        pass
    finally:
        os.close(descriptor)


def _atomic_write_bytes(path, payload, mode=0o600):
    directory = os.path.dirname(path) or "."
    _ensure_private_dir(directory)
    descriptor, temporary = tempfile.mkstemp(prefix=".auth-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = None
            handle.write(payload)
            handle.flush()
            os.fchmod(handle.fileno(), mode)
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
        _fsync_dir(directory)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def _atomic_write_json(path, value, mode=0o600):
    payload = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8") + b"\n"
    _atomic_write_bytes(path, payload, mode)


def _atomic_write_text(path, value, mode=0o600):
    _atomic_write_bytes(path, value.encode("ascii"), mode)


def _valid_username(username):
    return (
        isinstance(username, str)
        and 1 <= len(username) <= 64
        and not any(ord(char) < 32 or ord(char) == 127 for char in username)
    )


def _credentials_path(state_dir):
    return os.path.join(state_dir, CREDENTIALS_FILE)


def _valid_credentials(value):
    if not isinstance(value, dict) or set(value) != {"version", "username", "password"}:
        return False
    if value.get("version") != AUTH_VERSION or not _valid_username(value.get("username")):
        return False
    password = value.get("password")
    return isinstance(password, dict) and set(password) == {
        "algorithm", "iterations", "salt", "digest"
    } and _password_record_valid(password)


def _password_record_valid(record):
    try:
        if record.get("algorithm") != PASSWORD_ALGORITHM:
            return False
        iterations = record.get("iterations")
        if not isinstance(iterations, int) or isinstance(iterations, bool):
            return False
        if not PBKDF2_MIN_ITERATIONS <= iterations <= PBKDF2_MAX_ITERATIONS:
            return False
        return len(_b64decode(record.get("salt"))) >= 16 and len(
            _b64decode(record.get("digest"))
        ) == hashlib.sha256().digest_size
    except (UnicodeError, ValueError, TypeError, binascii.Error):
        return False


def _write_credentials_unlocked(state_dir, username, password, iterations=None):
    if not _valid_username(username):
        raise ValueError("invalid username")
    value = {
        "version": AUTH_VERSION,
        "username": username,
        "password": make_password_record(password, iterations=iterations),
    }
    _atomic_write_json(_credentials_path(state_dir), value)
    return value


def write_credentials(state_dir, username, password, iterations=None):
    with _exclusive_lock(state_dir, "auth.lock"):
        return _write_credentials_unlocked(
            state_dir, username, password, iterations=iterations
        )


def load_credentials(state_dir):
    path = _credentials_path(state_dir)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError, UnicodeError):
        return None
    return value if _valid_credentials(value) else None


def has_credentials(state_dir):
    return load_credentials(state_dir) is not None


def _setup_code_path(state_dir):
    return os.path.join(state_dir, SETUP_CODE_FILE)


def is_setup_pending(state_dir):
    path = _setup_code_path(state_dir)
    try:
        with open(path, "r", encoding="ascii") as handle:
            digest = handle.read().strip()
    except (OSError, UnicodeError):
        return False
    return len(digest) == 64 and all(char in "0123456789abcdef" for char in digest)


def verify_setup_code(state_dir, candidate):
    if not isinstance(candidate, str):
        return False
    path = _setup_code_path(state_dir)
    try:
        with open(path, "r", encoding="ascii") as handle:
            expected = handle.read().strip()
    except (OSError, UnicodeError):
        return False
    if len(expected) != 64 or not all(char in "0123456789abcdef" for char in expected):
        return False
    actual = hashlib.sha256(candidate.encode("utf-8")).hexdigest()
    return hmac.compare_digest(actual, expected)


def clear_sessions(runtime_dir):
    with _exclusive_lock(runtime_dir, "sessions.lock"):
        sessions_dir = os.path.join(runtime_dir, "sessions")
        if os.path.islink(sessions_dir):
            os.unlink(sessions_dir)
            return
        if not os.path.isdir(sessions_dir):
            return
        try:
            shutil.rmtree(sessions_dir)
        except FileNotFoundError:
            pass


def reset_auth(state_dir, runtime_dir):
    code = "".join(secrets.choice(SETUP_CODE_ALPHABET) for _ in range(SETUP_CODE_LENGTH))
    digest = hashlib.sha256(code.encode("ascii")).hexdigest()
    with _exclusive_lock(state_dir, "auth.lock"):
        _atomic_write_text(_setup_code_path(state_dir), digest + "\n")
        credentials_path = _credentials_path(state_dir)
        try:
            os.unlink(credentials_path)
        except FileNotFoundError:
            pass
        _fsync_dir(state_dir)
    clear_sessions(runtime_dir)
    return code


def complete_setup(state_dir, code, username, password, iterations=None):
    with _exclusive_lock(state_dir, "auth.lock"):
        if not verify_setup_code(state_dir, code):
            raise ValueError("invalid setup code")
        credentials = _write_credentials_unlocked(
            state_dir, username, password, iterations=iterations
        )
        try:
            os.unlink(_setup_code_path(state_dir))
        except FileNotFoundError:
            pass
        _fsync_dir(state_dir)
        return credentials


def complete_setup_and_create_session(
    state_dir, runtime_dir, code, username, password, iterations=None
):
    """Завершить setup и создать сессию без окна для параллельного reset."""
    with _exclusive_lock(state_dir, "auth.lock"):
        if not verify_setup_code(state_dir, code):
            raise ValueError("invalid setup code")
        _write_credentials_unlocked(
            state_dir, username, password, iterations=iterations
        )
        try:
            os.unlink(_setup_code_path(state_dir))
        except FileNotFoundError:
            pass
        _fsync_dir(state_dir)
        return create_session(runtime_dir, username)


def authenticate_and_create_session(state_dir, runtime_dir, username, password):
    """Проверить credentials и создать сессию атомарно относительно reset."""
    if not isinstance(username, str) or not isinstance(password, str):
        return None
    with _exclusive_lock(state_dir, "auth.lock"):
        credentials = load_credentials(state_dir)
        if credentials is None:
            return None
        try:
            valid_user = hmac.compare_digest(
                username.encode("utf-8"), credentials["username"].encode("utf-8")
            )
        except UnicodeError:
            valid_user = False
        valid_password = verify_password(password, credentials["password"])
        if not (valid_user and valid_password):
            return None
        return create_session(runtime_dir, credentials["username"])


def _session_path(runtime_dir, session_id):
    if not isinstance(session_id, str) or not TOKEN_RE.match(session_id):
        return None
    filename = hashlib.sha256(session_id.encode("ascii")).hexdigest() + ".json"
    return os.path.join(runtime_dir, "sessions", filename)


def _validate_sessions_dir(runtime_dir, create):
    sessions_dir = os.path.join(runtime_dir, "sessions")
    if not create and not os.path.lexists(sessions_dir):
        return False
    _ensure_private_dir(sessions_dir)
    return True


def _valid_session(value):
    if not isinstance(value, dict) or set(value) != {
        "version", "username", "created_at", "last_seen", "csrf"
    }:
        return False
    if value.get("version") != SESSION_VERSION or not _valid_username(value.get("username")):
        return False
    for field in ("created_at", "last_seen"):
        number = value.get(field)
        if not isinstance(number, (int, float)) or isinstance(number, bool):
            return False
        if not math.isfinite(number):
            return False
    return isinstance(value.get("csrf"), str) and TOKEN_RE.match(value["csrf"]) is not None


def create_session(runtime_dir, username, now=None):
    if not _valid_username(username):
        raise ValueError("invalid username")
    if now is None:
        now = time.time()
    session_id = secrets.token_urlsafe(32)
    csrf = secrets.token_urlsafe(32)
    value = {
        "version": SESSION_VERSION,
        "username": username,
        "created_at": float(now),
        "last_seen": float(now),
        "csrf": csrf,
    }
    with _exclusive_lock(runtime_dir, "sessions.lock"):
        _validate_sessions_dir(runtime_dir, create=True)
        path = _session_path(runtime_dir, session_id)
        _atomic_write_json(path, value)
    return {"id": session_id, "csrf": csrf}


def _remove_file(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def load_session(runtime_dir, session_id, now=None, touch=True):
    path = _session_path(runtime_dir, session_id)
    if path is None:
        return None
    with _exclusive_lock(runtime_dir, "sessions.lock"):
        if not _validate_sessions_dir(runtime_dir, create=False):
            return None
        try:
            with open(path, "r", encoding="utf-8") as handle:
                value = json.load(handle)
        except (OSError, ValueError, UnicodeError):
            _remove_file(path)
            return None
        if not _valid_session(value):
            _remove_file(path)
            return None
        if now is None:
            now = time.time()
        now = float(now)
        if now - value["last_seen"] > SESSION_IDLE_SECONDS:
            _remove_file(path)
            return None
        if touch and now != value["last_seen"]:
            value["last_seen"] = now
            _atomic_write_json(path, value)
        return value


def destroy_session(runtime_dir, session_id):
    path = _session_path(runtime_dir, session_id)
    if path is not None:
        with _exclusive_lock(runtime_dir, "sessions.lock"):
            if not _validate_sessions_dir(runtime_dir, create=False):
                return
            _remove_file(path)


def verify_csrf(session, candidate):
    if not _valid_session(session) or not isinstance(candidate, str):
        return False
    return hmac.compare_digest(session["csrf"], candidate)


def _load_rate_attempts(path, now):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError, UnicodeError):
        return []
    if not isinstance(value, dict) or set(value) != {"version", "attempts"}:
        return []
    if value.get("version") != 1 or not isinstance(value.get("attempts"), list):
        return []
    attempts = []
    for timestamp in value["attempts"]:
        if not isinstance(timestamp, (int, float)) or isinstance(timestamp, bool):
            return []
        timestamp = float(timestamp)
        if not math.isfinite(timestamp) or timestamp > now:
            return []
        attempts.append(timestamp)
    return attempts


def consume_rate_limit(runtime_dir, bucket, key, limit, window_seconds, now=None):
    if not isinstance(bucket, str) or not bucket or not isinstance(key, str) or not key:
        raise ValueError("bucket and key must be non-empty text")
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1:
        raise ValueError("limit must be a positive integer")
    if not isinstance(window_seconds, (int, float)) or window_seconds <= 0:
        raise ValueError("window must be positive")
    if now is None:
        now = time.time()
    now = float(now)

    _ensure_private_dir(runtime_dir)
    rate_dir = os.path.join(runtime_dir, "rate-limit")
    _ensure_private_dir(rate_dir)
    identity = hashlib.sha256((bucket + "\0" + key).encode("utf-8")).hexdigest()
    data_path = os.path.join(rate_dir, identity + ".json")
    lock_path = os.path.join(rate_dir, identity + ".lock")
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        attempts = _load_rate_attempts(data_path, now)
        cutoff = now - float(window_seconds)
        attempts = [timestamp for timestamp in attempts if timestamp > cutoff]
        if len(attempts) >= limit:
            retry_after = max(1, int(math.ceil(attempts[0] + window_seconds - now)))
            return False, retry_after
        attempts.append(now)
        _atomic_write_json(data_path, {"version": 1, "attempts": attempts})
        return True, 0
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def cli_main(argv):
    if len(argv) != 5 or argv[0] != "reset" or argv[1] != "--state-dir" or argv[3] != "--runtime-dir":
        sys.stderr.write(
            "usage: stats_auth.py reset --state-dir PATH --runtime-dir PATH\n"
        )
        return 2
    code = reset_auth(argv[2], argv[4])
    sys.stdout.write(code + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(cli_main(sys.argv[1:]))
