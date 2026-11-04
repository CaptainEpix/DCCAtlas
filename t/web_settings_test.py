"""The operator's download settings (2026-10-22)."""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from webapp.settings import DEFAULTS, DownloadSettings, SettingsError
from webapp.sources import SourceConfigStore


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.database = Path(self.directory.name) / "fserve.sqlite3"
        SourceConfigStore(self.database)
        self.settings = DownloadSettings(self.database)

    def tearDown(self):
        self.directory.cleanup()

    def test_defaults_changes_and_persistence(self):
        self.assertEqual(self.settings.view(), DEFAULTS)
        self.assertTrue(self.settings.get("retry_before_request"), "on unless turned off")
        self.assertFalse(self.settings.update({"retry_before_request": False})["retry_before_request"])
        self.assertFalse(DownloadSettings(self.database).get("retry_before_request"),
                         "kept in the database")
        self.assertEqual(self.settings.get("downloads_at_once"), 2, "two at once by default")
        self.assertEqual(self.settings.update({"downloads_at_once": 1})["downloads_at_once"], 1)

    def test_bad_changes_are_refused_and_change_nothing(self):
        for bad in ({}, None, [], {"retry_before_request": 1}, {"retry_before_request": "yes"},
                    {"unknown": True}, {"retry_before_request": False, "unknown": True},
                    {"downloads_at_once": 3}, {"downloads_at_once": 0}, {"downloads_at_once": True},
                    {"downloads_at_once": "2"}, {"downloads_at_once": 2.0}):
            with self.assertRaises(SettingsError) as caught:
                self.settings.update(bad)
            self.assertEqual(caught.exception.code, "invalid_settings", bad)
        self.assertEqual(self.settings.view(), DEFAULTS)


if __name__ == "__main__":
    unittest.main()
