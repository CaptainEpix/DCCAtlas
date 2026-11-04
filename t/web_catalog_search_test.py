"""Searching a file list: every word in any order, accents aside (2026-10-27)."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
WORKER = ROOT / "lib" / "FServe" / "Catalog" / "worker.py"

LIST = ("D:\\Books\\\r\n"
        "!Shelf Ren\u00e9e Bright - Dare to Test.m4b  ::INFO:: 222.93MB\r\n"
        "!Shelf Ana Pe\u00f1a - The Villa.epub  ::INFO:: 1.1MB\r\n"
        "!Shelf Ana Pena - The Villa (Retail).epub  ::INFO:: 1.2MB\r\n"
        "!Shelf A C Marlow - Raven Rave Island.epub  ::INFO:: 1.14MB\r\n"
        "!Shelf Ravenna - Performance.epub  ::INFO:: 2MB\r\n")


def worker(*arguments: str) -> dict:
    done = subprocess.run([sys.executable, "-B", str(WORKER), *arguments],
                          capture_output=True, text=True, timeout=120)
    events = [json.loads(line) for line in done.stdout.splitlines() if line.startswith("{")]
    result = next((event for event in events if event.get("event") == "result"), None)
    if result is None:
        error = next((event for event in events if event.get("event") == "error"), {})
        raise ValueError(error.get("reason") or done.stderr[-500:])
    return result


class CatalogSearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        root = Path(cls.directory.name)
        source = root / "Shelf.txt"
        source.write_bytes(LIST.encode("utf-8"))
        cls.root = str(root / "catalog")
        context = {"network_id": "web-source:test", "server_tag": "irc.example:6667",
                   "server_nick": "Shelf", "trigger_raw": "!Shelf",
                   "trigger_mode": "channel_text", "discovery_channel": "#books",
                   "list_format": "posted"}
        worker("import", "--root", cls.root, "--source", str(source),
               "--context-json", json.dumps(context), "--perl", "perl",
               "--library", str(ROOT / "lib"), "--root-profile", "posted:#books",
               "--reserve-bytes", "1")

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def names(self, query: str) -> list[str]:
        return sorted(row["name"] for row in worker("search", "--root", self.root,
                                                    "--query", query)["rows"])

    def test_every_word_in_any_order(self):
        self.assertEqual(self.names("marlow island raven"),
                         ["A C Marlow - Raven Rave Island.epub"])
        # A word matches as part of a name, as one word did before.
        self.assertEqual(self.names("raven rave"),
                         ["A C Marlow - Raven Rave Island.epub", "Ravenna - Performance.epub"])
        self.assertEqual(self.names("raven"),
                         ["A C Marlow - Raven Rave Island.epub", "Ravenna - Performance.epub"])
        self.assertEqual(self.names("raven tolkien"), [])

    def test_accents_aside(self):
        self.assertEqual(self.names("renee dare"), ["Ren\u00e9e Bright - Dare to Test.m4b"])
        self.assertEqual(self.names("REN\u00c9E"), ["Ren\u00e9e Bright - Dare to Test.m4b"])
        self.assertEqual(self.names("pena villa"),
                         ["Ana Pena - The Villa (Retail).epub",
                          "Ana Pe\u00f1a - The Villa.epub"])

    def test_a_word_of_three_letters_is_needed(self):
        with self.assertRaises(ValueError):
            worker("search", "--root", self.root, "--query", "a c d")
        self.assertEqual(self.names("a c marlow"), ["A C Marlow - Raven Rave Island.epub"])


class PageBuildTests(unittest.TestCase):
    def test_the_fingerprint_follows_the_page_files(self):
        from webapp import api
        with tempfile.TemporaryDirectory() as name:
            static = Path(name)
            (static / "app.js").write_text("one", encoding="utf-8")
            with mock.patch.object(api, "STATIC_DIRECTORY", static):
                first = api.page_build()
                self.assertRegex(first, r"\A[0-9a-f]{16}\Z")
                self.assertEqual(api.page_build(), first, "the same files, the same print")
                (static / "app.js").write_text("two", encoding="utf-8")
                self.assertNotEqual(api.page_build(), first, "a changed file, another")


if __name__ == "__main__":
    unittest.main()
