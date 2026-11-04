"""File servers seen in a source's channel (web M3, Y1)."""

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
from webapp.adverts import KEEP_SECONDS, AdvertService, clean_advert
from webapp.engine_client import EngineClient, EngineRequestError
from webapp.sources import SourceService, UnknownSource


def source_values(port: int = 6667, **overrides):
    values = dict(label="Lab", provider="sysreset_find", host="127.0.0.1",
                  port=port, tls=False, nickname="SeenTest", channel="#review")
    values.update(overrides)
    return values


def engine_advert(nick="Fixture", age=0.0, **extra):
    advert = {
        "nick": nick, "first_seen": 1000.0 - age, "last_seen": 1000.0 - age, "seen_count": 1,
        "triggers": [{"trigger": "!fserve", "kind": "channel", "voice_only": False,
                      "queued": 0, "queue_limit": 10}],
        "users": {"in_use": 0, "limit": 5}, "version": "2.55",
    }
    advert.update(extra)
    return advert


class FakeEngine:
    """Answers adverts.list from a list it is given; records every request."""

    def __init__(self):
        self.adverts: list[dict] = []
        self.unrecognised = 0
        self.refusal: str | None = None
        self.requests: list[tuple[str, dict]] = []

    async def request(self, operation, arguments=None, *, operation_id=None, timeout=10.0):
        self.requests.append((operation, dict(arguments or {})))
        if operation == "source.configure":
            return {"source": {}}
        if operation == "status":
            return {"sources": []}
        if operation != "adverts.list":
            raise AssertionError(f"unexpected request {operation}")
        if self.refusal:
            raise EngineRequestError(self.refusal, "refused")
        offset, limit = arguments.get("offset", 0), arguments.get("limit", 25)
        return {"source_id": arguments["source_id"], "now": 1000.0, "offset": offset,
                "total": len(self.adverts), "unrecognised": self.unrecognised,
                "adverts": self.adverts[offset:offset + limit]}

    async def status(self):
        return {"sources": []}

    def list_requests(self):
        return [args for operation, args in self.requests if operation == "adverts.list"]


class AdvertOfflineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.engine = FakeEngine()
        self.sources = SourceService(Path(self.directory.name) / "fserve.sqlite3", self.engine)
        self.service = AdvertService(self.sources)
        asyncio.run(self.sources.save(source_values()))

    def tearDown(self):
        self.directory.cleanup()

    def listed(self, source_id="primary"):
        self.service._refreshed.clear()
        return asyncio.run(self.service.list(source_id))

    def test_adverts_are_listed_kept_and_marked_by_age(self):
        self.engine.adverts = [engine_advert("Fresh"), engine_advert("Old", age=2 * 3600)]
        self.engine.unrecognised = 2
        reply = self.listed()
        self.assertTrue(reply["supported"])
        self.assertEqual([item["nick"] for item in reply["adverts"]], ["Fresh", "Old"])
        self.assertFalse(reply["adverts"][0]["stale"])
        self.assertTrue(reply["adverts"][1]["stale"], "unseen for over an hour")
        self.assertEqual(reply["adverts"][0]["triggers"][0]["trigger"], "!fserve")
        self.assertEqual(reply["unrecognised"], 2)
        # The engine forgets everything when it restarts; the web service does not.
        self.engine.adverts = []
        self.assertEqual([item["nick"] for item in self.listed()["adverts"]], ["Fresh", "Old"])
        sent = [operation for operation, _ in self.engine.requests]
        self.assertEqual(set(sent) - {"source.configure", "status"}, {"adverts.list"},
                         "listing adverts only ever asks the engine for its list")

    def test_a_newer_advert_replaces_the_stored_one(self):
        self.engine.adverts = [engine_advert("Fixture", age=60, message="first")]
        self.listed()
        self.engine.adverts = [engine_advert("fixture", message="second", seen_count=2)]
        adverts = self.listed()["adverts"]
        self.assertEqual(len(adverts), 1, "a nick in another case is the same server")
        self.assertEqual((adverts[0]["nick"], adverts[0]["message"], adverts[0]["seen_count"]),
                         ("fixture", "second", 2))
        self.engine.adverts = [engine_advert("Fixture", age=600, message="older")]
        self.assertEqual(self.listed()["adverts"][0]["message"], "second",
                         "an older advert does not replace a newer one")

    def test_a_day_without_an_advert_drops_the_server(self):
        self.engine.adverts = [engine_advert("Gone", age=KEEP_SECONDS + 60), engine_advert("Here")]
        self.assertEqual([item["nick"] for item in self.listed()["adverts"]], ["Here"])

    def test_pointing_the_source_elsewhere_forgets_its_adverts(self):
        self.engine.adverts = [engine_advert("Fixture")]
        self.listed()
        self.engine.adverts = []
        asyncio.run(self.sources.save(source_values(channel="#elsewhere")))
        self.assertEqual(self.listed()["adverts"], [])
        asyncio.run(self.sources.save(source_values()))
        self.assertEqual(self.listed()["adverts"], [], "and going back does not bring them back")

    def test_a_search_bot_source_lists_the_servers_in_its_channel_too(self):
        # A search bot's channel has list and file servers (2026-10-28).
        source_id = asyncio.run(self.sources.create(
            source_values(provider="searchbot", search_bot="Search", nickname="Other")))["source_id"]
        self.engine.adverts = [engine_advert("Shelf")]
        before = len(self.engine.list_requests())
        reply = self.listed(source_id)
        self.assertTrue(reply["supported"])
        self.assertEqual([advert["nick"] for advert in reply["adverts"]], ["Shelf"])
        self.assertEqual(len(self.engine.list_requests()), before + 1, "the engine was asked")

    def test_the_page_vouches_for_a_list_server_it_kept(self):
        # Kept over an engine restart (2026-10-28), so Get list still works.
        self.engine.adverts = [
            engine_advert("Shelf", script="list", triggers=[{"trigger": "@Shelf", "kind": "list"}]),
            engine_advert("Plain")]
        self.listed()
        self.engine.adverts = []
        self.assertTrue(self.service.offers_list("primary", "shelf"), "nick case is IRC case")
        self.assertFalse(self.service.offers_list("primary", "Plain"), "a file server is not one")
        self.assertFalse(self.service.offers_list("primary", "Nobody"))
        self.assertFalse(self.service.offers_list("nowhere", "Shelf"))

    def test_a_nick_typed_by_the_operator_is_taken_as_a_list_server(self):
        # "Get list for a nick" beside !list (2026-10-29).
        self.assertFalse(self.service.offers_list("primary", "Quill"))
        self.service.vouch("primary", "Quill")
        self.assertTrue(self.service.offers_list("primary", "quill"), "IRC case")
        self.assertFalse(self.service.offers_list("other", "Quill"), "on that source only")
        # Typed, so its list may come from another nick (2026-11-02); a nick
        # only seen advertising is not.
        self.assertTrue(self.service.typed("primary", "QUILL"))
        self.assertFalse(self.service.typed("other", "Quill"))
        self.assertFalse(self.service.typed("primary", "Sprout"))

    def test_an_unknown_source_is_refused(self):
        with self.assertRaises(UnknownSource):
            self.listed("nowhere")

    def test_the_engine_is_asked_at_most_every_few_seconds(self):
        self.engine.adverts = [engine_advert()]
        asyncio.run(self.service.list("primary"))
        asyncio.run(self.service.list("primary"))
        self.assertEqual(len(self.engine.list_requests()), 1)

    def test_pages_are_read_up_to_the_engine_limit(self):
        self.engine.adverts = [engine_advert(f"Server{n}") for n in range(60)]
        self.assertEqual(len(self.listed()["adverts"]), 60)
        self.assertEqual([args["offset"] for args in self.engine.list_requests()], [0, 25, 50])

    def test_an_engine_without_the_source_leaves_what_is_stored(self):
        self.engine.adverts = [engine_advert("Kept")]
        self.listed()
        self.engine.refusal = "unknown_source"
        self.assertEqual([item["nick"] for item in self.listed()["adverts"]], ["Kept"])

    def test_malformed_entries_are_left_out(self):
        good = engine_advert("Good")
        bad = [
            engine_advert("Bad name!"),
            engine_advert("Ctrl", message="a\x01b"),
            engine_advert("Long", message="m" * 301),
            engine_advert("Kind", triggers=[{"trigger": "!x", "kind": "dcc"}]),
            engine_advert("Users", users={"in_use": "0", "limit": 5}),
            engine_advert("Many", triggers=[{"trigger": f"!t{n}", "kind": "channel"} for n in range(9)]),
            engine_advert("CtcpNick", triggers=[{"trigger": "!x", "kind": "ctcp", "ctcp_nick": "a b"}]),
            engine_advert("Restricted", restricted="admin"),
            engine_advert("Script", script="mirc"),
            engine_advert("Content", content=7),
            "not an object",
        ]
        self.engine.adverts = [good, *bad]
        self.assertEqual([item["nick"] for item in self.listed()["adverts"]], ["Good"])

    def test_clean_advert_keeps_only_what_the_page_shows(self):
        cleaned = clean_advert(engine_advert(
            "Shown", restricted="Voice", stats={"Bytes Sent": "1GB"}, extra="dropped",
            triggers=[{"trigger": "!t", "kind": "ctcp", "ctcp_nick": "Shown",
                       "ctcp_nick_is_sender": True, "pool": 2, "unknown": 1}]))
        self.assertNotIn("extra", cleaned)
        self.assertEqual(cleaned["triggers"], [{"trigger": "!t", "kind": "ctcp", "ctcp_nick": "Shown",
                                                "ctcp_nick_is_sender": True, "pool": 2,
                                                "voice_only": False}])
        self.assertEqual(cleaned["stats"], {"Bytes Sent": "1GB"})
        self.assertEqual(cleaned["script"], "sysreset", "an entry naming no script is SysReset's")

    def test_an_fservepl_advert_keeps_its_script_and_what_it_serves(self):
        cleaned = clean_advert(engine_advert(
            "Irssiserve", script="fserve.pl", version="2.0.0", content="RPG books",
            triggers=[{"trigger": "!irssi", "kind": "ctcp", "ctcp_nick": "Irssiserve",
                       "ctcp_nick_is_sender": True}]))
        self.assertEqual((cleaned["script"], cleaned["version"], cleaned["content"]),
                         ("fserve.pl", "2.0.0", "RPG books"))

    def test_a_list_server_has_one_trigger_its_own_at_nick(self):
        list_trigger = [{"trigger": "@Musing", "kind": "list", "voice_only": False}]
        raw = engine_advert("Musing", script="list", triggers=list_trigger,
                            message="Type: @Musing For My List Of: 1,068,389 Files")
        raw.pop("users")
        cleaned = clean_advert(raw)
        self.assertEqual((cleaned["script"], cleaned["triggers"]), ("list", list_trigger))
        # Any other shape is left out: another nick's @, a second trigger,
        # a list trigger on a file server, a list server without one.
        for script, triggers in (
                ("list", [{**list_trigger[0], "trigger": "@Someone"}]),
                ("list", list_trigger * 2),
                ("sysreset", list_trigger),
                ("list", [{"trigger": "!p", "kind": "channel", "voice_only": False}])):
            raw = engine_advert("Musing", script=script, triggers=triggers)
            raw.pop("users")
            self.assertIsNone(clean_advert(raw), (script, triggers))

    def test_a_file_server_may_offer_its_list_on_its_own_at_nick_too(self):
        # One FServe.pl server's "@Nick for my file list" (2026-10-29).
        own = {"trigger": "!quill", "kind": "ctcp", "ctcp_nick": "Quill",
               "ctcp_nick_is_sender": True, "voice_only": False}
        listed = {"trigger": "@Quill", "kind": "list", "voice_only": False}
        cleaned = clean_advert(engine_advert("Quill", script="fserve.pl", triggers=[own, listed]))
        self.assertEqual(cleaned["triggers"], [own, listed])
        for triggers in ([own, {**listed, "trigger": "@Someone"}], [own, listed, listed]):
            self.assertIsNone(clean_advert(engine_advert("Quill", script="fserve.pl",
                                                         triggers=triggers)), triggers)
        self.engine.adverts = [engine_advert("Quill", script="fserve.pl", triggers=[own, listed])]
        self.listed()
        self.assertTrue(self.service.offers_list("primary", "Quill"))
        self.assertEqual(self.service.file_server_trigger("primary", "quill"), "/ctcp Quill !quill")


