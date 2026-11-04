# DCCAtlas user guide

DCCAtlas runs as one Docker container. You open it in a browser, point it
at IRC channels where files are shared, search them, and download one file
at a time, or queue several to be fetched in turn. You never need to type
IRC commands. What changed in each version is in [CHANGES.md](CHANGES.md).

There are three ways to find a file, and one search box for all of them:

| Way | What is sent | How fresh the rows are |
| --- | --- | --- |
| **File servers** | One `@find` to the channel. Each file server answers for itself. | Current: the servers just answered. |
| **A search bot** | One `@search` to the channel. The bot answers with a list. | As current as the bot's index. Tried against one real bot. |
| **A stored file list** | Nothing. It is a file server's own list that you downloaded earlier or put in the downloads folder. | As old as the list. Every row shows the day the list was added, which for a list you placed by hand can be long after it was made. |

Every result row says which way found it. Whichever it was, a download is
always a fresh request to the sender, and DCCAtlas sends as little as it
can: one query per source per search, searches and requests at least 30
seconds apart, and nothing repeated on its own.

It is for one operator on a trusted computer or network, with one download
at a time.

## What you need

- Docker with Compose.
- An IRC server and channel where files are shared over DCC: one whose
  file servers answer SysReset-style `@find` searches, or one with a
  search bot that answers `@search`.
- Outbound network access from the container to that IRC server and to the
  senders' DCC addresses.

## Start it

From the repository root:

```sh
docker compose -f deploy/compose.yaml up --build -d
```

Then open <http://localhost:8080>. The first time, the page asks you to
**set a password**, with a setup code to show it is you: DCCAtlas writes
the code to its log when it starts, where only someone who can run Docker
on this computer can read it:

```sh
docker compose -f deploy/compose.yaml logs dccatlas
```

Look for the line `Setup code: XXXX-XXXX-XXXX`, and type the code (case,
spaces and dashes do not matter) with your new password, twice. You are
signed in at once. Until a password is set, each start prints a new code.

- The password must be at least 12 characters of UTF-8 text. Only a salted
  scrypt verifier of it is stored.
- **Changing it:** open **Settings → Password** and give the current one
  and the new one. Any other browser signed in is signed out; this one
  stays signed in.
- **Forgot it:** press **Forgot password?** on the sign-in page. DCCAtlas
  writes a reset code to its log (the line `Password reset code: …`); enter
  it with a new password. The code works once, for 15 minutes, and a new one
  can be asked for once a minute. Everyone signed in is signed out; sources,
  logins, file lists and downloads are kept.
- Wrong codes count with wrong passwords: after five in a row each try
  waits longer, up to 15 minutes.
