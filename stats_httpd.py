#!/usr/bin/env python3
"""Запасной веб-сервер для веб-сервиса статистики speedtest2 (см. README,
раздел про stats_www) - на случай, если busybox на роутере собран без
апплета httpd (бывает на некоторых прошивках Keenetic). Ставится install.sh
как $DIR/stats_httpd.py; ensure_stats_httpd() в speedtest2.sh запускает его
теми же аргументами, что и "busybox httpd", если тот не смог стартовать.

Поддерживает ту часть CLI busybox httpd, которой пользуется этот проект:
  -p BIND:PORT   адрес и порт
  -h DIR         раздаваемый каталог (docroot)
  -c CONFFILE    файл Basic Auth в формате "/путь:логин:пароль" на строку
                 (пишет write_stats_httpd_conf() в speedtest2.sh) - защищает
                 только запросы к путям с этим префиксом, остальное открыто
  -f             без демонизации, для совместимости (этот сервер и так
                 всегда работает на переднем плане - в фон его уводит "&"
                 в speedtest2.sh, как и busybox httpd)

Только стандартная библиотека - на роутере с Entware кроме самого python3
ставить нечего. Целится в Python 3.7+, но написан с оглядкой на 3.13, где
http.server.CGIHTTPRequestHandler и модуль cgi уже удалены (PEP 594) -
поэтому обработка CGI реализована руками через subprocess, без них.

Модель обработки запросов - процесс НА КАЖДОЕ соединение (fork), а не поток
на соединение: self-restart в speedtest2.sh (ensure_stats_httpd() убивает
старый процесс-слушатель и поднимает новый при смене адреса/пароля, обычно
из-под уже принятого HTTP-запроса к форме настройки) полагается на то, что
уже принятое соединение переживает убийство слушателя, отвечая клиенту как
ни в чём не бывало - ровно так же, как это устроено у busybox httpd
(отдельный процесс-обработчик на соединение). При потоках слушатель и
обработчик были бы одним процессом, и kill оборвал бы поток, дописывающий
ответ, вместе со всем остальным.
"""
import base64
import http.server
import os
import socketserver
import subprocess
import sys
import urllib.parse


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


def load_auth_conf(path):
    # Формат "/путь:логин:пароль" на строку. Пустой/отсутствующий файл -
    # без ограничений (как пустой конфиг у busybox httpd).
    rules = []
    if not path or not os.path.isfile(path):
        return rules
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split(":", 2)
            if len(parts) == 3:
                rules.append((parts[0], parts[1], parts[2]))
    return rules


def guess_content_type(path):
    if path.endswith(".html") or path.endswith(".htm"):
        return "text/html; charset=utf-8"
    if path.endswith(".css"):
        return "text/css; charset=utf-8"
    if path.endswith(".js"):
        return "application/javascript; charset=utf-8"
    if path.endswith(".svg"):
        return "image/svg+xml"
    return "application/octet-stream"


def make_handler(docroot, auth_rules):
    docroot = os.path.normpath(docroot)

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "stats_httpd.py/1"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass  # тихо - лог уже ведёт speedtest2.sh поверх stdout/stderr процесса

        def _resolve_path(self, url_path):
            # Без ".." и абсолютных путей за пределы docroot.
            raw = urllib.parse.unquote(url_path.split("?", 1)[0])
            rel = os.path.normpath(raw).lstrip("/\\")
            if rel in ("", "."):
                rel = "stats.html"
            full = os.path.normpath(os.path.join(docroot, rel))
            if full != docroot and not full.startswith(docroot + os.sep):
                return None
            return full

        def _url_path_of(self, full_path):
            rel = os.path.relpath(full_path, docroot).replace(os.sep, "/")
            return "/" + rel

        def _auth_required_for(self, url_path):
            for prefix, user, pw in auth_rules:
                prefix_slash = prefix.rstrip("/") + "/"
                if url_path == prefix or url_path.startswith(prefix_slash):
                    return (user, pw)
            return None

        def _has_valid_auth(self, user, pw):
            hdr = self.headers.get("Authorization", "")
            if not hdr.startswith("Basic "):
                return False
            try:
                decoded = base64.b64decode(hdr[6:].strip()).decode("utf-8", "replace")
            except Exception:
                return False
            return decoded == "%s:%s" % (user, pw)

        def _send_simple(self, status, content_type, body_bytes):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            if body_bytes:
                self.wfile.write(body_bytes)

        def _send_auth_challenge(self):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="stats"')
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _is_cgi(self, full_path):
            rel_parts = os.path.relpath(full_path, docroot).split(os.sep)
            return len(rel_parts) >= 2 and "cgi-bin" in rel_parts[:-1] and os.access(full_path, os.X_OK)

        def _run_cgi(self, full_path):
            parsed = urllib.parse.urlsplit(self.path)
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(length) if length > 0 else b""
            env = os.environ.copy()
            env["REQUEST_METHOD"] = self.command
            env["CONTENT_LENGTH"] = str(length)
            env["CONTENT_TYPE"] = self.headers.get("Content-Type", "")
            env["QUERY_STRING"] = parsed.query
            env["SCRIPT_NAME"] = parsed.path
            env["SERVER_SOFTWARE"] = self.server_version
            env["REMOTE_ADDR"] = self.client_address[0]
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

        def _handle(self):
            full_path = self._resolve_path(self.path)
            if full_path is None:
                self._send_simple(403, "text/plain; charset=utf-8", b"403 forbidden\n")
                return
            url_path = self._url_path_of(full_path)
            required = self._auth_required_for(url_path)
            if required and not self._has_valid_auth(*required):
                self._send_auth_challenge()
                return
            if self._is_cgi(full_path):
                self._run_cgi(full_path)
                return
            if not os.path.isfile(full_path):
                self._send_simple(404, "text/plain; charset=utf-8", b"404 not found\n")
                return
            try:
                with open(full_path, "rb") as f:
                    data = f.read()
            except OSError:
                self._send_simple(500, "text/plain; charset=utf-8", b"500 internal error\n")
                return
            self._send_simple(200, guess_content_type(full_path), data)

        def do_GET(self):
            self._handle()

        def do_POST(self):
            self._handle()

        def do_HEAD(self):
            self._handle()

    return Handler


class ForkingHTTPServer(socketserver.ForkingMixIn, http.server.HTTPServer):
    # ForkingMixIn - см. пояснение в шапке файла про self-restart.
    allow_reuse_address = True
    daemon_threads = False


def main(argv):
    opts = parse_args(argv)
    auth_rules = load_auth_conf(opts["conf"])
    handler = make_handler(opts["docroot"], auth_rules)
    server = ForkingHTTPServer((opts["bind"], opts["port"]), handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main(sys.argv[1:])
