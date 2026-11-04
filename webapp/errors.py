"""The error a service raises for a request it refuses (2026-11-03).

It carries a stable code, which the page and the apps act on, and a message
for the operator. The API answers each with its code's HTTP status.
"""

from __future__ import annotations


class ServiceError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