- **A password file (optional):** for a setup made by script, write the
  password to `deploy/secrets/password.txt` before starting. It is adopted
  at a start when the file is new or its contents have changed, and left
  alone otherwise, so a password changed on the page stays. Removing the
  file changes nothing. If a new one is rejected (the sign-in page says why),
  the previous password still works. `deploy/secrets/` is ignored by git; on
  Linux the file must be readable by uid 1000, the user the container runs
  as. On Windows PowerShell write it like this (plain `>` in Windows
  PowerShell 5 writes UTF-16, which is rejected):

  ```powershell
  New-Item -ItemType Directory -Force deploy/secrets | Out-Null
  [IO.File]::WriteAllText("$PWD/deploy/secrets/password.txt", "choose-a-long-password`n")
  ```

Building the image downloads Debian packages and the pinned Python packages
listed in `deploy/requirements.txt`.

## Use it

The page shows one section at a time, picked in the sidebar: **Search**,
**Servers** (the servers seen in each source's channel, and their file lists),
**Browse** and **Transfers** (the queue and downloads), and under **Settings**, which folds open and shut: **Sources**,
**Apps** (Prowlarr and other apps), **Log** and **Password**. Settings opens
by itself on one of its pages, and remembers whether you left it open. The
browser's Back button returns to the section before. The sidebar also lists each source with a
light for its state, and counts the transfers waiting or running and the
servers seen. With no source yet, the page opens on
Sources. Pressing Browse, or a download or queue entry that is refused,
opens the section that shows it. On a narrow screen the sidebar is a bar
across the top. The longer explanations on the page are folded under
**How this works**.

### 1. Set up a source

A source is one IRC server and one channel. Sources are set up under
**Settings → Sources**.

- Enter a label, the server host and port, a nickname and the channel.
  Tick TLS if the server uses it; the certificate is verified. With TLS
  unticked the connection is plain text, even on a server that offers to
  switch to encryption (STARTTLS).
- The port and TLS go together: 6697 is the usual port for TLS and 6667
  for plain text. The form warns when they look mismatched (6697 with TLS
  off, or 6667 with it on). A plain connection to a TLS port usually waits
  and is then closed; a TLS connection to a plain port fails at once.
- **Searched through** says what kind of channel it is: one whose file
  servers answer `@find`, or one with a search bot that answers
  `@search`. For a search bot, also enter the bot's nickname: the nick
  that sends you the result list.
- **Category** says what the channel holds: Books, Books/EBook,
  Books/Comics, Audio/Audiobook, Audio, Movies, TV, PC, Console or Other.
  Every source has one (sources saved before categories existed hold
  Books). It matters only to Prowlarr and the apps behind it: a search
  from them reaches a source only when it asks for that source's category
  (see Prowlarr below). A search on this page is not affected.
- Press **Save**. Saving never connects.

Each source has a tab, with a dot for its state (green when ready, amber
while connecting, red when it failed); the sidebar shows the same, and
pressing a source there opens it. Pick a tab to show that source; the
line under the tabs says where it connects. Save, Connect, Disconnect and
**Remove** act on the one shown. **+ Add source** opens a blank form for a
further one, up to eight. Remove asks for a second press and works only on
a disconnected source. Changes typed into the form and not saved are lost
when you pick another tab.

Each source is its own IRC connection, so two sources cannot use the same
server and nickname. A channel that has both file servers and a search bot
needs two sources with different nicknames.

Two sources of the same kind cannot have the same channel on the same
server, whatever their nicknames or ports: searching both would put the
same query in that channel twice. This is not enforced for a server
entered as a loopback or private-network address (such as `127.0.0.1` or
`192.168.x.x`), which is taken to be a lab or test server. A host name is
always treated as a public server. DCCAtlas cannot tell that two different
host names are the same network; do not set that up.

### 2. Connect

Press **Connect** and wait for the badge to read **Ready** (connected and
joined). **Disconnect** leaves the server.

Connect uses the saved settings. While the form holds changes that are not
saved, the button reads **Save and connect**: it saves them first, and
connects only if that worked.

One Connect is one attempt. If the connection fails or is dropped, the
source says why: what the server said, or Irssi's own reason, such as
"Connection refused" or "SSL handshake failed: wrong version number" (TLS
on a plain port). "Closed before the server let this client in" means the
server ended the connection before welcoming it, which a plain connection
to a TLS port usually does. Nothing is tried again until you press
Connect. **See this source's log** opens the log for that source.

### 3. Search

Type your terms and press **Search**.

With a single source and no stored file list, that source is asked. With
more to choose from, a **Where to look** box lists the connected sources
and the stored file lists. Tick the ones you want; none is ticked for you.
**All channels** ticks the connected sources (the first five, if there
are more) and **All file lists** every stored list; once all are ticked,
each reads **No channels** or **No file lists** and unticks them.

- Each ticked source is sent one query, and at most five sources can be
  ticked. Sources searched with `@find` are asked at the same time, each on
  its own connection; a search bot's source is asked after them, one at a
  time.
- A ticked file list is searched inside DCCAtlas and sends nothing. File
  lists do not count towards the five, and one search may look in all of
  them, a few at a time.
- Searches on one channel are sent at least 30 seconds apart. One
  submitted sooner shows **Waiting to send** until its turn.

The results come as one list. The line above it says what each place is
doing or found. With more than one place, a **Found in** column names the
place and how the row was found: `@find`, `search bot`, or `file list of`
and the list's date.

What you type is treated differently by each way of searching:

| Way | The terms |
| --- | --- |
| File servers | Sent exactly as typed after `@find`. Each server matches them its own way. Some answer slowly, a line every second or two, so the search is complete once no answer has come for 30 seconds, or after two and a half minutes at most. If nothing answers at all within a minute, the search ends then, saying so. |
| Search bot | Letters, digits and spaces only. Nothing is shown until the bot's list has arrived and been checked. If none arrives within 30 seconds the search ends as **Failed**, with whatever the bot said. |
| File list | Matches any part of a file's name, three characters or more. |

A place that cannot take your terms is skipped and says why; the others
still answer.

File servers answer `@find` in more than one way. DCCAtlas reads three:

- **SysReset's answer**, a list of folders and files reached through its
  trigger. The row's trigger is the server's, such as `!fserve`.
- **FServe.pl's answer** (the Irssi script "FServe 2.0.0"), read the same
  way: `1. File: (folder/file) Size:(…)` under its CTCP trigger. A
  download opens its session, checks the file's folder and asks for it,
  as for SysReset; FServe.pl's queue and refusal replies are understood.
- **Rows to post back**, lines of the form `!Nick file name ::INFO:: size`
  that a file server sends you in a private message or notice. They are
  listed after the others, with `!Nick` as their trigger. A line is taken
  only from the nick it names. A server sends at most a few dozen of them
  per search, however many files it has.

Other answers are not read yet; they can be seen in the **Log**. Some file
servers offer a session that cannot be reached from your network (their
address refuses the connection); a download from them fails at the
session.

**Earlier searches** lists what you searched before. A search across
several places is one entry. Opening one shows its rows again; they can be
downloaded only while they are still current (see "Things that can look
odd"). **Search again** beside one runs it as a saved search runs: its
terms and places go back in the form and it is searched as if typed, for
example after a restart cut a search short. **Clear all** under the list
takes away every search that has ended; one still
running stays. They are only hidden: a download, a queued file or an app's
grab made from one of their rows still works.

**Save this search**, beside Search, keeps the terms and the ticked places
under **Saved searches**. Pressing **Search** beside a saved one puts its
terms and places back in the form and searches, exactly as if you had
typed it, with the same 30-second spacing. A saved search never runs by
itself. If some of its places are not connected (or a file list is no
longer stored), the rest are ticked and nothing is sent until you press
Search yourself. Up to 50 can be saved; **Remove** drops one.

### 4. Download

Press **Download** on one row. Under **Transfers**, **Downloads at once**
is 2 unless you set it to 1: with 2, a file server's file can start while
another file server's file is being received (its first one must already
be arriving). Never two from one file server; a search, a browse, a search
bot's row or a row to post back still waits until no transfer is running.
To start the second, DCCAtlas closes the first one's session, which has
nothing left to do; FServe.pl goes on sending after its session closes
(its `sig_dcc_destroyed`), and SysReset is expected to as well, but that
has not been seen yet.

| The row came from | What a download does |
| --- | --- |
| File servers, or a file list | Opens a session with the file server, asks it for a fresh listing of the file's folder, and requests the file only if it is still there. |
| A search bot, or a row to post back | Posts the row to the channel exactly as it was given, once, without colours. The file is taken only from the nick the row names, under its name or under that name with underscores for its spaces, as mIRC-based servers send it; it is saved under the row's name. |

While a transfer runs the page shows how many bytes have reached the disk,
out of the size the sender announced. Requests to one sender are spaced 30
seconds apart; a download started sooner shows **Preparing** until its
turn.

The same file is requested from the same sender only once per connection,
and the same search text is sent to a search bot only once per connection.
A repeat is refused and nothing is sent. To repeat, disconnect and
connect.

After a row is posted, DCCAtlas waits two minutes for the file to be
offered. A file server that queues the request usually says so in a notice
naming the file ("I have added … as 1 in my queue"); the download then
shows **Queued on the server** and waits up to 15 minutes from that notice.
While it waits, the row shows what the file server last said. An offer
that comes later still is not taken, and nothing is asked again.

**Trying again.** When a file server's session drops after it opened and
before the file was asked for, DCCAtlas opens a fresh one by itself: at
most twice, on the same connection, within two minutes, with the same
fresh listing first. The row says "trying again (1 of 2)". A request that
may have been sent is never sent again by itself. Untick **Try again by
itself…** under Transfers to stop this.

Two failures are never tried again by themselves, because each retry would
send the trigger again with little chance of a different answer. Both show
**Not started**, say that nothing was asked for and that the trigger was
not sent again, and offer **Try again**:

- **No session.** The file server did not open one within a minute, or
  answered with a refusal; what it said is shown. It may be full, busy,
  off, or serving only some users.
- **Session unreachable.** It offered a session, but connecting to it
  failed at once. This usually means the server cannot take connections
  from outside its own network, so trying again will most likely fail the
  same way.

**Try again** beside a download that ended without its file asks for it
once more, when you press it, the same way. On the same connection the
file was usually already asked for, so it shows **Not requested** and
nothing is sent; after a disconnect and connect it goes. A file server's
search result is asked for by the server, trigger and path it named, so
it can be tried again after a new search or a reconnect; a search bot's
row or a row to post back cannot (search again). A download still waiting
or stuck must be cancelled first.

**Delete** beside a download that has ended removes its record, and
**Clear finished** removes the records of every one that has ended. A
saved file stays where it was saved; a download still going, or stuck, is
kept, and so is one the queue is still following. An app that fetched
through DCCAtlas no longer sees a deleted one in its history.

### 5. Find your files

Completed files are in the downloads volume. The page shows each file's
path below.

| Found through | Path under the downloads volume |
| --- | --- |
| File servers or a file list | `<server host>/<file server nick>/<trigger>/<remote folders>/<file name>` |
| A search bot | `<server host>/<nick>/SearchBot/<list id>/<file name>` |
| A row to post back | `<server host>/<nick>/@find/<file name>` |

An existing file is never overwritten; a numbered name such as
`name-1.ext` is used instead.

Lists are kept apart from the downloads, in a `lists` folder of the config
volume (on Unraid, `/mnt/user/appdata/dccatlas/lists/`), until you delete
them: a search bot's result list under
`<server host>/<bot>/@search/SearchBot results/`, and a list from **Get
list** under `<server host>/<Nick>/@list/`. A newer one of the same name
replaces the one kept before.

### Search bots

This has been tried against one real search bot, once. Other bots may
differ.

- The bot's result list is taken only from the nickname you entered, and
  only under the file name such bots are known to use.
- If nothing is offered within two minutes of posting a row, the download
  shows **Expired**, with whatever that nick said. Nothing is sent again.
- A row that is not plain ASCII, or too long for one IRC line, is listed
  without a Download button.
- A file over 256 MB is refused, a transfer is stopped after five minutes,
  and the first 1,000 rows of a list are shown.
- The same search text is sent to a search bot once per connection, and
  the same row is requested once per connection. To repeat either,
  disconnect and connect again.
- After 1,000 search-bot searches, or 1,000 search-bot downloads, since
  DCCAtlas was started, further ones are refused until it is restarted.

### File lists

Some file servers publish a text file listing everything they hold.

File lists are shown under **Servers**, below the servers of the source
they belong to.

- **Adding one.** Download it like any other file. When a completed
  download is a `.txt` file, its row offers **Use as a file list**.
  **Servers** then shows it under its source, with its date. Add it before you
  change that source's settings: afterwards DCCAtlas can no longer be
  sure which server the file describes, and refuses it. Adding a list
  needs about 512 MB of free space, whatever its size.
- **Adding one by hand.** Open **Add a list by hand** under Servers. Pick
  the list on this computer, or one already in the downloads folder: a
  `.txt`, or a `.zip`, `.rar` or `.7z` holding one `.txt`. Pick the source
  whose channel the file server is in, and type the file server's
  nickname. A list picked on this computer is sent to DCCAtlas (at most
  1 GB) and kept in the config volume's `lists/uploaded/` folder; sent
  again under the same name, it replaces the one kept, and one that cannot
  be read is not kept.
  - **A list server's list** (rows such as `!Nick name ::INFO:: size`,
    as Get list fetches) is recognised by itself, from rows naming the nick
    you typed, and read as Get list reads one. It needs no trigger: its
    files are fetched by posting their rows. If its rows name another nick,
    the form says which one to type.
  - **A file server's listing** needs its trigger as the server shows it:
    `!Name`, or `/ctcp Name trigger`. Nothing checks that the list really
    is that file server's: a download from it asks the nick you typed, with
    that trigger. A trigger starting with `@` is refused, because every
    file server in the channel would answer it. Two layouts are read: a
    tree with each file's size in brackets (`[ 70K]  Folder\name.pdf`), and
    the one a file server sent on `@Nick`: each folder as
    `[Folder/Sub/]` (`[]` the top) with its files under it, indented, as
    `name   (9.74 MB)`, after a line or two about the server.

  An archive must hold exactly one `.txt` (other files in it are left),
  and is unpacked no larger than a list may be. Files in folders whose names
  start with a dot are not offered; unfinished downloads are kept there.
  The form lists at most 200 files of the downloads folder, up to six
  folders deep; **Look again** reads the folder afresh. A list it does not
  show, in a big or deep downloads folder, can be picked on this computer
  instead.
- **Searching one.** Tick it under **Where to look**. That sends nothing.
  The first 1,000 matches are shown. Every word you type must be in the
  file's name, in any order, as part of a word or whole ("raven island"
  finds "Raven Rave Island"); at least one word needs three letters. Accents
  are ignored ("renee" finds "Renée").
- **Downloading from one.** As for any file-server row: the source must be
  connected, and the file server is asked for a fresh listing first. If
  the file has gone, nothing is requested.
- Adding the same file server's list again replaces the earlier one. Rows
  found in the earlier one can then no longer be downloaded; search again.
- A list whose source you removed, or pointed at a different server, is
  shown under **Lists of removed or changed sources** and cannot be
  ticked. It describes a file server that source no longer reaches.
- **Browse** beside a file server's list sends its trigger once and reads
  its folders, as Browse beside a search result does, whether or not the
  server has announced itself lately. A list server's list has none: its
  files are asked for by posting their rows.
- Only the tree-with-sizes list format is understood, apart from a list
  server's own list (below), whose folder headings may be written
  `D:\Books\`, as vListMaker writes them, `[ Contents of D:\Books\ ]`, or,
  as OmenServe writes them, on a line of their own between two lines of
  `=` (`+1New\2025\2025-01-12` or `Fiction/A/Some Author`, with no drive;
  a line of a welcome text under one line of `=` is no folder). A name
  listed twice in one folder, at two sizes, is kept once, as first listed:
  a file is asked for by its name alone, so only one can be had (one list
  had 3,855 such of 607,545). A size followed by `::HASH:: …` is read
  without the hash, and a row with a `%hash%` before its name (as one
  FWServer list writes every row) is the name after it; such rows before
  any folder heading are a "new files" section repeating the list, and are
  left out. A list server's catalog may also give each title as fields, as one
  OmenServe server does: `ID | Author - Title | !Nick file name | licence`.
  Only a row with the `!Nick file name` field is a file; rows of a title
  and a web link only ("metadata only") describe works the server cannot
  send, and are left out. Some OmenServe servers start every row with a
  word other than their nick: the list's name, `!Nick-Ebooks2 file name`,
  or a trigger of the server's own, such as `!Tome file name`. A list Get list fetched is read with the
  word nearly all its rows start with, its rows are posted back as
  written, and the file is taken from the nick Get list asked, never from
  another. A list added by hand is read this way only when its word is the
  nick and a dash; otherwise the form names the word its rows use. A file
  in another format is refused, with a message such as "Unrecognized manifest format at line 1".
- **A list server's list.** **Get list** under Servers
  asks a list server for its list and adds it by itself, marked
  "(list server)". Reading a big list takes a while: about a quarter of an
  hour for a million files. A stored list takes about three times the
  list's text in disk space (a 40 MB list, 115 MB). Servers shows how far a list being read has got. A file from such a list is asked for by posting its row,
  `!Nick name  ::INFO:: size`, once, as a search bot's row is: no session,
  no fresh listing first, and only a file of that name from that nick is
  taken. It can wait in the queue like any file; its row is built from
  the stored list when its turn comes, and it runs alone, as a posted row
  always does. A name
  with a letter outside plain ASCII (such as `é`) is shown and searchable
  but cannot be asked for.

### Servers

While a source is connected, DCCAtlas reads what file servers announce in
its channel and lists them under **Servers**, by source: their nick, which
script they run, triggers, users, sends and queues, their message, and how
long ago each was seen. Nothing is sent to get this. File servers announce
themselves on their own timer, from every few minutes to once an hour, so
the list fills slowly. A search-bot source's channel is listened to as
well: ebook channels have list servers besides their
search bot. A server's kept file list is shown beside it ("27,901 files ·
listed 28/10/2026"), and its Get list button then reads **Update list**;
lists of servers not seen lately are listed below them (see File lists).
A server whose exact name a source added earlier also lists, on any IRC
server, is marked **DUPLICATE**; **Hide duplicates** at the top hides those
copies (the page remembers it). A finished list's notice at the top (added,
or not added and why) has a red close button that removes it.
**Delete list** beside a kept list (also under "File lists of servers not
seen lately" and "Lists of removed or changed sources") forgets it after
you confirm: its files are no longer searched, and the file it was read
from is deleted too: a list sent from the page, one placed in the
downloads folder, or one Get list kept, with its server's `@list` folder
once empty. Get list, or adding the list by hand, brings it back.

- **Ask for lists (!list)** beside a source sends `!list` to its channel,
  at most once a minute (the button says when it may be pressed again),
  under the usual 30-second spacing. Servers answer it to you, as notices
  such as `List trigger(s): @Nick  OmenServe 2.74` or `I have the
  following lists: @Nick, @Nick-New`; for two minutes after, those answers
  are read as their announcements are, and the servers are listed. A list
  is counted only by the sender's own `@Nick`, so `@Nick-New` lists (the
  newest files only) are left out.
- **Get list for a nick**, on the same line, asks a nick you type (with or
  without its `@`) for its list: for a list one server's
  words name under another nick, which announces nothing of its own. It is
  sent and taken as Get list is (once a connection, the 30-second spacing,
  one list file), and the nick counts as a list server for a day, until
  DCCAtlas restarts. Nothing checks that it is one. Its list may come from any nick on that connection, because one nick may
  advertise `@Name` while the file server's own nick sends it. The first
  `.txt`, `.zip`, `.rar` or `.7z` offered while the list is awaited is
  taken and filed under the nick you typed. Get list beside a server's
  own advert still takes the list only from that nick.
- Some servers send their list unasked in answer to `!list`. In those two
  minutes, a `.txt`, `.zip`, `.rar` or `.7z` of at most 128 MB from a nick
  that answered, or is in the channel, is taken as Get list takes one: one
  at a time, kept in the `lists` folder, and added as that server's file
  list. It counts as that server's list for the connection, so Get list
  for that server is refused until the next connection. Any other offer is
  left untaken.

- SysReset's announcements (`[Fserve Active] - Trigger:[…] … SysReset 2.55`)
  and FServe.pl's (`(FServe Online) Trigger:(/ctcp nick !trigger) …
  [FServe.pl 2.0.0]`) are read. An FServe.pl server announces in a channel
  only if its owner set it to; most answer `@find` without announcing.
  Other announcements are left out, and the card says how many there were.
- A **list server** (common in ebook channels) announces itself with
  `@` and its own nick: "Type: @Musing For My List Of: 1,068,389
  Files". A line counts as one only when the nick saying it names itself;
  anyone else's `@Nick` is a request, not an announcement. A server seen
  so stays listed for a day, also after DCCAtlas restarts, and Get list
  can be pressed for it all that time. A file server whose own announcement
  names `@` and its nick too, as one FServe.pl server's "@Nick for my file
  list", gets **Get list** beside its trigger; the list it
  sends is read as a list server's if its rows are `!Nick name` ones, and
  otherwise as that file server's listing, fetched by its trigger. **Get list**
  beside it sends `@Nick` to the channel once a connection, under the
  usual 30-second spacing, and takes one file back: a `.txt`, or a `.zip`,
  `.rar` or `.7z` holding one, of at most 128 MB (as sent) from that nick, offered
  within five minutes, under a name no other request on the connection is
  waiting for. Anything else that nick offers is refused, and the Log says
  why ("Turned down …"). The list is kept in the config volume's
  `lists` folder, under `<network>/<Nick>/@list/`, and added as a file
  list under the source.
  Asking again needs a new connection, except after a list whose transfer
  failed (cut short, or out of time) once its offer was taken: the server
  answered, so it may be asked once more on the same connection, by
  **Get list** or **Try again**; a list that stopped
  part-way is cancelled first, by itself. Pressed while a file or another list
  is coming, or a search runs, Get list waits in the queue under Transfers
  and is asked for in its turn, alone; the press starts
  a paused queue that holds nothing but lists, and otherwise it waits for
  **Start** with the files queued before it.
- A server not seen for an hour is greyed, and after a day it is removed.
  So are all of a source's servers when you point it at another server or
  channel.
- **Browse** beside a trigger sends it once and reads the server's
  folders, exactly as Browse beside a search result does (see "Browsing a
  file server"). It is not offered for a trigger that names another nick
  than the one announcing it, for voiced users only, or for an
  announcement restricted to ops or voiced users.
- **Use for a list placed by hand** fills in that form with the server's
  nick and trigger. It does not send the trigger. A CTCP trigger that
  names another nick than the one announcing it is shown but not offered.

### Logging in

For a network or channel that only deals with registered nicks, open
**Login** under the source's settings.

- **Account (SASL)**: your account name and password, checked by the
  server before you join anything. If the server refuses them, the
  connection ends and the badge says so.
- **Server password**: for a server that asks one of every connection. It
  cannot contain a space, start with a colon or be just `-` (which Irssi
  takes to mean no password).
- **NickServ password**: for a network whose services register nicks. Once
  the server has let the client in, DCCAtlas sends `IDENTIFY` to NickServ,
  with the account name if you give one (leave it empty to identify the
  nick itself), and joins the channel when NickServ answers, or after ten
  seconds. The password cannot contain a space. What NickServ says is in
  the **Log**; the password is not.
- Passwords are printable ASCII, up to 128 characters. They are given to
  the server at the next Connect and are never shown again; the page only
  says which kind of login is set. **Clear login** removes it.
- On a source without TLS a password is refused, because it would cross
  the network as typed, unless the server is on a private network such as
  a lab's: entered as a loopback address, `10.x`, `172.16.x` to
  `172.31.x`, `192.168.x`, `169.254.x`, or IPv6 `fc00::/7` or `fe80::/10`.
  Turning TLS off, or pointing the source at another server or
  port, deletes the login.
- The password is kept in the configuration volume's database, readable
  only by the container's user. Anyone who can read that volume can read
  it.
- **Client certificate (SASL EXTERNAL)**: logs in with no password. When
  you save it, DCCAtlas makes a certificate for this source (RSA 3072,
  valid ten years) and shows its SHA-256 and SHA-512 fingerprints. Add it
  to your account once, from any client already logged in to it (HexChat,
  say): `/msg NickServ CERT ADD <fingerprint>`, with the fingerprint your
  network uses. Libera.Chat uses SHA-512
  ([its guide](https://libera.chat/guides/certfp)); Ergo servers use
  SHA-256 ([Ergo's manual](https://github.com/ergochat/ergo/blob/v2.19.1/docs/MANUAL.md));
  Atheme's NickServ, which Libera runs, takes a fingerprint after
  `CERT ADD` ([its help](https://github.com/atheme/atheme/blob/master/help/default/nickserv/cert)).
  Ask the network if unsure. From then on each Connect presents the
  certificate and logs in before joining; if no account has it, the
  server refuses the login and the connection ends. It needs TLS, on a
  private network too. Saving it again keeps the same certificate; **Clear
  login** deletes it, and saving after that makes a new one, which has to
  be added again. Its private key is kept where a password is, and in a
  file only the app's user can read, which Irssi reads at Connect.
- All four were tried against Ergo, a real IRC server with NickServ and
  SASL (offline): NickServ, SASL and a certificate log in; a
  wrong NickServ password leaves you connected but not logged in, said in
  the Log and not tried again; a wrong SASL password, or a certificate on
  no account, ends the connection.

### Browsing a file server

To walk a file server's folders instead of searching them, press
**Browse** beside one of its results. DCCAtlas opens its session once,
with that result's trigger, and reads its folders without asking for any
file: two folders deep and 40 folders at most, at the session's usual
pace, for five minutes at most. Then it closes the session.

- The **Browse** section opens by itself and shows the folders as it reads them, then lets you
  open each one. A folder the walk did not get to is marked **not read**;
  open it and press **Browse from here** to read it and what is below it,
  the same way (its trigger is sent again). A folder with more than 500
  folders or files shows the first 500 of each and says how many more
  there are. **Download** and **Add to queue** beside a file fetch it
  as for any download: a new session, a fresh listing of its folder, then
  the request, so a file that has gone is not asked for.
- **Find** looks for files anywhere in what the browse read, by words in
  their folder or file name (all of them, in any case). It searches what
  is kept and sends nothing. The first 200 are shown, each with its
  folder, which you can open; **Show folders** goes back.
- A search bot's rows and `!Nick file` rows have no session, so they have
  no Browse button.
- A browse cut short (the engine restarted, or the session ended early)
  says so, and **Browse again** starts it afresh from where it started; it
  sends the trigger once more.
- The last ten browses are kept, also after a restart. A browse belongs to
  its source's server: once the source points at another server, its
  files can no longer be fetched from it.

### Queue

To fetch several files without staying to press each one, press **Add to
queue** beside any result, then **Start** under **Transfers**.

- Files are fetched in the order added, each exactly as if you had
  pressed its Download button: the same fresh listing first, and requests
  to one sender 30 seconds apart. With two downloads at once, the next
  file starts beside one being received if it comes from another file
  server; one from the same server waits its turn, and so does every row
  to post back.
- A search bot's row, or a `!Nick file ::INFO:: size` row a file server
  sent, is fetched by posting it back to the channel. When you add one,
  DCCAtlas keeps a copy of the list it came from, so it can still be
  fetched after you search again. It is posted exactly as it came, once.
  The copy belongs to that connection: after a reconnect or a restart the
  row shows **Not requested** and nothing is posted; search again and add
  it again.
- The queue goes on after a file arrives, or after it turns out to have
  gone from the server's folder, or was already asked for on this
  connection (both shown as **Not requested**; nothing is sent). DCCAtlas
  counts `foo bar.txt` and `foo_bar.txt` as one name, because a file
  server may offer a name with spaces as one with underscores, so of two such files only the first is asked
  for on a connection. At anything
  else it pauses and says why: a refusal, a transfer that failed or was
  cancelled, a source that was disconnected or changed, or one that
  reconnected since you pressed Start. Press **Start** to go on with the
  next file.
- While a search is running the queue waits for it. If DCCAtlas is busy
  with something else, the queue tries again later, waiting longer each
  time, and pauses after about three minutes of it.
- A file the server queues on its side holds the queue until it arrives
  (at most 15 minutes, as for any download). A download you start by hand
  runs first, and the queue waits for it.
- **Pause** lets the file being fetched finish and starts no more. After
  a restart of DCCAtlas the queue is paused and never starts by itself.
- **Remove** takes out a file that has not started, or a finished one;
  **Clear finished** takes out every finished one. A file already in the
  queue cannot be added again.
- **Queue again** puts a stopped file back at the end, by the server,
  trigger and path it was added with; it waits for **Start** like any
  other. A row to post back cannot be put back (search again and add it).
- At most 25 files wait at once.

### Prowlarr

[Prowlarr](https://wiki.servarr.com/prowlarr) can search and download
through DCCAtlas, as if DCCAtlas were a Usenet indexer and a SABnzbd
download client. Nothing in Prowlarr needs changing. Any app that speaks
the same two dialects (Newznab to search, SABnzbd to download) can use
DCCAtlas the same way, with the same key: Sonarr, Radarr and Readarr
through Prowlarr, or a book app such as Bindery directly.

1. Start Prowlarr beside DCCAtlas:
   `docker compose -f deploy/compose.yaml --profile prowlarr up -d`, then
   open `http://localhost:9696`. (A Prowlarr you already run elsewhere
   needs to reach DCCAtlas by the name `dccatlas`; put it on the same
   Docker network.)
