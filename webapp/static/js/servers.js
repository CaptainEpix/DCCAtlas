// File servers seen in a channel, "!list" and Get list.

import { $, badge, randomKey, setText, show } from "./core.js";
import { api } from "./api.js";
import { openSection, setCount } from "./sections.js";
import {
  fileLists,
  fillPlacedSources,
  keptListOf,
  keptText,
  listDeleteButton,
  listLabel,
  placedForm,
  refreshFileLists,
} from "./lists.js";
import { entryState, sourceEntries } from "./sources.js";
import { startBrowse } from "./browse.js";
import { refreshDownloads, refreshQueue } from "./transfers.js";

export const ADVERT_POLL_TICKS = 5;   // every fifth status poll, about every ten seconds

export const advertsBySource = new Map();   // source_id -> last reply

export function ago(seconds) {
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  return `${Math.floor(seconds / 3600)} h ago`;
}

function pairText(label, pair) {
  return pair ? `${label} ${pair.in_use}/${pair.limit}` : "";
}

function triggerText(trigger) {
  return trigger.kind === "ctcp" ? `/ctcp ${trigger.ctcp_nick} ${trigger.trigger}` : trigger.trigger;
}

// Ask a list server for its list, once (2026-10-27). The key is reused until
// the server answers, so a repeated click never asks twice.
const listKeys = new Map();

async function getList(sourceId, nick, button) {
  setText($("seen-error"), "");
  button.disabled = true;
  const id = `${sourceId}\u0001${nick.toLowerCase()}`;
  const key = listKeys.get(id) || randomKey();
  listKeys.set(id, key);
  try {
    const reply = await api("POST", `/api/sources/${encodeURIComponent(sourceId)}/list`,
      { idempotency_key: key, sender: nick });
    listKeys.delete(id);
    // While something else is being fetched, it waits its turn (2026-10-29).
    button.textContent = reply.queued ? "Queued (see Transfers)" : "List asked for";
    await Promise.all([refreshDownloads(), refreshFileLists(), refreshQueue()]);
  } catch (error) {
    if (error.status !== 0 && error.status < 500) listKeys.delete(id);
    setText($("seen-error"), error.message);
    button.disabled = false;
  }
}

async function manualGetList(sourceId, input, button, said) {
  const nick = input.value.trim().replace(/^@/, "");
  setText($("seen-error"), "");
  setText(said, "");
  if (!/^[A-Za-z\[\]\\`_^{}|][A-Za-z0-9\-\[\]\\`_^{}|]{0,63}$/.test(nick)) {
    setText($("seen-error"), "Type the list server's nickname, as in @Nick.");
    return;
  }
  button.disabled = true;
  const id = `${sourceId}\u0001${nick.toLowerCase()}`;
  const key = listKeys.get(id) || randomKey();
  listKeys.set(id, key);
  try {
    const reply = await api("POST", `/api/sources/${encodeURIComponent(sourceId)}/list`,
      { idempotency_key: key, sender: nick, manual: true });
    listKeys.delete(id);
    input.value = "";
    setText(said, reply.queued ? `${nick}'s list is queued (see Transfers).`
      : `Asked ${nick} for its list (see Transfers).`);
    await Promise.all([refreshDownloads(), refreshFileLists(), refreshQueue()]);
  } catch (error) {
    if (error.status !== 0 && error.status < 500) listKeys.delete(id);
    setText($("seen-error"), error.message);
  } finally {
    button.disabled = false;
  }
}

// Fill the "list placed by hand" form with a server seen here; nothing is sent.
function usePlacedList(sourceId, nick, trigger) {
  $("placed-box").open = true;
  fillPlacedSources(sourceEntries);
  placedForm.elements.source_id.value = sourceId;
  placedForm.elements.sender.value = nick;
  placedForm.elements.trigger.value = trigger;
  openSection("servers");
  placedForm.elements.sender.focus();
}

