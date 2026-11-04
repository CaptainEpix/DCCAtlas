# Test-only image for the browser checks (t/web_browser_test.py): the product
# image plus Debian's own Chromium and Playwright to drive it. Not shipped.
# Build from the repository root, after the product image:
#   docker build -f deploy/Dockerfile -t dccatlas:dev .
#   docker build -t dccatlas:browser-test tools/browser
# Debian's Chromium is used rather than Playwright's own download, which is
# built for the distributions Playwright lists.
FROM dccatlas:dev

USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends chromium fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /app/tools/browser/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir --disable-pip-version-check \
        --require-hashes --only-binary=:all: -r /app/tools/browser/requirements.txt
USER user
ENV FSERVE_BROWSER_CHROMIUM=/usr/bin/chromium
