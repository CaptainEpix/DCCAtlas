"""Offline W4 download-ledger and reconciliation regression tests."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import asyncio
from contextlib import closing
from pathlib import Path
import sqlite3
import sys
import tempfile
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from webapp.downloads import DownloadError, DownloadService
from webapp.engine_client import EngineRequestError


RESULT_A = "row-" + "a" * 32
RESULT_B = "row-" + "b" * 32
JOB_A = "job-" + "a" * 32
JOB_B = "job-" + "b" * 32


class FakeEngine:
    engine_instance_id = "fixture-engine-instance"

    def __init__(self):
        self.dispatch_mode = "job"
        self.lookup_error = None
        self.status_error = None
        self.cancel_error = None
        self.jobs_by_operation = {}
        self.calls = []
        self._next_job = 0

    async def request(self, operation, arguments=None, *, operation_id=None, timeout=10):
        arguments = arguments or {}
        self.calls.append((operation, dict(arguments), operation_id))
        if operation == "search.download":
            if self.dispatch_mode == "unknown":
                raise TimeoutError("fixture lost the dispatch response")
            if self.dispatch_mode == "handler_died":
                raise EngineRequestError("engine_error", "fixture handler died")
            if self.dispatch_mode == "too_large":
                raise EngineRequestError("response_too_large", "the reply was too large to send")
            if self.dispatch_mode == "refusal":
                raise EngineRequestError("stale_result", "fixture refused stale result")
            if self.dispatch_mode == "missing_job":
                return {"job": None}
            self._next_job += 1
            job = {
                "job_id": "job-" + f"{self._next_job:032x}",
                "web_operation_id": operation_id,
                "state": "preparing",
                "transition_sequence": 2,
                "outcome": None,
                "reason": None,
                "sender": "FixtureBot",
                "name": "fixture.txt",
                "remote_path": "/fixture.txt",
                "download_path": None,
                "bytes_received": 0,
                "total_bytes": 17,
            }
            self.jobs_by_operation[operation_id] = job
            return {"job": dict(job)}
        if operation == "job.find_by_operation":
            if self.lookup_error:
                raise self.lookup_error
            return {"job": self.jobs_by_operation.get(arguments["web_operation_id"])}
        if operation == "job.status":
            if self.status_error:
                raise self.status_error
            job = next((value for value in self.jobs_by_operation.values()
                        if value["job_id"] == arguments["job_id"]), None)
            return {"job": dict(job) if job is not None else None}
        if operation == "job.cancel":
            if self.cancel_error:
                raise self.cancel_error
            job = next(value for value in self.jobs_by_operation.values()
                       if value["job_id"] == arguments["job_id"])
            job["state"] = "cancelled"
            job["transition_sequence"] += 1
            return {"job": dict(job)}
        raise AssertionError(f"unexpected engine operation: {operation}")


class FakeSearches:
    def __init__(self, database: Path, engine: FakeEngine):
        # The stored rows, as a search keeps them; B's file server and file.
        rows = {RESULT_B: {"sender": "FixtureBot", "remote_path": "/books/refused.txt"}}
        self.store = SimpleNamespace(path=database, find_result=rows.get)
        self.engine = engine

    async def resolve_result(self, result_id):
        if result_id not in (RESULT_A, RESULT_B):
            raise AssertionError(f"unexpected result ID: {result_id}")
        return {
            "search_id": "search-fixture",
            "source_id": "primary",
            "source_revision": 1,
            "engine_instance_id": self.engine.engine_instance_id,
            "engine_search_id": "find-fixture",
            "engine_selection_id": "sel-" + "c" * 40,
        }


def make_services(database: Path, engine: FakeEngine):
    database.touch(exist_ok=True)
    sources = SimpleNamespace(
        store=SimpleNamespace(path=database), engine=engine,
    )
    searches = FakeSearches(database, engine)
    return DownloadService(sources, searches)


def seed_pending(service: DownloadService, key: str, result_id: str = RESULT_A):
    row, created = service.store.create_pending(
        operation_id=service._operation_id(key),
        idempotency_key=key,
        result_id=result_id,
        selection={
            "search_id": "search-fixture",
            "source_id": "primary",
            "source_revision": 1,
            "engine_instance_id": "fixture-engine-instance",
            "engine_search_id": "find-fixture",
        },
    )
    assert created
    return row


def job_snapshot(
    operation_id: str, *, job_id: str = JOB_A, state: str = "receiving",
    sequence: int | None = 5, bytes_received: int | None = 20,
):
    job = {
        "job_id": job_id,
        "web_operation_id": operation_id,
        "state": state,
        "outcome": None,
        "reason": None,
        "sender": "FixtureBot",
        "name": "fixture.txt",
        "remote_path": "/fixture.txt",
        "download_path": None,
        "bytes_received": bytes_received,
        "total_bytes": 100,
    }
    if sequence is not None:
        job["transition_sequence"] = sequence
    return job


class DownloadServiceTests(unittest.TestCase):
    def test_ended_records_are_deleted_one_or_all_and_others_kept(self):
        # Delete and Clear finished under Transfers (2026-10-29).
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            service = make_services(database, FakeEngine())
            from webapp.download_queue import QueueStore
            QueueStore(database)
            keys = [f"request-key-{number:07}" for number in range(1, 6)]
            ids = []
            for key, state in zip(keys, ("complete", "failed", "cancelled", "complete",
                                         "complete")):
                ids.append(seed_pending(service, key)["operation_id"])
                with closing(sqlite3.connect(database)) as connection, connection:
                    connection.execute("UPDATE download_operation SET state=? "
                                       "WHERE operation_id=?", (state, ids[-1]))
            with closing(sqlite3.connect(database)) as connection, connection:
                connection.execute("UPDATE download_operation SET state='receiving' "
                                   "WHERE operation_id=?", (ids[3],))
            # The last is one the queue is still following.
            with closing(sqlite3.connect(database)) as connection, connection:
                connection.execute(
                    "INSERT INTO download_queue (item_id, position, state, source_id, "
                    "source_revision, result_id, origin, sender, trigger_text, trigger_mode, "
                    "remote_path, operation_key, added_at, updated_at) VALUES "
                    "('queue-1', 1, 'running', 'primary', 1, ?, 'search', 'Fixture', "
                    "'!Fixture', 'channel_text', '/a.txt', ?, 0, 0)", (RESULT_A, keys[4]))

            async def workflow():
                await service.forget(ids[0])
                self.assertIsNone(service.store.get(ids[0]))
                for operation_id, code in ((ids[3], "not_finished"), (ids[4], "in_queue"),
                                           (ids[0], "unknown_operation"),
                                           ("not-an-id", "invalid_operation")):
                    with self.subTest(code), self.assertRaises(DownloadError) as refused:
                        await service.forget(operation_id)
                    self.assertEqual(refused.exception.code, code)
                self.assertEqual(await service.forget_finished(), 2)
                self.assertEqual(sorted(row["operation_id"] for row in service.store.recent(10)),
                                 sorted([ids[3], ids[4]]))

            asyncio.run(workflow())

    def test_uncertain_operation_needs_bound_confirmation_before_slot_release(self):
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            engine = FakeEngine()
            engine.dispatch_mode = "unknown"
            service = make_services(database, engine)

            async def workflow():
                uncertain = await service.download("request-key-0000001", RESULT_A)
                self.assertEqual(uncertain["state"], "needs_attention")
                operation_id = uncertain["operation_id"]
                self.assertIsNone(uncertain["job_id"])

                with self.assertRaises(DownloadError) as busy:
                    await service.download("request-key-0000002", RESULT_B)
                self.assertEqual(busy.exception.code, "download_busy")
                self.assertEqual(sum(call[0] == "search.download" for call in engine.calls), 1)

                with self.assertRaises(DownloadError) as confirmation:
                    await service.resolve_uncertain(operation_id, confirmation="yes")
                self.assertEqual(confirmation.exception.code, "confirmation_required")

                engine.engine_instance_id = "replacement-engine-instance"
                reconciled = await service.status(operation_id)
                self.assertEqual(reconciled["state"], "needs_attention")
                self.assertEqual(reconciled["outcome"], "job_not_reconciled")

                phrase = service.uncertain_resolution_phrase(operation_id)
                retired = await service.resolve_uncertain(operation_id, confirmation=phrase)
                self.assertEqual(retired["state"], "abandoned_uncertain")
                self.assertIn("may still exist", retired["reason"])

                engine.dispatch_mode = "job"
                next_download = await service.download("request-key-0000002", RESULT_B)
                self.assertEqual(next_download["state"], "preparing")
                self.assertEqual(
                    sum(call[0] == "search.download" for call in engine.calls), 2,
                    "retiring uncertainty must not replay the old request",
                )
                self.assertEqual((await service.status(operation_id))["state"], "abandoned_uncertain")

            asyncio.run(workflow())

    def test_job_missing_from_engine_journal_can_be_retired_but_known_job_cannot(self):
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            engine = FakeEngine()
            service = make_services(database, engine)

            async def workflow():
                started = await service.download("request-key-0000001", RESULT_A)
                operation_id = started["operation_id"]
                phrase = service.uncertain_resolution_phrase(operation_id)
                self.assertIsNotNone(started["job_id"])
                self.assertFalse(started["abandonable"])

                engine.status_error = EngineRequestError("journal_unavailable", "fixture")
                unavailable = await service.status(operation_id)
                self.assertEqual(unavailable["state"], "needs_attention")
                self.assertFalse(unavailable["abandonable"])
                with self.assertRaises(DownloadError) as refused:
                    await service.resolve_uncertain(operation_id, confirmation=phrase)
                self.assertEqual(refused.exception.code, "not_resolvable")

                engine.status_error = None
                recovered = await service.status(operation_id)
                self.assertEqual(recovered["state"], "preparing")

                engine.status_error = EngineRequestError("unknown_job", "fixture lost journal")
                missing = await service.status(operation_id)
                self.assertEqual(missing["state"], "needs_attention")
                self.assertEqual(missing["outcome"], "engine_job_missing")
                self.assertTrue(missing["abandonable"])
                with self.assertRaises(DownloadError) as busy:
                    await service.download("request-key-0000002", RESULT_B)
                self.assertEqual(busy.exception.code, "download_busy")

                retired = await service.resolve_uncertain(operation_id, confirmation=phrase)
                self.assertEqual(retired["state"], "abandoned_uncertain")
                self.assertEqual(retired["job_id"], started["job_id"])
                engine.status_error = None
                self.assertEqual(
                    (await service.download("request-key-0000002", RESULT_B))["state"],
                    "preparing",
                )

            asyncio.run(workflow())

    def test_handler_failure_during_dispatch_is_uncertain_not_a_refusal(self):
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            engine = FakeEngine()
            service = make_services(database, engine)

            async def workflow():
                engine.dispatch_mode = "handler_died"
                uncertain = await service.download("request-key-0000001", RESULT_A)
                self.assertEqual(uncertain["state"], "needs_attention")
                self.assertEqual(uncertain["outcome"], "dispatch_outcome_unknown")

                engine.dispatch_mode = "refusal"
                with self.assertRaises(DownloadError) as busy:
                    await service.download("request-key-0000002", RESULT_B)
                self.assertEqual(busy.exception.code, "download_busy")
                await service.resolve_uncertain(
                    uncertain["operation_id"],
                    confirmation=service.uncertain_resolution_phrase(uncertain["operation_id"]),
                )
                with self.assertRaises(DownloadError) as refused:
                    await service.download("request-key-0000002", RESULT_B)
                self.assertEqual(refused.exception.code, "stale_result")
                failed = (await service.history())[0]
                self.assertEqual(
                    failed["state"], "failed",
                    "a definitive refusal is terminal and frees the slot",
                )
                # A refused start still names what was asked for (2026-10-27).
                self.assertEqual((failed["sender"], failed["name"], failed["remote_path"]),
                                 ("FixtureBot", "refused.txt", "/books/refused.txt"))

            asyncio.run(workflow())

    def test_dispatch_reply_too_large_to_send_is_uncertain_not_a_refusal(self):
        # The engine refuses a reply too large for one frame after it has
        # acted on the request, so the refusal does not show that nothing
        # was sent.
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            engine = FakeEngine()
            service = make_services(database, engine)

            async def workflow():
                engine.dispatch_mode = "too_large"
                uncertain = await service.download("request-key-0000001", RESULT_A)
                self.assertEqual(uncertain["state"], "needs_attention")
                self.assertEqual(uncertain["outcome"], "dispatch_outcome_unknown")
                self.assertEqual(sum(call[0] == "search.download" for call in engine.calls), 1)

            asyncio.run(workflow())

    def test_each_cancel_is_its_own_request(self):
        # The engine answers a repeated operation ID from its memory, failures
        # included, so a Cancel that failed would fail again however often it
        # was tried. Cancelling twice is harmless in the engine.
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            engine = FakeEngine()
            service = make_services(database, engine)

            async def workflow():
                started = await service.download("request-key-0000001", RESULT_A)
                operation_id = started["operation_id"]
                engine.cancel_error = EngineRequestError("journal_unavailable", "fixture")
                failed = await service.cancel(operation_id)
                self.assertEqual(failed["state"], "needs_attention")
                engine.cancel_error = None
                cancelled = await service.cancel(operation_id)
                self.assertEqual(cancelled["state"], "cancelled")
                ids = [call[2] for call in engine.calls if call[0] == "job.cancel"]
                self.assertEqual(len(ids), 2)
                self.assertNotEqual(ids[0], ids[1], "the second Cancel is a new request")
                self.assertEqual(ids[0][:44], ids[1][:44], "both name the same download")
                for value in ids:
                    self.assertRegex(value, r"\Aweb-cancel-[0-9a-f]{32}-[0-9a-f]{32}\Z")

            asyncio.run(workflow())

    def test_v1_database_migrates_terminal_slot_predicate(self):
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            engine = FakeEngine()
            service = make_services(database, engine)
            pending = seed_pending(service, "migration-key-000001")
            service.store.mark_needs_attention(
                pending["operation_id"], outcome="job_not_reconciled",
                reason="fixture unknown operation",
            )

            with closing(sqlite3.connect(database)) as connection:
                connection.execute("UPDATE download_schema SET version=1 WHERE singleton=1")
                connection.execute("DROP INDEX download_one_active")
                connection.execute("""
                    CREATE UNIQUE INDEX download_one_active ON download_operation(active_guard)
                    WHERE state NOT IN ('complete','failed','cancelled','expired','stale',
                                        'refused_without_queue')
                """)
                connection.commit()

            migrated = make_services(database, engine)
            with closing(sqlite3.connect(database)) as connection:
                self.assertEqual(connection.execute(
                    "SELECT version FROM download_schema WHERE singleton=1"
                ).fetchone()[0], 3)

            async def workflow():
                phrase = migrated.uncertain_resolution_phrase(pending["operation_id"])
                result = await migrated.resolve_uncertain(
                    pending["operation_id"], confirmation=phrase,
                )
                self.assertEqual(result["state"], "abandoned_uncertain")
                next_row, created = migrated.store.create_pending(
                    operation_id=migrated._operation_id("migration-key-000002"),
                    idempotency_key="migration-key-000002", result_id=RESULT_B,
                    selection={
                        "search_id": "search-fixture", "source_id": "primary",
                        "source_revision": 1, "engine_instance_id": engine.engine_instance_id,
                        "engine_search_id": "find-fixture",
                    },
                )
                self.assertTrue(created)
                self.assertEqual(next_row["state"], "dispatch_pending")

            asyncio.run(workflow())

    def test_v2_database_gets_two_slots_and_keeps_its_rows(self):
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            engine = FakeEngine()
            service = make_services(database, engine)
            kept = seed_pending(service, "migration-key-000003")
            with closing(sqlite3.connect(database)) as connection:
                # Back to version 2's table: one slot only.
                sql = connection.execute("SELECT sql FROM sqlite_master WHERE type='table' "
                                         "AND name='download_operation'").fetchone()[0]
                connection.execute("DROP INDEX download_one_active")
                connection.execute("ALTER TABLE download_operation RENAME TO old_operation")
                connection.execute(sql.replace("CHECK (active_guard IN (1, 2))",
                                               "CHECK (active_guard = 1)"))
                connection.execute("INSERT INTO download_operation SELECT * FROM old_operation")
                connection.execute("DROP TABLE old_operation")
                connection.execute("UPDATE download_schema SET version=2 WHERE singleton=1")
                connection.commit()

            migrated = make_services(database, engine)
            with closing(sqlite3.connect(database)) as connection:
                self.assertEqual(connection.execute(
                    "SELECT version FROM download_schema WHERE singleton=1").fetchone()[0], 3)
                self.assertIn("CHECK (active_guard IN (1, 2))", connection.execute(
                    "SELECT sql FROM sqlite_master WHERE name='download_operation'").fetchone()[0])
            self.assertEqual(migrated.store.get(kept["operation_id"])["idempotency_key"],
                             "migration-key-000003", "its rows are kept")
            with closing(sqlite3.connect(database)) as connection:
                connection.execute("UPDATE download_operation SET state='receiving'")
                connection.commit()
            selection = {"search_id": "search-fixture", "source_id": "primary",
                         "source_revision": 1, "engine_instance_id": engine.engine_instance_id,
                         "engine_search_id": "find-fixture"}
            second, created = migrated.store.create_pending(
                operation_id=migrated._operation_id("migration-key-000004"),
                idempotency_key="migration-key-000004", result_id=RESULT_B,
                selection=selection, at_once=2)
            self.assertTrue(created)
            self.assertEqual(second["active_guard"], 2, "the second slot")
            with self.assertRaises(DownloadError) as full:
                migrated.store.create_pending(
                    operation_id=migrated._operation_id("migration-key-000005"),
                    idempotency_key="migration-key-000005", result_id=RESULT_A,
                    selection=selection, at_once=2)
            self.assertEqual(full.exception.code, "download_busy", "never a third")
            with closing(sqlite3.connect(database)) as connection, self.assertRaises(
                    sqlite3.IntegrityError, msg="the database itself allows two at most"):
                connection.execute("""INSERT INTO download_operation (operation_id,
                    idempotency_key, request_fingerprint, result_id, search_id, source_id,
                    source_revision, engine_instance_id, engine_search_id, state, active_guard,
                    created_at, updated_at) VALUES ('x', 'x', 'x', 'x', 'x', 'x', 1, 'x', 'x',
                    'receiving', 3, 0, 0)""")

    def test_job_snapshots_require_known_state_sequence_and_stable_identity(self):
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            service = make_services(database, FakeEngine())
            pending = seed_pending(service, "snapshot-key-000001")
            operation_id = pending["operation_id"]

            first = service._apply_job(operation_id, job_snapshot(operation_id, sequence=8))
            self.assertEqual((first["state"], first["engine_transition_sequence"]),
                             ("receiving", 8))
            self.assertEqual(first["bytes_received"], 20)

            stale = service._apply_job(operation_id, job_snapshot(
                operation_id, state="ready", sequence=7, bytes_received=4,
            ))
            self.assertEqual((stale["state"], stale["engine_transition_sequence"]),
                             ("receiving", 8))
            self.assertEqual(stale["bytes_received"], 20)

            same_sequence_progress = service._apply_job(operation_id, job_snapshot(
                operation_id, sequence=8, bytes_received=12,
            ))
            self.assertEqual(same_sequence_progress["bytes_received"], 20)

            conflicting_sequence = service._apply_job(operation_id, job_snapshot(
                operation_id, state="finalizing", sequence=8,
            ))
            self.assertEqual(conflicting_sequence["state"], "needs_attention")
            self.assertEqual(conflicting_sequence["engine_state"], "receiving")
            self.assertEqual(conflicting_sequence["outcome"], "sequence_state_conflict")

            conflicting_identity = service._apply_job(operation_id, job_snapshot(
                operation_id, job_id=JOB_B, state="finalizing", sequence=9,
            ))
            self.assertEqual(conflicting_identity["state"], "needs_attention")
            self.assertEqual(conflicting_identity["job_id"], JOB_A)
            self.assertEqual(conflicting_identity["outcome"], "job_identity_conflict")

    def test_missing_sequence_and_unknown_state_are_not_accepted(self):
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            service = make_services(database, FakeEngine())
            first = seed_pending(service, "invalid-sequence-key-001")
            missing = service._apply_job(
                first["operation_id"], job_snapshot(first["operation_id"], sequence=None),
            )
            self.assertEqual(missing["state"], "needs_attention")
            self.assertEqual(missing["outcome"], "invalid_transition_sequence")
            self.assertEqual(missing["engine_transition_sequence"], -1)
            boolean_sequence = service._apply_job(
                first["operation_id"],
                job_snapshot(first["operation_id"], sequence=True),
            )
            self.assertEqual(boolean_sequence["state"], "needs_attention")
            self.assertEqual(boolean_sequence["outcome"], "invalid_transition_sequence")

            service.store.record_refusal(
                first["operation_id"], outcome="fixture_retired", reason="fixture",
            )
            second = seed_pending(service, "invalid-state-key-0001", RESULT_B)
            unknown = service._apply_job(
                second["operation_id"],
                job_snapshot(second["operation_id"], state="invented_state", sequence=2),
            )
            self.assertEqual(unknown["state"], "needs_attention")
            self.assertEqual(unknown["outcome"], "invalid_job_evidence")
            self.assertIsNone(unknown["job_id"])

    def test_transition_sequence_outside_sqlite_integer_range_is_uncertain(self):
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            service = make_services(database, FakeEngine())
            pending = seed_pending(service, "overflow-sequence-key-01")
            result = service._apply_job(
                pending["operation_id"],
                job_snapshot(
                    pending["operation_id"], sequence=9_223_372_036_854_775_808,
                ),
            )
            self.assertEqual(result["state"], "needs_attention")
            self.assertEqual(result["outcome"], "invalid_transition_sequence")
            self.assertEqual(result["engine_transition_sequence"], -1)

    def test_atomic_sequence_application_wins_across_service_instances(self):
        with tempfile.TemporaryDirectory(prefix=".test-web-download-", dir=ROOT) as temporary:
            database = Path(temporary) / "application.sqlite3"
            first_engine, second_engine = FakeEngine(), FakeEngine()
            first_service = make_services(database, first_engine)
            second_service = make_services(database, second_engine)
            pending = seed_pending(first_service, "concurrent-key-000001")
            operation_id = pending["operation_id"]
            first_service._apply_job(operation_id, job_snapshot(operation_id, sequence=4))

            def apply(service, sequence, state):
                return service._apply_job(operation_id, job_snapshot(
                    operation_id, sequence=sequence, state=state,
                ))

            with ThreadPoolExecutor(max_workers=2) as pool:
                newer = pool.submit(apply, first_service, 10, "finalizing")
                older = pool.submit(apply, second_service, 9, "receiving")
                newer.result()
                older.result()

            latest = first_service.store.get(operation_id)
            self.assertEqual(latest["engine_transition_sequence"], 10)
            self.assertEqual(latest["engine_state"], "finalizing")
            self.assertEqual(latest["state"], "finalizing")


if __name__ == "__main__":
    unittest.main()
