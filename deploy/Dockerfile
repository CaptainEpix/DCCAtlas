# DCCAtlas product image: Irssi engine plus the web service, run as one unit.
# Build from the repository root:
#   docker build -f deploy/Dockerfile -t dccatlas:dev .
# The base is pinned by digest because the tag is rebuilt in place. To update,
# pull the tag, re-run the test suites (docs/TESTING.md) and replace the
# digest here.
FROM irssi:1.4.5@sha256:5da20d308820d2278b9bcbc031ccc0ef87d7e8e603869bf6bfab02090a2c8ec8 AS base

USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends python3 python3-venv libarchive-tools \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/venv

FROM base

COPY deploy/requirements.txt /app/deploy/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir --disable-pip-version-check \
        --require-hashes --only-binary=:all: -r /app/deploy/requirements.txt

COPY lib /app/lib
COPY engine /app/engine
COPY webapp /app/webapp
COPY deploy/supervisor.py /app/deploy/supervisor.py

RUN mkdir -p /config /downloads && chown user:user /config /downloads

# Started as root, the supervisor gives the volumes to PUID:PGID and becomes
# that user before anything else runs (unRAID: 99:100). The compose file
# starts it as 1000:1000 instead, so that nothing ever runs as root there.
USER root
WORKDIR /app
ENV FSERVE_APP_ROOT=/app \
    FSERVE_CONFIG_DIR=/config \
    FSERVE_DOWNLOAD_DIR=/downloads \
    FSERVE_HTTP_PORT=8080 \
    PUID=1000 \
    PGID=1000 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
VOLUME ["/config", "/downloads"]
EXPOSE 8080

# Liveness only. A disconnected IRC source is a normal state, not a failure.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD ["/opt/venv/bin/python", "-c", "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:' + os.environ.get('FSERVE_HTTP_PORT', '8080') + '/healthz', timeout=3)"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/opt/venv/bin/python", "/app/deploy/supervisor.py"]