// The source added earlier that lists a server of exactly this name too, on
// any IRC server (2026-10-29); sources come in the order they were added.
function duplicateOf(sourceId, nick) {
  const at = sourceEntries.findIndex((entry) => entry.configuration.source_id === sourceId);
  if (at <= 0) return null;
  return sourceEntries.slice(0, at).find((entry) =>
    ((advertsBySource.get(entry.configuration.source_id) || {}).adverts || [])
      .some((advert) => advert.nick === nick)) || null;
}

function hideDuplicates() {
  return $("hide-duplicates").checked;
}

(function restoreHideDuplicates() {
  try { $("hide-duplicates").checked = localStorage.getItem("dccatlas-hide-duplicates") === "on"; }
  catch (error) { /* a convenience only */ }
})();
$("hide-duplicates").addEventListener("change", () => {
  try { localStorage.setItem("dccatlas-hide-duplicates", hideDuplicates() ? "on" : "off"); }
  catch (error) { /* a convenience only */ }
  renderAdverts();
});

function renderAdvert(sourceId, advert) {
  const item = document.createElement("li");
  item.dataset.advert = `${sourceId}${advert.nick.toLowerCase()}`;
  const head = document.createElement("div");
  head.className = "download-head";
  const name = document.createElement("span");
  name.className = "download-name";
  name.textContent = advert.nick + (advert.restricted ? ` (${advert.restricted} only)` : "");
  const script = document.createElement("span");
  script.className = "hint";
  script.textContent = [advert.script === "fserve.pl" ? "FServe.pl"
    : advert.script === "list" ? "List server" : "SysReset", advert.version]
    .filter(Boolean).join(" ");
  const when = document.createElement("span");
  when.className = "hint seen-when";
  head.append(name, script);
  const earlier = duplicateOf(sourceId, advert.nick);
  if (earlier) {
    const twice = document.createElement("span");
    twice.className = "badge warn";
    twice.textContent = "DUPLICATE";
    twice.title = `Also listed under ${earlier.configuration.label}, added earlier`;
    head.append(twice);
  }
  head.append(when);
  item.append(head);
  const slots = [pairText("Users", advert.users), pairText("Sends", advert.sends),
    advert.queues ? (advert.queues.pools ? `Queues ${advert.queues.pools}`
      : pairText("Queues", advert.queues)) : ""].filter(Boolean).join(" · ");
  if (slots || advert.notice) {
    const meta = document.createElement("div");
    meta.className = "download-meta";
    meta.textContent = [slots, advert.notice].filter(Boolean).join(" · ");
    item.append(meta);
  }
  if (advert.message) {
    const message = document.createElement("div");
    message.className = "download-meta";
    message.textContent = `“${advert.message}”`;
    item.append(message);
  }
  if (advert.content) {
    const content = document.createElement("div");
    content.className = "download-meta";
    content.textContent = `Serves: ${advert.content}`;
    item.append(content);
  }
  for (const trigger of advert.triggers) {
    const row = document.createElement("div");
    row.className = "advert-trigger";
    const text = document.createElement("code");
    text.textContent = triggerText(trigger);
    if (trigger.kind === "list") {
      // "@Nick" once; its list is kept as a file list (2026-10-27), and
      // shown here once it is.
      const kept = keptListOf(sourceId, advert.nick, true) ||
        (advert.script !== "list" && keptListOf(sourceId, advert.nick, false));
      const get = document.createElement("button");
      get.type = "button";
      get.textContent = kept ? "Update list" : "Get list";
      get.addEventListener("click", () => getList(sourceId, advert.nick, get));
      row.append(text, get);
      if (kept) {
        const held = document.createElement("span");
        held.className = "hint kept-list";
        held.textContent = keptText(kept);
        row.append(held, listDeleteButton(kept));
      }
      item.append(row);
      continue;
    }
    const notes = [];
    if (trigger.queue_limit !== undefined) notes.push(`queue ${trigger.queued}/${trigger.queue_limit}`);
    if (trigger.voice_only) notes.push("voiced users only");
    const foreign = trigger.kind === "ctcp" && !trigger.ctcp_nick_is_sender;
    if (foreign) notes.push("names another nick, so it is not offered");
    const note = document.createElement("span");
    note.className = "hint";
    note.textContent = notes.join(" · ");
    row.append(text, note);
    if (!foreign && !trigger.voice_only && !advert.restricted) {
      // Sends this trigger once, as Browse beside a search result does.
      const browse = document.createElement("button");
      browse.type = "button";
      browse.textContent = "Browse";
      browse.addEventListener("click", () => startBrowse(
        { source_id: sourceId, nick: advert.nick, trigger: trigger.trigger }, browse));
      row.append(browse);
    }
    if (!foreign) {
      const use = document.createElement("button");
      use.type = "button";
      use.className = "quiet";
      use.textContent = "Use for a list placed by hand";
      use.addEventListener("click", () => usePlacedList(sourceId, advert.nick, triggerText(trigger)));
      row.append(use);
    }
    item.append(row);
  }
  // Shown beside Get list instead when the advert offers its list so too.
  const ownList = advert.script !== "list" &&
    !advert.triggers.some((trigger) => trigger.kind === "list") &&
    keptListOf(sourceId, advert.nick, false);
  if (ownList) {
    const held = document.createElement("div");
    held.className = "download-meta kept-list";
    held.textContent = `File list: ${keptText(ownList)} `;
    held.append(listDeleteButton(ownList));
    item.append(held);
  }
  return item;
}

