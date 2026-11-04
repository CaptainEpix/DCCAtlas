#!/bin/sh
# A real Prowlarr against the app, offline (2026-10-26): t/web_prowlarr_real_test.py.
#
# Both containers are on an internal Docker network, which has no way out:
# Prowlarr's own update and definition checks fail quietly, and nothing
# reaches IRC but the generated file server inside the test container.
# Needs the product image (dccatlas:dev) and the pinned Prowlarr image.
set -eu

PROWLARR_IMAGE=docker.io/linuxserver/prowlarr:2.6.5@sha256:b3b00047ed20f6ce2b16780145cb6a0acb51c9e28ea6aa6f5dcd33c7034f1797
NETWORK=dccatlas-prowlarr-check
# A key made for this run only; it is never stored.
KEY=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
PROJECT=${PROJECT:-$(pwd)}

cleanup() {
  docker rm -f dccatlas-prowlarr-check-prowlarr >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
docker network create --internal "$NETWORK" >/dev/null
docker run -d --name dccatlas-prowlarr-check-prowlarr --network "$NETWORK" \
  --network-alias prowlarr -e PUID=1000 -e PGID=1000 -e TZ=Etc/UTC \
  -e PROWLARR__AUTH__APIKEY="$KEY" -e PROWLARR__AUTH__METHOD=External \
  -e PROWLARR__AUTH__REQUIRED=DisabledForLocalAddresses \
  "$PROWLARR_IMAGE" >/dev/null
docker run --rm --pull=never --network "$NETWORK" --network-alias dccatlas \
  -e FSERVE_PROWLARR_URL=http://prowlarr:9696 -e FSERVE_PROWLARR_KEY="$KEY" \
  --mount "type=bind,source=$PROJECT,target=/project" --workdir /project \
  --entrypoint /opt/venv/bin/python dccatlas:dev \
  -B -m unittest t.web_prowlarr_real_test -v
