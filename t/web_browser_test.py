"""The page in a real browser (item 15, 2026-10-22), on loopback only.

Real Irssi with the engine, the web service, and the generated fixture as
the IRC server and its file server, all in one container with networking
disabled; Playwright drives Debian's Chromium through the page as the
operator would. Run in the test image (tools/browser/Dockerfile):

    docker build -t dccatlas:browser-test tools/browser
    docker run --rm --network none --mount type=bind,source=$PWD,target=/project \
      --workdir /project --entrypoint /opt/venv/bin/python dccatlas:browser-test \
      -B -m unittest t.web_browser_test -v

Elsewhere, without Playwright or Chromium, it is skipped.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))

try:
    from playwright.sync_api import expect, sync_playwright
except ImportError:   # only the browser-test image has it
    sync_playwright = None
CHROMIUM = os.environ.get("FSERVE_BROWSER_CHROMIUM", "")
USABLE = sync_playwright is not None and os.path.exists(CHROMIUM)

if USABLE:
    import uvicorn
    from web_advert_test import sysreset_advert
    from web_download_native_test import (CONTENT, FILENAME, DownloadFixture,
                                          RestartableIrssi, published_files)
    from webapp.__main__ import server_config
    from webapp.runtime import Runtime, Settings

PASSWORD = "browser-check-password-0001"   # a test value for this container only
WAIT_MS = 60_000


def open_section(page, name):
    """One section of the page is shown at a time, picked in the sidebar; the
    ones under Settings once that is folded open."""
    link = page.locator(f"#nav a[href='#{name}']")
    # The page may open Settings by itself (no source yet: Sources), so it is
    # toggled only when shut, and the link waited for. The page can open it
    # between the look and the click, and the click then shuts it: so it is
    # looked at again, a few times.
    for _ in range(3):
        if link.is_visible():
            break
        if page.get_attribute("#nav-settings", "aria-expanded") != "true":
            page.click("#nav-settings")
        try:
            expect(link).to_be_visible(timeout=2000)
            break
        except AssertionError:
            continue
    expect(link).to_be_visible()
    link.click()
    expect(page.locator(f"#section-{name}")).to_be_visible()


class Served:
    """The web service on a loopback port, talking to the native engine."""

    def __init__(self, root: Path, socket_path: str, *, password_file: bool = True) -> None:
        secret = root / "password"
        if password_file:
            secret.write_text(PASSWORD + "\n", encoding="utf-8")
        self.runtime = Runtime(Settings(
            database=root / "config" / "fserve" / "fserve.sqlite3", socket_path=socket_path,
            password_file=str(secret), cookie_secure=False,
            allowed_hosts=("127.0.0.1", "localhost")))
        self.server = uvicorn.Server(server_config(self.runtime, "127.0.0.1", 0))
        self.thread = threading.Thread(target=self.server.run, daemon=True)

    def __enter__(self) -> str:
        self.thread.start()
        deadline = time.monotonic() + 15
        while not self.server.started:
            if time.monotonic() > deadline:
                raise AssertionError("the web service did not start")
            time.sleep(.05)
        return f"http://127.0.0.1:{self.server.servers[0].sockets[0].getsockname()[1]}/"

    def __exit__(self, *exc) -> None:
        self.server.should_exit = True
        self.thread.join(timeout=15)


@unittest.skipUnless(USABLE, "needs Playwright and Chromium (the browser-test image)")
class BrowserChecks(unittest.TestCase):
    def test_the_operator_signs_in_connects_searches_saves_browses_and_downloads(self):
        fixture = DownloadFixture()
        fixture.tree = {
            "/": (["BOOKS"], {"readme.txt": b"r" * 10}),
            "/BOOKS": (["OLD"], {FILENAME: CONTENT}),
            "/BOOKS/OLD": ([], {"older.txt": b"o" * 5}),
        }
        fixture.start()
        problems: list[str] = []
        try:
            with RestartableIrssi() as native, tempfile.TemporaryDirectory() as directory:
                native.command("/set fscrawl_find_quiet_ms 250")
                native.command("/set dcc_autoget OFF")
                native.command("/set dcc_autochat OFF")
                with Served(Path(directory), str(native.path)) as url, sync_playwright() as driver:
                    browser = driver.chromium.launch(executable_path=CHROMIUM,
                                                     chromium_sandbox=False)
                    try:
                        page = browser.new_page()
                        page.on("console", lambda message: problems.append(message.text)
                                if message.type == "error" else None)
                        page.on("pageerror", lambda error: problems.append(str(error)))
                        page.on("response", lambda response: problems.append(
                            f"{response.status} for {response.url}")
                            if response.status >= 400 else None)
                        page.on("request", lambda request: problems.append(
                            "left loopback: " + request.url)
                            if not request.url.startswith(url) else None)
                        self.walk_through(page, url, fixture)
                        self.fits_a_phone(page)
                    except BaseException:
                        for shown in ("#source-error", "#search-error", "#browse-error",
                                      "#download-error", "#placed-error", "#seen-sources", "#orphan-lists",
                                      "#notice", "#log-box"):
                            text = page.locator(shown).inner_text()
                            if text.strip():
                                print(f"{shown}: {text[-1500:]}", flush=True)
                        print(page.evaluate("() => [...document.querySelectorAll('#source-form "
                                            "input, #source-form select')].map((i) => i.name + '=' "
                                            "+ i.value + (i.validity.valid ? '' : ' (invalid)'))"),
                              flush=True)
                        print(f"fixture lines={fixture.lines[-12:]!r} "
                              f"chat={fixture.chat_commands!r}", flush=True)
                        print(native.transcript[-4000:].decode(errors="replace"), flush=True)
                        raise
                    finally:
                        browser.close()
                self.assertTrue(any(name.endswith(FILENAME) for name in published_files(native)),
                                published_files(native))
            self.assertEqual(problems, [], "the page logged errors or reached past loopback")
            self.assertEqual((fixture.find_count, fixture.trigger_count, fixture.get_count),
                             (1, 4, 1), "one search; a trigger for each browse, the file and "
                             "the unreachable one, which was not sent again")
            self.assertFalse(fixture.errors, fixture.errors)
        finally:
            fixture.stop()

    def walk_through(self, page, url, fixture):
        page.goto(url)
        page.fill("#password", PASSWORD)
        page.click("#login-form button[type=submit]")
        expect(page.locator("#view-app")).to_be_visible()
        # The web service reaches the engine a moment after it starts.
        expect(page.locator("#source-state")).to_have_text("Not set up", timeout=WAIT_MS)
        # With no source yet, the page opens on the form that adds one.
        expect(page.locator("#section-sources")).to_be_visible()

        form = page.locator("#source-form")
        for name, value in (("label", "Lab"), ("host", "127.0.0.1"), ("port", str(fixture.port)),
                            ("nickname", "BrowserCheck"), ("channel", "#review")):
            form.locator(f"[name={name}]").fill(value)
        form.locator("button[type=submit]").click()
        expect(page.locator("#source-state")).to_have_text(
            re.compile("Not connected|Disconnected"), timeout=WAIT_MS)
        page.click("#connect")
        expect(page.locator("#source-state")).to_have_text("Ready", timeout=WAIT_MS)

        open_section(page, "search")
        page.fill("#terms", "fixture")
        page.click("#search-form button[type=submit]")
        row = page.locator("#results tbody tr", has_text=FILENAME)
        expect(row).to_be_visible(timeout=WAIT_MS)
        expect(page.locator("#search-state")).to_have_text("Complete", timeout=WAIT_MS)

        # The download settings, as stored, and changed from the page.
        open_section(page, "transfers")
        expect(page.locator("#retry-before-request")).to_be_checked()
        expect(page.locator("#downloads-at-once")).to_have_value("2")
        page.select_option("#downloads-at-once", "1")
        expect(page.locator("#downloads-at-once")).to_be_enabled()
        page.select_option("#downloads-at-once", "2")
        expect(page.locator("#downloads-at-once")).to_be_enabled()
        expect(page.locator("#downloads-at-once")).to_have_value("2")

        # Prowlarr is shut out until let in; then the section shows the key.
        open_section(page, "apps")
        expect(page.locator("#prowlarr-setup")).to_be_hidden()
        page.check("#prowlarr-enabled")
        expect(page.locator("#prowlarr-setup")).to_be_visible()
        expect(page.locator("#prowlarr-key")).to_have_text(re.compile(r"^[0-9a-f]{32}$"))

        open_section(page, "search")
        page.click("#save-search")
        saved = page.locator("#saved-searches li")
        expect(saved).to_have_count(1)
        expect(saved).to_contain_text("fixture")
        expect(saved).to_contain_text("Lab")
        page.click("#search-history-box summary")
        expect(page.locator("#search-history li", has_text="fixture").get_by_role(
            "button", name="Search again")).to_be_visible()

        row.get_by_role("button", name="Browse").click()
        expect(page.locator("#section-browse")).to_be_visible()   # opened by itself
        expect(page.locator("#browse-state")).to_have_text("Read", timeout=WAIT_MS)
        expect(page.locator("#browse-folders")).to_contain_text("BOOKS/")
        page.fill("#browse-find-terms", "older")
        page.click("#browse-find button[type=submit]")
        found = page.locator("#browse-files tbody tr")
        expect(found).to_have_count(1)
        expect(found).to_contain_text("older.txt")
        expect(found).to_contain_text("/BOOKS/OLD")
        page.click("#browse-find-clear")
        page.locator("#browse-folders button", has_text="BOOKS/").click()
        browsed = page.locator("#browse-files tbody tr", has_text=FILENAME)
        expect(browsed).to_be_visible()
        browsed.get_by_role("button", name="Download").click()

        open_section(page, "transfers")
        arrived = page.locator("#downloads li", has_text=FILENAME)
        expect(arrived.locator(".badge")).to_have_text("Complete", timeout=WAIT_MS)
        expect(arrived).to_contain_text("saved as")

        # A file server announcing itself can be browsed by its trigger.
        fixture.send(f":Fixture!fixture@127.0.0.1 PRIVMSG #review :"
                     f"{sysreset_advert('!Fixture')}".encode())
        open_section(page, "servers")
        seen = page.locator("#seen-sources li", has_text="Fixture")
        expect(seen).to_contain_text("SysReset", timeout=WAIT_MS)
        seen.get_by_role("button", name="Browse").click()
        expect(page.locator("#browse-title")).to_have_text(
            re.compile(r"^Folders of Fixture \(!Fixture\)$"), timeout=WAIT_MS)
        expect(page.locator("#browse-folders")).to_contain_text("BOOKS/", timeout=WAIT_MS)

        # A file server whose session cannot be reached: said plainly, with
        # what to do, and not tried again by itself.
        fixture.chat_unreachable = True
        page.locator("#browse-files tbody tr", has_text="readme.txt").get_by_role(
            "button", name="Download").click()
        open_section(page, "transfers")
        failed = page.locator("#downloads li", has_text="readme.txt")
        expect(failed.locator(".badge")).to_have_text("Not started", timeout=WAIT_MS)
        expect(failed).to_contain_text("connecting to it failed")
        expect(failed).to_contain_text("the trigger was not sent again")
        expect(failed).to_contain_text("cannot take connections from outside")
        expect(failed.get_by_role("button", name="Try again")).to_be_visible()

        # "!list" beside the source (2026-10-28): servers' answers are listed,
        # and the button waits a minute before it can be pressed again.
        fixture.list_answers = [("Musing", " List trigger(s): @Musing,@Musing-new  OmenServe 2.74 ")]
        open_section(page, "servers")
        page.get_by_role("button", name="Ask for lists (!list)").click()
        expect(page.locator("#seen-sources li", has_text="Musing")).to_contain_text(
            "List server", timeout=WAIT_MS)
        expect(page.locator("#seen-sources .ask-servers")).to_be_disabled()
        expect(page.locator("#seen-sources .ask-servers")).to_contain_text("again in")
        self.assertEqual(fixture.list_command_count, 1)
        # With this computer's clock 90 s behind the server's, the wait is
        # still at most a minute, and goes down (2026-10-28: it stuck when
        # the page compared the two clocks).
        page.evaluate("() => { window.realNow = Date.now; "
                      "Date.now = () => window.realNow() - 90000; }")
        button = page.locator("#seen-sources .ask-servers")
        page.wait_for_timeout(2500)   # a status poll or two, by the shifted clock
        expect(button).to_contain_text("again in", timeout=WAIT_MS)
        first = int(re.search(r"again in (\d+) s", button.inner_text()).group(1))
        self.assertLessEqual(first, 60)
        page.wait_for_timeout(3500)
        later = int(re.search(r"again in (\d+) s", button.inner_text()).group(1))
        self.assertLess(later, first)
        page.evaluate("() => { Date.now = window.realNow; }")

        # A list picked on this computer is sent and read (2026-10-28).
        open_section(page, "servers")
        page.click("#placed-box summary")
        placed = page.locator("#placed-form")
        placed.locator("[name=upload]").set_input_files(files=[{
            "name": "Shelf.txt", "mimeType": "text/plain",
            "buffer": b"[ Contents of D:\\Books\\ ]\r\n!Shelf One.epub  ::INFO:: 1.2MB\r\n"
                      b"!Shelf Two.epub  ::INFO:: 2.0MB\r\n"}])
        placed.locator("[name=sender]").fill("Shelf")
        placed.locator("button[type=submit]").click()
        expect(page.locator("#placed-note")).to_have_text("Added as a file list (2 files).",
                                                          timeout=WAIT_MS)
        expect(page.locator("#seen-sources .stored-list", has_text="Shelf")).to_contain_text(
            "list server")

        # A server's kept list is shown beside it, and Get list then updates
        # it (2026-10-28): Musing answered !list above.
        placed.locator("[name=upload]").set_input_files(files=[{
            "name": "Musing.txt", "mimeType": "text/plain",
            "buffer": b"[ Contents of D:\\Books\\ ]\r\n!Musing One.epub  ::INFO:: 1.2MB\r\n"}])
        placed.locator("[name=sender]").fill("Musing")
        placed.locator("button[type=submit]").click()
        expect(page.locator("#placed-note")).to_have_text("Added as a file list (1 files).",
                                                          timeout=WAIT_MS)
        musing = page.locator("#seen-sources li[data-advert]", has_text="Musing")
        expect(musing.locator(".kept-list")).to_contain_text("1 files · listed")
        expect(musing.get_by_role("button", name="Update list")).to_be_visible()
        expect(page.locator("#seen-sources .stored-list", has_text="Musing")).to_have_count(0)

        # A server a source added earlier lists too is marked DUPLICATE, and
        # can be hidden (2026-10-29), on any IRC server. A second source on
        # another one is put in the page as one would come, and taken out again.
        # The page's own modules are imported: the same ones it runs.
        seen = page.evaluate("""async () => {
          const { sourceEntries } = await import("/js/sources.js");
          const { advertsBySource, renderAdverts } = await import("/js/servers.js");
          const first = sourceEntries[0];
          const id = first.configuration.source_id;
          sourceEntries.push({ ...first, configuration: { ...first.configuration,
            source_id: "later", label: "Later", channel: "#later",
            host: "irc.elsewhere.test" } });
          advertsBySource.set("later", { ...advertsBySource.get(id) });
          const count = (selector) => document.querySelectorAll(selector).length;
          renderAdverts();
          const marked = [...document.querySelectorAll('[data-source="later"] .badge.warn')]
            .map((badge) => badge.textContent);
          const firstMarked = count(`[data-source="${id}"] .badge.warn`);
          const shownBefore = count('[data-source="later"] li[data-advert]');
          document.getElementById("hide-duplicates").click();
          const shownHidden = count('[data-source="later"] li[data-advert]');
          const firstHidden = count(`[data-source="${id}"] li[data-advert]`);
          document.getElementById("hide-duplicates").click();
          sourceEntries.pop();
          advertsBySource.delete("later");
          renderAdverts();
          return { marked, firstMarked, shownBefore, shownHidden, firstHidden };
        }""")
        self.assertEqual(seen["firstMarked"], 0, "the earlier source's servers are not marked")
        self.assertGreater(seen["shownBefore"], 0)
        self.assertEqual(seen["marked"], ["DUPLICATE"] * seen["shownBefore"])
        self.assertEqual(seen["shownHidden"], 0, "hidden, the later source's copies go")
        self.assertEqual(seen["firstHidden"], seen["shownBefore"], "and the first ones stay")

        # Get list for a nick, beside !list (2026-10-29); a nick that is
        # none is refused on the page, and nothing is sent.
        manual = page.locator("#seen-sources .manual-list").first
        expect(manual.locator("input")).to_be_visible()
        manual.locator("input").fill("not a nick")
        manual.locator("button").click()
        expect(page.locator("#seen-error")).to_contain_text("nickname")

        # All file lists, under the search bar, ticks every stored list and
        # then reads No file lists (2026-10-29).
        ticked = page.evaluate("""async () => {
          const { renderSearchSources, sourceEntries, tickedLists } =
            await import("/js/sources.js");
          const { fileLists } = await import("/js/lists.js");
          renderSearchSources(sourceEntries);
          const button = document.getElementById("tick-lists");
          if (button.hidden) return null;
          button.click();
          const all = fileLists.filter((list) => list.source_label)
            .every((list) => tickedLists.has(list.route_key));
          const label = button.textContent;
          button.click();
          return { all, label, after: tickedLists.size };
        }""")
        self.assertEqual(ticked, {"all": True, "label": "No file lists", "after": 0})

    def test_the_password_is_set_changed_and_reset_on_the_page(self):
        """Codes are read from the service's own output, as the operator reads docker logs."""
        problems: list[str] = []
        first, changed, reset = "first-browser-password", "changed-browser-pw", "reset-browser-pw"
        with RestartableIrssi() as native, tempfile.TemporaryDirectory() as directory:
            with self.assertLogs("dccatlas.web", level="WARNING") as logs:
                served = Served(Path(directory), str(native.path), password_file=False)

            def code(words):
                line = [line for line in logs.output if words in line][-1]
                return line.split(words + ": ", 1)[1].split(" ", 1)[0]

            with served as url, sync_playwright() as driver:
                browser = driver.chromium.launch(executable_path=CHROMIUM, chromium_sandbox=False)
                try:
                    page = browser.new_page()
                    page.on("pageerror", lambda error: problems.append(str(error)))
                    page.goto(url)
                    setup = page.locator("#setup-form")
                    expect(setup).to_be_visible(timeout=WAIT_MS)
                    setup.locator("[name=code]").fill("AAAA-BBBB-CCCC")
                    setup.locator("[name=password]").fill(first)
                    setup.locator("[name=again]").fill(first + "x")
                    setup.locator("button[type=submit]").click()
                    expect(page.locator("#setup-error")).to_have_text(re.compile("not the same"))
                    setup.locator("[name=again]").fill(first)
                    setup.locator("button[type=submit]").click()
                    expect(page.locator("#setup-error")).to_have_text(re.compile("not correct"))
                    setup.locator("[name=code]").fill(code("Setup code"))
                    setup.locator("button[type=submit]").click()
                    expect(page.locator("#view-app")).to_be_visible(timeout=WAIT_MS)

                    open_section(page, "account")
                    form = page.locator("#password-form")
                    form.locator("[name=current]").fill(first)
                    form.locator("[name=password]").fill(changed)
                    form.locator("[name=again]").fill(changed)
                    form.locator("button[type=submit]").click()
                    expect(page.locator("#password-note")).to_have_text(re.compile("Changed"),
                                                                        timeout=WAIT_MS)
                    open_section(page, "search")   # still signed in

                    page.click("#logout")
                    expect(page.locator("#login-form")).to_be_visible()
                    with self.assertLogs("dccatlas.web", level="WARNING") as logs:
                        page.click("#forgot")
                        expect(page.locator("#reset-form")).to_be_visible(timeout=WAIT_MS)
                    form = page.locator("#reset-form")
                    form.locator("[name=code]").fill(code("Password reset code"))
                    form.locator("[name=password]").fill(reset)
                    form.locator("[name=again]").fill(reset)
                    form.locator("button[type=submit]").click()
                    expect(page.locator("#view-app")).to_be_visible(timeout=WAIT_MS)

                    page.click("#logout")
                    page.fill("#password", changed)
                    page.click("#login-form button[type=submit]")
                    expect(page.locator("#login-error")).to_have_text(re.compile("not correct"))
                    page.fill("#password", reset)
                    page.click("#login-form button[type=submit]")
                    expect(page.locator("#view-app")).to_be_visible(timeout=WAIT_MS)
                finally:
                    browser.close()
        self.assertEqual(problems, [])

    def test_a_certificate_login_is_made_and_its_fingerprints_shown(self):
        """Nothing is connected: saving a login only keeps it for the next Connect."""
        problems: list[str] = []
        with RestartableIrssi() as native, tempfile.TemporaryDirectory() as directory:
            with Served(Path(directory), str(native.path)) as url, sync_playwright() as driver:
                browser = driver.chromium.launch(executable_path=CHROMIUM, chromium_sandbox=False)
                try:
                    page = browser.new_page()
                    page.on("pageerror", lambda error: problems.append(str(error)))
                    page.goto(url)
                    page.fill("#password", PASSWORD)
                    page.click("#login-form button[type=submit]")
                    expect(page.locator("#source-state")).to_have_text("Not set up",
                                                                       timeout=WAIT_MS)
                    form = page.locator("#source-form")
                    for name, value in (("label", "Net"), ("host", "irc.example.net"),
                                        ("port", "6697"), ("nickname", "CertCheck"),
                                        ("channel", "#review")):
                        form.locator(f"[name={name}]").fill(value)
                    form.locator("[name=tls]").check()
                    form.locator("button[type=submit]").click()
                    expect(page.locator("#login-box")).to_be_visible(timeout=WAIT_MS)
                    page.click("#login-summary")
                    login = page.locator("#login-source-form")
                    login.locator("[name=kind]").select_option("certificate")
                    expect(page.locator("#login-password-field")).to_be_hidden()
                    expect(page.locator("#login-user-field")).to_be_hidden()
                    login.locator("button[type=submit]").click()
                    expect(page.locator("#login-summary")).to_have_text(
                        "Login: client certificate", timeout=WAIT_MS)
                    expect(page.locator("#login-sha256")).to_have_text(
                        re.compile(r"^[0-9a-f]{64}$"))
                    expect(page.locator("#login-sha512")).to_have_text(
                        re.compile(r"^[0-9a-f]{128}$"))
                    shown = page.locator("#login-sha256").inner_text()
                    page.click("#login-clear")
                    expect(page.locator("#login-summary")).to_have_text("Login: none",
                                                                        timeout=WAIT_MS)
                    expect(page.locator("#login-fingerprints")).to_be_hidden()
                    login.locator("button[type=submit]").click()
                    expect(page.locator("#login-sha256")).not_to_have_text(shown,
                                                                           timeout=WAIT_MS)
                    expect(page.locator("#login-sha256")).to_have_text(
                        re.compile(r"^[0-9a-f]{64}$"))
                finally:
                    browser.close()
        self.assertEqual(problems, [])

    def fits_a_phone(self, page):
        page.set_viewport_size({"width": 375, "height": 812})
        page.wait_for_timeout(300)
        wide = page.evaluate(
            "() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
        self.assertLessEqual(wide, 0, "the page scrolls sideways at phone width")


if __name__ == "__main__":
    unittest.main()
