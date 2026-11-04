"""What the service's identifiers look like, each in one place (2026-11-03).

Each is matched whole, with ``fullmatch``.
"""

from __future__ import annotations

import re

# A source the operator configured.
SOURCE_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}")
# An IRC nickname: a letter or one of []\`_^{}| first, then those, digits and
# "-", up to 64 characters in all.
IRC_NICK = re.compile(r"[A-Za-z\[\]\\`_^{}|][A-Za-z0-9\-\[\]\\`_^{}|]{0,63}")
# A stored file list.
ROUTE_KEY = re.compile(r"[0-9a-f]{64}")
# A download, by its idempotency key.
OPERATION_ID = re.compile(r"web-download-[0-9a-f]{64}")
# A result row: of a search, of a stored file list, and of a Browse (its
# browse and its row number).
SEARCH_ROW = re.compile(r"row-[0-9a-f]{32}")
LIST_ROW = re.compile(r"mrow-[0-9a-f]{64}")
BROWSE_ROW = re.compile(r"brow-([0-9a-f]{32})-([1-9][0-9]{0,4})")
