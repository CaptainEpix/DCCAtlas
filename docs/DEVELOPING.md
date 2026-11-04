# Developing DCCAtlas

How the parts fit together, the rules every change keeps, and how to work on
the code. [TESTING.md](TESTING.md) says how to run the tests,
[RELEASING.md](RELEASING.md) how a version is published, and
[BACKLOG.md](BACKLOG.md) what is left to do.

## How it fits together

One container runs two processes, started and watched by
`deploy/supervisor.py`. If either exits, the other is stopped and the
container exits.

- **The engine**: Irssi 1.4.5 running `engine/dccatlas.pl`. It is the only
  thing that talks to IRC: connections, joins, `@find` and `@search`, file
  servers' DCC CHAT sessions, and DCC transfers. The script loads its parts,
  one file per area, from `lib/FServe/Engine/` (`@ENGINE_PARTS` lists them);
  all of them are in one Perl package and share its state. Parsing,
  discovery and the transfer coordinator are ordinary modules under
  `lib/FServe/`.
- **The web service**: a Starlette application in `webapp/`
  (`python -m webapp`). It serves the page (`webapp/static/`, ES modules
  under `js/`), the HTTP API for it, and the Newznab and SABnzbd endpoints
  for Prowlarr. It never opens an IRC connection itself.
- **The bridge** between them: a Unix socket in the engine's folder, private
  to the app's user (`lib/FServe/Bridge/Unix.pm`, `webapp/engine_client.py`).
  JSON frames of at most 64 KB, protocol version 1; the web service asks, the
  engine answers and reports its status. A request that changes something
  carries an ID, so it is not done twice.

What is kept where, in the configuration volume (`/config`):

| Path | What |
| --- | --- |
| `fserve/fserve.sqlite3` | Sources, logins, settings, searches, downloads, the queue, the password's verifier |
| `fserve/file-lists/` | The stored file lists' catalog, built by `lib/FServe/Catalog/worker.py` |
| `lists/` | The list files Get list, search bots and the page delivered |
| `irssi/` | Irssi's home; its `fserve-poc/` folder holds the engine's job journal and the bridge socket |

Downloads go to `/downloads`, received first into `.incoming/` and moved
into place only once complete.

Some internal names are older than the product's: settings start
`fscrawl_`, the engine's folder is `fserve-poc`, and some journal keys say
`phase6`. They stay as they are, so that existing installations keep their
data.

## Rules every change keeps

DCCAtlas talks to other people's servers. These rules are what make it safe
to point at a real channel, and none of them is relaxed to make something
work:

- **Each request is sent once.** A file is asked for once per file server
  and name on a connection. A request whose outcome is uncertain is never
  repeated by itself; the operator decides. The one exception: a list whose
  transfer failed after its offer was taken may be asked for once more.
- **Searches are spaced.** Lines to a channel go through the outbound
  scheduler (`lib/FServe/Engine/outbound.pl`): searches at least 30 seconds
  apart, a `!list` at most once a minute.
- **At most two downloads at once, never two from one file server.**
- **Nothing connects to IRC by itself.** Only Connect does it, or an app's
  search for a source set to connect for it, which disconnects it again
  once idle.
- **Only what was asked for is taken.** An offer is accepted only from the
  nick and under the name a request is waiting for; anything else is turned
  down, and the Log says why.
- **Irssi is the only IRC and DCC transport.** There is no XDCC support, by
  design.
- **Text from IRC is data.** Names, triggers and rows from servers are
  checked before they reach an Irssi command or a path, and the page shows
  them as text, never as HTML.

## Working on it

- **Tests run offline.** Every suite runs with networking disabled, on
  loopback, or on an internal Docker network (see
  [TESTING.md](TESTING.md)). A test never connects to a real IRC network,
  and neither does development: trying something against a real network
  is the owner's call, each time.
- **Examples and tests use made-up names**: nicks such as Quill, Emberline,
  Sprout, Musing, Shelfbot, Tome, ListBot and Bot, and invented channels
  and titles. Real networks, channels, nicks, titles and anyone's addresses
  are never committed.
- **On Windows**, run the shell commands from Git Bash with
  `MSYS_NO_PATHCONV=1` in front, and give mount sources as
  `C:/path/to/DCCAtlas`.
- **GitHub** runs every suite but the three labs on every push and pull
  request (`.github/workflows/tests.yml`). Dependabot proposes updates once a
  month.
- **A new setting** that the container reads from its environment also
  belongs in the Unraid template,
  [CaptainEpix/dccatlas-unraid](https://github.com/CaptainEpix/dccatlas-unraid),
  and in the user guide.
- **Documentation** describes DCCAtlas as it is now. What changed, and when,
  goes in [CHANGES.md](CHANGES.md).
