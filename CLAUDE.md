# CLAUDE.md — working on DCCAtlas

A careful IRC file-server client with a web page: Irssi as the engine, a
Starlette web service in front, one Docker container. Released as 1.0.0 on
2026-11-04; the image is `ghcr.io/captainepix/dccatlas`, and the Unraid
template is in `CaptainEpix/dccatlas-unraid` (in Community Apps).

Read [docs/DEVELOPING.md](docs/DEVELOPING.md) first: how the parts fit
together, and the rules every change keeps. Then
[docs/TESTING.md](docs/TESTING.md), [docs/RELEASING.md](docs/RELEASING.md)
and [docs/BACKLOG.md](docs/BACKLOG.md).

## Hard rules

- **Never connect to a real IRC network** or file server without the owner's
  fresh approval for that one test. Tests and checks run offline.
- **The traffic rules in DEVELOPING.md are not relaxed**, not even to make a
  test pass or a feature work: one request per file server and name per
  connection, 30-second spacing, no automatic repeats.
- **No real names in the repository**: no real networks, channels, nicks or
  titles, nor the owner's machine, accounts or addresses. Use the made-up
  names. The owner keeps a list of denied words outside this repository;
  scan a change with it before committing.
- **Never handle the owner's secrets**: passwords, API keys, tokens. The
  owner enters them.
- **Commit or push only when asked.** Every outward step (a release tag, a
  change of visibility, a submission) is confirmed with the owner first.

## Environment

- This checkout: `C:\Dropbox\Coding\DCCAtlas\DCCAtlas`, Windows, Git Bash and
  Docker Desktop. Prefix Docker commands with `MSYS_NO_PATHCONV=1`.
- Beside it: `..\dccatlas-unraid` (the template repo) and `..\DCCAtlas-dev`,
  the private history up to 1.0.0 and the build diary. That one is a record,
  not a place to work.
- The owner runs DCCAtlas on Unraid from the published `:latest`; a release
  reaches it through "Check for updates".
