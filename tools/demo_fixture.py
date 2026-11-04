"""Run the generated IRC/Find/FServe fixture for a browser demonstration.

Start it inside the product container so IRC and DCC stay on the container's
loopback. Configure the source in the browser as host 127.0.0.1, the chosen
port, plain text (no TLS), any nickname, channel #review, then search for
anything: the fixture answers every Find with one small generated file.

Options make it misbehave on purpose: `--extra-results N` lists N more files
it does not have (paging, and a refused selection); `--stall-bytes N` sends
only N bytes and then waits (cancel during a transfer); adding `--drop` closes
the transfer there instead (an interrupted transfer). `--file-list` adds a
second file, `list.txt`: the server's own list of its files, naming the one it
has and one it no longer has (for the browser's file-list search).
`--search-bot` adds a search bot named SearchBot: it answers `@search` with a
result list of three rows from BookBot, one of which BookBot then sends.
`--adverts N` has the file server, and a second one that does not exist,
announce themselves in #review every N seconds, as SysReset 2.55 does (for
the "File servers seen" card).

One fixture serves one IRC client. To try several sources, start one fixture
per source, each on its own `--port` and with its own `--status-file`; a
second source pointed at a fixture already in use fails to connect.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import signal
import socket
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "t"))
from web_download_native_test import CONTENT, FILENAME, DownloadFixture


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=6667)
    parser.add_argument("--status-file", type=Path,
                        help="write the fixture's request counters here as JSON")
    parser.add_argument("--extra-results", type=int, default=0)
    parser.add_argument("--stall-bytes", type=int)
    parser.add_argument("--drop", action="store_true")
    parser.add_argument("--file-list", action="store_true")
    parser.add_argument("--search-bot", action="store_true")
    parser.add_argument("--adverts", type=float, metavar="SECONDS")
    arguments = parser.parse_args()

    fixture = DownloadFixture()
    fixture.extra_results = arguments.extra_results
    fixture.stall_after_bytes = arguments.stall_bytes
    fixture.drop_after_stall = arguments.drop
    if arguments.file_list:
        fixture.extra_files["list.txt"] = (
            f"[  {len(CONTENT)}]  books\\{FILENAME}\n[ 1.2M]  books\\gone.bin\n".encode())
    if arguments.search_bot:
        wanted = f"!BookBot Sample.epub  ::INFO:: {len(CONTENT)}B"
        fixture.search_rows = [wanted, "!BookBot Absent.epub  ::INFO:: 1.2MB",
                               "!BookBot Café.epub  ::INFO:: 2KB"]
        fixture.row_files[wanted] = ("Sample.epub", CONTENT)
    fixture.listener.close()
    fixture.listener = socket.socket()
    fixture.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    fixture.listener.bind(("127.0.0.1", arguments.port))
    fixture.listener.listen(1)
    fixture.port = arguments.port
    fixture.start()
    print(f"fixture listening on 127.0.0.1:{arguments.port}", flush=True)

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    advertised_at = 0.0
    while not stop.wait(0.25):
        if arguments.adverts and fixture.registered and                 time.monotonic() - advertised_at >= arguments.adverts:
            advertised_at = time.monotonic()
            for line in adverts():
                fixture.send(line.encode())
        if arguments.status_file:
            temporary = arguments.status_file.with_suffix(".tmp")
            temporary.write_text(json.dumps({
                "connections": fixture.accept_count, "find": fixture.find_count,
                "trigger": fixture.trigger_count, "chat": fixture.chat_offer_count,
                "search": fixture.search_count, "rows": fixture.row_requests,
                "get": fixture.get_count, "chat_commands": fixture.chat_commands,
                "errors": fixture.errors,
            }), encoding="utf-8")
            temporary.replace(arguments.status_file)
    fixture.stop()
    print(f"find={fixture.find_count} trigger={fixture.trigger_count} "
          f"chat={fixture.chat_offer_count} get={fixture.get_count} errors={fixture.errors!r}",
          flush=True)


def adverts() -> list[str]:
    """Announcements as SysReset 2.55 builds them, colour codes included."""
    c1, c2 = "04", "14"
    return [
        f":Fixture!fixture@127.0.0.1 PRIVMSG #review :{c1}[{c2}Fserve Active{c1}]"
        f" - Trigger:[{c2}!Fixture{c1}(0/5){c1}] - Users:[{c2}0/3{c1}]"
        f" - Message:[{c2}Generated demonstration files{c1}] - SysReset 2.55",
        # A long advert, split over two lines; its CTCP trigger names another nick.
        f":Elsewhere!else@127.0.0.1 PRIVMSG #review :{c1}[{c2}Fserve Active{c1}]"
        f" - Triggers:[{c2}!Elsewhere {c1}& {c2}/ctcp Someone !notmine{c1}]"
        f" - Users:[{c2}2/5{c1}] - Bytes Sent:[{c2}12.5GB{c1}]",
        f":Elsewhere!else@127.0.0.1 PRIVMSG #review :{c1}Files Sent:[{c2}311{c1}]"
        f" - Message:[{c2}Not a real server{c1}] - SysReset 2.55",
    ]


if __name__ == "__main__":
    main()
