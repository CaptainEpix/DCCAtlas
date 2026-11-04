#!/bin/sh
# Real FServe.pl file servers on a real IRC server, offline (2026-10-27):
# t/web_fservepl_lab_test.py.
#
# Ergo (https://github.com/ergochat/ergo) runs with its default
# configuration on an internal Docker network, which has no way out; the
# test container beside it runs two Irssi instances with FServe.pl 2.0.0
# (https://scripts.irssi.org/scripts/fserve.pl) as file servers, and the
# app's engine as their client. The script is fetched once into .cache/
# (git-ignored) and used only if its SHA-256 is the one read and checked on
# 2026-10-27. Needs the product image (dccatlas:dev) and the pinned Ergo image.
set -eu

ERGO_IMAGE=ghcr.io/ergochat/ergo:v2.19.1@sha256:ef885e44f7fa19101bbbc41baef11dc280dc8107465dccaf6f0860f41b48a682
FSERVEPL_URL=https://scripts.irssi.org/scripts/fserve.pl
FSERVEPL_SHA256=27f4d8884ae541c3df92598b2f3a40ba9b42e1f7f44fe5a87b0179a8d94d4fb3
NETWORK=dccatlas-fservepl-lab
PROJECT=${PROJECT:-$(pwd)}
CACHE=.cache/fservepl

mkdir -p "$CACHE"
if [ ! -f "$CACHE/fserve.pl" ]; then
  curl -sfL "$FSERVEPL_URL" -o "$CACHE/fserve.pl.part"
  mv "$CACHE/fserve.pl.part" "$CACHE/fserve.pl"
fi
echo "$FSERVEPL_SHA256  $CACHE/fserve.pl" | sha256sum -c - >/dev/null || {
  echo "fserve.pl is not the copy that was read; not running it" >&2
  exit 1
}

cleanup() {
  docker rm -f dccatlas-fservepl-lab-ergo >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
docker network create --internal "$NETWORK" >/dev/null
docker run -d --name dccatlas-fservepl-lab-ergo --network "$NETWORK" --pull=never \
  "$ERGO_IMAGE" >/dev/null
ERGO_ADDRESS=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  dccatlas-fservepl-lab-ergo)
sleep 3
docker run --rm --pull=never --network "$NETWORK" \
  -e FSERVE_ERGO_HOST="$ERGO_ADDRESS" -e FSERVE_FSERVEPL=/project/$CACHE/fserve.pl \
  --mount "type=bind,source=$PROJECT,target=/project" --workdir /project \
  --entrypoint /opt/venv/bin/python dccatlas:dev \
  -B -m unittest t.web_fservepl_lab_test -v
