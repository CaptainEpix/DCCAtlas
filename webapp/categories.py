"""Source categories (2026-10-28): what a source holds, in Newznab's numbers.

Every source has one. Prowlarr, and the apps behind it, ask an indexer for
categories by these numbers (Prowlarr's NewznabStandardCategory.cs:
https://github.com/Prowlarr/Prowlarr/blob/develop/src/NzbDrone.Core/Indexers/NewznabStandardCategory.cs),
and a search from Prowlarr reaches a source only when it asks for that
source's category, so a TV search never reaches a books channel. A search on
the page is not affected: there the operator picks the sources.

The numbers nest as Newznab's do: a top category (7000 Books) holds its
subcategories (7020 EBook, 7030 Comics). Asking for Books reaches Books,
EBook and Comics sources; asking for EBook reaches EBook and Books sources,
since a Books source may hold ebooks, but not Comics ones.
"""

from __future__ import annotations

from pathlib import PurePosixPath

BOOKS, EBOOK, COMICS = 7000, 7020, 7030
AUDIO, AUDIOBOOK = 3000, 3030
DEFAULT = BOOKS     # what a source saved before categories existed held

# The choices, in the order the page lists them.
CATEGORIES: dict[int, str] = {
    BOOKS: "Books",
    EBOOK: "Books/EBook",
    COMICS: "Books/Comics",
    AUDIOBOOK: "Audio/Audiobook",
    AUDIO: "Audio",
    2000: "Movies",
    5000: "TV",
    4000: "PC",
    1000: "Console",
    8000: "Other",
}

_EBOOK = frozenset({"epub", "mobi", "azw", "azw3", "kf8", "pdf", "djvu", "fb2", "lit",
                    "lrf", "pdb", "prc", "rtf", "txt", "doc", "docx", "chm"})
_COMICS = frozenset({"cbr", "cbz", "cb7"})
_AUDIOBOOK = frozenset({"m4b"})


def parent(category: int) -> int:
    return category - category % 1000


def valid(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value in CATEGORIES


def reaches(source: int, asked: set[int]) -> bool:
    """Whether a search for any of the asked categories reaches this source."""
    return any(wanted == source or wanted == parent(source) or parent(wanted) == source
               for wanted in asked)


def of_file(name: str, source: int) -> int:
    """A file's category: its source's, made finer by its extension where that fits."""
    extension = PurePosixPath(name).suffix.lower().lstrip(".")
    guess = (EBOOK if extension in _EBOOK else COMICS if extension in _COMICS
             else AUDIOBOOK if extension in _AUDIOBOOK else None)
    if guess is not None and parent(guess) == parent(source) and source == parent(source):
        return guess
    return source
