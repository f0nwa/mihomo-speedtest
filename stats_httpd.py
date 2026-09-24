#!/usr/bin/env python3
"""Веб-сервер веб-сервиса статистики speedtest2 (см. README, раздел про
stats_www). Ставится install.sh как $DIR/stats_httpd.py; start_backend()
в stats_service.sh (независимая служба, порция 3) запускает его теми же
аргументами, что и "busybox httpd".

С шага 5 SPA-миграции (см.
docs/plans/2026-09-12-web-spa-migration-design.md, решение по
python3-зависимости - вариант 2, деградация) это ОСНОВНОЙ сервер: только
он умеет чистые URL (/, /stats, /settings) и /api/* (см. ниже).
"busybox httpd" остаётся резервным вариантом на роутерах без python3 -
start_backend() переходит на него автоматически, если этот файл не найден
или сам python3 не установлен; тогда работают только старые адреса
/stats.html и /cgi-bin/*, без чистых URL.

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

Маршрутизация "чистых" URL (добавлено 2026-09-12, см. design-док выше -
шаг 1 из плана миграции, дальше в шагах 2-6):
  - "/api/run" - внутренний алиас на "cgi-bin/run": дальше запрос идёт по
    тому же пути, что и раньше "/cgi-bin/run" (сам stats_run.sh не менялся)
    и под общей сессионной защитой.
  - "/api/settings" - внутренний алиас на "cgi-bin/config" с добавленной
    переменной окружения API_JSON=1 - по ней stats_cgi.sh печатает JSON
    вместо HTML-формы (см. шаг 3 design-дока и его же "Статус выполнения
    шага 4"): GET отдаёт текущие значения полей, POST - результат
    валидации/сохранения.
  - "/api/stats" - внутренний алиас на статический "stats.json" в
    docroot, который render_stats() в speedtest2.sh пишет рядом со
    stats.html (тот же awk, режим -v format=json - см. шаг 2). Не CGI -
    обычная раздача файла, данные всегда посчитаны заранее, а не по
    запросу.
  - "/api/progress" - внутренний алиас на статический "progress.json" в
    docroot: прогресс скоростного теста по нодам ТЕКУЩЕГО прогона (шаг 1
    задачи "видно по нодам при прогоне" - см. CHANGELOG.md), который
    write_progress() в speedtest2.sh пишет после каждой протестированной
    ноды. Тоже не CGI, обычная раздача файла - как и "/api/stats", без
    отдельного CGI-процесса. Файла может не быть вовсе, если ещё
    ни разу не было прогона с этой версией speedtest2.sh - тогда ТА ЖЕ
    особенность, что и у "/api/stats": SPA-фоллбек (_spa_fallback) не
    отличает "путь из API_ALIASES без файла-цели" от обычной навигации и
    отдаёт index.html с кодом 200 вместо 404 (см. _handle() ниже - алиас
    подставляется ДО проверки на "api/", различить их там уже нельзя).
    Существующее поведение, не новое - фронтенд должен сам отличать JSON
    от HTML в ответе (Content-Type или неудачный JSON.parse), а не
    полагаться на код ответа.
  - "/api/updates/check", "/api/updates/status", "/api/updates/prepare",
    "/api/updates/apply", "/api/updates/discard" - внутренние алиасы на
    один и тот же CGI-скрипт "cgi-bin/update" (копия stats_update.sh,
    кладётся write_stats_update() в speedtest2.sh - раздел "Обновления"),
    различаются только переменной окружения MST_UPDATE_ACTION
    ("check"/"status"/"prepare"/"apply"/"discard" соответственно) - тем же
    приёмом, что уже используется у "/api/settings" с API_JSON=1. Сам
    stats_update.sh решает по MST_UPDATE_ACTION и REQUEST_METHOD, какую
    команду update.sh вызвать (см. stats_update.sh и спеку раздела
    "Веб-флоу") - здесь, в stats_httpd.py, только маршрутизация под общей
    сессией/CSRF, без отдельной логики авторизации.
  - "/api/..." (всё остальное) - алиасов нет, отвечает JSON с кодом 501,
    а не 404, чтобы фронтенд мог отличить "эндпоинт ещё не существует" от
    обрыва сети или опечатки в пути.
  - "/", "/stats", "/settings" и вообще любой GET/HEAD, не попавший ни в
    файл в docroot, ни в один из путей выше, - отдаёт "index.html"
    (SPA-shell) с кодом 200, если он есть в docroot (SPA-фоллбек: клиентский
    роутер сам решает, что показать, по location.pathname). Если
    index.html ещё не установлен (роутер не обновлял install.sh) - как и
    раньше, для корня подставляется "stats.html", если он на месте, а для
    остальных путей - обычный 404. Ничего не ломает для тех, у кого этих
    новых файлов ещё нет.
"""
import http.server
import json
import os
import socketserver
import subprocess
import sys
import urllib.parse
from http.cookies import SimpleCookie

