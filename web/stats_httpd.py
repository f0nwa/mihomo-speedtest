#!/usr/bin/env python3
"""Веб-сервер веб-сервиса статистики speedtest2 (см. README, раздел про
stats_www). Ставится install.sh как $DIR/stats_httpd.py; start_backend()
в stats_service.sh (независимая служба, порция 3) запускает его теми же
аргументами, что и "busybox httpd".

С шага 5 SPA-миграции (см.
docs/plans/2026-09-12-web-spa-migration-design.md, решение по
python3-зависимости - вариант 2, деградация) это ОСНОВНОЙ сервер: только
он умеет чистые URL (/, /stats, /settings) и /api/* (см. ниже).
Резервного "busybox httpd" больше нет: веб-интерфейс требует python3
(см. start_backend() в stats_service.sh). Старая HTML-страница
/stats.html удалена 2026-09-28, render_stats() удаляет её остатки.

Поддерживает ту часть CLI busybox httpd, которой пользуется этот проект:
  -p BIND:PORT   адрес и порт
  -h DIR         раздаваемый каталог (docroot)
  -c CONFFILE    принят для совместимости со старым запуском, но не
                 используется: весь интерфейс защищён сессией
  -f             без демонизации, для совместимости (этот сервер и так
                 всегда работает на переднем плане - в фон его уводит "&"
                 в speedtest2.sh, как и busybox httpd)

Только стандартная библиотека - на роутере с Entware кроме самого python3
ставить нечего. Целится в Python 3.7+, но написан с оглядкой на 3.13, где
http.server.CGIHTTPRequestHandler и модуль cgi уже удалены (PEP 594) -
поэтому обработка CGI реализована руками через subprocess, без них.

Модель обработки запросов - процесс НА КАЖДОЕ соединение (fork), а не поток
на соединение: self-restart в stats_service.sh (supervisor убивает старый
процесс-слушатель и поднимает новый по команде reconfigure/restart, обычно
из-под уже принятого HTTP-запроса к форме настройки) полагается на то, что
уже принятое соединение переживает убийство слушателя, отвечая клиенту как
ни в чём не бывало - ровно так же, как это устроено у busybox httpd
(отдельный процесс-обработчик на соединение). При потоках слушатель и
обработчик были бы одним процессом, и kill оборвал бы поток, дописывающий
ответ, вместе со всем остальным.

Маршрутизация (таблицы STATIC_FILES, DATA_FILES, API_ROUTES ниже):
  - "/", "/style.css", "/app.js", ... - файлы интерфейса прямо из каталога
    приложения ($DIR, рядом с этим файлом; в тестах - STATS_APP_DIR).
  - "/api/stats" - stats.json из docroot, "/api/progress" - progress.json
    из /tmp (оба пишет speedtest2.sh). Файла нет - ответ "{}" с кодом 200:
    фронтенд трактует это как "данных ещё нет".
  - "/api/system" - версия, аптайм, CPU, память, mihomo (system_status()).
  - "/api/run", "/api/settings", "/api/updates/*",
    "/api/config/*" - запуск скрипта из $DIR по протоколу CGI (переменные
    REQUEST_METHOD/QUERY_STRING/..., тело на stdin, заголовки + тело на
    stdout). Действие передаётся переменной окружения из API_ROUTES.
  - "/api/log" - живой журнал, обрабатывается здесь (live_log_poll()).
  - "/api/auth/*" - вход и сессии (stats_auth.py).
  - прочие "/api/..." - 501; "/cgi-bin/..." - 404;
  - любой другой GET/HEAD - index.html (клиентский роутер SPA).
"""
import http.server
import json
import os
import signal
import socketserver
import subprocess
import sys
import time
import urllib.parse
from http.cookies import SimpleCookie

import stats_auth


AUTH_COOKIE = "mst_session"
AUTH_BODY_LIMIT = 16 * 1024
# Тело запроса к скриптам API: самое большое - config.yaml в редакторе
# (stats_config.sh сам ограничивает его 1 МиБ), с запасом на кодирование.
SCRIPT_BODY_LIMIT = 4 * 1024 * 1024


# ----- состояние системы для футера (GET /api/system) -----
# Раньше это делал stats_system.sh (sh + несколько awk/cat/pidof на каждый
# опрос футера раз в 30 с); здесь - чтение трёх файлов /proc в уже
# запущенном процессе.

def _read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def _release_version(manifest_path):
    text = _read_text(manifest_path)
    if text is None:
        return None
    fields = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            fields[key.strip()] = value.strip()
    tag = fields.get("RELEASE_TAG", "")
    if tag.startswith("v"):
        tag = tag[1:]
    return tag or fields.get("RELEASE_VERSION") or None


def _cpu_times(proc):
    text = _read_text(os.path.join(proc, "stat"))
    if not text:
        return None
    for line in text.splitlines():
        parts = line.split()
        if parts and parts[0] == "cpu":
            try:
                values = [int(v) for v in parts[1:]]
            except ValueError:
                return None
            idle = values[3] + (values[4] if len(values) > 4 else 0)
            return sum(values), idle
    return None


def _cpu_percent(proc, delay, sleep):
    first = _cpu_times(proc)
    if first is None:
        return None
    sleep(delay)
    second = _cpu_times(proc)
    if second is None:
        return None
    total, idle = second[0] - first[0], second[1] - first[1]
    if total <= 0:
        return 0
    return int(100 * (total - idle) / total)


