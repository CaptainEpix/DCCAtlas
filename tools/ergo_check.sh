#!/bin/sh
# A source's login against real services, offline (2026-10-27): t/web_login_ergo_test.py.
#
# Ergo (https://github.com/ergochat/ergo), an IRC server with NickServ and
# SASL built in, runs with its default configuration on an internal Docker
# network, which has no way out; the test runs in the product image beside
# it. Needs the product image (dccatlas:dev) and the pinned Ergo image.
#
# For the certificate login, Ergo's TLS port (6697) is given a certificate for
# the name ergo.test, signed by a CA made for this run only (in the git-ignored
# .cache/ergo-tls), and the test's Irssi trusts that CA alone (SSL_CERT_FILE),
# so the app verifies the server as it always does.
set -eu

ERGO_IMAGE=ghcr.io/ergochat/ergo:v2.19.1@sha256:ef885e44f7fa19101bbbc41baef11dc280dc8107465dccaf6f0860f41b48a682
NETWORK=dccatlas-ergo-check
PROJECT=${PROJECT:-$(pwd)}
TLS_NAME=ergo.test

cleanup() {
  docker rm -f dccatlas-ergo-check-ergo >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

mkdir -p "$PROJECT/.cache/ergo-tls"
docker run --rm --pull=never --network none \
  --mount "type=bind,source=$PROJECT/.cache/ergo-tls,target=/tls" --workdir /tls \
  --entrypoint sh dccatlas:dev -c '
    set -eu
    rm -f ./*.pem ./*.key ./*.csr ./*.srl ./*.cnf
    openssl req -x509 -new -newkey rsa:2048 -nodes -days 2 -subj /CN=dccatlas-ergo-check-ca \
      -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
      -keyout ca.key -out ca.pem 2>/dev/null
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN='"$TLS_NAME"'" \
      -keyout privkey.pem -out server.csr 2>/dev/null
    printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n" \
      '"$TLS_NAME"' > server.cnf
    openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 \
      -extfile server.cnf -out fullchain.pem 2>/dev/null
    chmod 644 privkey.pem'

docker network create --internal "$NETWORK" >/dev/null
docker run -d --name dccatlas-ergo-check-ergo --network "$NETWORK" --network-alias "$TLS_NAME" \
  --mount "type=bind,source=$PROJECT/.cache/ergo-tls/fullchain.pem,target=/ircd/fullchain.pem,readonly" \
  --mount "type=bind,source=$PROJECT/.cache/ergo-tls/privkey.pem,target=/ircd/privkey.pem,readonly" \
  --pull=never "$ERGO_IMAGE" >/dev/null
# The app sends a password in plain text only to a private address, so the
# test is given the server's address, not its name.
ERGO_ADDRESS=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  dccatlas-ergo-check-ergo)
sleep 3
docker run --rm --pull=never --network "$NETWORK" \
  -e FSERVE_ERGO_HOST="$ERGO_ADDRESS" -e FSERVE_ERGO_TLS_HOST="$TLS_NAME" \
  -e SSL_CERT_FILE=/project/.cache/ergo-tls/ca.pem \
  --mount "type=bind,source=$PROJECT,target=/project" --workdir /project \
  --entrypoint /opt/venv/bin/python dccatlas:dev \
  -B -m unittest t.web_login_ergo_test -v