import stats_auth


AUTH_COOKIE = "mst_session"
AUTH_BODY_LIMIT = 16 * 1024
PUBLIC_ASSETS = {"index.html", "style.css", "app.js", "chart.js", "favicon.ico"}


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


# Внутренние алиасы "чистых" API-путей на существующие файлы/cgi-bin-скрипты
# (см. шапку файла). Ключ - относительный путь без ведущего "/", в том
# виде, в котором его возвращает Handler._normalize_rel(). Значение -
# пара (target_rel, extra_env): target_rel - на что заменить путь дальше
# по коду (тот же формат, без ведущего "/"), extra_env - дополнительные
# переменные окружения, которые нужно добавить, если target_rel окажется
# CGI (для обычного файла extra_env просто не используется). Раскрывать
# такие алиасы нужно раскрывать до решения "это /api/*, без
# алиаса" - только тогда, например, запрос к "/api/run" пройдёт по тем же
# правилам защиты и исполнения, что и "/cgi-bin/run" сегодня.
API_ALIASES = {
    "api/run": ("cgi-bin/run", {}),
    "api/settings": ("cgi-bin/config", {"API_JSON": "1"}),
    "api/stats": ("stats.json", {}),
    "api/progress": ("progress.json", {}),
    "api/updates/check": ("cgi-bin/update", {"MST_UPDATE_ACTION": "check"}),
    "api/updates/status": ("cgi-bin/update", {"MST_UPDATE_ACTION": "status"}),
    "api/updates/prepare": ("cgi-bin/update", {"MST_UPDATE_ACTION": "prepare"}),
    "api/updates/apply": ("cgi-bin/update", {"MST_UPDATE_ACTION": "apply"}),
    "api/updates/discard": ("cgi-bin/update", {"MST_UPDATE_ACTION": "discard"}),
}