def _mem_percent(proc):
    text = _read_text(os.path.join(proc, "meminfo"))
    if not text:
        return None
    info = {}
    for line in text.splitlines():
        key, _, rest = line.partition(":")
        try:
            info[key] = int(rest.split()[0])
        except (IndexError, ValueError):
            pass
    total = info.get("MemTotal", 0)
    if total <= 0:
        return None
    avail = info.get("MemAvailable", info.get("MemFree", 0))
    return int(100 * (total - avail) / total)


def _uptime_seconds(proc):
    text = _read_text(os.path.join(proc, "uptime"))
    try:
        return int(float(text.split()[0]))
    except (AttributeError, IndexError, ValueError):
        return None


def _process_running(proc, name):
    # Тот же смысл, что у "pidof mihomo": есть процесс с таким именем.
    try:
        entries = os.listdir(proc)
    except OSError:
        return None
    for entry in entries:
        if not entry.isdigit():
            continue
        comm = _read_text(os.path.join(proc, entry, "comm"))
        if comm is not None and comm.strip() == name:
            return True
    return False


def system_status(proc=None, manifest=None, cpu_delay=None, sleep=time.sleep):
    proc = proc or os.environ.get("STATS_PROC_DIR", "/proc")
    if manifest is None:
        manifest = os.environ.get("INSTALLED_MANIFEST_PATH") or os.path.join(
            os.environ.get("UPDATE_STATE_DIR")
            or os.path.join(os.environ.get("MIHOMO_DIR", "/opt/etc/mihomo"), ".update"),
            "installed-manifest.txt",
        )
    if cpu_delay is None:
        try:
            cpu_delay = float(os.environ.get("CPU_SAMPLE_DELAY", "0.2"))
        except ValueError:
            cpu_delay = 0.2
    return {
        "release_version": _release_version(manifest),
        "uptime_seconds": _uptime_seconds(proc),
        "cpu_percent": _cpu_percent(proc, cpu_delay, sleep),
        "mem_percent": _mem_percent(proc),
        "mihomo_active": _process_running(proc, "mihomo"),
    }


# ----- живой журнал (вкладка «Журнал», GET /api/log) -----
#
# Пока страница «Журнал» открыта, она раз в пару секунд опрашивает
# /api/log. Каждый запрос обновляет mtime файла-маркера viewer в
# LIVE_LOG_DIR; пока маркер есть, say() в speedtest2.sh дублирует свои
# строки в live.log. Если запросов нет дольше LIVE_LOG_IDLE секунд,
# родительский процесс сервера (service_actions() ниже) удаляет маркер и
# все файлы журнала - сбор прекращается. Всё лежит только в /tmp (tmpfs),
# в /opt ничего не пишется (см. AGENTS.md про флешку).
#
# Файлы в LIVE_LOG_DIR:
#   viewer   - маркер «есть зрители», mtime = время последнего опроса;
#   gen      - идентификатор поколения журнала; меняется при создании и
#              при обрезке, клиент по нему понимает, что нужно начать заново;
#   seed     - затравка, пишется один раз на поколение: хвост постоянного
#              speedtest.log и журнала идущего прогона (при обрезке - хвост
#              обрезанного live.log), чтобы страница не открывалась пустой;
#   live.log - новые строки, say() только дописывает в конец;
#   lock     - flock для сериализации запросов (сервер форкается на запрос).
#
# Размер: если live.log вырос больше LIVE_LOG_LIMIT, он атомарно
# переименовывается (новые строки say() пойдут в новый файл, ничего не
# теряется), его хвост становится новой затравкой, поколение меняется.

import fcntl
import glob

LIVE_LOG_LIMIT = int(os.environ.get("LIVE_LOG_LIMIT", "65536"))
LIVE_LOG_IDLE = int(os.environ.get("LIVE_LOG_IDLE", "30"))
LIVE_LOG_READ_MAX = 32 * 1024
LIVE_LOG_SEED_HISTORY_LINES = 40
LIVE_LOG_SEED_RUN_LINES = 200
LIVE_LOG_SEED_MAX = 16 * 1024


def live_log_dir():
    d = os.environ.get("LIVE_LOG_DIR")
    if d:
        return d
    return os.path.join(os.environ.get("TMPROOT", "/tmp"), "mihomo-speedtest-live")


def _live_paths(d):
    return {
        "viewer": os.path.join(d, "viewer"),
        "gen": os.path.join(d, "gen"),
        "seed": os.path.join(d, "seed"),
        "log": os.path.join(d, "live.log"),
        "lock": os.path.join(d, "lock"),
        "rot": os.path.join(d, "live.log.rot"),
    }


