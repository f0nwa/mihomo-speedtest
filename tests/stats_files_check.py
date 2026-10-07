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


class WriteTests(Base):
    def test_write_text_makes_bak_and_preserves_mode(self):
        p = self.touch("c.yaml", b"old\n")
        os.chmod(p, 0o640)
        res = sf.write_text(p, "new\n")
        with open(p, encoding="utf-8") as f:
            self.assertEqual(f.read(), "new\n")
        with open(p + ".bak", "rb") as f:
            self.assertEqual(f.read(), b"old\n")
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o640)
        self.assertEqual(res["size"], 4)
        self.assertEqual(os.listdir(self.root).count("c.yaml.part"), 0)

    def test_write_text_creates_new_file_without_bak(self):
        p = self.path("fresh.txt")
        sf.write_text(p, "x")
        self.assertTrue(os.path.isfile(p))
        self.assertFalse(os.path.exists(p + ".bak"))

    def test_write_text_conflict_on_stale_mtime(self):
        p = self.touch("c.yaml", b"old")
        mtime = os.stat(p).st_mtime
        os.utime(p, (mtime + 10, mtime + 10))
        with self.assertRaises(sf.FileError) as cm:
            sf.write_text(p, "new", expected_mtime=mtime)
        self.assertEqual((cm.exception.status, cm.exception.code), (409, "conflict"))
        with open(p, "rb") as f:
            self.assertEqual(f.read(), b"old")

    def test_write_text_refuses_panel_files(self):
        guard = self.path("guard")
        os.mkdir(guard)
        os.environ["FM_READONLY"] = guard
        self.addCleanup(os.environ.pop, "FM_READONLY", None)
        with self.assertRaises(sf.FileError) as cm:
            sf.write_text(os.path.join(guard, "x"), "data")
        self.assertEqual((cm.exception.status, cm.exception.code), (403, "readonly"))


class UploadTests(Base):
    def stream(self, name, data, length=None, **kw):
        return sf.save_stream(self.root, name, io.BytesIO(data),
                              len(data) if length is None else length, **kw)

    def test_save_stream_roundtrip_and_replace(self):
        res = self.stream("a.bin", b"x" * 200000, chunk=4096)
        self.assertEqual(res["size"], 200000)
        self.assertEqual(res["path"], self.path("a.bin"))
        self.stream("a.bin", b"short")
        with open(self.path("a.bin"), "rb") as f:
            self.assertEqual(f.read(), b"short")
        self.assertEqual(os.listdir(self.root), ["a.bin"])

    def test_save_stream_rejects_bad_names(self):
        for bad in ("../x", "a/b", ".", "..", "", "a\0b"):
            with self.assertRaises(sf.FileError) as cm:
                self.stream(bad, b"d")
            self.assertEqual(cm.exception.code, "bad_name", bad)
        self.assertEqual(os.listdir(self.root), [])

    def test_save_stream_too_large(self):
        with self.assertRaises(sf.FileError) as cm:
            self.stream("big", b"x" * 20, max_bytes=10)
        self.assertEqual(cm.exception.status, 413)
        self.assertEqual(os.listdir(self.root), [])

    def test_save_stream_truncated_body_cleans_part(self):
        self.touch("keep", b"original")
        with self.assertRaises(sf.FileError):
            self.stream("keep", b"abc", length=100)
        self.assertEqual(sorted(os.listdir(self.root)), ["keep"])
        with open(self.path("keep"), "rb") as f:
            self.assertEqual(f.read(), b"original")

    def test_save_stream_no_space(self):
        real = os.statvfs

        class V:
            f_bavail = 0
            f_frsize = 4096

        os.statvfs = lambda p: V()
        self.addCleanup(setattr, os, "statvfs", real)
        with self.assertRaises(sf.FileError) as cm:
            self.stream("a", b"data")
        self.assertEqual((cm.exception.status, cm.exception.code), (507, "no_space"))
        self.assertEqual(os.listdir(self.root), [])


class StructureTests(Base):
    def test_mkdir(self):
        sf.mkdir(self.path("new"))
        self.assertTrue(os.path.isdir(self.path("new")))
        with self.assertRaises(sf.FileError) as cm:
            sf.mkdir(self.path("new"))
        self.assertEqual(cm.exception.status, 409)

    def test_rename_refuses_existing(self):
        a = self.touch("a", b"A")
        b = self.touch("b", b"B")
        with self.assertRaises(sf.FileError) as cm:
            sf.rename(a, b)
        self.assertEqual((cm.exception.status, cm.exception.code), (409, "exists"))
        with open(b, "rb") as f:
            self.assertEqual(f.read(), b"B")
        sf.rename(a, self.path("c"))
        self.assertTrue(os.path.exists(self.path("c")))

    def test_rename_and_delete_protected(self):
        with self.assertRaises(sf.FileError) as cm:
            sf.delete("/etc", recursive=True, confirm="/etc")
        self.assertEqual((cm.exception.status, cm.exception.code), (403, "protected"))
        with self.assertRaises(sf.FileError) as cm:
            sf.rename("/opt", "/opt2")
        self.assertEqual(cm.exception.code, "protected")

    def test_delete_symlink_keeps_target(self):
        target = self.path("target")
        os.mkdir(target)
        self.touch("target/inner")
        os.symlink(target, self.path("lnk"))
        sf.delete(self.path("lnk"))
        self.assertFalse(os.path.lexists(self.path("lnk")))
        self.assertTrue(os.path.exists(self.path("target", "inner")))

    def test_delete_recursive_needs_confirm(self):
        d = self.path("tree")
        os.makedirs(os.path.join(d, "sub"))
        self.touch("tree/sub/f")
        with self.assertRaises(sf.FileError) as cm:
            sf.delete(d)
        self.assertEqual((cm.exception.status, cm.exception.code), (409, "not_empty"))
        with self.assertRaises(sf.FileError) as cm:
            sf.delete(d, recursive=True)
        self.assertEqual((cm.exception.status, cm.exception.code), (400, "confirm_required"))
        with self.assertRaises(sf.FileError):
            sf.delete(d, recursive=True, confirm=d + "x")
        self.assertTrue(os.path.isdir(d))
        sf.delete(d, recursive=True, confirm=d)
        self.assertFalse(os.path.exists(d))

    def test_delete_file_and_missing(self):
        p = self.touch("f")
        sf.delete(p)
        self.assertFalse(os.path.exists(p))
        with self.assertRaises(sf.FileError) as cm:
            sf.delete(p)
        self.assertEqual(cm.exception.status, 404)


if __name__ == "__main__":
    unittest.main(verbosity=1)