def make_handler(docroot, state_dir=None, runtime_dir=None):
    docroot = os.path.normpath(docroot)
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

        def log_message(self, fmt, *args):
            pass  # тихо - лог уже ведёт speedtest2.sh поверх stdout/stderr процесса

        def _normalize_rel(self, url_path):
            # Возвращает (rel, ok). rel - путь относительно docroot без
            # ведущего "/", None означает запрос корня ("" или ".").
            # ok=False - попытка выйти за пределы docroot через ".." -
            # проверяется по самой строке пути, а не после join+normpath,
            # чтобы решение "отклонить" не зависело от того, существует ли
            # там что-нибудь физически (защита от race и от особенностей
            # symlink), и чтобы этот же rel можно было безопасно сверять с
            # API_ALIASES/префиксом "api/" ещё до похода в файловую систему.
            raw = urllib.parse.unquote(url_path.split("?", 1)[0])
            rel = os.path.normpath(raw).lstrip("/\\")
            if rel in ("", "."):
                return None, True
            if rel == ".." or rel.startswith(".." + os.sep):
                return None, False
            return rel, True

        def _full_path_for(self, rel):
            # rel уже нормализован _normalize_rel() (или является одним из
            # API_ALIASES) - None здесь означает корень.
            if rel is None:
                for cand in ("index.html", "stats.html"):
                    p = os.path.join(docroot, cand)
                    if os.path.isfile(p):
                        return p
                # Ни одного из двух нет - подставляем index.html: он не
                # существует, но по нему дальше корректно посчитается
                # url_path и решится 404 в общем порядке.
                return os.path.join(docroot, "index.html")
            full = os.path.normpath(os.path.join(docroot, rel))
            if full != docroot and not full.startswith(docroot + os.sep):
                return None
            return full

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
            if body_bytes:
                self.wfile.write(body_bytes)

        def _send_json(self, status, obj):
            # /api/stats и /api/settings реализованы через алиасы на файл/CGI
            # (см. API_ALIASES) - здесь остаётся единственный вызывающий:
            # заглушка "не реализовано" в _handle() для /api/* без алиаса.
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

        def _is_cgi(self, full_path):
            rel_parts = os.path.relpath(full_path, docroot).split(os.sep)
            return len(rel_parts) >= 2 and "cgi-bin" in rel_parts[:-1] and os.access(full_path, os.X_OK)

        def _run_cgi(self, full_path, extra_env=None):
            parsed = urllib.parse.urlsplit(self.path)
            length = int(self.headers.get("Content-Length", "0") or "0")
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
                # Доп. переменные из API_ALIASES (например API_JSON=1 для
                # "/api/settings") - только для алиасов, у обычных
                # "/cgi-bin/..." extra_env пустой/None, поведение не меняется.
                env.update(extra_env)
            try:
                proc = subprocess.run(
                    [full_path],
                    env=env,
                    input=body,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    cwd=os.path.dirname(full_path) or docroot,
                    timeout=30,
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
            self.wfile.write(cgi_body)

        def _serve_file(self, full_path):
            try:
                with open(full_path, "rb") as f:
                    data = f.read()
            except OSError:
                self._send_simple(500, "text/plain; charset=utf-8", b"500 internal error\n")
                return
            self._send_simple(200, guess_content_type(full_path), data)

        def _spa_fallback(self, rel):
            # Только для GET/HEAD - POST на несуществующий путь так и должен
            # оставаться 404, SPA-фоллбек нужен исключительно для того,
            # чтобы переход/обновление страницы браузером на "чистый" путь
            # клиентского роутера (например "/settings") не давал 404. Под
            # "cgi-bin" не подставляем - отсутствующий CGI-скрипт честнее
            # показать как 404, чем как SPA-shell.
            if self.command not in ("GET", "HEAD"):
                return False
            rel_parts = rel.split("/") if rel else []
            if rel_parts and "cgi-bin" in rel_parts[:-1]:
                return False
            index_path = os.path.join(docroot, "index.html")
            if not os.path.isfile(index_path):
                return False
            self._serve_file(index_path)
            return True

        def _handle(self):
            rel, ok = self._normalize_rel(self.path)
            if not ok:
                self._send_simple(403, "text/plain; charset=utf-8", b"403 forbidden\n")
                return

            if rel is not None and self._handle_auth_api(rel):
                return

            if self._authorize(rel) is None:
                return

            if rel == "cgi-bin/config":
                if self.command in ("GET", "HEAD"):
                    self._redirect("/settings")
                else:
                    self._send_json(410, {"error": "legacy_settings_removed"})
                return

            alias_env = None
            if rel is not None and rel in API_ALIASES:
                rel, alias_env = API_ALIASES[rel]

            if rel is not None and rel.split("/", 1)[0] == "api":
                # Сюда попадает только "/api/*" без записи в API_ALIASES -
                # "run"/"settings"/"stats" выше уже заменены на реальный
                # путь. Отвечаем 501, а не 404 - фронтенд должен уметь
                # отличить "эндпоинт ещё не существует" от опечатки в пути.
                self._send_json(501, {"error": "not_implemented", "path": "/" + rel})
                return

            full_path = self._full_path_for(rel)
            if full_path is None:
                self._send_simple(403, "text/plain; charset=utf-8", b"403 forbidden\n")
                return

            if self._is_cgi(full_path):
                self._run_cgi(full_path, alias_env)
                return

            if os.path.isfile(full_path):
                self._serve_file(full_path)
                return

            if self._spa_fallback(rel or ""):
                return

            self._send_simple(404, "text/plain; charset=utf-8", b"404 not found\n")

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


class ForkingHTTPServer(socketserver.ForkingMixIn, http.server.HTTPServer):
    # ForkingMixIn - см. пояснение в шапке файла про self-restart.
    allow_reuse_address = True
    daemon_threads = False

    def process_request(self, request, client_address):
        # Переопределяем socketserver.ForkingMixIn.process_request(): в
        # оригинале дочерний процесс НЕ закрывает self.socket - слушающий
        # сокет, принимающий НОВЫЕ соединения на STATS_HTTP_BIND:PORT. После
        # fork() он открыт в обоих процессах (fork дублирует все файловые
        # дескрипторы), и ребёнку он не нужен - но пока ребёнок жив, этот
        # дескриптор держит порт занятым, даже если родительский процесс уже
        # убит (например, stop_stats_httpd() в speedtest2.sh перед
        # перезапуском на новый адрес/порт или обновление кода).
        #
        # На практике это давало на роутере полностью недоступный веб-сервис
        # после setup.sh: клиент держал соединение открытым без завершения
        # тела запроса (см. STATS_HTTPD_READ_TIMEOUT выше - без него чтение
        # тела в _run_cgi() могло ждать вечно), speedtest2.sh перезапускал
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
        pid = os.fork()
        if pid:
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


def main(argv):
    opts = parse_args(argv)
    handler = make_handler(opts["docroot"])
    server = ForkingHTTPServer((opts["bind"], opts["port"]), handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main(sys.argv[1:])