2. In DCCAtlas, under **Settings → Apps**, tick **Let apps search and
   download through DCCAtlas**. It then shows the key to give Prowlarr.
3. In Prowlarr, **Indexers → Add Indexer → Generic Newznab**: URL
   `http://dccatlas:8080/newznab`, API path `/api`, API key the key.
   Prowlarr tests it when you save; that test sends nothing to IRC.
4. In Prowlarr, **Settings → Download Clients → SABnzbd**: host
   `dccatlas`, port `8080`, SSL off, URL base `sabnzbd`, API key the same
   key, no username or password.

`dccatlas` and `8080` are for Prowlarr started beside DCCAtlas from this
project's Compose file, on their shared network. Anywhere else, such as
on Unraid or another machine, use the address you open DCCAtlas at
instead: its IP address and port (on Unraid, port 7744 by default), for
both the indexer URL and the download client.

What it does:

- **Categories decide where a search goes.** A search from Prowlarr
  reaches only the sources whose **Category** it asks for, and the stored
  file lists of such sources. Categories nest: asking for Books reaches
  Books, Books/EBook and Books/Comics sources; asking for Books/EBook
  reaches Books/EBook and Books sources, but not Books/Comics ones. So a TV
  search from Sonarr never reaches a books channel. Prowlarr asks for a
  category only when you choose one (Sonarr, Radarr and Readarr always do):
  a search with none reaches no source, only stored file lists, which sends
  nothing, and the Log says to choose a category. A TV search for one
  episode is sent as its name with `S02E05`.
