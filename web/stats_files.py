"""Файловый менеджер веб-панели: работа с файловой системой без HTTP.

Ставится install.sh как $DIR/stats_files.py. stats_httpd.py только
маршрутизирует /api/fm/* в функции отсюда (см.
docs/superpowers/specs/2026-10-07-web-file-manager-design.md).

Единственный корень - "/": пути абсолютные, белого списка каталогов нет.
Безопасность держится на проверках в этом модуле: нормализация пути,
защищённые пути (их нельзя удалить и переименовать), чтение только обычных
файлов (устройства, FIFO, /proc не читаются как файлы), файлы самой панели
только на чтение, потоковая запись с атомарной заменой.

Только стандартная библиотека, Python 3.7+.
"""
import errno
import os
import posixpath
import stat

TEXT_LIMIT = 1024 * 1024
LIST_LIMIT = 2000
SNIFF_BYTES = 8192
HIDDEN_SUFFIXES = (".bak", ".part")
PROTECTED = frozenset([
    "/", "/bin", "/sbin", "/lib", "/etc", "/opt", "/proc", "/sys", "/dev",
])


class FileError(Exception):
    """Ошибка операции: status - код HTTP, code - машинное имя для UI."""

    def __init__(self, status, code):
        Exception.__init__(self, "%s (%s)" % (code, status))
        self.status = status
        self.code = code


def _oserror(exc):
    """Переводит OSError в FileError."""
    if exc.errno in (errno.ENOENT, errno.ENOTDIR):
        return FileError(404, "not_found")
    if exc.errno in (errno.EACCES, errno.EPERM, errno.EROFS):
        return FileError(403, "permission")
    if exc.errno == errno.ENOSPC:
        return FileError(507, "no_space")
    if exc.errno == errno.EEXIST:
        return FileError(409, "exists")
    if exc.errno == errno.ENOTEMPTY:
        return FileError(409, "not_empty")
    return FileError(500, "io")


def normalize(path):
    """Абсолютный нормализованный путь; иначе FileError(400, bad_path)."""
    if not isinstance(path, str) or not path.startswith("/") or "\0" in path:
        raise FileError(400, "bad_path")
    norm = posixpath.normpath(path)
    if norm.startswith("//"):
        norm = "/" + norm.lstrip("/")
    return norm


def _mount_points(mounts_file):
    points = set()
    try:
        with open(mounts_file, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                fields = line.split()
                if len(fields) >= 2:
                    # пробелы в точках монтирования записаны как \040
                    points.add(posixpath.normpath(fields[1].replace("\\040", " ")))
    except OSError:
        pass
    return points


def is_protected(path, mounts_file="/proc/mounts"):
    """Путь нельзя удалить и переименовать: системный каталог или mountpoint."""
    norm = normalize(path)
    return norm in PROTECTED or norm in _mount_points(mounts_file)


def _panel_guarded():
    """Каталоги и префиксы файлов панели, доступные только на чтение."""
    dirs = []
    prefixes = []
    state = os.environ.get("STATS_AUTH_STATE_DIR")
    if state:
        dirs.append(posixpath.normpath(state))
    for extra in os.environ.get("FM_READONLY", "").split(":"):
        if extra:
            dirs.append(posixpath.normpath(extra))
    app_dir = os.environ.get("DIR")
    if app_dir:
        prefixes.append(posixpath.join(posixpath.normpath(app_dir), "stats_auth"))
    return dirs, prefixes


def is_readonly(path):
    """Файл панели (пароль, сессии): из веб-интерфейса его не меняют."""
    norm = normalize(path)
    dirs, prefixes = _panel_guarded()
    for d in dirs:
        if norm == d or norm.startswith(d.rstrip("/") + "/"):
            return True
    for pre in prefixes:
        if norm.startswith(pre):
            return True
    return False


def _display(name):
    """Имя для JSON: байты не из UTF-8 заменяются знаком замены."""
    return name.encode("utf-8", "surrogateescape").decode("utf-8", "replace")


def _kind(mode):
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISLNK(mode):
        return "link"
    return "other"


def list_dir(path, show_hidden=False, limit=LIST_LIMIT):
    """Содержимое каталога: сначала каталоги, затем файлы, по имени."""
    norm = normalize(path)
    entries = []
    truncated = False
    try:
        with os.scandir(norm) as it:
            for entry in it:
                if not show_hidden and entry.name.endswith(HIDDEN_SUFFIXES):
                    continue
                if len(entries) >= limit:
                    truncated = True
                    break
                try:
                    st = entry.stat(follow_symlinks=False)
                except OSError:
                    entries.append({"name": _display(entry.name), "type": "other",
                                    "size": None, "mtime": None, "mode": "", "link": None})
                    continue
                kind = _kind(st.st_mode)
                link = None
                if kind == "link":
                    try:
                        link = _display(os.readlink(entry.path))
                    except OSError:
                        link = ""
                entries.append({
                    "name": _display(entry.name),
                    "type": kind,
                    "size": st.st_size if kind == "file" else None,
                    "mtime": st.st_mtime,
                    "mode": stat.filemode(st.st_mode),
                    "link": link,
                    "link_dir": kind == "link" and os.path.isdir(entry.path),
                })
    except NotADirectoryError:
        raise FileError(400, "not_dir")
    except OSError as exc:
        raise _oserror(exc)
    entries.sort(key=lambda e: (0 if e["type"] == "dir" or e.get("link_dir") else 1, e["name"]))
    return {"path": norm, "entries": entries, "truncated": truncated}


def tree(path):
    """Имена подкаталогов (без ссылок) - для ленивого дерева."""
    norm = normalize(path)
    names = []
    try:
        with os.scandir(norm) as it:
            for entry in it:
                try:
                    if entry.is_dir(follow_symlinks=False):
                        names.append(_display(entry.name))
                except OSError:
                    continue
    except NotADirectoryError:
        raise FileError(400, "not_dir")
    except OSError as exc:
        raise _oserror(exc)
    return sorted(names)


def read_text(path, limit=TEXT_LIMIT):
    """Текстовый файл для редактора: только обычный, UTF-8, до limit байт."""
    norm = normalize(path)
    try:
        st = os.stat(norm)
        if not stat.S_ISREG(st.st_mode):
            raise FileError(415, "not_regular")
        if st.st_size > limit:
            raise FileError(413, "too_large")
        with open(norm, "rb") as f:
            data = f.read(limit + 1)
    except OSError as exc:
        raise _oserror(exc)
    if len(data) > limit:
        raise FileError(413, "too_large")
    if b"\0" in data[:SNIFF_BYTES]:
        raise FileError(415, "not_text")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise FileError(415, "not_text")
    return {"content": text, "mtime": st.st_mtime, "size": len(data),
            "readonly": is_readonly(norm)}
