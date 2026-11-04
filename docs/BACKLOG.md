# Backlog

What is left to do, deferred by the owner on 2026-10-28. The numbers are
those of the feature list drawn up on 2026-10-21; the rest came up later.

## Needs the owner's decision first (adds traffic)

- **4 (the rest): saved searches on a timer.** Saving a search is built;
  running one by itself would send searches nobody asked for at that moment.

## Waiting for a real example to build from

- **10 (the rest): other advert formats.** SysReset's, FServe.pl's and list
  servers' ("@Nick") adverts are read.
- **19: queue replies from other file-server scripts.** SysReset's and the
  sender's own "queued" notices naming the file are understood.
- **21 (the rest): another file server's session layout.** Its session
  refused the connection when tried.
- **A file server that queues a file without saying so.** It is given up
  after two minutes.
- **Names with letters outside ASCII.** Such a file is not requested: its
  name would have to be sent in the server's own encoding.

## Needs something from the owner

- **A login on a public network** (NickServ, SASL or certificate). All three
  pass against Ergo offline; a live test needs approval to connect.
- **14: a queued file arriving from SysReset**, and two downloads at once and
  Browse from an advert against SysReset (seen against FServe.pl only). The
  lab's mIRC licence has lapsed.

## Small follow-ups

- **A flaky test:** `test_dropped_and_cancelled_receipts_leave_the_engine_usable`
  timed out waiting for a decline in some full runs of 2026-10-28. It passed
  in five full runs and twelve alone on 2026-11-03, also on a twentieth of a
  CPU, and its cause is not known. A failure now prints the engine's offer
  and session events; the Tests workflow keeps them.
- **A list whose offer never came** (the five minutes ran out) still
  needs a reconnect before it is asked again: an answer could still be on
  its way. Only a failed transfer after the offer frees it (2026-10-29).
- **Lists sent unasked at other times** than the two minutes after `!list`
  stay untaken (2026-10-28); a list a server sends on joining, say, would
  need its own rule.

## Small follow-ups to certificate login

- **Upload a certificate of one's own** instead of the one DCCAtlas makes.
- **Send `CERT ADD` from the app**, once, while logged in another way, so
  the fingerprint need not be typed in another client.

## Off by design, or a change of scope

- **2: resuming a partial download** stays off.
- **11: more than one user**, **12: running on the open Internet**, and
  **20: every kind of file server, and an installer**.
