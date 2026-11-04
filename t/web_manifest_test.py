"""Offline tests for a file list placed in the downloads folder by hand.

The catalog worker is the real one; nothing here talks to IRC. Which files
are offered, what is refused before anything is read, and how the typed-in
file server and trigger become the list's route are checked here. Fetching a
hit from such a list is the native download test's.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from webapp.manifests import MAX_FOLDER_DEPTH, ManifestError, ManifestService, trigger_of
from webapp.sources import SourceConfigStore


LIST = b"[  4]  books\\fixture.txt\n[ 1.2M]  books\\gone.bin\n"
# A list server's list, in the layout real ones have (names made up): an
# indented banner, folder headings, and a row per file naming the server.
POSTED = (b"  Shelfbot's list, made today\r\n"
          b"  Type !Shelfbot and the file's name to get it\r\n"
          b"D:\\Newlist\\Books\\\r\n"
          b"!Shelfbot A C Marlow - Raven Rave Island.epub  ::INFO:: 1.14MB\r\n"
          b"!Shelfbot A L Example - Carved in the Rock.epub  ::INFO:: 2.01MB\r\n")


def source_values(**overrides):
    values = dict(label="Lab", provider="sysreset_find", host="127.0.0.1", port=6667,
                  tls=False, nickname="Tester", channel="#review")
    values.update(overrides)
    return values


class TriggerTests(unittest.TestCase):
    def test_a_trigger_is_read_as_a_file_server_shows_it(self):
        self.assertEqual(trigger_of("!Fixture", "Fixture"), ("!Fixture", "channel_text"))
        self.assertEqual(trigger_of("  !Fixture ", "Fixture"), ("!Fixture", "channel_text"))
        self.assertEqual(trigger_of("/ctcp Fixture !fserve2", "fixture"), ("!fserve2", "ctcp"))
        self.assertEqual(trigger_of("CTCP Fixture files", "Fixture"), ("files", "ctcp"))
        for text, why in (
            ("", "empty"), (None, "not text"), ("two words", "two words"),
            ("@find", "a channel-wide search"), ("@search x", "a search with words"),
            ("/ctcp Other !fserve2", "a CTCP trigger for another nick"),
            ("/ctcp Fixture", "a CTCP trigger with no payload"),
            ("/ctcp Fixture a b", "a CTCP payload of two words"),
            ("!bad\x07", "a control character"), ("!" + "x" * 128, "longer than 128"),
        ):
            with self.subTest(why), self.assertRaises(ManifestError) as refused:
                trigger_of(text, "Fixture")
            self.assertEqual(refused.exception.code, "invalid_trigger")


class PlacedListTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dccatlas-lists-")
        base = Path(self.temporary.name)
        self.downloads = base / "downloads"
        self.downloads.mkdir()
        store = SourceConfigStore(base / "source.db")
        store.save(source_values())
        store.save(source_values(label="Bots", provider="searchbot", search_bot="Search",
                                 nickname="Other", channel="#bots"), "src-000000000001")
        self.lists = ManifestService(
            SimpleNamespace(searches=None, sources=SimpleNamespace(store=store), engine=None),
            catalog_root=base / "file-lists", download_root=self.downloads)

    def tearDown(self):
        self.temporary.cleanup()

    def place(self, relative: str, content: bytes = LIST) -> Path:
        path = self.downloads / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def run_async(self, coroutine):
        return asyncio.run(coroutine)

    def test_only_plain_text_files_outside_dot_folders_are_offered(self):
        self.assertEqual(self.run_async(self.lists.placed_files()), {"files": [], "complete": True})
        self.place("top.txt")
        self.place("lists/Fixture.TXT")
        self.place("irc.example/books/list.txt")
        self.place(".incoming/20261014-1/partial.txt")   # still arriving
        self.place(".hidden.txt")
        self.place("notes.bin")
        self.place("empty.txt", b"")
        self.place("/".join(["deep"] * (MAX_FOLDER_DEPTH + 1)) + "/far.txt")
        os.symlink(self.downloads / "top.txt", self.downloads / "link.txt")
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        (outside / "elsewhere.txt").write_bytes(LIST)
        os.symlink(outside, self.downloads / "linked-folder")
        placed = self.run_async(self.lists.placed_files())
        self.assertTrue(placed["complete"])
        self.assertEqual([item["path"] for item in placed["files"]],
                         ["top.txt", "irc.example/books/list.txt", "lists/Fixture.TXT"])
        self.assertEqual(placed["files"][0]["bytes"], len(LIST))

    def test_what_cannot_be_a_placed_list_is_refused_before_it_is_read(self):
        self.place("top.txt")
        self.place(".incoming/1/partial.txt")
        self.place("notes.bin")
        os.symlink(self.downloads / "top.txt", self.downloads / "link.txt")
        outside = Path(self.temporary.name) / "outside.txt"
        outside.write_bytes(LIST)
        os.symlink(outside.parent, self.downloads / "up")
        cases = [
            (("/etc/passwd", "primary", "Fixture", "!Fixture"), "invalid_file"),
            (("../outside.txt", "primary", "Fixture", "!Fixture"), "invalid_file"),
            (("lists\\top.txt", "primary", "Fixture", "!Fixture"), "invalid_file"),
            ((".incoming/1/partial.txt", "primary", "Fixture", "!Fixture"), "invalid_file"),
            (("notes.bin", "primary", "Fixture", "!Fixture"), "invalid_file"),
            (("link.txt", "primary", "Fixture", "!Fixture"), "invalid_file"),
            (("up/outside.txt", "primary", "Fixture", "!Fixture"), "invalid_file"),
            (("missing.txt", "primary", "Fixture", "!Fixture"), "invalid_file"),
            ((None, "primary", "Fixture", "!Fixture"), "invalid_file"),
            (("top.txt", "nobody", "Fixture", "!Fixture"), "unknown_source"),
            (("top.txt", "../primary", "Fixture", "!Fixture"), "invalid_request"),
            (("top.txt", "primary", "Two Words", "!Fixture"), "invalid_sender"),
            (("top.txt", "primary", "", "!Fixture"), "invalid_sender"),
            (("top.txt", "primary", "Fixture", "@find"), "invalid_trigger"),
        ]
        for arguments, code in cases:
            with self.subTest(arguments), self.assertRaises(ManifestError) as refused:
                self.run_async(self.lists.import_file(*arguments))
            self.assertEqual(refused.exception.code, code)
        self.assertFalse((Path(self.temporary.name) / "file-lists").exists(),
                         "the catalog was started for a refused file")

    @unittest.skipUnless(shutil.which("perl"), "the catalog worker's parser needs Perl")
    def test_a_placed_list_is_added_under_the_file_server_typed_in_and_searched(self):
        self.place("lists/fixture.txt")
        added = self.run_async(self.lists.import_file(
            "lists/fixture.txt", "primary", "Fixture", "!Fixture"))
        self.assertEqual(added["files"], 2)
        (entry,) = added["lists"]
        self.assertEqual(
            (entry["source_id"], entry["source_label"], entry["sender"], entry["trigger"],
             entry["files"]),
            ("primary", "Lab", "Fixture", "!Fixture", 2))
        hits = self.run_async(self.lists.search("fixture", entry["route_key"]))
        self.assertEqual(
            [(row["path"], row["sender"], row["trigger"], row["selection_available"])
             for row in hits["results"]],
            [("/books/fixture.txt", "Fixture", "!Fixture", True)])

        # The same file server's list added again replaces the first.
        self.place("lists/fixture.txt", b"[  4]  books\\fixture.txt\n")
        again = self.run_async(self.lists.import_file(
            "lists/fixture.txt", "primary", "fixture", "!Fixture"))
        self.assertEqual((again["files"], len(again["lists"])), (1, 1))
        self.assertEqual(again["route_key"], entry["route_key"])

        # A CTCP trigger is a list of its own.
        ctcp = self.run_async(self.lists.import_file(
            "lists/fixture.txt", "primary", "Fixture", "/ctcp Fixture !fserve2"))
        self.assertNotEqual(ctcp["route_key"], entry["route_key"])
        self.assertEqual(sorted(item["trigger"] for item in ctcp["lists"]), ["!Fixture", "!fserve2"])

    def zipped(self, relative: str, members: dict[str, bytes]) -> Path:
        path = self.downloads / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, content in members.items():
                archive.writestr(name, content)
        return path

    def test_zipped_lists_are_offered_too(self):
        self.place("top.txt")
        self.zipped("lists/shelf.zip", {"shelf.txt": POSTED})
        self.place("lists/other.tar.gz", b"x")
        self.assertEqual([item["path"] for item in self.run_async(self.lists.placed_files())["files"]],
                         ["top.txt", "lists/shelf.zip"])

    @unittest.skipUnless(shutil.which("perl"), "the catalog worker's parser needs Perl")
    def test_a_list_servers_list_is_read_as_get_list_reads_one(self):
        self.place("lists/shelf.txt", POSTED)
        # No trigger needed: its files are fetched by posting their rows.
        added = self.run_async(self.lists.import_file("lists/shelf.txt", "primary", "Shelfbot", ""))
        self.assertEqual(added["files"], 2)
        (entry,) = added["lists"]
        self.assertEqual((entry["sender"], entry["trigger"], entry["files"]),
                         ("Shelfbot", "!Shelfbot", 2))
        hits = self.run_async(self.lists.search("raven", entry["route_key"]))
        self.assertEqual([(row["path"], row["sender"]) for row in hits["results"]],
                         [("/Newlist/Books/A C Marlow - Raven Rave Island.epub", "Shelfbot")])

        # Zipped, as list servers send them, it is the same list again.
        self.zipped("lists/shelf.zip", {"shelf-newlist.txt": POSTED})
        again = self.run_async(self.lists.import_file("lists/shelf.zip", "primary", "shelfbot",
                                                      "@shelfbot"))
        self.assertEqual((again["files"], again["route_key"]), (2, entry["route_key"]))

    @unittest.skipUnless(shutil.which("perl"), "the catalog worker's parser needs Perl")
    def test_a_list_whose_rows_name_the_list_is_read_for_its_nick(self):
        # OmenServe's rows start "!Nick-Ebooks2", the list's name (2026-11-02).
        named = POSTED.replace(b"!Shelfbot ", b"!Shelfbot-Ebooks2 ")
        self.place("lists/named.txt", named)
        added = self.run_async(self.lists.import_file("lists/named.txt", "primary", "shelfbot", ""))
        self.assertEqual(added["files"], 2)
        (entry,) = added["lists"]
        self.assertEqual((entry["sender"], entry["trigger"], entry["posted"]),
                         ("Shelfbot", "!Shelfbot-Ebooks2", True))
        # A word with the nick but not its dash is another nick's.
        self.place("lists/other.txt", POSTED.replace(b"!Shelfbot ", b"!ShelfbotX "))
        with self.assertRaises(ManifestError) as other:
            self.run_async(self.lists.import_file("lists/other.txt", "primary", "Shelfbot", ""))
        self.assertIn("!ShelfbotX", other.exception.message)
        self.assertEqual(ManifestService._row_word(self.downloads / "lists/named.txt", "SHELFBOT"),
                         "Shelfbot-Ebooks2")
        # Get list took the list from the nick, so rows that all start with
        # another word are posted with it: the server's own trigger
        # (2026-11-03). A list added by hand is still
        # refused above, as nothing says whose it is.
        self.assertEqual(ManifestService._row_word(self.downloads / "lists/other.txt", "Shelfbot"),
                         "ShelfbotX")
        self.place("lists/trigger.txt", POSTED.replace(b"!Shelfbot ", b"!Tome "))
        self.assertEqual(ManifestService._row_word(self.downloads / "lists/trigger.txt", "Shelfbot"),
                         "Tome")
        mixed = POSTED + b"!Other One.epub  ::INFO:: 1KB\r\n"
        self.place("lists/mixed.txt", mixed.replace(b"!Shelfbot ", b"!Tome "))
        self.assertEqual(ManifestService._row_word(self.downloads / "lists/mixed.txt", "Shelfbot"),
                         "Shelfbot", "no word starts nearly every row: the reader says so")

    @unittest.skipUnless(shutil.which("perl"), "the catalog worker's parser needs Perl")
    def test_a_file_servers_listing_in_a_zip_is_unpacked_and_read(self):
        self.zipped("lists/fixture.zip", {"fixture.txt": LIST})
        added = self.run_async(self.lists.import_file(
            "lists/fixture.zip", "primary", "Fixture", "!Fixture"))
        self.assertEqual(added["files"], 2)
        self.assertEqual([path.name for path in Path(self.temporary.name).iterdir()
                          if path.name.startswith(".placed-")], [], "nothing unpacked is left")

    @unittest.skipUnless(shutil.which("bsdtar"), "RAR and 7-Zip are read with bsdtar")
    def test_rar_lists_are_unpacked_both_kinds(self):
        """libarchive's own RAR 5 and RAR 4 samples (t/fixtures/rar)."""
        fixtures = Path(__file__).resolve().parent / "fixtures" / "rar"
        for name, text in (("rar5-helloworld.rar", b"hello libarchive test suite!\n"),
                           ("rar4-test.rar", b"test text document\r\n")):
            with self.subTest(name), tempfile.TemporaryDirectory() as scratch:
                unpacked = ManifestService._list_text(fixtures / name, Path(scratch))
                self.assertEqual(unpacked.read_bytes(), text)

    def sevenzip(self, relative: str, members: dict[str, bytes]) -> Path:
        with tempfile.TemporaryDirectory() as staging:
            for name, content in members.items():
                (Path(staging) / name).write_bytes(content)
            path = self.downloads / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["bsdtar", "--format", "7zip", "-cf", str(path), "-C", staging,
                            *members], check=True)
        return path

    @unittest.skipUnless(shutil.which("bsdtar") and shutil.which("perl"),
                         "7-Zip is read with bsdtar, the list with the Perl reader")
    def test_a_list_servers_list_in_a_7z_is_read(self):
        self.sevenzip("lists/shelf.7z", {"shelf.txt": POSTED, "readme.nfo": b"hello"})
        self.assertIn("lists/shelf.7z",
                      [item["path"] for item in self.run_async(self.lists.placed_files())["files"]])
        added = self.run_async(self.lists.import_file("lists/shelf.7z", "primary", "Shelfbot", ""))
        self.assertEqual(added["files"], 2, "the other file in it is left")
        self.sevenzip("two.7z", {"a.txt": LIST, "b.txt": LIST})
        with self.assertRaises(ManifestError) as refused:
            self.run_async(self.lists.import_file("two.7z", "primary", "Fixture", "!Fixture"))
        self.assertIn("exactly one .txt", refused.exception.message)
        self.place("broken.rar", b"Rar!\x1a\x07\x01\x00 not really")
        with self.assertRaises(ManifestError) as refused:
            self.run_async(self.lists.import_file("broken.rar", "primary", "Fixture", "!Fixture"))
        self.assertIn("could not be read", refused.exception.message)

    @staticmethod
    async def chunks(content: bytes, size: int = 7):
        for start in range(0, len(content), size):
            yield content[start:start + size]

    @unittest.skipUnless(shutil.which("perl"), "the catalog worker's parser needs Perl")
    def test_a_list_sent_from_the_page_is_read_and_kept_with_the_lists(self):
        # 2026-10-28: picked on the operator's computer, not looked for in
        # the downloads folder.
        uploaded = self.lists.upload_root()
        added = self.run_async(self.lists.import_upload(
            self.chunks(POSTED), "shelf.txt", "primary", "Shelfbot", ""))
        self.assertEqual(added["files"], 2)
        self.assertEqual((uploaded / "shelf.txt").read_bytes(), POSTED)
        self.assertEqual(self.run_async(self.lists.placed_files())["files"], [],
                         "it is not put in the downloads folder")
        # Sent again under its name, it takes the old one's place.
        newer = POSTED.replace(b"Raven Rave Island", b"Raven Rave Isle")
        again = self.run_async(self.lists.import_upload(
            self.chunks(newer), "shelf.txt", "primary", "Shelfbot", ""))
        self.assertEqual(again["route_key"], added["route_key"])
        self.assertEqual((uploaded / "shelf.txt").read_bytes(), newer)
        # Zipped, it is unpacked as a downloaded list is, and kept as sent.
        zipped = self.zipped("shelf.zip", {"shelf-newlist.txt": POSTED}).read_bytes()
        unzipped = self.run_async(self.lists.import_upload(
            self.chunks(zipped, 4096), "shelf.zip", "primary", "Shelfbot", ""))
        self.assertEqual((unzipped["files"], unzipped["route_key"]), (2, added["route_key"]))
        self.assertEqual((uploaded / "shelf.zip").read_bytes(), zipped)
        (self.downloads / "shelf.zip").unlink()
        # One that cannot be read is refused and not kept; nor is what
        # was arriving.
        with self.assertRaises(ManifestError):
            self.run_async(self.lists.import_upload(
                self.chunks(b"nothing to read here\n"), "other.txt", "primary", "Shelfbot", ""))
        self.assertEqual(sorted(path.name for path in uploaded.iterdir()), ["shelf.txt", "shelf.zip"])

    def test_what_cannot_be_sent_as_a_list_is_refused_and_not_kept(self):
        for name in ("../escape.txt", "a/b.txt", "a\\b.txt", ".hidden.txt", "list.exe",
                     "list.txt ", "bell\x07.txt", "", 5, None):
            with self.subTest(name=name), self.assertRaises(ManifestError) as refused:
                self.run_async(self.lists.import_upload(
                    self.chunks(POSTED), name, "primary", "Shelfbot", ""))
            self.assertEqual(refused.exception.code, "invalid_file")
        with self.assertRaises(ManifestError) as refused:
            self.run_async(self.lists.import_upload(
                self.chunks(b""), "empty.txt", "primary", "Shelfbot", ""))
        self.assertIn("empty", refused.exception.message)
        with mock.patch("webapp.manifests.MAX_LIST_BYTES", 100), \
                self.assertRaises(ManifestError) as refused:
            self.run_async(self.lists.import_upload(
                self.chunks(b"x" * 101), "big.txt", "primary", "Shelfbot", ""))
        self.assertIn("too large", refused.exception.message)
        with self.assertRaises(ManifestError) as refused:
            self.run_async(self.lists.import_upload(
                self.chunks(POSTED), "shelf.txt", "nobody", "Shelfbot", ""))
        self.assertEqual(refused.exception.code, "unknown_source")
        uploaded = self.lists.upload_root()
        self.assertEqual(list(uploaded.iterdir()) if uploaded.exists() else [], [])

    def test_a_file_servers_bracketed_list_is_read(self):
        # The list one FServe.pl server sends on "@Nick" (2026-10-29).
        self.place("lists/quill.txt", (
            "RPG books. Trigger: /ctcp Quill !quill\n\n[]\n  .ignore   (0 B)\n\n"
            "[Books/Oath (1991])/]\n  Issue 21 [_oef_].pdf   (6.72 MB)\n").encode())
        added = self.run_async(self.lists.import_file(
            "lists/quill.txt", "primary", "Quill", "/ctcp Quill !quill"))
        self.assertEqual(added["files"], 2)
        hits = self.run_async(self.lists.search("issue 21", added["route_key"]))
        self.assertEqual([(row["path"], row["trigger"]) for row in hits["results"]],
                         [("/Books/Oath (1991])/Issue 21 [_oef_].pdf", "!quill")])

    @unittest.skipUnless(shutil.which("bsdtar"), "7-Zip is read with bsdtar")
    def test_deleting_an_archived_listing_sent_before_files_were_recorded_finds_it(self):
        # A listing in an archive is read from the .txt inside, so its
        # fingerprint is that .txt's, not the archive's (2026-10-29).
        uploaded = self.lists.upload_root()
        added = {}
        for name, path in (("fixture.7z", self.sevenzip("fixture.7z", {"fixture.txt": LIST})),
                           ("other.zip", self.zipped("other.zip", {"other.txt": LIST + b"\n"}))):
            nick = "Fixture" if name == "fixture.7z" else "Other"
            added[name] = self.run_async(self.lists.import_upload(
                self.chunks(path.read_bytes()), name, "primary", nick, "!" + nick))
            path.unlink()
        (self.lists.catalog_root / "list-files.json").unlink()
        for name in ("fixture.7z", "other.zip"):
            with self.subTest(name):
                self.assertEqual(
                    self.run_async(self.lists.remove(added[name]["route_key"]))["purged"], [name])
        self.assertFalse(uploaded.exists() and any(uploaded.iterdir()))

    def test_a_stored_list_is_deleted_and_no_longer_searched(self):
        # Delete list on the Servers page (2026-10-29).
        self.place("lists/fixture.txt")
        added = self.run_async(self.lists.import_file(
            "lists/fixture.txt", "primary", "Fixture", "!Fixture"))
        self.place("lists/other.txt", b"[  4]  books\\other.txt\n")
        other = self.run_async(self.lists.import_file(
            "lists/other.txt", "primary", "Other", "!Other"))
        left = self.run_async(self.lists.remove(added["route_key"]))
        self.assertEqual([entry["sender"] for entry in left["lists"]], ["Other"])
        self.assertEqual(self.run_async(self.lists.search("fixture"))["results"], [])
        self.assertEqual(len(list(self.lists.catalog_root.glob("snapshot-*.sqlite"))), 1,
                         "the deleted list's snapshot file is gone")
        for route_key, code in ((added["route_key"], "catalog_failed"), ("x" * 64, "invalid_request"),
                                (None, "invalid_request")):
            with self.subTest(route_key), self.assertRaises(ManifestError) as refused:
                self.run_async(self.lists.remove(route_key))
            self.assertEqual(refused.exception.code, code)
        self.assertEqual(other["route_key"], left["lists"][0]["route_key"])
        self.assertEqual(left["purged"], ["fixture.txt"])
        self.assertFalse((self.downloads / "lists" / "fixture.txt").exists(),
                         "the file it was read from is gone")
        self.assertTrue((self.downloads / "lists" / "other.txt").exists(), "another list's stays")

    def test_deleting_a_list_sent_from_the_page_removes_its_kept_copy(self):
        uploaded = self.lists.upload_root()
        posted = self.run_async(self.lists.import_upload(
            self.chunks(POSTED), "shelf.txt", "primary", "Shelfbot", ""))
        self.place("lists/fixture.txt")
        listing = self.run_async(self.lists.import_upload(
            self.chunks(LIST), "fixture-list.txt", "primary", "Fixture", "!Fixture"))
        # Lists read before their files were recorded are found by name, or
        # by what they hold.
        (self.lists.catalog_root / "list-files.json").unlink()
        self.assertEqual(self.run_async(self.lists.remove(posted["route_key"]))["purged"],
                         ["shelf.txt"])
        self.assertEqual(self.run_async(self.lists.remove(listing["route_key"]))["purged"],
                         ["fixture-list.txt"])
        self.assertFalse(uploaded.exists() and any(uploaded.iterdir()))
        self.assertTrue((self.downloads / "lists" / "fixture.txt").exists(),
                        "a file with the same contents elsewhere is not the list's")

    def test_a_finished_lists_notice_can_be_closed(self):
        # The close button beside a notice under Servers (2026-10-29).
        now = time.time()
        self.lists.list_imports = {
            "done-op": {"operation_id": "done-op", "sender": "A", "state": "failed",
                        "reason": "x", "files": None, "updated_at": now},
            "busy-op": {"operation_id": "busy-op", "sender": "B", "state": "importing",
                        "reason": None, "files": None, "updated_at": now},
        }
        left = self.lists.dismiss_import("done-op")
        self.assertEqual([entry["operation_id"] for entry in left], ["busy-op"])
        for operation_id, code in (("busy-op", "not_finished"), ("done-op", "unknown_operation"),
                                   (None, "unknown_operation")):
            with self.subTest(operation_id), self.assertRaises(ManifestError) as refused:
                self.lists.dismiss_import(operation_id)
            self.assertEqual(refused.exception.code, code)

    def test_a_list_for_another_nick_or_an_unreadable_zip_is_refused_plainly(self):
        self.place("lists/shelf.txt", POSTED)
        with self.assertRaises(ManifestError) as refused:
            self.run_async(self.lists.import_file("lists/shelf.txt", "primary", "Fixture",
                                                  "!Fixture"))
        self.assertEqual(refused.exception.code, "invalid_sender")
        self.assertIn("its rows are for !Shelfbot, not !Fixture: type Shelfbot",
                      refused.exception.message)
        cases = {
            "two.zip": ({"a.txt": LIST, "b.txt": LIST}, "exactly one .txt"),
            "notext.zip": ({"list.bin": LIST}, "exactly one .txt"),
        }
        for name, (members, words) in cases.items():
            with self.subTest(name):
                self.zipped(name, members)
                with self.assertRaises(ManifestError) as refused:
                    self.run_async(self.lists.import_file(name, "primary", "Fixture", "!Fixture"))
                self.assertIn(words, refused.exception.message)
        self.place("broken.zip", b"PK\x03\x04 not really a zip")
        with self.assertRaises(ManifestError) as refused:
            self.run_async(self.lists.import_file("broken.zip", "primary", "Fixture", "!Fixture"))
        self.assertIn("could not be read", refused.exception.message)
        # Its size is counted as it unpacks, whatever the zip claims.
        self.zipped("big.zip", {"big.txt": b"[  4]  books\\fixture.txt\n" * 4000})
        with mock.patch("webapp.manifests.MAX_LIST_BYTES", 50_000), \
                self.assertRaises(ManifestError) as refused:
            self.run_async(self.lists.import_file("big.zip", "primary", "Fixture", "!Fixture"))
        self.assertIn("too large", refused.exception.message)
        self.assertFalse((Path(self.temporary.name) / "file-lists").exists(),
                         "the catalog was started for a refused file")

    @unittest.skipUnless(shutil.which("perl"), "the catalog worker's parser needs Perl")
    def test_a_text_file_that_is_not_a_list_is_refused(self):
        self.place("notes.txt", b"just some notes\nnothing listed here\n")
        with self.assertRaises(ManifestError) as refused:
            self.run_async(self.lists.import_file("notes.txt", "primary", "Fixture", "!Fixture"))
        self.assertEqual((refused.exception.code, refused.exception.message),
                         ("catalog_failed", "unrecognized manifest format at line 1"))
        self.assertEqual(self.run_async(self.lists.lists()), {"lists": [], "imports": []})


