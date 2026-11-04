# Changes

What each version changed, newest first. The [user guide](USER_GUIDE.md)
describes DCCAtlas as it is now; this page says when things changed, and
what an update does to data kept from before it.

## 0.9.16 (2026-11-03)

- A newer base image: Irssi 1.4.5 on Debian with its latest updates, for
  the part that reads what IRC servers send. The web service runs on
  Starlette 1.10.
- Dependabot proposes updates once a month, each kind in one pull request.

## 0.9.15 (2026-11-03)

- A large folder listing is no longer given up as "kept the engine busy"
  on a host busy with other work: the engine's own time is counted, not the
  time on the clock.
- A `.rar` or `.7z` list that keeps its unpacking busy without end is given
  up after ten minutes, rather than holding up the import for good.
- Dependabot proposes updates to the base image, the Python packages and the
  GitHub Actions once a month, as pull requests the tests run on.

## 0.9.14 (2026-11-03)

- A list server's list whose rows start with a trigger word of the
  server's own (`!Tome file name`), rather than its nick, is read when
  Get list fetches it. Its rows are posted back as written, and the file
  is still taken only from the nick Get list asked.
- Inside: the engine is split into parts by area, and the page's script
  into modules by section. Nothing changes for you; settings and data
  folders keep their names.

## 0.9.13 (2026-11-03)

- A list whose rows start with the list's own name, `!Nick-Ebooks2 file
  name`, is read, by Get list or added by hand. Lists refused before as
  "no row starting !Nick" can be asked for again.

## 0.9.12 (2026-11-02)

- **Get list for a nick** takes the list from any nick on that connection:
  one nick may advertise `@Name` while the file server's own nick sends it.

## 0.9.11 (2026-10-29)

- **Get list for a nick**: ask a nick you type for its list.
- One search looks in every stored file list (it was eight at most), and
  up to 4,096 lists can be stored (it was 32).
- Only files reach the apps: what DCCAtlas has to say about a search goes
  to the Log, not into the answer as a row.
- **Clear all** under the searches list.

## 0.9.10 (2026-10-29)

- File-server listings written as `[Folder/Sub/]` headings with the files
  indented under them are read.
- **Delete list** also deletes the file the list was read from. A list read
  before this version is found by its name or its contents.
- A request's empty folder in `.incoming` is removed: at once after its file
  is saved, otherwise after two hours.

## 0.9.9 (2026-10-29)

- A list whose transfer failed after its offer was taken may be asked for
  once more on the same connection.
- **Delete** for a download's record, and for a kept list.
- A file server whose own advert names `@` and its nick ("@Nick for my
  file list") gets **Get list** beside its trigger.

## 0.9.8 (2026-10-29)

- Get list waits in the queue under Transfers while a file, another list or
  a search is under way.
- Apps may be set to search stored lists only. Two more list layouts are
  read.

## 0.9.7 (2026-10-29)

- Stored lists take about a third of the space they did. Lists stored
  before are rewritten so, in place, the first time DCCAtlas starts after
  the update; the Log says how much each shrank.
- OmenServe's folder headings are read. Kept lists are shown beside their
  servers.

## 0.9.6 (2026-10-28)

- The wait before **Ask for lists (!list)** may be pressed again is counted
  by the page's own clock. Servers comes first in the sidebar.

## 0.9.5 (2026-10-28)

- One **Servers** page. **Ask for lists (!list)**, and lists sent unasked in
  answer to it. Lists can be sent from the page.
- A search-bot source's channel is listened to for adverts as well.

## 0.9.4 (2026-10-28)

- vListMaker lists are read.
- Lists are kept in the config volume's `lists` folder. Lists received
  before this version stay in the downloads folder, where they were.

## 0.9.3 (2026-10-28)

- Lists as `.rar` and `.7z`. The Log says why an offer is turned down.

## 0.9.2 (2026-10-28)

- Each answer to an app says what it held, and the page shows the address
  apps reach DCCAtlas at.

## 0.9.1 (2026-10-28)

- A downloads folder on a network share works.

## 0.9.0 (2026-10-28)

The first tagged version: file servers, search bots and stored file lists
searched together; downloads, the queue and Browse; Prowlarr as indexer
and download client; NickServ, SASL and certificate logins; the Unraid
image.
