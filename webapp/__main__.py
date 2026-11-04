"""Run the web service: `python -m webapp`."""

from __future__ import annotations

import logging
import os

import uvicorn

from .api import create_app
from .runtime import Runtime, Settings


def server_config(runtime: Runtime, host: str, port: int) -> uvicorn.Config:
    return uvicorn.Config(
        create_app(runtime), host=host, port=port,
        log_level="warning", access_log=False, server_header=False,
        timeout_graceful_shutdown=5,
    )


def main() -> None:
    logging.basicConfig(level=logging.WARNING, format="[dccatlas] %(levelname)s %(message)s")
    runtime = Runtime(Settings.from_environment())
    uvicorn.Server(server_config(
        runtime,
        os.environ.get("FSERVE_HTTP_HOST", "127.0.0.1"),
        int(os.environ.get("FSERVE_HTTP_PORT", "8080")),
    )).run()


if __name__ == "__main__":
    main()
