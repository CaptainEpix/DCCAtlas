# RAR samples

Two tiny RAR archives, each holding one text file, for testing that
DCCAtlas unpacks RAR lists with bsdtar. RAR archives cannot be made with free
tools, so these come from libarchive's own test suite, version 3.7.4, decoded
from their `.uu` files:

| File here | From | Holds |
| --- | --- | --- |
| `rar5-helloworld.rar` | [`test_read_format_rar5_stored.rar.uu`](https://github.com/libarchive/libarchive/blob/v3.7.4/libarchive/test/test_read_format_rar5_stored.rar.uu) | `helloworld.txt` (RAR 5) |
| `rar4-test.rar` | [`test_read_format_rar_noeof.rar.uu`](https://github.com/libarchive/libarchive/blob/v3.7.4/libarchive/test/test_read_format_rar_noeof.rar.uu) | `test.txt` (RAR 4) |

libarchive is Copyright Tim Kientzle and others, under the BSD licence in its
[COPYING](https://github.com/libarchive/libarchive/blob/v3.7.4/COPYING) file.