// A source's stored lists of servers not listed above it (2026-10-28).
// Browse beside a file server's list stays as long as the list does.
function renderStoredList(list) {
  const item = document.createElement("li");
  item.className = "stored-list";
  const label = document.createElement("span");
  label.textContent = `${list.sender} ${list.posted ? "(list server)" : list.trigger} · ` +
    keptText(list);
  item.append(label);
  if (!list.posted && ["channel_text", "ctcp"].includes(list.trigger_mode)) {
    const browse = document.createElement("button");
    browse.type = "button";
    browse.className = "quiet";
    browse.textContent = "Browse";
    browse.title = `Read the folders of ${list.sender}`;
    browse.addEventListener("click", () => startBrowse({ route_key: list.route_key }, browse));
    item.append(browse);
  }
  item.append(listDeleteButton(list));
  return item;
}

export function listsOf(sourceId) {
  return fileLists.filter((list) => list.source_id === sourceId && list.source_label);
}

// "!list" beside a source: when it may be asked again, and what came of it.
// Waits come as seconds and are counted down from when they arrived, so the
// server's clock and this one need not agree.
const askedBySource = new Map();   // source_id -> last reply, with received_at

function rememberAsked(sourceId, reply) {
  askedBySource.set(sourceId, { ...reply, received_at: Date.now() / 1000 });
}

function askedLeft(asked, seconds) {
  if (!asked || typeof seconds !== "number") return 0;
  return Math.max(0, Math.ceil(seconds - (Date.now() / 1000 - asked.received_at)));
}

function askText(sourceId) {
  const asked = askedBySource.get(sourceId);
  if (!asked || asked.state === "idle") return "";
  const listening = askedLeft(asked, asked.listening_seconds);
  const parts = [];
  if (asked.state === "pending" || asked.state === "sending") parts.push("Waiting to send !list.");
  else if (asked.state === "failed") parts.push("!list may not have been sent; it was not sent again.");
  else if (asked.state === "listening" && listening > 0) {
    parts.push(`Reading answers for ${listening} s more.`);
  } else parts.push("Asked.");
  if (asked.answered.length) parts.push(`${asked.answered.length} answered.`);
  if (asked.taken.length) {
    parts.push(`Lists taken: ${asked.taken.map((item) => item.sender).join(", ")}.`);
  }
  if (asked.offers.length) parts.push(`${asked.offers.length} more offered, taken in turn.`);
  return parts.join(" ");
}