- It is one search of those places, as a search across sources here is,
  with all the same limits.
- **Sources are connected for a search.** A source of the category asked
  for that is not connected is connected first, and searched once it has
  joined (Prowlarr waits up to 100 seconds for an answer). It is
  disconnected again once no search has used it for the set minutes (30
  by default) and no download or queued file of it still needs it. A
  source you connect or disconnect yourself is left as you set it. A
  source that fails to connect is not tried again for ten minutes. This
  can be turned off; then only connected sources are searched.
- **Search only stored file lists** (under Apps; off by default): a search
  from Prowlarr is answered from the stored lists alone, within a second or
  so, and sends nothing to IRC, connects nothing and counts nothing toward
  the hourly limit. Servers without a stored list are not asked then.
- **At most so many searches an hour reach IRC** from Prowlarr (10 by
  default, up to 60). Past that, Prowlarr is told "Request limit reached",
  which it reads as a rate limit: it leaves DCCAtlas alone for an hour.
  Nothing is sent. A search answered from an earlier one, or from stored
  file lists only, does not count.
- **Only files reach the apps.** What DCCAtlas has to
  say about a search (nothing to search, busy with another search, still
  searching, a search bot that sent no result list in time) is written in
  the Log, starting "Prowlarr:", and the answer holds no row for it. Such
  answers are not errors: Prowlarr counts errors against an indexer and can
  turn it off for a while.
