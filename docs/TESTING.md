# Testing

Every test runs offline: on loopback, with networking disabled, or on an
internal Docker network with no way out. Nothing here connects to a real IRC
network. GitHub runs the engine, container and browser checks on every
push to `main`, and the web suite too on a version tag or when started by
hand (`.github/workflows/tests.yml`). Build the product image first:

```sh
docker build -f deploy/Dockerfile -t dccatlas:dev .
```

On Windows, run the shell commands from Git Bash with
`MSYS_NO_PATHCONV=1` in front, and give `PROJECT` and mount sources as
`C:/path/to/DCCAtlas`.

## Engine (Perl)

```sh
docker run --rm --network none --mount "type=bind,source=$PWD,target=/project" \
  --workdir /project --entrypoint sh dccatlas:dev -c \
  'prove -Ilib -It/lib -r t'
```

## Web service

```sh
docker run --rm --network none --mount "type=bind,source=$PWD,target=/project" \
  --workdir /project --entrypoint /opt/venv/bin/python dccatlas:dev \
  -B -m unittest discover -s t -p "web_*_test.py"
```

About half an hour. A few tests are skipped here because each needs
containers of its own; they run in the checks below.

## The page in a real browser

```sh
docker build -t dccatlas:browser-test tools/browser
docker run --rm --network none --mount "type=bind,source=$PWD,target=/project" \
  --workdir /project --entrypoint /opt/venv/bin/python dccatlas:browser-test \
  -B -m unittest t.web_browser_test -v
```

## The container

```sh
python tools/container_check.py
```

Starts the image as the compose file does and as Unraid does (root, then
PUID/PGID), with networking disabled.

## Real third-party software, offline

Each starts its own internal Docker network:

```sh
PROJECT=$PWD sh tools/ergo_check.sh          # NickServ, SASL and certificate logins on Ergo
PROJECT=$PWD sh tools/fservepl_lab_check.sh  # FServe.pl file servers: adverts, browse, two at once
PROJECT=$PWD sh tools/prowlarr_check.sh      # Prowlarr as indexer and download client
```

They use third-party images pinned by digest in the scripts (Ergo,
Prowlarr): pull those first with `docker pull` and the reference the script
names. The FServe.pl check also downloads FServe.pl 2.0.0 once from
scripts.irssi.org, checked against the SHA-256 in the script, into the
git-ignored `.cache/`.
