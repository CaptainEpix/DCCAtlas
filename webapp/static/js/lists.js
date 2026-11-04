// Stored file lists, and lists added by hand.

import { $, formatBytes, RequestError, setText, shared, show } from "./core.js";
import { api } from "./api.js";
import { showLogin } from "./sections.js";
import { listsOf, renderAdverts } from "./servers.js";
import { renderSearchSources, sourceEntries } from "./sources.js";

export let fileLists = [];
export let listImportsPending = false;

export function listWhen(listedAt) {
  return listedAt ? new Date(listedAt).toLocaleDateString() : "an unknown date";
}

// A kept list beside its server: how many files, and when (2026-10-28).
// Delete beside a stored list (2026-10-29), with the file it was read from;
// Get list or Add a list by hand brings it back.
export function listDeleteButton(list) {
  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "quiet";
  remove.textContent = "Delete list";
  remove.title = `Forget the stored list of ${list.sender}`;
  remove.addEventListener("click", () => deleteFileList(list, remove));
  return remove;
}

async function deleteFileList(list, button) {
  if (!window.confirm(`Delete the stored list of ${list.sender} (${keptText(list)}), and the ` +
      "file it was read from? Its files can no longer be searched until the list is added " +
      "again.")) return;
  setText($("seen-error"), "");
  button.disabled = true;
  try {
    await api("DELETE", `/api/file-lists/${encodeURIComponent(list.route_key)}`);
  } catch (error) {
    setText($("seen-error"), error.message);
    button.disabled = false;
    return;
  }
  await refreshFileLists();
}

export function keptText(list) {
  return `${Number(list.files || 0).toLocaleString()} files · listed ${listWhen(list.listed_at)}`;
}

// The kept list of a server listed under a source: a list server's posted
// list, or a file server's own.
export function keptListOf(sourceId, nick, posted) {
  const key = nick.toLowerCase();
  return listsOf(sourceId).find((list) => Boolean(list.posted) === posted &&
    String(list.sender || "").toLowerCase() === key);
}

export function listLabel(list) {
  const source = list.source_label || "a removed or changed source";
  return `${list.sender} ${list.posted ? "(list server)" : list.trigger} · ${source} · ` +
    `${list.files} file(s) · listed ${listWhen(list.listed_at)}`;
}

function importLabel(entry) {
  const whose = `${entry.sender || "A list server"}'s list`;
  if (entry.state === "waiting") return `${whose}: waiting for it to arrive (see Downloads).`;
  if (entry.state === "importing") {
    return `${whose}: arrived; reading it. A list of a million files takes about a quarter ` +
      "of an hour.";
  }
  if (entry.state === "done") return `${whose}: added, ${entry.files} file(s).`;
  return `${whose}: not added. ${entry.reason || ""}`;
}

export async function refreshFileLists() {
  let reply;
  try {
    reply = await api("GET", "/api/file-lists");
  } catch (error) { return; }
  fileLists = reply.lists;
  const imports = reply.imports || [];
  listImportsPending = imports.some((entry) => ["waiting", "importing"].includes(entry.state));
  const importBox = $("list-imports");
  const importStamp = imports.map(importLabel).join("|");
  if (importStamp !== importBox.dataset.stamp) {
    importBox.dataset.stamp = importStamp;
    importBox.replaceChildren(...imports.map((entry) => {
      const item = document.createElement("li");
      item.className = "notice-line";
      const words = document.createElement("span");
      words.textContent = importLabel(entry);
      item.append(words);
      if (["done", "failed"].includes(entry.state)) {
        const close = document.createElement("button");
        close.type = "button";
        close.className = "dismiss";
        close.setAttribute("aria-label", "Close this notice");
        close.title = "Close";
        close.textContent = "\u00d7";
        close.addEventListener("click", () => dismissImport(entry.operation_id, close));
        item.append(close);
      }
      return item;
    }));
  }
  const orphans = fileLists.filter((list) => !list.source_label ||
    !sourceEntries.some((entry) => entry.configuration.source_id === list.source_id));
  show($("orphan-lists"), orphans.length > 0);
  const box = $("stored-lists");
  const stamp = orphans.map((list) => list.route_key + listLabel(list)).join("|");
  if (stamp !== box.dataset.stamp) {
    box.dataset.stamp = stamp;
    box.replaceChildren(...orphans.map((list) => {
      const item = document.createElement("li");
      item.className = "stored-list";
      const label = document.createElement("span");
      label.textContent = listLabel(list);
      item.append(label, listDeleteButton(list));
      return item;
    }));
  }
  renderAdverts();
  renderSearchSources(sourceEntries);
}