- Prowlarr gets its answer within 30 seconds, with the files found by then.
  A search bot that has said how many it found but whose result list has
  not arrived by then has no rows yet. The search goes on here, and the
  same words again in Prowlarr within
  half an hour are answered from it, sending nothing new. Sources are
  asked at the same time, so most searches have ended by then; a search
  bot's source is asked after the others and may still be running.
- A search with no words, which Prowlarr's Test sends, is answered from
  the last few searches and sends nothing; with no row of theirs in the
  categories asked for, one row, a note saying DCCAtlas is ready, is the
  answer: Prowlarr's Test fails an answer with no rows, and Readarr's one
  with none in its categories ("Query successful, but no results were
  returned from your indexer", `TestConnection` in Prowlarr's
  [HttpIndexerBase.cs](https://github.com/Prowlarr/Prowlarr/blob/a69014a3d2f57d1f4051d3bbd4b39e203cb18069/src/NzbDrone.Core/Indexers/HttpIndexerBase.cs#L771-L774),
  and in [Readarr's](https://github.com/Readarr/Readarr/blob/ca0c95a2d2f15ba01ef7e16f10cca53a3bf71f74/src/NzbDrone.Core/Indexers/HttpIndexerBase.cs#L334-L336)).
  It is the only note sent as a row.
- A file sent from Prowlarr starts as **Download** does here, once, and
  shows under **Transfers**. Sending it again while it is on its way
  does nothing more; after it ended, it is a new press, and the one request
  per file and connection still applies. SABnzbd's **Retry** is refused:
  DCCAtlas never asks for a file again by itself.
- If DCCAtlas cannot start a file (two downloads already running, say),
  Prowlarr shows the reason. Notes are not files: sending one says so.
- **Category folders** (off by default): a finished file is moved into a
  folder named after the category its app sent it with (`tv`, `movies`,
  `books`…), as SABnzbd does, and that is where the app is told it is, so
  Sonarr, Radarr and the others import it from there. A file already there
  is never replaced; the moved one gets a number (`name-1.epub`).
- **New key** makes the old one stop working, in both places. Unticking the
  box shuts Prowlarr out and keeps the key.

### Things that can look odd

- **"DCCAtlas has been updated since this page was opened."** The app was
  updated while the page was open, and the page still runs the old
  version. Reload it.

- **Results from history cannot be downloaded.** After a reconnect, a
  settings change, a restart, or a newer search of the same source, old
  results are shown for reference only. A file-list row goes the same
  way once its list has been replaced, or its source removed or pointed
  at a different server. Search again to get rows with a Download button.
- **Only one download at a time.** A second request is refused until the
  first finishes, is cancelled, or is retired.
- **Cancel** stops the local side. A request already sent to a file server
  cannot be recalled.
- **Refused** means the file server answered the request with a refusal.
  Its own words are shown. A common one is a full queue: some file
  servers put a cancelled send back in their queue for you and then turn
  down your next request. Disconnecting and connecting again normally
  clears your queue there; then search again.
- **Queued on the server** means the file server accepted the request
  and will send the file when it has a free slot. DCCAtlas waits up to
  15 minutes and asks for nothing again. The download slot stays taken
  meanwhile. If the file has not come by then the download shows
  **Expired**; the server may still send it later, and it is then not
  taken.
- **Expired** without a queue message means nothing was offered within
  two minutes of the request and the file server said nothing DCCAtlas
  recognises.
- **Not started** means the file server's session never began, so no file
  was asked for. The reason is shown. The file server may have answered
  the request with a notice (busy, full, restricted) or with nothing for
  60 seconds. Or it is still offering an earlier file on the port it
  named for the session: DCCAtlas will not connect there for five
  minutes after a file offer it did not take, because some file servers
  would send that file instead. After cancelling a transfer, expect to
  wait that long before using the same file server again. It is also shown
  when DCCAtlas closed the session because the file server sent data that
  is not text, or text far faster than it can be read. A large folder is
  still read, with a pause of a few seconds for every 20,000 or so files;
  one of more than about 100,000 files sent at once is refused, and the
  reason says the folder listing was too large to read.
- **A file server that changes its nick** while its session is open, as
  some away scripts do, can no longer be told apart from anyone else, so
  DCCAtlas closes the session and asks for nothing more. The download
  shows **No longer valid**, or **Failed** if the file had already been
  asked for, and the reason names both nicks. A file the server then
  offers under its new nick is not taken. Search again: new results name
  the new nick.
- **After a cancel**, a file server may offer the file again. DCCAtlas
  declines it, up to three times, and never takes it.
- **Interrupted** means the transfer stopped early: the sender closed it, or
  the engine restarted. Nothing more will arrive and it is not resumed.
  Cancel it to free the download slot.
- **The same file twice.** A file can be requested from a given file server
  only once per connection, whether the first transfer completed, was
  cancelled or was interrupted. A second request is marked **Not requested**
  and nothing is sent. To ask again, disconnect, connect and search again.
- **Unfinished data.** Whatever arrived before a cancel or an interruption
  stays in `.incoming` inside the downloads volume. DCCAtlas never moves it
  into place, resumes it or deletes it. Each request's own folder there is
  removed once it is empty: at once after its file is saved, and otherwise
  after it has stood empty two hours.
- **Could not connect to the sender.** The file server offered the file at
  an address and port that did not answer, so not a byte came ("could not
  connect to the address the sender offered"). Another IRC client fails the
  same way, and asking again gets the same address; the fault is on the
  sender's side, such as a firewall in front of it.
- **Needs attention** means the outcome is not known, for example the engine
  stopped mid-request. DCCAtlas never sends such a request again by itself.
  If the engine still knows the job, cancel it. If it does not, the page
  offers to *retire* the record after you type an exact confirmation phrase.
  Retiring only clears the record so you can download again; the file server
  may still have queued or sent the file.
- **Restarting signs you out** and leaves the source disconnected. Settings,
  search history, download history and files are kept. Nothing reconnects,
  searches or resumes on its own.

## Stop, update, back up

```sh
docker compose -f deploy/compose.yaml stop     # graceful; an active transfer is interrupted
docker compose -f deploy/compose.yaml up --build -d   # after pulling new code
```

Two named volumes hold everything: `dccatlas-config` (settings, history, the
engine journal and its logs) and `dccatlas-downloads` (your files). Back up
both. To store downloads in a host folder, replace the downloads volume with a
bind mount owned by uid 1000.

## On Unraid

Install **DCCAtlas** from the Apps tab. The template
([CaptainEpix/dccatlas-unraid](https://github.com/CaptainEpix/dccatlas-unraid))
pulls `ghcr.io/captainepix/dccatlas:latest`, offers the page on port
**7744**, and asks for two folders: **Downloads** (default
`/mnt/user/downloads/dccatlas`) and **Appdata**
(`/mnt/user/appdata/dccatlas`). To set the password the first
time, click the DCCAtlas icon on the Docker tab, choose **Logs**, and find
`Setup code: …`.

- Files belong to `nobody:users` (PUID 99, PGID 100), as for most Unraid
  apps. The container starts as root only to give the appdata folder, and
  the downloads folder itself, to that user, and then runs as it; files
  already in the downloads folder are left as they are. PUID or PGID 0 is
  refused.
- Open the page by the server's address, such as `http://192.168.1.10:7744`.
  To open it by name, such as `http://tower:7744`, list the name under
  **Host names**.
- Downloaded files and the folders DCCAtlas makes follow **UMASK**: `022`
  makes them readable by everyone (644 and 755), `002` also lets the users
  group change them (664 and 775).
- Updates: Unraid's "Check for updates" on the Docker tab sees a new
  release; the setup, sources and file lists are kept in appdata, and so
  are the lists Get list and search bots send (in `lists`).

## Reaching it from another computer

By default the page is published on the Docker host only (`127.0.0.1:8080`).
To use it from the LAN:

1. Put an HTTPS reverse proxy in front of it. Without one, the password and
   session cookie cross the network unencrypted. The proxy must pass the
   original `Host` header through; requests are otherwise refused.
2. Set `FSERVE_COOKIE_SECURE` to `"1"` so the session cookie is sent only over
   HTTPS.
3. Add the name you browse to in `FSERVE_ALLOWED_HOSTS` (comma-separated).
   Requests for any other name are refused, which protects against DNS
   rebinding; `localhost`, and any address on a private network (such as
   `192.168.1.10` or `10.0.0.5`), are always accepted, since an address
   cannot be made to point elsewhere.
4. Change the published address in `deploy/compose.yaml` deliberately.

Do not expose it to the Internet. There is one operator account and no
second factor.

## Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `FSERVE_ALLOWED_HOSTS` | (none) | Further names the page may be opened under, besides `localhost` and private-network addresses. |
| `FSERVE_COOKIE_SECURE` | `0` | `1` marks the session cookie HTTPS-only. |
| `FSERVE_HTTP_PORT` | `8080` | Port inside the container. |
| `PUID`, `PGID` | `1000` | Started as root, the user and group the volumes are given to and the app runs as (Unraid: 99 and 100). Not 0. Ignored when started as another user. |
| `UMASK` | (none) | Started as root, the permission mask for new files, such as `002`. |
| `FSERVE_PASSWORD_FILE` | `/run/secrets/dccatlas_password` | The optional password file. The compose file sets it to `/run/secrets/dccatlas/password.txt`, in the mounted `deploy/secrets` folder. |

## Limits

- Up to eight sources, one channel each, each either file servers
  (`@find`) or a search bot (`@search`). The search-bot kind has been
  tried against one real bot, once.
- One search asks up to five sources and looks in every stored file
  list; up to 4,096 lists can be stored. A search cannot be cancelled once started. Results are listed
  place by place in the order shown under Where to look, not sorted
  together.
- Whose list a file placed
  by hand is, is taken on your word.
- Browsing reads two folders deep and 40 folders at most. At most two
  downloads run at once, never two from one file server.
- Login is a server password, a SASL PLAIN account, a NickServ password
  or a certificate DCCAtlas makes (SASL EXTERNAL). A certificate of your
  own cannot be uploaded; nor can a channel key or a custom certificate
  authority be set. TLS connections verify the server certificate.
- Only SysReset's and FServe.pl's announcements are read for **File
  servers seen**.
- If the nickname is in use, Irssi changes it (for example
  `CaptainEpix` to `CaptainE1ix`). The page then says which nick it is
  connected as.
- No resume of interrupted transfers. The only retry by itself is a fresh
  session when one drops before the request (see "Trying again").
- At most 1,000 results are kept per place searched, shown ten at a time.
- Sessions last 12 hours without activity and 7 days at most, and end on
  restart. An open, visible page counts as activity.

### Log

The **Log** section shows what happened on the
connections: what the servers said to this client (notices, private
messages, CTCP requests such as DCC file offers, errors and the welcome),
what DCCAtlas sent (searches, triggers, requests), Irssi's own notices and
errors, and each source's changes of state. **Show** picks one source;
errors tied to no server, such as a TLS failure, are shown under every
source.

- Channel chat, the server's message of the day, pings and the login
  exchange are left out. A password is never written to the log: it goes
  to Irssi in a way the log does not see.
- The engine keeps its last 1,000 lines and the web service its last
  2,000. More than 100 lines in one second are counted rather than kept.
- The web service also saves its lines in the configuration volume
  (`fserve/connection-log.jsonl`, at most two files of 1 MB, readable only
  by the container's user), so they are still there after a restart. A
  line marks where DCCAtlas started again.
- Every line is also printed to the container's output, on lines starting
  with `[log]`, so `docker compose -f deploy/compose.yaml logs` has them.
  The compose file keeps at most three files of 10 MB each.
- **Clear the view** empties the box on this page only.

If a file server's answer to a search does not show up as a result, the
log shows what it sent instead.

## If something is wrong

- **A source fails or will not connect:** read its reason, then the **Log**
  for that source. Check the port and TLS first.
- **"Engine starting" does not go away:** check `docker compose logs`. The
  container stops with a clear message if `/config` or `/downloads` is not
  writable by uid 1000. Unexpected failures of the web service are logged
  there too, on lines starting with `[dccatlas]`.
- **The container keeps restarting:** either the engine or the web service
  exited; the log line names which. A disconnected IRC server never causes a
  restart.
- **A request is refused with a "busy" message:** finish or cancel the active
  search or download first, or disconnect before changing source settings.
- **Sign-in says to wait:** five wrong passwords in a row add a growing delay,
  up to 15 minutes. The right password is refused too until it has passed.
