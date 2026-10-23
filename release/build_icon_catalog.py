#!/usr/bin/env python3
"""Собрать проверенный каталог URL иконок Qure и Dashboard Icons."""

import argparse
import datetime
import json
import os
import pathlib
import re
import sys
import tempfile
import urllib.parse
import urllib.request


SOURCES = {
    "qure": "https://raw.githubusercontent.com/Koolson/Qure/master/Other/QureColor.json",
    "dashboard-metadata": "https://raw.githubusercontent.com/homarr-labs/dashboard-icons/main/metadata.json",
    "dashboard-tree": "https://raw.githubusercontent.com/homarr-labs/dashboard-icons/main/tree.json",
}
QURE_RAW = "https://raw.githubusercontent.com/Koolson/Qure/master/IconSet/Color/"
QURE_CDN = "https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/"
DASHBOARD_CDN = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@main/png/"
URL_RE = re.compile(r"https?://[^\s\"'#]+\Z")
QURE_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._!&+-]*\.png\Z")
DASHBOARD_SLUG_RE = re.compile(r"[a-z0-9][a-z0-9._-]*\Z")
MAX_JSON_BYTES = 8 * 1024 * 1024


def get_json(name, fixtures):
    if fixtures:
        raw = (fixtures / (name + ".json")).read_bytes()
    else:
        request = urllib.request.Request(SOURCES[name], headers={"User-Agent": "mihomo-icon-catalog/1"})
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read(MAX_JSON_BYTES + 1)
    if len(raw) > MAX_JSON_BYTES:
        raise ValueError(name + ": JSON больше 8 МиБ")
    return json.loads(raw.decode("utf-8"))


def field(value, what, *, alias=False):
    if not isinstance(value, str) or not value or any(ord(ch) < 32 for ch in value):
        raise ValueError(what + ": пустое или недопустимое поле")
    if alias and "|" in value:
        raise ValueError(what + ": символ | недопустим")
    return value


def row(source, slug, label, url, aliases):
    for name, value in (("источник", source), ("slug", slug), ("название", label), ("URL", url)):
        field(value, name)
    if not URL_RE.fullmatch(url):
        raise ValueError("недопустимый URL иконки: " + url)
    clean_aliases = []
    seen = {label.casefold()}
    for alias in aliases:
        alias = field(alias, "синоним", alias=True)
        if alias.casefold() not in seen:
            clean_aliases.append(alias)
            seen.add(alias.casefold())
    return (source, slug, label, url, "|".join(clean_aliases))


def qure_rows(data):
    if not isinstance(data, dict) or not isinstance(data.get("icons"), list):
        raise ValueError("Qure: нет списка icons")
    found = {}
    for entry in data["icons"]:
        if not isinstance(entry, dict):
            raise ValueError("Qure: неверная запись")
        name = field(entry.get("name"), "Qure: имя")
        source_url = field(entry.get("url"), "Qure: URL")
        if not QURE_NAME_RE.fullmatch(name) or source_url != QURE_RAW + name:
            raise ValueError("Qure: неверное имя или адрес " + name)
        stem = name[:-4]
        slug = stem.lower()
        value = row("qure", slug, stem.replace("_", " ").replace("-", " "),
                    QURE_CDN + urllib.parse.quote(name, safe=""), [])
        if slug in found and found[slug] != value:
            raise ValueError("Qure: повтор slug " + slug)
        found[slug] = value
    if not found:
        raise ValueError("Qure: нет иконок")
    return [found[key] for key in sorted(found)]


def dashboard_rows(metadata, tree):
    if not isinstance(metadata, dict) or not isinstance(tree, dict) or not isinstance(tree.get("png"), list):
        raise ValueError("Dashboard Icons: нет metadata или списка png")
    png = set()
    for name in tree["png"]:
        name = field(name, "Dashboard Icons: файл png")
        png.add(name)
    result = []
    for slug in sorted(metadata):
        if slug + ".png" not in png:
            continue
        if not DASHBOARD_SLUG_RE.fullmatch(slug):
            raise ValueError("Dashboard Icons: неверный slug " + slug)
        entry = metadata[slug]
        if not isinstance(entry, dict) or not isinstance(entry.get("aliases", []), list):
            raise ValueError("Dashboard Icons: неверная запись " + slug)
        label = slug.replace("-", " ").replace("_", " ")
        result.append(row("dashboard", slug, label,
                          DASHBOARD_CDN + urllib.parse.quote(slug + ".png", safe=""),
                          entry.get("aliases", [])))
    if not result:
        raise ValueError("Dashboard Icons: нет PNG с метаданными")
    return result


def build(fixtures, date):
    items = qure_rows(get_json("qure", fixtures))
    items.extend(dashboard_rows(get_json("dashboard-metadata", fixtures), get_json("dashboard-tree", fixtures)))
    return "# собран: " + date + "\n" + "".join("\t".join(item) + "\n" for item in items)


def write_atomic(path, content):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="\n", dir=path.parent,
                                         prefix=".icon-catalog.", delete=False) as stream:
            temporary = pathlib.Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True, help="итоговый icon-catalog.tsv")
    parser.add_argument("--fixtures", type=pathlib.Path, help="каталог локальных JSON вместо сети")
    parser.add_argument("--date", default=datetime.date.today().isoformat(), help="дата в шапке YYYY-MM-DD")
    args = parser.parse_args()
    datetime.date.fromisoformat(args.date)
    content = build(args.fixtures, args.date)
    write_atomic(args.output, content)
    print("Собрано иконок: " + str(content.count("\n") - 1), file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print("build_icon_catalog.py: " + str(exc), file=sys.stderr)
        sys.exit(1)