function askWait(sourceId) {
  const asked = askedBySource.get(sourceId);
  return askedLeft(asked, asked && asked.wait_seconds);
}

async function askServers(sourceId, button) {
  setText($("seen-error"), "");
  button.disabled = true;
  try {
    rememberAsked(sourceId, await api(
      "POST", `/api/sources/${encodeURIComponent(sourceId)}/ask-servers`, {}));
  } catch (error) {
    setText($("seen-error"), error.message);
  }
  renderAskState();
}

export async function refreshAsked() {
  const now = Date.now() / 1000;
  await Promise.allSettled([...askedBySource.keys()].map(async (id) => {
    const last = askedBySource.get(id);
    // Followed while it may still change: two minutes of answers, then
    // offers taken in turn.
    if (!last || typeof last.asked_seconds_ago !== "number" ||
        last.asked_seconds_ago + (now - last.received_at) > 7 * 60) return;
    rememberAsked(id, await api("GET", `/api/sources/${encodeURIComponent(id)}/ask-servers`));
  }));
  renderAskState();
}

function renderAskState() {
  for (const block of document.querySelectorAll("#seen-sources [data-source]")) {
    const id = block.dataset.source;
    const entry = sourceEntries.find((item) => item.configuration.source_id === id);
    const button = block.querySelector(".ask-servers");
    const wait = askWait(id);
    if (button) {
      button.disabled = wait > 0 || !entry || entryState(entry) !== "ready";
      button.textContent = wait > 0 ? `Ask for lists again in ${wait} s` : "Ask for lists (!list)";
    }
    const note = block.querySelector(".ask-note");
    if (note) setText(note, askText(id));
  }
}

export function renderAdverts() {
  const usable = sourceEntries;
  show($("seen-card"), usable.length > 0);
  const box = $("seen-sources");
  // What is shown, without the times: a server announcing itself again
  // only changes "seen … ago", which is updated in place below.
  const stamp = JSON.stringify(usable.map((entry) => {
    const reply = advertsBySource.get(entry.configuration.source_id);
    return [entry.configuration.source_id, entry.configuration.label,
      entryState(entry) === "ready",
      listsOf(entry.configuration.source_id).map((list) => list.route_key + listLabel(list)),
      reply ? reply.adverts.map(({ last_seen, first_seen, age_seconds, stale, seen_count,
        ...shown }) => shown) : null,
      reply ? reply.unrecognised : null];
  }).concat([hideDuplicates()]));
  // Do not replace buttons under the pointer, nor a nick being typed.
  const typing = box.contains(document.activeElement) && document.activeElement.tagName === "INPUT";
  if (stamp !== box.dataset.stamp && !typing) {
    box.dataset.stamp = stamp;
    renderAdvertParts(box, usable);
  }
  renderAskState();
  setCount($("nav-servers"), usable.reduce((total, entry) => {
    const reply = advertsBySource.get(entry.configuration.source_id);
    return total + (reply ? reply.adverts.filter((advert) => !advert.stale).length : 0);
  }, 0));
  for (const entry of usable) {
    const reply = advertsBySource.get(entry.configuration.source_id);
    for (const advert of (reply ? reply.adverts : [])) {
      const key = `${entry.configuration.source_id}${advert.nick.toLowerCase()}`;
      const item = [...box.querySelectorAll("li[data-advert]")]
        .find((element) => element.dataset.advert === key);
      if (!item) continue;
      item.classList.toggle("stale", advert.stale);
      item.querySelector(".seen-when").textContent = `seen ${ago(advert.age_seconds)}`;
    }
  }
}