@unittest.skipUnless(os.name == "posix", "a stand-in bsdtar is a shell script")
class StalledArchiveTests(unittest.TestCase):
    """An archive comes from whoever sent it (2026-11-03): one that keeps
    bsdtar busy without end is given up, not waited for."""

    def test_an_archive_that_never_unpacks_is_given_up(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            # Lists one .txt, then sends nothing and never ends.
            fake = folder / "bin" / "bsdtar"
            fake.parent.mkdir()
            fake.write_text('#!/bin/sh\ncase "$1" in -tf) echo list.txt ;; *) exec sleep 120 ;; esac\n')
            fake.chmod(0o755)
            archive = folder / "fixture.7z"
            archive.write_bytes(b"not looked at")
            path = f"{fake.parent}{os.pathsep}{os.environ.get('PATH', '')}"
            with mock.patch.dict(os.environ, {"PATH": path}), \
                    mock.patch("webapp.manifests.BSDTAR_SECONDS", 1):
                began = time.monotonic()
                with self.assertRaises(ManifestError) as refused:
                    ManifestService._unpack_with_bsdtar(archive, folder)
            self.assertLess(time.monotonic() - began, 30)
            self.assertEqual(refused.exception.message, "that .7z could not be read")


if __name__ == "__main__":
    unittest.main()