async function dismissImport(operationId, button) {
  button.disabled = true;
  try {
    await api("DELETE", `/api/file-lists/imports/${encodeURIComponent(operationId)}`);
  } catch (error) {
    button.disabled = false;
    return;
  }
  await refreshFileLists();
}

export async function addFileList(operationId, button) {
  setText($("download-error"), "");
  button.disabled = true;
  try {
    const added = await api("POST", "/api/file-lists", { operation_id: operationId });
    button.textContent = `Added as a file list (${added.files} files)`;
    await refreshFileLists();
  } catch (error) {
    setText($("download-error"), error.message);
    button.disabled = false;
  }
}

// A list put in the downloads folder by hand: the operator says whose it is.
export const placedForm = $("placed-form");

async function refreshPlacedFiles() {
  setText($("placed-error"), "");
  let placed;
  try {
    placed = await api("GET", "/api/file-lists/placed");
  } catch (error) {
    setText($("placed-error"), error.message);
    return;
  }
  const select = placedForm.elements.path;
  const kept = select.value;
  select.replaceChildren(...placed.files.map((file) => {
    const option = document.createElement("option");
    option.value = file.path;
    option.textContent = `${file.path} (${formatBytes(file.bytes)})`;
    return option;
  }));
  if (placed.files.some((file) => file.path === kept)) select.value = kept;
  setText($("placed-note"), !placed.files.length
    ? "No list file was found in the downloads folder; pick one on this computer instead."
    : (placed.complete ? "" : "Only the first files found are shown; if yours is not "
      + "among them, pick it on this computer instead."));
  fillPlacedSources(sourceEntries);
}

// Only a source whose channel has file servers can have their lists.
export function fillPlacedSources(entries) {
  const select = placedForm.elements.source_id;
  const usable = entries;
  const stamp = usable.map((entry) =>
    entry.configuration.source_id + "\u0001" + entry.configuration.label + "\u0001" +
    entry.configuration.channel).join("\u0002");
  if (stamp === select.dataset.stamp) return;   // do not replace the list under the pointer
  select.dataset.stamp = stamp;
  const kept = select.value;
  select.replaceChildren(...usable.map((entry) => {
    const option = document.createElement("option");
    option.value = entry.configuration.source_id;
    option.textContent = `${entry.configuration.label} (${entry.configuration.channel})`;
    return option;
  }));
  if (usable.some((entry) => entry.configuration.source_id === kept)) select.value = kept;
}

// A list sent from this computer: the file is the body, the rest the query.
async function uploadList(file) {
  const query = new URLSearchParams({
    name: file.name, source_id: placedForm.elements.source_id.value,
    sender: placedForm.elements.sender.value, trigger: placedForm.elements.trigger.value,
  });
  let response;
  try {
    response = await fetch("/api/file-lists/upload?" + query, {
      method: "POST", credentials: "same-origin", cache: "no-store", body: file,
      headers: { "Content-Type": "application/octet-stream", "X-CSRF-Token": shared.csrfToken || "" },
    });
  } catch (error) {
    throw new RequestError(0, "network", "The server could not be reached.");
  }
  let data = null;
  try { data = await response.json(); } catch (error) { data = null; }
  if (!response.ok) {
    const detail = (data && data.error) || {};
    if (response.status === 401 && detail.code === "not_authenticated") showLogin();
    const message = response.status === 413 ? "That file is too large to be a file list."
      : detail.message || "The request failed.";
    throw new RequestError(response.status, detail.code || "error",
      message.charAt(0).toUpperCase() + message.slice(1));
  }
  return data;
}

$("placed-box").addEventListener("toggle", () => {
  if ($("placed-box").open) refreshPlacedFiles();
});
$("placed-refresh").addEventListener("click", refreshPlacedFiles);
placedForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  setText($("placed-error"), "");
  const button = placedForm.querySelector("button[type=submit]");
  button.disabled = true;
  try {
    const picked = placedForm.elements.upload.files[0];
    let added;
    if (picked) {
      setText($("placed-note"), `Sending ${picked.name} (${formatBytes(picked.size)}) and ` +
        "reading it. A big list takes some minutes; leave this page open.");
      added = await uploadList(picked);
      placedForm.elements.upload.value = "";
    } else if (placedForm.elements.path.value) {
      added = await api("POST", "/api/file-lists", {
        path: placedForm.elements.path.value, source_id: placedForm.elements.source_id.value,
        sender: placedForm.elements.sender.value, trigger: placedForm.elements.trigger.value,
      });
    } else {
      throw new RequestError(0, "invalid_file",
        "Pick a file on this computer, or one in the downloads folder.");
    }
    setText($("placed-note"), `Added as a file list (${added.files} files).`);
    await refreshFileLists();
  } catch (error) {
    setText($("placed-note"), "");
    setText($("placed-error"), error.message);
  }
  button.disabled = false;
});