function renderAdvertParts(box, usable) {
  box.replaceChildren(...usable.map((entry) => {
    const id = entry.configuration.source_id;
    const reply = advertsBySource.get(id);
    const part = document.createElement("div");
    part.className = "source-servers";
    part.dataset.source = id;
    const title = document.createElement("h3");
    title.textContent = `${entry.configuration.label} (${entry.configuration.channel})`;
    part.append(title);
    const ask = document.createElement("div");
    ask.className = "advert-trigger";
    const button = document.createElement("button");
    button.type = "button";
    button.className = "quiet ask-servers";
    button.addEventListener("click", () => askServers(id, button));
    // Get list for a nick typed here (2026-10-29): one named by another, as
    // "type @Other for my list", announces nothing of its own.
    const manual = document.createElement("form");
    manual.className = "manual-list";
    manual.autocomplete = "off";
    const nick = document.createElement("input");
    nick.type = "text";
    nick.name = "nick";
    nick.maxLength = 64;
    nick.placeholder = "Nick";
    nick.setAttribute("aria-label", `List server's nick in ${entry.configuration.channel}`);
    const get = document.createElement("button");
    get.type = "submit";
    get.className = "quiet";
    get.textContent = "Get list for a nick";
    get.title = "Send @Nick to the channel once, and take the list that nick sends";
    const said = document.createElement("span");
    said.className = "hint";
    manual.append(nick, get, said);
    manual.addEventListener("submit", (event) => {
      event.preventDefault();
      manualGetList(id, nick, get, said);
    });
    const note = document.createElement("span");
    note.className = "hint ask-note";
    ask.append(button, manual, note);
    part.append(ask);
    const adverts = reply ? reply.adverts : [];
    const shown = hideDuplicates()
      ? adverts.filter((advert) => !duplicateOf(id, advert.nick)) : adverts;
    if (!shown.length) {
      const empty = document.createElement("p");
      empty.className = "hint";
      empty.textContent = adverts.length
        ? `${adverts.length} server(s), all listed under a source added earlier.`
        : entryState(entry) === "ready"
        ? "None yet. File servers usually announce themselves every few minutes to an hour."
        : "None seen. Connect the source to listen.";
      part.append(empty);
    } else {
      const list = document.createElement("ul");
      list.className = "plain";
      list.append(...shown.map((advert) => renderAdvert(id, advert)));
      part.append(list);
    }
    if (reply && reply.unrecognised) {
      const odd = document.createElement("p");
      odd.className = "hint";
      odd.textContent = `${reply.unrecognised} announcement(s) were not in SysReset's or FServe.pl's form and were left out.`;
      part.append(odd);
    }
    // Lists beside a server listed above are shown there.
    const kept = listsOf(id).filter((list) => !adverts.some((advert) =>
      advert.nick.toLowerCase() === String(list.sender || "").toLowerCase() &&
      (list.posted ? advert.triggers.some((trigger) => trigger.kind === "list")
        : advert.script !== "list")));
    if (kept.length) {
      const heading = document.createElement("h4");
      heading.textContent = "File lists of servers not seen lately";
      const list = document.createElement("ul");
      list.className = "plain";
      list.append(...kept.map(renderStoredList));
      part.append(heading, list);
    }
    return part;
  }));
}

export async function refreshAdverts() {
  const usable = sourceEntries;
  await Promise.allSettled(usable.map(async (entry) => {
    const id = entry.configuration.source_id;
    const reply = await api("GET", `/api/sources/${encodeURIComponent(id)}/adverts`);
    // By nick, so a server announcing itself again does not move the list.
    reply.adverts.sort((a, b) => a.nick.toLowerCase().localeCompare(b.nick.toLowerCase()));
    advertsBySource.set(id, reply);
    // When "!list" may be sent again, also after the page is reloaded.
    rememberAsked(id, await api("GET", `/api/sources/${encodeURIComponent(id)}/ask-servers`));
  }));
  for (const id of [...advertsBySource.keys()]) {
    if (!usable.some((entry) => entry.configuration.source_id === id)) {
      advertsBySource.delete(id);
      askedBySource.delete(id);
    }
  }
  renderAdverts();
}
