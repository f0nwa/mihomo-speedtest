"""Проверки web/stats_files.py (файловый менеджер веб-панели).

Запускается из tests/test_stats_files.sh: python3 -I tests/stats_files_check.py
"""
import io
import json
import os
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "web"))

import stats_files as sf  # noqa: E402


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.realpath(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def touch(self, name, data=b""):
        p = self.path(name)
        with open(p, "wb") as f:
            f.write(data)
        return p


class PathTests(Base):
    def test_normalize_rejects_relative_and_nul(self):
        for bad in ("", "a/b", "../x", "/a\0b"):
            with self.assertRaises(sf.FileError) as cm:
                sf.normalize(bad)
            self.assertEqual(cm.exception.status, 400)
            self.assertEqual(cm.exception.code, "bad_path")

    def test_normalize_collapses_dotdot(self):
        self.assertEqual(sf.normalize("/a/../b"), "/b")
        self.assertEqual(sf.normalize("/../.."), "/")
        self.assertEqual(sf.normalize("//a///b/"), "/a/b")

    def test_protected_paths(self):
        mounts = self.touch("mounts", b"/dev/sda1 /mnt/usb ext4 rw 0 0\n")
        for p in ("/", "/etc", "/opt", "/proc", "/mnt/usb"):
            self.assertTrue(sf.is_protected(p, mounts), p)
        self.assertFalse(sf.is_protected("/etc/mihomo", mounts))
        self.assertFalse(sf.is_protected("/mnt/usb/data", mounts))

    def test_readonly_panel_files(self):
        state = self.path("auth")
        os.mkdir(state)
        os.environ["STATS_AUTH_STATE_DIR"] = state
        self.addCleanup(os.environ.pop, "STATS_AUTH_STATE_DIR", None)
        self.assertTrue(sf.is_readonly(os.path.join(state, "credentials")))
        self.assertFalse(sf.is_readonly(self.path("other")))


class ListTests(Base):
    def test_list_dir_sorts_dirs_first_and_hides_bak(self):
        os.mkdir(self.path("zdir"))
        self.touch("b.txt", b"12345")
        self.touch("a.txt")
        self.touch("a.txt.bak")
        self.touch("c.part")
        res = sf.list_dir(self.root)
        names = [e["name"] for e in res["entries"]]
        self.assertEqual(names, ["zdir", "a.txt", "b.txt"])
        self.assertEqual(res["entries"][2]["size"], 5)
        self.assertEqual(res["entries"][0]["type"], "dir")
        self.assertFalse(res["truncated"])
        shown = sf.list_dir(self.root, show_hidden=True)
        self.assertEqual(len(shown["entries"]), 5)

    def test_list_dir_truncates(self):
        for i in range(5):
            self.touch("f%d" % i)
        res = sf.list_dir(self.root, limit=3)
        self.assertEqual(len(res["entries"]), 3)
        self.assertTrue(res["truncated"])

    def test_list_dir_broken_symlink(self):
        os.symlink(self.path("nowhere"), self.path("dangling"))
        os.symlink(self.root, self.path("tolink"))
        res = sf.list_dir(self.root)
        by = {e["name"]: e for e in res["entries"]}
        self.assertEqual(by["dangling"]["type"], "link")
        self.assertEqual(by["dangling"]["link"], self.path("nowhere"))
        self.assertEqual(by["tolink"]["type"], "link")

    def test_list_dir_non_utf8_name(self):
        open(os.path.join(os.fsencode(self.root), b"bad\xff.txt"), "wb").close()
        res = sf.list_dir(self.root)
        json.dumps(res)  # не должно падать
        self.assertEqual(len(res["entries"]), 1)

    def test_list_dir_errors(self):
        with self.assertRaises(sf.FileError) as cm:
            sf.list_dir(self.path("missing"))
        self.assertEqual(cm.exception.status, 404)
        self.touch("f")
        with self.assertRaises(sf.FileError) as cm:
            sf.list_dir(self.path("f"))
        self.assertEqual(cm.exception.code, "not_dir")

    def test_tree_only_dirs(self):
        os.mkdir(self.path("d2"))
        os.mkdir(self.path("d1"))
        self.touch("file")
        os.symlink(self.root, self.path("lnk"))
        self.assertEqual(sf.tree(self.root), ["d1", "d2"])


class ReadTests(Base):
    def test_read_text_ok(self):
        p = self.touch("c.yaml", "ключ: значение\n".encode("utf-8"))
        res = sf.read_text(p)
        self.assertEqual(res["content"], "ключ: значение\n")
        self.assertEqual(res["size"], len("ключ: значение\n".encode("utf-8")))
        self.assertFalse(res["readonly"])
        self.assertIsInstance(res["mtime"], float)

    def test_read_text_rejects_binary_large_and_device(self):
        binary = self.touch("b.bin", b"ab\0cd")
        with self.assertRaises(sf.FileError) as cm:
            sf.read_text(binary)
        self.assertEqual((cm.exception.status, cm.exception.code), (415, "not_text"))
        bad_utf = self.touch("u.txt", b"\xff\xfe\xfa")
        with self.assertRaises(sf.FileError) as cm:
            sf.read_text(bad_utf)
        self.assertEqual(cm.exception.code, "not_text")
        big = self.touch("big.txt", b"a" * 20)
        with self.assertRaises(sf.FileError) as cm:
            sf.read_text(big, limit=10)
        self.assertEqual((cm.exception.status, cm.exception.code), (413, "too_large"))
        with self.assertRaises(sf.FileError) as cm:
            sf.read_text("/dev/null")
        self.assertEqual((cm.exception.status, cm.exception.code), (415, "not_regular"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