try:
    from web_bridge_test import IRCFixture, NativeIrssi
except ImportError:   # the native helpers need a POSIX pty
    IRCFixture = NativeIrssi = None


def fservepl_advert(nick: str, trigger: str) -> str:
    """An advert as FServe.pl 2.0.0's show_notice builds it, with its colour codes."""
    hi, txt = "\x0312", "\x0315"
    return (f"{txt}\x02({hi}\x02FServe Online\x02{txt})\x02 Trigger:({hi}/ctcp {nick} {trigger}{txt})"
            f" Sends:({hi}0/2{txt}) Queues:({hi}0/10{txt}) [FServe.pl 2.0.0]")


def sysreset_advert(nick_triggers: str, message: str = "Fixture books") -> str:
    """An advert as SysReset 2.55 builds it, with its colour codes."""
    c1, c2 = "\x0304", "\x0314"
    return (f"{c1}[{c2}Fserve Active{c1}] - Trigger:[{c2}{nick_triggers}{c1}(0/10){c1}]"
            f" - Users:[{c2}0/5{c1}] - Message:[{c2}{message}{c1}] - SysReset 2.55")


@unittest.skipIf(NativeIrssi is None, "needs the native Irssi helpers")
class AdvertNativeTests(unittest.TestCase):
    def test_adverts_are_read_from_the_channel_and_a_flood_of_them_costs_little(self):
        fixture = IRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                async def workflow():
                    engine = await EngineClient.open(str(native.path))
                    try:
                        with tempfile.TemporaryDirectory() as directory:
                            sources = SourceService(Path(directory) / "fserve.sqlite3", engine)
                            service = AdvertService(sources)
                            await sources.save(source_values(fixture.port))
                            await sources.connect()
                            deadline = time.monotonic() + 15
                            while time.monotonic() < deadline:
                                view = sources.engine_source(await engine.status(), "primary")
                                if view and view["state"] == "ready":
                                    break
                                await asyncio.sleep(.05)
                            else:
                                self.fail("the source did not become ready")
                            sent_before = len(fixture.lines)

                            fixture.send(
                                f":Fixture!fx@127.0.0.1 PRIVMSG #review :{sysreset_advert('!Fixture')}"
                                .encode())
                            fixture.send(b":Chatter!cx@127.0.0.1 PRIVMSG #review :hello all")
                            fixture.send(
                                f":Irssiserve!ix@127.0.0.1 PRIVMSG #review :"
                                f"{fservepl_advert('Irssiserve', '!irssi')}".encode())
                            deadline = time.monotonic() + 10
                            reply = None
                            while time.monotonic() < deadline:
                                service._refreshed.clear()
                                reply = await service.list("primary")
                                if len(reply["adverts"]) >= 2:
                                    break
                                await asyncio.sleep(.1)
                            self.assertEqual([item["nick"] for item in reply["adverts"]],
                                             ["Fixture", "Irssiserve"])
                            advert = reply["adverts"][0]
                            self.assertEqual(advert["triggers"][0]["trigger"], "!Fixture")
                            self.assertEqual(advert["message"], "Fixture books")
                            self.assertEqual(advert["script"], "sysreset")
                            irssi = reply["adverts"][1]
                            self.assertEqual((irssi["script"], irssi["triggers"][0]["trigger"],
                                              irssi["triggers"][0]["ctcp_nick_is_sender"]),
                                             ("fserve.pl", "!irssi", True))

                            # A flood: 5,000 adverts from 1,000 nicks, sent at once.
                            burst = b"".join(
                                f":Flood{n % 1000}!f@127.0.0.1 PRIVMSG #review :"
                                f"{sysreset_advert('!Flood' + str(n % 1000))}\r\n".encode()
                                for n in range(5000))
                            flood_started = time.monotonic()
                            with fixture.send_lock:
                                fixture.client.sendall(burst)
                            slowest = 0.0
                            deadline = time.monotonic() + 30
                            while time.monotonic() < deadline:
                                started = time.monotonic()
                                page = await engine.request("adverts.list",
                                                            {"source_id": "primary", "limit": 1})
                                slowest = max(slowest, time.monotonic() - started)
                                # The last line is from Flood999. With room for 200,
                                # each nick was dropped and seen afresh many times.
                                if page["adverts"] and page["adverts"][0]["nick"] == "Flood999":
                                    break
                                await asyncio.sleep(.02)
                            else:
                                self.fail("the flood of adverts was not read")
                            self.assertEqual(page["total"], 200, "the engine keeps at most 200 servers")
                            print(f"\nflood of 5,000 adverts read in {time.monotonic() - flood_started:.2f} s;"
                                  f" slowest list reply {slowest:.3f} s", flush=True)
                            self.assertLess(slowest, 2.0, "the engine kept answering during the flood")
                            nicks = {item["nick"] for item in (await engine.request(
                                "adverts.list", {"source_id": "primary", "offset": 175, "limit": 25}))["adverts"]}
                            self.assertEqual(nicks, {f"Flood{n}" for n in range(800, 825)},
                                             "the 200 most recently seen are kept")
                            service._refreshed.clear()
                            self.assertEqual(len((await service.list("primary"))["adverts"]), 200)

                            # Irssi's own queries after joining (the channel's
                            # modes, ban list and users) can come late on a
                            # loaded machine; they are not caused by an advert.
                            sent = [line for line in fixture.lines[sent_before:]
                                    if not line.startswith((b"PONG", b"PING"))
                                    and bytes(line) not in (b"MODE #review", b"MODE #review b",
                                                            b"WHO #review")]
                            self.assertEqual(sent, [], "nothing was sent because of an advert")
                            await sources.disconnect()
                    finally:
                        await engine.close()

                asyncio.run(workflow())
            self.assertFalse(fixture.errors, fixture.errors)
        finally:
            fixture.stop()


if __name__ == "__main__":
    unittest.main()
