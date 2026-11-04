"""Native check: a combined search asks two sources at once (2026-10-27).

Two generated file servers, each a source on its own connection, through
native Irssi and the engine. The combined search sends both @find queries
together instead of one after the other, each search keeps its own replies,
and a result of either downloads as before. Nothing leaves loopback.
"""

from __future__ import annotations

import asyncio
from pathlib import Path
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from web_download_native_test import (CONTENT, KEY_ONE, DownloadFixture, RestartableIrssi,
                                      open_engine, wait_download, wait_source_by_id,
                                      wait_true)
from web_source_test import source_values
from webapp.downloads import DownloadService
from webapp.multisearch import MultiSearchService
from webapp.searches import SearchService
from webapp.sources import SourceService

QUIET_SECONDS = 6   # each search ends this long after its last reply


class ParallelSearchNativeTests(unittest.TestCase):
    def test_a_combined_search_asks_both_sources_together(self):
        first, second = DownloadFixture(), DownloadFixture()
        first.start()
        second.start()
        self.addCleanup(first.stop)
        self.addCleanup(second.stop)

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = multi = None
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(first.port))
                second_id = (await sources.create(source_values(second.port,
                                                                label="Second")))["source_id"]
                await sources.connect()
                await sources.connect(second_id)
                await wait_source_by_id(engine, "primary", {"ready"})
                await wait_source_by_id(engine, second_id, {"ready"})
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                multi = MultiSearchService(searches)
                await multi.startup()

                group = await multi.start("fixture", ["primary", second_id])
                await wait_true(lambda: first.find_count == 1 and second.find_count == 1,
                                "both sources asked", timeout=30)
                # Asked one after the other, the second would be asked only
                # once the first search had ended, a quiet window after its
                # reply. Measured between the two queries' arrivals, not from
                # the start, so a slow host's start-up does not count.
                gap = abs(first.find_times[0] - second.find_times[0])
                self.assertLess(gap, QUIET_SECONDS - 1,
                                "the second was asked before the first search ended")
                summary = None
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    summary = await multi.status(group["group_id"])
                    if summary["state"] != "running":
                        break
                    await asyncio.sleep(.5)
                self.assertEqual(summary["state"], "complete", summary)
                self.assertEqual([member["state"] for member in summary["members"]],
                                 ["complete", "complete"], summary)
                page = await multi.page(group["group_id"], offset=0, limit=10)
                self.assertEqual(sorted(row["source_id"] for row in page["results"]),
                                 sorted(["primary", second_id]),
                                 "each source's search kept its own reply")

                row = next(row for row in page["results"] if row["source_id"] == second_id)
                begun = await downloads.download(KEY_ONE, row["result_id"])
                done = await wait_download(downloads, begun["operation_id"],
                                           lambda status: status["state"] == "complete",
                                           "the second source's file")
                published = native.home / "fserve-poc" / "downloads" / done["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual((first.find_count, first.trigger_count, first.get_count),
                                 (1, 0, 0))
                self.assertEqual((second.find_count, second.trigger_count, second.get_count),
                                 (1, 1, 1))
            finally:
                if multi is not None:
                    await multi.close()
                if searches is not None:
                    await searches.close()
                await engine.close()

        with RestartableIrssi() as native:
            native.command(f"/set fscrawl_find_quiet_ms {QUIET_SECONDS * 1000}")
            native.command("/set dcc_autoget OFF")
            native.command("/set dcc_autochat OFF")
            with tempfile.TemporaryDirectory() as directory:
                try:
                    asyncio.run(workflow(native, Path(directory) / "fserve.sqlite3"))
                except BaseException:
                    print(f"first={first.lines[-8:]!r} second={second.lines[-8:]!r}", flush=True)
                    print(native.transcript[-4000:].decode(errors="replace"), flush=True)
                    raise
        self.assertFalse(first.errors or second.errors, (first.errors, second.errors))


if __name__ == "__main__":
    unittest.main()