def _unlink(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def _read_tail_lines(path, n, max_bytes=LIVE_LOG_SEED_MAX):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            data = f.read()
    except OSError:
        return []
    if size > max_bytes:
        # первая строка почти наверняка обрезана посередине
        data = data.split(b"\n", 1)[1] if b"\n" in data else b""
    return data.splitlines()[-n:]


def _history_log_path():
    if os.environ.get("LOG"):
        return os.environ["LOG"]
    return os.path.join(os.environ.get("DIR", "/opt/etc/mihomo-speedtest"), "speedtest.log")


def _run_log_paths():
    # WORK идущего прогона - $TMPROOT/mst.$$ (см. speedtest2.sh); его
    # speedtest.log попадает в постоянный журнал только в конце прогона.
    root = os.environ.get("TMPROOT", "/tmp")
    return sorted(glob.glob(os.path.join(root, "mst.[0-9]*", "speedtest.log")))


def _build_seed():
    out = []
    lines = _read_tail_lines(_history_log_path(), LIVE_LOG_SEED_HISTORY_LINES)
    if lines:
        out.append("--- последние записи speedtest.log ---".encode("utf-8"))
        out.extend(lines)
    for p in _run_log_paths():
        lines = _read_tail_lines(p, LIVE_LOG_SEED_RUN_LINES)
        if lines:
            out.append("--- идущий прогон ---".encode("utf-8"))
            out.extend(lines)
    out.append("--- дальше - новые сообщения ---".encode("utf-8"))
    return b"\n".join(out) + b"\n"


def _write_file(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def _new_gen():
    return os.urandom(8).hex()


def _decode(data):
    return data.decode("utf-8", errors="replace")


def live_log_cleanup(d=None, idle=None, now=None, force=False):
    """Удаляет маркер и файлы журнала, если зрителей нет дольше idle секунд
    (или маркера нет вовсе - тогда подчищает случайный live.log от say(),
    успевшего дописать строку после удаления маркера). Возвращает True,
    если что-то удалено или удалять было нечего."""
    d = d or live_log_dir()
    idle = LIVE_LOG_IDLE if idle is None else idle
    now = time.time() if now is None else now
    p = _live_paths(d)
    if not os.path.isdir(d):
        return True
    try:
        mtime = os.stat(p["viewer"]).st_mtime
    except FileNotFoundError:
        mtime = None
    if not force and mtime is not None and now - mtime <= idle:
        return False
    # Маркер - первым: после этого say() больше не открывает live.log.
    for key in ("viewer", "gen", "seed", "log", "rot"):
        _unlink(p[key])
    return True


def live_log_poll(client_gen, client_offset, d=None, limit=None, read_max=LIVE_LOG_READ_MAX):
    """Один опрос страницы «Журнал». Возвращает dict для JSON-ответа:
    gen, offset (с какого байта live.log спрашивать в следующий раз),
    reset (клиент должен очистить вывод и показать seed заново), seed
    (только при reset), text (новые целые строки), more (есть ещё)."""
    d = d or live_log_dir()
    limit = LIVE_LOG_LIMIT if limit is None else limit
    p = _live_paths(d)
    os.makedirs(d, mode=0o700, exist_ok=True)
    with open(p["lock"], "a") as lockf:
        fcntl.flock(lockf, fcntl.LOCK_EX)
        try:
            # Маркер - до затравки: строки, сказанные между этими шагами,
            # попадут и туда, и сюда (повтор лучше потери).
            with open(p["viewer"], "a"):
                pass
            os.utime(p["viewer"], None)
            try:
                with open(p["gen"]) as f:
                    gen = f.read().strip()
            except FileNotFoundError:
                gen = ""
            if not gen or not os.path.exists(p["seed"]):
                _write_file(p["seed"], _build_seed())
                gen = _new_gen()
                _write_file(p["gen"], gen.encode("ascii"))
            try:
                size = os.stat(p["log"]).st_size
            except FileNotFoundError:
                size = 0
            if size > limit:
                os.replace(p["log"], p["rot"])
                lines = _read_tail_lines(p["rot"], 10 ** 6, max_bytes=max(1, limit // 2))
                seed = "--- более ранние сообщения обрезаны ---".encode("utf-8") + b"\n"
                if lines:
                    seed += b"\n".join(lines) + b"\n"
                _write_file(p["seed"], seed)
                _unlink(p["rot"])
                gen = _new_gen()
                _write_file(p["gen"], gen.encode("ascii"))
                try:
                    size = os.stat(p["log"]).st_size
                except FileNotFoundError:
                    size = 0
            reset = client_gen != gen or client_offset < 0 or client_offset > size
            offset = 0 if reset else client_offset
            seed_text = None
            if reset:
                with open(p["seed"], "rb") as f:
                    seed_text = _decode(f.read())
            chunk = b""
            if offset < size:
                with open(p["log"], "rb") as f:
                    f.seek(offset)
                    chunk = f.read(min(read_max, size - offset))
                cut = chunk.rfind(b"\n")
                chunk = chunk[:cut + 1] if cut >= 0 else b""
        finally:
            fcntl.flock(lockf, fcntl.LOCK_UN)
    new_offset = offset + len(chunk)
    result = {
        "gen": gen,
        "offset": new_offset,
        "reset": reset,
        "text": _decode(chunk),
        "more": new_offset < size and len(chunk) > 0,
    }
    if reset:
        result["seed"] = seed_text
    return result


def parse_args(argv):
    opts = {"bind": "0.0.0.0", "port": None, "docroot": None, "conf": None}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "-p" and i + 1 < len(argv):
            bind_port = argv[i + 1]
            if ":" in bind_port:
                opts["bind"], port_str = bind_port.rsplit(":", 1)
            else:
                port_str = bind_port
            opts["port"] = int(port_str)
            i += 2
        elif arg == "-h" and i + 1 < len(argv):
            opts["docroot"] = argv[i + 1]
            i += 2
        elif arg == "-c" and i + 1 < len(argv):
            opts["conf"] = argv[i + 1]
            i += 2
        elif arg == "-f":
            i += 1
        else:
            i += 1
    if opts["port"] is None or opts["docroot"] is None:
        sys.stderr.write("usage: stats_httpd.py -p BIND:PORT -h DOCROOT [-c CONFFILE] [-f]\n")
        sys.exit(2)
    return opts


def guess_content_type(path):
    if path.endswith(".html") or path.endswith(".htm"):
        return "text/html; charset=utf-8"
    if path.endswith(".css"):
        return "text/css; charset=utf-8"
    if path.endswith(".js"):
        return "application/javascript; charset=utf-8"
    if path.endswith(".svg"):
        return "image/svg+xml"
    if path.endswith(".json"):
        return "application/json; charset=utf-8"
    return "application/octet-stream"


# Файлы интерфейса: URL без "/" -> имя файла в каталоге приложения.
STATIC_FILES = {
    "index.html": "stats_index.html",
    "style.css": "stats_style.css",
    "app.js": "stats_app.js",
    "app-core.js": "stats_app_core.js",
    "app-stats.js": "stats_app_stats.js",
    "app-settings.js": "stats_app_settings.js",
    "app-updates.js": "stats_app_updates.js",
    "app-log.js": "stats_app_log.js",
    "app-config.js": "stats_app_config.js",
    "codemirror.js": "stats_codemirror.js",
    "codemirror.css": "stats_codemirror.css",
}

# Файлы интерфейса доступны без входа: экран входа - тот же SPA.
PUBLIC_ASSETS = set(STATIC_FILES) | {"favicon.ico"}

# Данные, которые пишет speedtest2.sh в docroot.
DATA_FILES = {
    "api/stats": "stats.json",
}


def progress_path():
    # Прогресс текущего прогона пишется после каждой ноды - держим его в
    # RAM, а не на USB. Путь тот же, что STATS_PROGRESS в speedtest2.sh
    # (stats_service.sh экспортирует его серверу).
    return os.environ.get("STATS_PROGRESS") or os.path.join(
        os.environ.get("TMPROOT", "/tmp"), "mihomo-speedtest-progress.json")

# API на скриптах: URL -> (скрипт в каталоге приложения, доп. переменные).
# MST_CGI_TIMEOUT - таймаут скрипта в секундах (по умолчанию 30).
API_ROUTES = {
    "api/run": ("stats_run.sh", {}),
    "api/settings": ("stats_cgi.sh", {"API_JSON": "1"}),
    # check синхронно качает манифест, хеши и заметки релиза с GitHub -
    # на медленном канале роутера 30 с не хватало.
    "api/updates/check": ("stats_update.sh", {"MST_UPDATE_ACTION": "check", "MST_CGI_TIMEOUT": "120"}),
    "api/updates/status": ("stats_update.sh", {"MST_UPDATE_ACTION": "status"}),
    "api/updates/prepare": ("stats_update.sh", {"MST_UPDATE_ACTION": "prepare"}),
    "api/updates/apply": ("stats_update.sh", {"MST_UPDATE_ACTION": "apply"}),
    "api/updates/discard": ("stats_update.sh", {"MST_UPDATE_ACTION": "discard"}),
    # Применение конфига ждёт mihomo -t, xkeen -restart, проверку ядра и
    # при провале - откат, поэтому таймауты больше.
    "api/config": ("stats_config.sh", {"MST_CONFIG_ACTION": "read"}),
    "api/config/backups": ("stats_config.sh", {"MST_CONFIG_ACTION": "backups"}),
    "api/config/backup": ("stats_config.sh", {"MST_CONFIG_ACTION": "backup"}),
    "api/config/check": ("stats_config.sh", {"MST_CONFIG_ACTION": "check"}),
    "api/config/repair": ("stats_config.sh", {"MST_CONFIG_ACTION": "repair", "MST_CGI_TIMEOUT": "60"}),
    "api/config/save": ("stats_config.sh", {"MST_CONFIG_ACTION": "save", "MST_CGI_TIMEOUT": "150"}),
    "api/config/restore": ("stats_config.sh", {"MST_CONFIG_ACTION": "restore", "MST_CGI_TIMEOUT": "150"}),
    "api/config/restore-working": ("stats_config.sh", {"MST_CONFIG_ACTION": "restore-working", "MST_CGI_TIMEOUT": "300"}),
    "api/config/log": ("stats_config.sh", {"MST_CONFIG_ACTION": "log"}),
}


def make_handler(docroot, state_dir=None, runtime_dir=None, app_dir=None):
    docroot = os.path.normpath(docroot)
    app_dir = os.path.normpath(
        app_dir or os.environ.get("STATS_APP_DIR") or os.path.dirname(os.path.abspath(__file__))
    )
    state_dir = state_dir or os.environ.get(
        "STATS_AUTH_STATE_DIR", os.path.join(os.environ.get("DIR", os.path.dirname(__file__)), ".stats-auth")
    )
    runtime_dir = runtime_dir or os.environ.get(
        "STATS_AUTH_RUNTIME_DIR", "/tmp/mihomo-speedtest-auth"
    )

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "stats_httpd.py/1"
        protocol_version = "HTTP/1.1"
        # Без этого таймаута сокет не имеет ограничения по времени ни на
        # одном чтении - обнаружено на реальном роутере: одно повисшее
        # keep-alive-соединение (HTTP/1.1 держит его открытым между
        # запросами) заблокировало ВЕСЬ процесс на неопределённый срок -
        # ни один новый клиент, включая localhost, не мог достучаться,
        # хотя порт оставался в состоянии LISTEN (см. CHANGELOG). Значение
        # берётся из stdlib: BaseHTTPRequestHandler.handle_one_request()
        # сам ловит socket.timeout и корректно закрывает соединение, если
        # этот атрибут не None - здесь только включаем эту защиту.
        # STATS_HTTPD_READ_TIMEOUT позволяет тестам подставить маленькое
        # значение вместо ожидания секунд по умолчанию.
        timeout = int(os.environ.get("STATS_HTTPD_READ_TIMEOUT", "30"))

        # Остановка сервиса и keep-alive (см. _child_on_term() ниже): пока
        # ребёнок ждёт СЛЕДУЮЩИЙ запрос по keep-alive-соединению, он
        # простаивает (_CHILD_BUSY=False) и по TERM завершается сразу; пока
        # обрабатывает запрос - дописывает ответ и закрывает соединение.
        def handle_one_request(self):
            global _CHILD_BUSY
            _CHILD_BUSY = False
            if _STOPPING:
                self.close_connection = True
                return
            try:
                super().handle_one_request()
            finally:
                _CHILD_BUSY = False
                if _STOPPING:
                    self.close_connection = True

        def parse_request(self):
            # Вызывается stdlib сразу после чтения строки запроса - с этого
            # момента соединение "занято" и TERM не должен обрывать ответ.
            global _CHILD_BUSY
            _CHILD_BUSY = True
            return super().parse_request()

        def log_message(self, fmt, *args):
            pass  # тихо - лог уже ведёт speedtest2.sh поверх stdout/stderr процесса

        def _normalize_rel(self, url_path):
            # Возвращает (rel, ok). rel - путь без ведущего "/", None -
            # корень. ok=False - попытка выйти наверх через "..". Файлы
            # по rel напрямую не открываются: только через таблицы
            # STATIC_FILES/DATA_FILES/API_ROUTES.
            raw = urllib.parse.unquote(url_path.split("?", 1)[0])
            rel = os.path.normpath(raw).lstrip("/\\")
            if rel in ("", "."):
                return None, True
            if rel == ".." or rel.startswith(".." + os.sep):
                return None, False
            return rel, True

        def _send_simple(self, status, content_type, body_bytes):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body_bytes)))
            # Без ETag/Last-Modified (их этот сервер не отдаёт) браузер не
            # может ничего сверить и в их отсутствие иногда просто отдаёт
            # старую версию app.js/style.css/index.html из диска - на
            # практике так и произошло: правка графика по нодам работала
            # только в приватном окне (пустой кэш), в обычном браузер
            # продолжал показывать старый файл. no-store - на каждый
            # запрос идти в сеть, не сохраняя ответ в кэше вовсе; для
            # админки роутера с низкой нагрузкой безопаснее, чем городить
            # условные запросы, которые этот сервер не поддерживает.
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if body_bytes and self.command != "HEAD":
                self.wfile.write(body_bytes)

        def _send_json(self, status, obj):
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self._send_simple(status, "application/json; charset=utf-8", body)

        def _send_json_with_headers(self, status, obj, headers=()):
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for name, value in headers:
                self.send_header(name, value)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _redirect(self, location):
            self.send_response(302)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()

        def _auth_mode(self):
            credentials = stats_auth.load_credentials(state_dir)
            if credentials is not None:
                return "login", credentials
            if stats_auth.is_setup_pending(state_dir):
                return "setup", None
            return "uninitialized", None

        def _session_token(self):
            raw = self.headers.get("Cookie", "")
            try:
                cookie = SimpleCookie()
                cookie.load(raw)
                morsel = cookie.get(AUTH_COOKIE)
                return morsel.value if morsel is not None else None
            except Exception:
                return None

        def _session(self):
            token = self._session_token()
            if token is None:
                return None
            return stats_auth.load_session(runtime_dir, token)

        def _cookie_header(self, token, clear=False):
            value = "%s=%s; Path=/; HttpOnly; SameSite=Strict" % (AUTH_COOKIE, token)
            if clear:
                value += "; Max-Age=0"
            return value

        def _read_json(self):
            raw_length = self.headers.get("Content-Length", "0") or "0"
            try:
                length = int(raw_length)
            except ValueError:
                self._send_json(400, {"error": "invalid_request"})
                return None
            if length < 0:
                self._send_json(400, {"error": "invalid_request"})
                return None
            if length > AUTH_BODY_LIMIT:
                self._send_json(413, {"error": "request_too_large"})
                return None
            try:
                payload = self.rfile.read(length)
                value = json.loads(payload.decode("utf-8"))
            except (OSError, UnicodeError, ValueError):
                self._send_json(400, {"error": "invalid_json"})
                return None
            if not isinstance(value, dict):
                self._send_json(400, {"error": "invalid_request"})
                return None
            return value

        def _rate_limit(self, bucket, limit, window):
            allowed, retry_after = stats_auth.consume_rate_limit(
                runtime_dir, bucket, self.client_address[0], limit, window
            )
            if not allowed:
                self._send_json_with_headers(
                    429, {"error": "rate_limited"}, (("Retry-After", str(retry_after)),)
                )
                return False
            return True

        def _handle_auth_api(self, rel):
            mode, credentials = self._auth_mode()
            session = self._session() if mode == "login" else None

            if rel == "api/auth/status" and self.command in ("GET", "HEAD"):
                if mode == "uninitialized":
                    self._send_json(503, {"mode": "uninitialized", "error": "auth_not_initialized"})
                elif session is not None:
                    self._send_json(200, {
                        "mode": "authenticated", "username": session["username"],
                        "csrf": session["csrf"],
                    })
                else:
                    self._send_json(200, {"mode": mode})
                return True

            if rel == "api/auth/setup" and self.command == "POST":
                if mode != "setup":
                    self._send_json(409, {"error": "setup_unavailable"})
                    return True
                if not self._rate_limit("setup", 5, 600):
                    return True
                value = self._read_json()
                if value is None:
                    return True
                code = value.get("code")
                username = value.get("username")
                password = value.get("password")
                confirmation = value.get("password_confirm")
                if not all(isinstance(item, str) for item in (code, username, password, confirmation)):
                    self._send_json(400, {"error": "invalid_request"})
                    return True
                if password != confirmation:
                    self._send_json(400, {"error": "password_mismatch"})
                    return True
                try:
                    created = stats_auth.complete_setup_and_create_session(
                        state_dir, runtime_dir, code, username, password
                    )
                except ValueError:
                    self._send_json(401, {"error": "invalid_setup"})
                    return True
                self._send_json_with_headers(
                    200, {"mode": "authenticated", "username": username, "csrf": created["csrf"]},
                    (("Set-Cookie", self._cookie_header(created["id"])),),
                )
                return True

            if rel == "api/auth/login" and self.command == "POST":
                if mode != "login":
                    self._send_json(409, {"error": "login_unavailable"})
                    return True
                if not self._rate_limit("login", 5, 300):
                    return True
                value = self._read_json()
                if value is None:
                    return True
                created = stats_auth.authenticate_and_create_session(
                    state_dir, runtime_dir, value.get("username"), value.get("password")
                )
                if created is None:
                    self._send_json(401, {"error": "invalid_credentials"})
                    return True
                self._send_json_with_headers(
                    200, {"mode": "authenticated", "username": credentials["username"], "csrf": created["csrf"]},
                    (("Set-Cookie", self._cookie_header(created["id"])),),
                )
                return True

            if rel == "api/auth/logout" and self.command == "POST":
                if session is None:
                    self._send_json(401, {"error": "authentication_required"})
                    return True
                if not stats_auth.verify_csrf(session, self.headers.get("X-CSRF-Token", "")):
                    self._send_json(403, {"error": "invalid_csrf"})
                    return True
                token = self._session_token()
                stats_auth.destroy_session(runtime_dir, token)
                self._send_json_with_headers(
                    200, {"ok": True},
                    (("Set-Cookie", self._cookie_header("", clear=True)),),
                )
                return True

            if rel.startswith("api/auth/"):
                self._send_json(404, {"error": "not_found"})
                return True
            return False

        def _authorize(self, rel):
            mode, _ = self._auth_mode()
            session = self._session() if mode == "login" else None
            is_api = rel is not None and rel.startswith("api/")
            is_asset = rel in PUBLIC_ASSETS
            page = rel or ""
            is_mutating = self.command in ("POST", "PUT", "PATCH", "DELETE")

            if is_asset or page in ("setup", "login"):
                if is_mutating:
                    if session is None:
                        self._send_json(401, {"error": "authentication_required"})
                    elif not stats_auth.verify_csrf(
                        session, self.headers.get("X-CSRF-Token", "")
                    ):
                        self._send_json(403, {"error": "invalid_csrf"})
                    else:
                        self._send_json(405, {"error": "method_not_allowed"})
                    return None
                if session is not None and page in ("setup", "login"):
                    self._redirect("/")
                    return None
                if mode == "setup" and page == "login":
                    self._redirect("/setup")
                    return None
                if mode == "login" and page == "setup":
                    self._redirect("/login")
                    return None
                return session or False

            if mode == "uninitialized":
                if is_api:
                    self._send_json(503, {"error": "auth_not_initialized"})
                else:
                    self._send_simple(503, "text/plain; charset=utf-8", b"Authorization is not initialized. Run stats_auth.sh reset.\n")
                return None
            if session is None:
                if is_api:
                    self._send_json(401, {"error": "authentication_required"})
                else:
                    self._redirect("/setup" if mode == "setup" else "/login")
                return None
            if self.command in ("POST", "PUT", "PATCH", "DELETE") and not stats_auth.verify_csrf(
                session, self.headers.get("X-CSRF-Token", "")
            ):
                self._send_json(403, {"error": "invalid_csrf"})
                return None
            return session

        def _run_script(self, full_path, extra_env=None):
            parsed = urllib.parse.urlsplit(self.path)
            try:
                length = int(self.headers.get("Content-Length", "0") or "0")
            except ValueError:
                length = -1
            if length < 0:
                self._send_json(400, {"error": "invalid_content_length"})
                return
            if length > SCRIPT_BODY_LIMIT:
                self._send_json(413, {"error": "request_too_large"})
                return
            # Content-Length может быть враньём клиента (случайным или нет)
            # - без self.timeout (см. класс Handler выше) чтение тела ждало
            # бы недостающие байты бесконечно, вешая процесс целиком на
            # этом единственном соединении. При таймауте отвечаем 408, а не
            # роняем необработанным исключением - это ожидаемая ситуация
            # для внешнего клиента, а не баг сервера.
            try:
                body = self.rfile.read(length) if length > 0 else b""
            except OSError as exc:
                self._send_simple(408, "text/plain; charset=utf-8",
                                   ("Request timeout: %s\n" % exc).encode())
                return
            env = os.environ.copy()
            env["REQUEST_METHOD"] = self.command
            env["CONTENT_LENGTH"] = str(length)
            env["CONTENT_TYPE"] = self.headers.get("Content-Type", "")
            env["QUERY_STRING"] = parsed.query
            env["SCRIPT_NAME"] = parsed.path
            env["SERVER_SOFTWARE"] = self.server_version
            env["REMOTE_ADDR"] = self.client_address[0]
            if extra_env:
                # Доп. переменные из API_ROUTES (например API_JSON=1).
                env.update(extra_env)
            # По умолчанию 30 с; долгим действиям API_ROUTES задаёт свой
            # MST_CGI_TIMEOUT.
            try:
                cgi_timeout = int((extra_env or {}).get("MST_CGI_TIMEOUT", "30"))
            except ValueError:
                cgi_timeout = 30
            try:
                proc = subprocess.run(
                    [full_path],
                    env=env,
                    input=body,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    cwd=app_dir,
                    timeout=cgi_timeout,
                )
            except Exception as exc:
                self._send_simple(500, "text/plain; charset=utf-8", ("CGI error: %s\n" % exc).encode())
                return
            out = proc.stdout
            if b"\r\n\r\n" in out:
                head, _, cgi_body = out.partition(b"\r\n\r\n")
            elif b"\n\n" in out:
                head, _, cgi_body = out.partition(b"\n\n")
            else:
                head, cgi_body = b"", out
            status = 200
            headers = []
            for line in head.decode("utf-8", "replace").splitlines():
                if not line.strip():
                    continue
                name, sep, value = line.partition(":")
                if not sep:
                    continue
                name = name.strip()
                value = value.strip()
                if name.lower() == "status":
                    try:
                        status = int(value.split()[0])
                    except (ValueError, IndexError):
                        pass
                else:
                    headers.append((name, value))
            self.send_response(status)
            for name, value in headers:
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(cgi_body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(cgi_body)

        def _serve_file(self, full_path):
            try:
                with open(full_path, "rb") as f:
                    data = f.read()
            except OSError:
                self._send_simple(500, "text/plain; charset=utf-8", b"500 internal error\n")
                return
            self._send_simple(200, guess_content_type(full_path), data)

        def _serve_index(self):
            if self.command not in ("GET", "HEAD"):
                self._send_simple(404, "text/plain; charset=utf-8", b"404 not found\n")
                return
            index_path = os.path.join(app_dir, STATIC_FILES["index.html"])
            if not os.path.isfile(index_path):
                self._send_simple(404, "text/plain; charset=utf-8", b"404 not found\n")
                return
            self._serve_file(index_path)

        def _handle_live_log(self):
            # Живой журнал, см. live_log_poll(). Доступ - только после
            # _authorize(), как у остальных /api/*.
            if self.command not in ("GET", "HEAD"):
                self._send_json_with_headers(405, {"error": "method_not_allowed"}, (("Allow", "GET, HEAD"),))
                return
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            client_gen = (query.get("gen") or [""])[0]
            try:
                client_offset = int((query.get("offset") or ["0"])[0])
            except ValueError:
                client_offset = -1
            try:
                result = live_log_poll(client_gen, client_offset)
            except OSError as e:
                self._send_json_with_headers(503, {"error": "live_log_unavailable", "detail": str(e)})
                return
            self._send_json_with_headers(200, result)

        def _handle(self):
            rel, ok = self._normalize_rel(self.path)
            if not ok:
                self._send_simple(403, "text/plain; charset=utf-8", b"403 forbidden\n")
                return

            if rel is not None and self._handle_auth_api(rel):
                return

            if self._authorize(rel) is None:
                return

            if rel == "api/log":
                self._handle_live_log()
                return

            if rel == "api/system":
                if self.command not in ("GET", "HEAD"):
                    self._send_json_with_headers(405, {"error": "method_not_allowed"}, (("Allow", "GET, HEAD"),))
                    return
                self._send_json_with_headers(200, system_status())
                return

            if rel in API_ROUTES:
                script, env = API_ROUTES[rel]
                path = os.path.join(app_dir, script)
                if not os.path.isfile(path):
                    self._send_json(503, {"error": "script_missing", "script": script})
                    return
                self._run_script(path, env)
                return

            if rel in DATA_FILES or rel == "api/progress":
                if self.command not in ("GET", "HEAD"):
                    self._send_json_with_headers(405, {"error": "method_not_allowed"}, (("Allow", "GET, HEAD"),))
                    return
                if rel == "api/progress":
                    path = progress_path()
                else:
                    path = os.path.join(docroot, DATA_FILES[rel])
                if os.path.isfile(path):
                    self._serve_file(path)
                else:
                    self._send_json(200, {})
                return

            if rel is not None and rel.split("/", 1)[0] == "api":
                self._send_json(501, {"error": "not_implemented", "path": "/" + rel})
                return

            if rel is not None and rel.split("/", 1)[0] == "cgi-bin":
                self._send_simple(404, "text/plain; charset=utf-8", b"404 not found\n")
                return

            if rel in STATIC_FILES and self.command in ("GET", "HEAD"):
                path = os.path.join(app_dir, STATIC_FILES[rel])
                if os.path.isfile(path):
                    self._serve_file(path)
                    return

            self._serve_index()

        def do_GET(self):
            self._handle()

        def do_POST(self):
            self._handle()

        def do_HEAD(self):
            self._handle()

        def do_PUT(self):
            self._handle()

        def do_PATCH(self):
            self._handle()

        def do_DELETE(self):
            self._handle()

    return Handler


# Состояние остановки для процесса-обработчика соединения (ребёнка после
# fork) - см. _child_on_term() и Handler.handle_one_request().
_STOPPING = False
_CHILD_BUSY = False


def _child_on_term(signum, frame):
    # TERM в ребёнке (его шлёт родитель из _on_term() при остановке службы).
    # Простаивающее keep-alive-соединение закрываем немедленно - иначе
    # открытая вкладка панели, опрашивающая сервер каждые 2 с, держала бы
    # ребёнка живым бесконечно (таймаут простоя не наступает), и после
    # "S80speedtest-stats stop"/uninstall.sh веб-интерфейс продолжал бы
    # отвечать по старому соединению. Запрос, который уже обрабатывается,
    # дописываем до конца (на это полагается self-restart - см. шапку
    # файла) и только потом закрываем соединение.
    global _STOPPING
    _STOPPING = True
    if not _CHILD_BUSY:
        os._exit(0)


class ForkingHTTPServer(socketserver.ForkingMixIn, http.server.HTTPServer):
    # ForkingMixIn - см. пояснение в шапке файла про self-restart.
    allow_reuse_address = True
    daemon_threads = False
    _live_log_checked = 0.0

    def service_actions(self):
        # Вызывается serve_forever() в родительском процессе примерно раз в
        # poll_interval (0,5 с) - здесь без лишних потоков раз в 5 секунд
        # прекращаем сбор живого журнала, если страницу «Журнал» закрыли.
        super().service_actions()
        now = time.time()
        if now - self._live_log_checked >= 5:
            self._live_log_checked = now
            try:
                live_log_cleanup(now=now)
            except OSError:
                pass

    def process_request(self, request, client_address):
        # Переопределяем socketserver.ForkingMixIn.process_request(): в
        # оригинале дочерний процесс НЕ закрывает self.socket - слушающий
        # сокет, принимающий НОВЫЕ соединения на STATS_HTTP_BIND:PORT. После
        # fork() он открыт в обоих процессах (fork дублирует все файловые
        # дескрипторы), и ребёнку он не нужен - но пока ребёнок жив, этот
        # дескриптор держит порт занятым, даже если родительский процесс уже
        # убит (например, supervisor перезапускает сервер на новый адрес/порт
        # или после обновления кода).
        #
        # На практике это давало на роутере полностью недоступный веб-сервис
        # после setup.sh: клиент держал соединение открытым без завершения
        # тела запроса (см. STATS_HTTPD_READ_TIMEOUT выше - без него чтение
        # тела в _run_script() могло ждать вечно), speedtest2.sh перезапускал
        # сервис и убивал СТАРЫЙ родительский pid из pidfile - но зависший
        # ребёнок пережил родителя и продолжал слушать порт, так что НОВЫЙ
        # процесс (что python3, что резервный busybox httpd) не мог
        # забиндиться на тот же адрес: "OSError: [Errno 125] Address already
        # in use" в stats_httpd.log (125 - это EADDRINUSE на MIPS, на
        # x86/ARM тот же код ошибки - 98; в обоих случаях суть одна). При
        # этом "netstat" продолжал показывать порт как LISTEN (сокет-то у
        # ребёнка открыт), только Recv-Q рос, а не отдавался ни один запрос -
        # ни новый процесс не поднимался, ни старый (зависший) ничего не
        # принимал.
        #
        # Фикс - закрыть self.socket в РЕБЁНКЕ сразу после fork(): для
        # обработки уже принятого соединения (request) слушающий сокет не
        # нужен. Дальше - копия socketserver.ForkingMixIn.process_request()
        # из стандартной библиотеки.
        # TERM блокируется на время fork(), чтобы ребёнок не получил его,
        # пока ещё действует унаследованный родительский обработчик
        # (_on_term() в ребёнке разослал бы TERM "братьям" по копии
        # active_children). Ребёнок ставит свой обработчик и снимает блок.
        masked = _block_term()
        try:
            pid = os.fork()
        except BaseException:
            _unblock_term(masked)
            raise
        if pid:
            _unblock_term(masked)
            # Родитель - как в оригинале: просто регистрирует ребёнка и
            # закрывает СВОЮ копию request (не листенер, а принятое
            # соединение - им теперь занимается ребёнок). active_children -
            # ленивая инициализация (None до первого ребёнка), как в
            # socketserver.ForkingMixIn - без этой проверки первый же запрос
            # падал с "TypeError: argument of type 'NoneType' is not
            # iterable" ДО close_request(), а последующий handle_error()/
            # shutdown_request() в родителе вызывает socket.shutdown() на
            # СЕТЕВОМ соединении, разделяемом с ребёнком (fork дублирует
            # дескриптор, но не сам сокет) - ребёнок в этот момент ловил
            # "BrokenPipeError" при попытке ответить клиенту, то есть
            # вообще ни один запрос не обслуживался.
            if self.active_children is None:
                self.active_children = set()
            self.active_children.add(pid)
            self.close_request(request)
            return
        # Ребёнок - никогда не возвращается, только os._exit() в finally.
        signal.signal(signal.SIGTERM, _child_on_term)
        _unblock_term(masked)
        try:
            self.socket.close()
        except OSError:
            pass
        try:
            self.finish_request(request, client_address)
            status = 0
        except Exception:
            self.handle_error(request, client_address)
            status = 1
        finally:
            try:
                self.shutdown_request(request)
            finally:
                os._exit(status)


def _block_term():
    if hasattr(signal, "pthread_sigmask"):
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
        return True
    return False


def _unblock_term(masked):
    if masked:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})


def _install_parent_term(server):
    # TERM в родителе-слушателе (supervisor в stats_service.sh гасит им
    # бэкенд при stop/restart/reconfigure, в т.ч. из uninstall.sh): сначала
    # рассылаем TERM всем живым детям-обработчикам соединений - иначе они
    # переживают родителя и продолжают отвечать по keep-alive (см.
    # _child_on_term()), - затем завершаемся так же, как без обработчика
    # (смерть от сигнала TERM, код для wait в supervisor не меняется).
    def _on_term(signum, frame):
        for pid in list(server.active_children or ()):
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGTERM)

    signal.signal(signal.SIGTERM, _on_term)


def main(argv):
    opts = parse_args(argv)
    handler = make_handler(opts["docroot"])
    server = ForkingHTTPServer((opts["bind"], opts["port"]), handler)
    _install_parent_term(server)
    try:
        live_log_cleanup(force=True)   # хвосты прошлого запуска сервера
    except OSError:
        pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main(sys.argv[1:])
