"""Saved searches (2026-10-21): kept, listed and removed; nothing is sent."""

from __future__ import annotations

import asyncio
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from webapp.multisearch import MAX_LISTS_PER_SEARCH
from webapp.saved_searches import MAX_SAVED, SavedSearchService
from webapp.searches import SearchError
from webapp.sources import SourceService


def source_values(**overrides):
    values = dict(label="Lab", provider="sysreset_find", host="127.0.0.1", port=6667,
                  tls=False, nickname="SavedTest", channel="#review")
    values.update(overrides)
    return values


class ConfigureOnlyEngine:
    engine_instance_id = "saved-engine"

    def __init__(self):
        self.calls = []

    async def status(self, *, timeout=10.0):
        return {"engine_instance_id": self.engine_instance_id, "sources": []}

    async def request(self, operation, arguments=None, *, operation_id=None, timeout=10.0):
        self.calls.append(operation)
        if operation == "source.configure":
            return {"source": dict(arguments or {})}
        raise AssertionError(operation)


class SavedSearchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.database = Path(self.directory.name) / "fserve.sqlite3"
        self.engine = ConfigureOnlyEngine()
        self.sources = SourceService(self.database, self.engine)
        asyncio.run(self.sources.save(source_values()))
        self.service = SavedSearchService(self.sources)

    def tearDown(self):
        self.directory.cleanup()

    def refused(self, code, *arguments):
        with self.assertRaises(SearchError) as caught:
            self.service.save(*arguments)
        self.assertEqual(caught.exception.code, code)

    def test_a_search_is_saved_listed_and_removed_without_sending_anything(self):
        calls_before = list(self.engine.calls)
        saved = self.service.save("space saga", ["primary"], ["route-a"])
        self.assertTrue(saved["saved_id"].startswith("saved-"))
        self.assertEqual((saved["terms"], saved["source_ids"], saved["list_keys"]),
                         ("space saga", ["primary"], ["route-a"]))
        later = self.service.save("traveller", ["primary"], None)
        listed = self.service.list()
        self.assertEqual([item["terms"] for item in listed["saved"]], ["traveller", "space saga"],
                         "newest first")
        self.assertEqual(listed["limit"], MAX_SAVED)
        self.assertEqual(self.service.remove(later["saved_id"])["saved"], [saved])
        self.assertEqual(self.engine.calls, calls_before, "saving and removing send nothing")

    def test_saving_the_same_search_twice_keeps_one(self):
        first = self.service.save("dune", ["primary"], ["b", "a"])
        again = self.service.save("dune", ["primary"], ["a", "b"])
        self.assertEqual(first["saved_id"], again["saved_id"])
        self.assertEqual(len(self.service.list()["saved"]), 1)
        self.assertNotEqual(self.service.save("Dune", ["primary"], ["a", "b"])["saved_id"],
                            first["saved_id"], "other terms are another search")

    def test_saved_searches_outlast_the_service(self):
        self.service.save("dune", ["primary"], None)
        again = SavedSearchService(self.sources)
        self.assertEqual([item["terms"] for item in again.list()["saved"]], ["dune"])

    def test_what_cannot_be_searched_is_not_saved(self):
        self.refused("invalid_query", "", ["primary"], None)
        self.refused("invalid_query", "x" * 351, ["primary"], None)
        self.refused("invalid_query", "bad\x07terms", ["primary"], None)
        self.refused("invalid_query", 7, ["primary"], None)
        self.refused("invalid_request", "dune", [], [])
        self.refused("invalid_request", "dune", None, None)
        self.refused("invalid_request", "dune", "primary", None)
        self.refused("invalid_request", "dune", ["primary", "primary"], None)
        self.refused("invalid_request", "dune", [f"s{n}" for n in range(6)], None)
        self.refused("invalid_request", "dune", None, [f"l{n}" for n in range(MAX_LISTS_PER_SEARCH + 1)])
        self.refused("invalid_request", "dune", None, ["bad\x01key"])
        self.refused("invalid_request", "dune", None, [7])
        self.refused("unknown_source", "dune", ["nowhere"], None)
        self.assertEqual(self.service.list()["saved"], [])

    def test_there_is_a_limit(self):
        for number in range(MAX_SAVED):
            self.service.save(f"search {number}", ["primary"], None)
        self.refused("too_many_saved", "one more", ["primary"], None)
        self.assertEqual(self.service.save("search 3", ["primary"], None)["terms"], "search 3",
                         "saving one already saved is still fine")

    def test_removing_an_unknown_one_is_refused(self):
        for bad in ("saved-" + "0" * 32, "nonsense", None, 7):
            with self.assertRaises(SearchError) as caught:
                self.service.remove(bad)
            self.assertEqual(caught.exception.code, "unknown_saved")


if __name__ == "__main__":
    unittest.main()
