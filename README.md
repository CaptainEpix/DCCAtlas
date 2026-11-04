# DCCAtlas

DCCAtlas is a careful IRC file-server client with a web page. It runs
[Irssi](https://irssi.org/) as its IRC and DCC engine, with a self-hosted
web application in front of it, in one container.

- **Search** the file servers in the channels you choose: SysReset-style
  `@find` servers, search bots that answer `@search`, and file lists, kept
  and searched offline, including the whole lists list servers post
  (`@Nick`).
- **Browse** a file server's folders, and see the file servers announcing
  themselves in a channel.
- **Download** over DCC into a folder of your choice, with a queue, at most
  two at once and never two from the same server.
- **Log in** to a network with a server password, SASL, NickServ, or a
  client certificate the app makes for you.
- **Prowlarr and the *arr apps**: DCCAtlas can be added as an indexer and a
  download client (Newznab and SABnzbd). Each source has a category (Books,
  TV, Movies…), and a search reaches only the sources of the category it
  asks for, connecting them for the search and disconnecting them later.

It is cautious by design: each request is sent once, searches are spaced
out, an uncertain request is never repeated by itself, and nothing connects
to IRC until you press Connect.

Use it only for files you have the right to download.

## Install

### Unraid

Install **DCCAtlas** from the Apps tab (Community Applications); the
template is in [CaptainEpix/dccatlas-unraid](https://github.com/CaptainEpix/dccatlas-unraid).
Then open the WebUI. To set the password the first time, you need the setup
code DCCAtlas prints when it starts: on the Docker tab click its icon,
choose **Logs**, and find the line `Setup code: XXXX-XXXX-XXXX`.

### Docker Compose

From a copy of this repository:

```sh
docker compose -f deploy/compose.yaml up --build -d
docker compose -f deploy/compose.yaml logs dccatlas   # the setup code
```

Then open <http://localhost:8080>. The image is also published as
`ghcr.io/captainepix/dccatlas`.

The [user guide](docs/USER_GUIDE.md) covers everything else:
sources, searching, downloads, logins, Prowlarr, settings and what to do
when something looks odd.

## Security

There is one operator, with a password set on the page. The page is plain
HTTP: use it on your own network, or put an HTTPS reverse proxy in front.
It accepts being opened by `localhost`, by an address on your own network,
or by a name listed in `FSERVE_ALLOWED_HOSTS`, and refuses other names, which
protects against DNS rebinding. Passwords and keys are kept only in the
configuration volume.

## Development

- `engine/dccatlas.pl` — the Irssi script (the engine); it loads its parts,
  one file per area, from `lib/FServe/Engine/`.
- `lib/FServe/` — parsing, discovery, catalog and the durable transfer engine.
- `webapp/` — the web service and the page (`webapp/static/`).
- `deploy/` — Dockerfile, Compose file and the container supervisor.
- `t/`, `tools/`, `protocol-fixtures/` — the offline tests and fixtures;
  [docs/TESTING.md](docs/TESTING.md) says how to run them.

How the parts fit together, and the rules every change keeps, are in
[docs/DEVELOPING.md](docs/DEVELOPING.md). What changed in each version is in
[docs/CHANGES.md](docs/CHANGES.md); what is left to do is in the
[backlog](docs/BACKLOG.md); how a version is released is in
[docs/RELEASING.md](docs/RELEASING.md).

## Licence

[MIT](LICENSE). The image includes Irssi, which is licensed under the GNU
GPL version 2 or later.
