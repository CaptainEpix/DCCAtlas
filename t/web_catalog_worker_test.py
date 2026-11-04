import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "fserve_catalog_worker", ROOT / "lib/FServe/Catalog/worker.py"
)
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)


class FakeProducer:
    def __init__(self, records, source_digest, *, exit_code=0, final_ok=True):
        self.stdout = io.BytesIO(b"".join(
            json.dumps({"type": "file", **record}, ensure_ascii=True).encode() + b"\n"
            for record in records
        ))
        result = {"ok": final_ok, "records_emitted": len(records),
                  "sha256": source_digest, "estimated_sizes": 0}
        self.stderr = io.BytesIO(json.dumps(result).encode() + b"\n")
        self.returncode = exit_code

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        return self.returncode

    def terminate(self):
        self.returncode = 143

    def kill(self):
        self.returncode = 137


class CatalogWorkerTests(unittest.TestCase):
    def setUp(self):
        worker.CANCEL_REQUESTED = False
        self.tmp = tempfile.TemporaryDirectory(prefix="fserve-catalog-worker-")
        self.root = Path(self.tmp.name) / "catalog"
        self.source = Path(self.tmp.name) / "manifest.txt"
        self.source.write_bytes(b"offline fixture manifest")
        self.context = {
            "network_id": "private-net", "server_tag": "lab-server",
            "server_nick": "TNW", "trigger_raw": "!TNW",
            "trigger_mode": "ctcp", "discovery_channel": "",
            "manifest_remote_path": "/FullFiles-List.txt",
        }
        self.records = [
            {"remote_path": f"Books/book-{i:03}.txt", "size_raw": "100 B",
             "size_bytes": 100, "size_precision": "exact"}
            for i in range(55)
        ]
        self.events = []

    def tearDown(self):
        worker.CANCEL_REQUESTED = False
        self.tmp.cleanup()

    def run_import(self, records=None, source=None, *, exit_code=0, final_ok=True):
        records = self.records if records is None else records
        source = self.source if source is None else source
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        producer = FakeProducer(records, digest, exit_code=exit_code, final_ok=final_ok)
        # This exercises import_manifest directly; building argparse here would
        # perform an unrelated terminal-size probe on every fixture import.
        args = argparse.Namespace(
            command="import", root=str(self.root), source=str(source),
            context_json=json.dumps(self.context), perl="perl",
            library=str(ROOT / "lib"),
            helper=str(ROOT / "lib/FServe/Catalog/ManifestStream.pl"),
            root_profile="test-root", reserve_bytes=0,
            max_source_bytes=1_073_741_824, max_rows=5_000_000,
            max_seconds=1_800, max_line_bytes=65_536,
            irc_casemapping="rfc1459", path_policy="sensitive",
            parser_version=worker.PARSER_VERSION,
        )
        with mock.patch.object(worker.subprocess, "Popen", return_value=producer), \
             mock.patch.object(worker.shutil, "disk_usage", return_value=argparse.Namespace(free=10**12)), \
             mock.patch.object(worker, "emit", side_effect=self.events.append):
            status = worker.import_manifest(args)
        return status

    def route_key(self):
        registry = worker.open_registry(self.root)
        try:
            route = registry.execute("SELECT route_key FROM route").fetchone()
            return route[0].hex()
        finally:
            registry.close()

    def query(self, operation, **kwargs):
        args = argparse.Namespace(root=str(self.root), route_key=kwargs.get("route_key"),
                                  command=operation, query_timeout=5.0,
                                  cursor=kwargs.get("cursor"))
        self.events.clear()
        with mock.patch.object(worker, "emit", side_effect=self.events.append):
            if operation == "search":
                args.query = kwargs["query"]
                worker.manifest_search(args)
            else:
                args.mode = kwargs["mode"]
                args.value = kwargs["value"]
                worker.manifest_browse(args)
        return self.events[-1]

    def test_import_publishes_sqlite_snapshot_and_indexed_pages(self):
        self.assertEqual(self.run_import(), 0)
        route_key = self.route_key()
        self.assertEqual(self.events[-1]["status"], "published")
        first = self.query("search", route_key=route_key, query="book")
        self.assertEqual(len(first["rows"]), 50)
        self.assertTrue(first["has_more"])
        self.assertEqual(len(first["endpoint_modes"]), 1)
        second = self.query("search", route_key=route_key, query="book",
                            cursor=first["next_cursor"])
        self.assertEqual(len(second["rows"]), 5)
        self.assertEqual(set(row["path"] for row in first["rows"] + second["rows"]),
                         {"/" + record["remote_path"] for record in self.records})
        self.assertEqual(self.query("browse", route_key=route_key, mode="parent",
                                    value="/Books")["rows"][0]["path"], "/Books/book-000.txt")
        self.assertEqual(len(self.query("browse", route_key=route_key, mode="prefix",
                                        value="book-00")["rows"]), 10)
        self.assertEqual(self.query("browse", route_key=route_key, mode="exact",
                                    value="/Books/book-003.txt")["rows"][0]["size_precision"], "exact")

    def old_layout(self):
        """Turn the active snapshot back into the layout used before
        2026-10-28, as one stored then is, and return its file."""
        registry = worker.open_registry(self.root)
        try:
            row = registry.execute("SELECT snapshot_id,database_path FROM snapshot").fetchone()
        finally:
            registry.close()
        path = self.root / row["database_path"]
        db = sqlite3.connect(path)
        db.row_factory = sqlite3.Row
        rows = db.execute("SELECT * FROM entry_v ORDER BY row_id").fetchall()
        db.executescript("""
          DROP TABLE entry_fts; DROP VIEW entry_v; DROP VIEW entry_text;
          DROP TABLE entry; DROP TABLE folder;
          CREATE TABLE entry (
            row_id INTEGER PRIMARY KEY, file_key BLOB NOT NULL UNIQUE, path TEXT NOT NULL,
            path_key TEXT NOT NULL UNIQUE, parent_key TEXT NOT NULL, basename TEXT NOT NULL,
            name_key TEXT NOT NULL, fold_key TEXT NOT NULL, size_raw TEXT, size_bytes INTEGER,
            size_precision TEXT NOT NULL);
        """)
        for item in rows:
            db.execute("INSERT INTO entry VALUES (?,?,?,?,?,?,?,?,?,?,?)", (
                item["row_id"], item["file_key"], item["path"], item["path"],
                item["parent_key"], item["basename"], item["basename"].casefold(),
                worker.fold_text(item["basename"]), item["size_raw"], item["size_bytes"],
                item["size_precision"]))
        db.execute("CREATE INDEX entry_name ON entry(name_key,row_id)")
        db.execute("CREATE INDEX entry_parent ON entry(parent_key,name_key,row_id)")
        worker.create_fts(db)
        db.commit()
        db.execute("VACUUM")
        db.close()
        return path

    def test_an_old_layout_snapshot_is_read_then_compacted_in_place(self):
        # 2026-10-28: a stored list took about ten times its text.
        self.records.append({"remote_path": "Books/Ren\u00e9e Book.txt", "size_raw": "1 KB",
                             "size_bytes": None, "size_precision": "estimated"})
        self.assertEqual(self.run_import(), 0)
        route_key = self.route_key()
        old_path = self.old_layout()
        old_size = old_path.stat().st_size
        # An old snapshot still answers as before, and a selection is made.
        before = self.query("search", route_key=route_key, query="book-00")
        self.assertEqual(len(before["rows"]), 10)
        token = before["rows"][0]["token"]
        self.assertEqual(self.query("search", route_key=route_key, query="renee")["rows"][0]["name"],
                         "Ren\u00e9e Book.txt")
        self.assertEqual(self.query("browse", route_key=route_key, mode="exact",
                                    value="/Books/book-003.txt")["rows"][0]["size_precision"], "exact")

        self.events.clear()
        with mock.patch.object(worker, "emit", side_effect=self.events.append):
            self.assertEqual(worker.compact_snapshots(argparse.Namespace(root=str(self.root))), 0)
        (done,) = self.events[-1]["compacted"]
        self.assertFalse(old_path.exists(), "the old file is removed")
        self.assertLess(done["bytes_after"], old_size)
        registry = worker.open_registry(self.root)
        try:
            new_path = self.root / registry.execute(
                "SELECT database_path FROM snapshot").fetchone()[0]
        finally:
            registry.close()
        db = sqlite3.connect(new_path)
        self.assertEqual(worker.entry_source(db), worker.COMPACT_VIEW)
        self.assertEqual(db.execute("SELECT count(*) FROM folder").fetchone()[0], 1)
        # Only the name with an accent keeps its searched form apart.
        self.assertEqual(db.execute("SELECT count(*) FROM entry WHERE fold_key IS NOT NULL")
                         .fetchone()[0], 1)
        db.close()

        after = self.query("search", route_key=route_key, query="book-00")
        self.assertEqual([row["path"] for row in after["rows"]],
                         [row["path"] for row in before["rows"]])
        self.assertEqual(after["rows"][0]["token"], token, "selections carry over")
        self.assertEqual(self.query("search", route_key=route_key, query="renee")["rows"][0]["name"],
                         "Ren\u00e9e Book.txt")
        self.assertEqual([row["path"] for row in self.query(
            "browse", route_key=route_key, mode="parent", value="/Books")["rows"]][:2],
            ["/Books/book-000.txt", "/Books/book-001.txt"])
        self.assertEqual(len(self.query("browse", route_key=route_key, mode="prefix",
                                        value="book-00")["rows"]), 10)
        self.assertEqual(self.query("browse", route_key=route_key, mode="exact",
                                    value="/Books/book-003.txt")["rows"][0]["size_precision"], "exact")
        resolved = argparse.Namespace(root=str(self.root), selection=token, command="resolve")
        self.events.clear()
        with mock.patch.object(worker, "emit", side_effect=self.events.append):
            worker.resolve_selection(resolved)
        self.assertEqual(self.events[-1]["path"], before["rows"][0]["path"])
        # Nothing is left to do a second time.
        self.events.clear()
        with mock.patch.object(worker, "emit", side_effect=self.events.append):
            worker.compact_snapshots(argparse.Namespace(root=str(self.root)))
        self.assertEqual(self.events[-1]["compacted"], [])

    def test_importing_an_old_layout_list_again_replaces_it_compact(self):
        self.assertEqual(self.run_import(), 0)
        old_path = self.old_layout()
        self.assertEqual(self.run_import(), 0)
        self.assertFalse(old_path.exists(), "the old file is not kept beside the new one")
        registry = worker.open_registry(self.root)
        try:
            (only,) = registry.execute("SELECT database_path FROM snapshot").fetchall()
        finally:
            registry.close()
        db = sqlite3.connect(self.root / only[0])
        self.assertEqual(worker.entry_source(db), worker.COMPACT_VIEW)
        db.close()

    def test_a_name_repeated_with_another_size_keeps_the_first(self):
        # 2026-10-29: a real list named 3,855 of its 607,545 files twice in a
        # folder, at two sizes; it was refused whole.
        self.records.append({"remote_path": "Books/book-001.txt", "size_raw": "235 B",
                             "size_bytes": 235, "size_precision": "exact"})
        self.assertEqual(self.run_import(), 0)
        result = self.events[-1]
        self.assertEqual((result["records"], result["duplicates"], result["conflicting"]),
                         (55, 1, 1))
        found = self.query("browse", route_key=self.route_key(), mode="exact",
                           value="/Books/book-001.txt")["rows"][0]
        self.assertEqual(found["size_raw"], "100 B", "the first is kept")

    def test_selection_lease_blocks_refresh_then_old_token_goes_stale(self):
        self.assertEqual(self.run_import(), 0)
        route_key = self.route_key()
        page = self.query("search", route_key=route_key, query="book")
        token = page["rows"][0]["token"]
        args = argparse.Namespace(root=str(self.root), selection=token, command="check",
                                  acquire=True, lease_token=None, owner_pid=os.getpid(),
                                  query_timeout=5.0)
        self.events.clear()
        with mock.patch.object(worker, "emit", side_effect=self.events.append):
            worker.resolve_selection(args)
        lease = self.events[-1]["fetch_lease"]
        self.assertTrue(lease)

        updated_source = Path(self.tmp.name) / "manifest-new.txt"
        updated_source.write_bytes(b"offline fixture manifest version two")
        updated_records = [{"remote_path": "Books/replacement.txt", "size_raw": "1 B",
                            "size_bytes": 1, "size_precision": "exact"}]
        status = self.run_import(updated_records, updated_source)
        self.assertEqual(status, 3)
        self.assertIn("in progress", self.events[-1]["reason"])

        self.events.clear()
        with mock.patch.object(worker, "emit", side_effect=self.events.append):
            worker.release_lease(argparse.Namespace(root=str(self.root), lease_token=lease))
        self.assertTrue(self.events[-1]["released"])
        self.assertEqual(self.run_import(updated_records, updated_source), 0)
        args.acquire = False
        with self.assertRaisesRegex(ValueError, "stale"):
            worker.resolve_selection(args)

    def cancel_when_reusable_snapshot_opens(self):
        original_connect = sqlite3.connect

        def connect(database, *args, **kwargs):
            db = original_connect(database, *args, **kwargs)
            if isinstance(database, str) and "?mode=ro&immutable=1" in database:
                worker.CANCEL_REQUESTED = True
            return db

        return connect

    def assert_import_cancelled_without_changes(self, prior_id, prior_generation):
        registry = worker.open_registry(self.root)
        try:
            active = registry.execute("""SELECT a.snapshot_id,a.generation
              FROM active_snapshot a JOIN route r USING(route_id)""").fetchone()
            self.assertEqual((active["snapshot_id"], active["generation"]),
                             (prior_id, prior_generation))
            self.assertEqual(registry.execute(
                "SELECT count(*) FROM route_import_lock").fetchone()[0], 0)
            snapshot_count = registry.execute("SELECT count(*) FROM snapshot").fetchone()[0]
        finally:
            registry.close()
        self.assertEqual(list(self.root.glob(".building-*.sqlite")), [])
        self.assertEqual(len(list(self.root.glob("snapshot-*.sqlite"))), snapshot_count)

    def test_cancelled_reusable_retired_snapshot_does_not_reactivate(self):
        self.assertEqual(self.run_import(), 0)
        first_id = self.events[-1]["snapshot_id"]
        updated_source = Path(self.tmp.name) / "manifest-generation-two.txt"
        updated_source.write_bytes(b"fixture source generation two")
        self.assertEqual(self.run_import(source=updated_source), 0)
        second_id = self.events[-1]["snapshot_id"]
        self.assertNotEqual(first_id, second_id)

        self.events.clear()
        with mock.patch.object(worker.sqlite3, "connect",
                               side_effect=self.cancel_when_reusable_snapshot_opens()):
            with self.assertRaisesRegex(InterruptedError, "cancelled"):
                self.run_import()
        self.assertFalse(any(event.get("event") == "result" for event in self.events))
        self.assert_import_cancelled_without_changes(second_id, 2)

        worker.CANCEL_REQUESTED = False
        self.assertEqual(self.run_import(), 0)
        self.assertEqual(self.events[-1]["status"], "reused")
        self.assertEqual(self.events[-1]["generation"], 3)
        self.assertEqual(self.events[-1]["snapshot_id"], first_id)

    def test_cancelled_same_source_validation_reports_cancel_and_keeps_generation(self):
        self.assertEqual(self.run_import(), 0)
        snapshot_id = self.events[-1]["snapshot_id"]
        self.events.clear()
        with mock.patch.object(worker.sqlite3, "connect",
                               side_effect=self.cancel_when_reusable_snapshot_opens()):
            with self.assertRaisesRegex(InterruptedError, "cancelled"):
                self.run_import()
        self.assertFalse(any(event.get("event") == "result" for event in self.events))
        self.assert_import_cancelled_without_changes(snapshot_id, 1)

    def test_cancellation_while_waiting_for_publication_lock_rolls_back_candidate(self):
        self.assertEqual(self.run_import(), 0)
        prior_id = self.events[-1]["snapshot_id"]
        publication_begin = threading.Event()
        blocker_ready = threading.Event()
        release_blocker = threading.Event()
        blocker_thread = []
        import_errors = []
        original_connect = sqlite3.connect
        original_fsync = worker.os.fsync

        class RegistryConnection(sqlite3.Connection):
            def execute(connection, sql, parameters=()):
                if sql.strip().upper() == "BEGIN IMMEDIATE":
                    count = getattr(connection, "import_begin_count", 0) + 1
                    connection.import_begin_count = count
                    if count == 2:
                        publication_begin.set()
                return super(RegistryConnection, connection).execute(sql, parameters)

        def connect(database, *args, **kwargs):
            if Path(database).name == "catalog-registry.sqlite":
                kwargs["factory"] = RegistryConnection
            return original_connect(database, *args, **kwargs)

        def hold_registry_write_lock(fd):
            original_fsync(fd)
            def hold_lock():
                blocker = original_connect(self.root / "catalog-registry.sqlite", timeout=5)
                try:
                    blocker.execute("BEGIN IMMEDIATE")
                    blocker_ready.set()
                    release_blocker.wait(10)
                finally:
                    blocker.rollback()
                    blocker.close()

            thread = threading.Thread(target=hold_lock)
            blocker_thread.append(thread)
            thread.start()
            if not blocker_ready.wait(5):
                raise TimeoutError("test could not acquire the publication lock")

        def run_import_in_thread():
            try:
                updated_source = Path(self.tmp.name) / "manifest-publication-cancel.txt"
                updated_source.write_bytes(b"fixture publication cancellation")
                self.run_import(source=updated_source)
            except BaseException as exc:
                import_errors.append(exc)

        import_thread = threading.Thread(target=run_import_in_thread)
        with mock.patch.object(worker.sqlite3, "connect", side_effect=connect), \
             mock.patch.object(worker.os, "fsync", side_effect=hold_registry_write_lock):
            import_thread.start()
            try:
                self.assertTrue(publication_begin.wait(10), "worker did not reach publication lock")
                worker.CANCEL_REQUESTED = True
            finally:
                release_blocker.set()
                if blocker_thread:
                    blocker_thread[0].join(5)
                import_thread.join(10)

        self.assertFalse(import_thread.is_alive(), "cancelled import did not finish")
        self.assertTrue(import_errors)
        self.assertIsInstance(import_errors[0], InterruptedError)
        self.assert_import_cancelled_without_changes(prior_id, 1)
        worker.CANCEL_REQUESTED = False
        self.assertEqual(self.run_import(), 0)

    def test_failed_provider_never_replaces_active_snapshot(self):
        self.assertEqual(self.run_import(), 0)
        route_key = self.route_key()
        before = worker.open_registry(self.root)
        old_snapshot = before.execute(
            "SELECT snapshot_id FROM active_snapshot JOIN route USING(route_id) WHERE route_key=?",
            (bytes.fromhex(route_key),),
        ).fetchone()[0]
        before.close()
        changed = Path(self.tmp.name) / "malformed.txt"
        changed.write_bytes(b"offline malformed fixture")
        with self.assertRaisesRegex(ValueError, "failed|provider"):
            self.run_import(self.records[:1], changed, exit_code=2, final_ok=False)
        registry = worker.open_registry(self.root)
        try:
            current = registry.execute(
                "SELECT snapshot_id FROM active_snapshot WHERE route_id=1"
            ).fetchone()[0]
            self.assertEqual(current, old_snapshot)
        finally:
            registry.close()

    def test_sqlite_full_during_index_keeps_active_snapshot_and_releases_lock(self):
        self.assertEqual(self.run_import(), 0)
        registry = worker.open_registry(self.root)
        before = registry.execute(
            "SELECT snapshot_id FROM active_snapshot WHERE route_id=1"
        ).fetchone()[0]
        registry.close()

        updated_source = Path(self.tmp.name) / "manifest-updated.txt"
        updated_source.write_bytes(b"offline fixture manifest with a new generation")
        updated_records = [
            {"remote_path": f"IndexFull/file-{i:05}.txt", "size_raw": "1 B",
             "size_bytes": 1, "size_precision": "exact"}
            for i in range(5000)
        ]
        with mock.patch.dict(os.environ, {
            "FSERVE_CATALOG_TEST_MODE": "1",
            "FSERVE_CATALOG_TEST_SQLITE_FULL_AT": "first-index",
            "FSERVE_CATALOG_TEST_PAGE_LIMIT_DELTA": "1",
        }):
            with self.assertRaisesRegex(sqlite3.OperationalError, "full"):
                self.run_import(updated_records, updated_source)

        registry = worker.open_registry(self.root)
        try:
            current = registry.execute(
                "SELECT snapshot_id FROM active_snapshot WHERE route_id=1"
            ).fetchone()[0]
            self.assertEqual(current, before)
            self.assertEqual(registry.execute("SELECT count(*) FROM route_import_lock").fetchone()[0], 0)
        finally:
            registry.close()
        self.assertEqual(list(self.root.glob(".building-*.sqlite")), [])

    def test_gc_removes_crash_orphans_and_sqlite_sidecars(self):
        self.assertEqual(self.run_import(), 0)
        stale = time.time() - 2 * 86400
        building = self.root / (".building-" + "a" * 32 + ".sqlite")
        orphan = self.root / ("snapshot-" + "b" * 20 + "-" + "c" * 8 + ".sqlite")
        files = [building, Path(str(building) + "-journal"), orphan,
                 Path(str(orphan) + "-wal")]
        for path in files:
            path.write_bytes(b"offline crash artifact")
            os.utime(path, (stale, stale))

        self.events.clear()
        args = argparse.Namespace(root=str(self.root), retention_days=1, apply=True)
        with mock.patch.object(worker, "emit", side_effect=self.events.append):
            status = worker.collect_snapshots(args)
        self.assertEqual(status, 0)
        self.assertEqual(self.events[-1]["building_candidates"], 1)
        self.assertEqual(self.events[-1]["orphan_candidates"], 1)
        self.assertEqual(self.events[-1]["removed_files"], len(files))
        self.assertTrue(all(not path.exists() for path in files))

    def test_gc_does_not_remove_stale_building_file_while_import_is_live(self):
        self.assertEqual(self.run_import(), 0)
        building = self.root / (".building-" + "d" * 32 + ".sqlite")
        journal = Path(str(building) + "-journal")
        building.write_bytes(b"active build sentinel")
        journal.write_bytes(b"active journal sentinel")
        stale = time.time() - 2 * 86400
        os.utime(building, (stale, stale))
        os.utime(journal, (stale, stale))
        registry = worker.open_registry(self.root)
        try:
            registry.execute("INSERT INTO route_import_lock VALUES (?,?,?,?)",
                             (1, "live-test-lock", os.getpid(), time.time()))
            registry.commit()
        finally:
            registry.close()

        self.events.clear()
        args = argparse.Namespace(root=str(self.root), retention_days=1, apply=True)
        with mock.patch.object(worker, "emit", side_effect=self.events.append):
            status = worker.collect_snapshots(args)
        self.assertEqual(status, 0)
        self.assertEqual(self.events[-1]["building_candidates"], 0)
        self.assertTrue(building.exists())
        self.assertTrue(journal.exists())

    def test_route_identity_uses_irc_casemapping_but_not_path_case(self):
        key_one, _ = worker.route_identity(self.context, "rfc1459", "sensitive", "same")
        variant = {**self.context, "server_nick": "tnw"}
        key_two, _ = worker.route_identity(variant, "rfc1459", "sensitive", "same")
        self.assertEqual(key_one, key_two)
        self.assertNotEqual(worker.normalize_path("Dir/File.txt"),
                            worker.normalize_path("dir/file.txt"))

    def test_current_process_liveness_probe_is_safe(self):
        self.assertTrue(worker.process_is_alive(os.getpid()))

    def test_page_selection_and_cursor_are_bound_to_route_and_snapshot(self):
        self.assertEqual(self.run_import(), 0)
        route_key = self.route_key()
        page = self.query("search", route_key=route_key, query="book")
        with self.assertRaisesRegex(ValueError, "different query|expired"):
            self.query("search", route_key=route_key, query="books", cursor=page["next_cursor"])
        with self.assertRaisesRegex(ValueError, "three"):
            self.query("search", route_key=route_key, query="bo")


if __name__ == "__main__":
    unittest.main()
