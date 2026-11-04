// Transfers: downloads and the queue.

import {
  $,
  badge,
  DOWNLOAD_HINTS,
  formatBytes,
  NOT_REQUESTED,
  NOT_STARTED,
  randomKey,
  SESSION_HINTS,
  setText,
  shared,
  show,
  TERMINAL_DOWNLOADS,
} from "./core.js";
import { api } from "./api.js";
import { openSection, renderTransferCount } from "./sections.js";
import { addFileList } from "./lists.js";

let downloadKeys = new Map();  // result_id -> idempotency key awaiting a definite answer
let lastDownloadsStamp = "";

const QUEUE_LABELS = {
  queued: "Waiting", running: "Fetching", done: "Arrived",
  not_requested: "Not requested", stopped: "Stopped",
};
const QUEUE_OUTCOMES = {
  live_parent_file_missing: "the file server's folder no longer has it",
  tuple_preflight_refused: "it, or the same name with underscores for spaces, was already " +
    "asked for on this connection",
  source_changed: "its source was changed or removed",
  stale_hold: "the engine restarted, or its source changed or reconnected, since it was " +
    "added; search again and add it again",
  repeat_refused: "it was already asked for on this connection",
  session_not_opened: "the file server did not open a session; the trigger was not sent again",
  session_unreachable: "the file server's session could not be reached; the trigger was not " +
    "sent again",
};

function queueDetail(item) {
  if (item.state === "not_requested" || item.state === "stopped") {
    return QUEUE_OUTCOMES[item.outcome] || DOWNLOAD_HINTS[item.outcome] || item.outcome || "";
  }
  return "";
}

function renderQueue(queue) {
  const waiting = queue.items.filter((item) => ["queued", "running"].includes(item.state));
  // A running item is counted with the downloads.
  shared.queuedCount = queue.items.filter((item) => item.state === "queued").length;
  renderTransferCount();
  badge($("queue-state"), queue.running ? "receiving" : "",
    queue.running ? "Running"
      : !waiting.length ? "Idle" : queue.paused_reason ? "Paused" : "Not started");
  setText($("queue-reason"), queue.running ? "" : (queue.paused_reason || ""));
  show($("queue-empty"), queue.items.length === 0);
  $("queue-start").disabled = queue.running || !waiting.some((item) => item.state === "queued");
  $("queue-pause").disabled = !queue.running;
  $("queue-clear").disabled = !queue.items.some((item) => !["queued", "running"].includes(item.state));
  const box = $("queue-items");
  const stamp = JSON.stringify(queue.items.map((item) => [item.item_id, item.state, item.outcome]));
  if (stamp === box.dataset.stamp) return;   // do not replace buttons under the pointer
  box.dataset.stamp = stamp;
  box.replaceChildren(...queue.items.map((item) => {
    const entry = document.createElement("li");
    const head = document.createElement("div");
    head.className = "download-head";
    const name = document.createElement("span");
    name.className = "download-name";
    name.textContent = item.name;
    const state = document.createElement("span");
    badge(state, item.state === "done" ? "complete" : item.state === "stopped" ? "failed"
      : item.state === "running" ? "receiving" : "", QUEUE_LABELS[item.state]);
    head.append(name, state);
    const meta = document.createElement("div");
    meta.className = "download-meta";
    meta.textContent = [`from ${item.sender} ${item.trigger}`, item.path,
      typeof item.size_bytes === "number" ? formatBytes(item.size_bytes) : "",
      queueDetail(item)].filter(Boolean).join(" · ");
    entry.append(head, meta);
    if (item.state === "stopped" && item.trigger_mode !== "posted") {
      const again = document.createElement("button");
      again.type = "button";
      again.className = "quiet";
      again.textContent = "Queue again";
      again.addEventListener("click", () => queueAction("POST",
        `/api/queue/${encodeURIComponent(item.item_id)}/again`));
      entry.append(again, " ");
    }
    if (item.state !== "running") {
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "quiet";
      remove.textContent = "Remove";
      remove.addEventListener("click", () => queueAction("DELETE",
        `/api/queue/${encodeURIComponent(item.item_id)}`));
      entry.append(remove);
    }
    return entry;
  }));
}

export async function refreshQueue() {
  try { renderQueue(await api("GET", "/api/queue")); } catch (error) { /* shown on next success */ }
}

async function queueAction(method, path) {
  setText($("queue-error"), "");
  try {
    renderQueue(await api(method, path, method === "POST" ? {} : undefined));
  } catch (error) {
    setText($("queue-error"), error.message);
  }
}

export async function addToQueue(resultId, button) {
  setText($("queue-error"), "");
  button.disabled = true;
  try {
    renderQueue(await api("POST", "/api/queue", { result_id: resultId }));
    button.textContent = "Queued";
  } catch (error) {
    setText($("queue-error"), error.message);
    openSection("transfers");
    button.disabled = false;
  }
}

$("queue-start").addEventListener("click", () => queueAction("POST", "/api/queue/start"));
$("queue-pause").addEventListener("click", () => queueAction("POST", "/api/queue/pause"));
$("queue-clear").addEventListener("click", () => queueAction("POST", "/api/queue/clear"));

export async function startDownload(resultId, button) {
  setText($("download-error"), "");
  button.disabled = true;
  // Reuse the key until the server gives a definite answer, so a repeated
  // click after a lost reply can never start a second transfer.
  const key = downloadKeys.get(resultId) || randomKey();
  downloadKeys.set(resultId, key);
  try {
    await api("POST", "/api/downloads", { idempotency_key: key, result_id: resultId });
    downloadKeys.delete(resultId);
    await refreshDownloads();
  } catch (error) {
    if (error.status !== 0 && error.status < 500) downloadKeys.delete(resultId);
    setText($("download-error"), error.message);
    openSection("transfers");
    button.disabled = false;
  }
}

export async function refreshDownloads() {
  let downloads;
  try {
    ({ downloads } = await api("GET", "/api/downloads"));
  } catch (error) { return; }
  // History is a stored view; asking for an unfinished one reconciles it.
  for (let index = 0; index < downloads.length; index += 1) {
    if (!TERMINAL_DOWNLOADS.has(downloads[index].state)) {
      try {
        downloads[index] = await api("GET", "/api/downloads/" + downloads[index].operation_id);
      } catch (error) { /* keep the stored view */ }
    }
  }
  renderDownloads(downloads);
}

function renderDownloads(downloads) {
  shared.activeDownloads = downloads.filter((download) => !TERMINAL_DOWNLOADS.has(download.state)).length;
  renderTransferCount();
  const list = $("downloads");
  // Rebuild only when something shown has changed, so that a button is not
  // replaced under the pointer on every poll.
  const stamp = JSON.stringify(downloads, (key, value) => (key === "updated_at" ? undefined : value));
  if (stamp === lastDownloadsStamp) return;
  const typing = list.contains(document.activeElement) && document.activeElement.tagName === "INPUT";
  if (typing) return;   // do not wipe a confirmation the operator is typing
  lastDownloadsStamp = stamp;
  list.replaceChildren();
  show($("downloads-empty"), downloads.length === 0);
  show($("downloads-clear"), downloads.some((download) => TERMINAL_DOWNLOADS.has(download.state)));
  for (const download of downloads) list.append(renderDownload(download));
}

function renderDownload(download) {
  const item = document.createElement("li");
  const head = document.createElement("div");
  head.className = "download-head";
  const name = document.createElement("span");
  name.className = "download-name";
  name.textContent = download.name || download.remote_path || "Download";
  const state = document.createElement("span");
  badge(state, download.state, NOT_REQUESTED.has(download.outcome) ? "Not requested"
    : NOT_STARTED.has(download.outcome) ? "Not started" : null);
  head.append(name, state);
  item.append(head);

  const meta = [];
  if (download.sender) meta.push("from " + download.sender);
  if (typeof download.bytes_received === "number" && typeof download.total_bytes === "number"
      && download.state !== "complete") {
    meta.push(`${formatBytes(download.bytes_received)} of ${formatBytes(download.total_bytes)} received`);
  } else if (typeof download.total_bytes === "number") {
    meta.push(formatBytes(download.total_bytes));
  }
  if (download.state === "complete" && download.download_path) meta.push("saved as " + download.download_path);
  if (SESSION_HINTS[download.outcome]) {
    if (download.reason) meta.push(download.reason);
    meta.push(SESSION_HINTS[download.outcome]);
  } else if (DOWNLOAD_HINTS[download.outcome]) {
    meta.push(DOWNLOAD_HINTS[download.outcome]);
  } else if (String(download.outcome || "").startsWith("pre_dispatch_recovery_")) {
    meta.push("The file server's session dropped before the file was asked for, and trying " +
      "again did not get it. Nothing was asked for.");
    if (download.reason) meta.push(download.reason);
  } else {
    if (download.state !== "complete" && download.reason) meta.push(download.reason);
    if (DOWNLOAD_HINTS[download.state]) meta.push(DOWNLOAD_HINTS[download.state]);
  }
  meta.push(new Date(download.created_at * 1000).toLocaleString());
  const line = document.createElement("div");
  line.className = "download-meta";
  line.textContent = meta.join(" · ");
  item.append(line);

  // A file server's own list of its files arrives as an ordinary text file.
  if (download.state === "complete" && /\.txt$/i.test(download.name || "")) {
    const use = document.createElement("button");
    use.type = "button";
    use.className = "quiet";
    use.textContent = "Use as a file list";
    use.addEventListener("click", () => addFileList(download.operation_id, use));
    const actions = document.createElement("div");
    actions.className = "actions";
    actions.append(use);
    item.append(actions);
  }

  if (!TERMINAL_DOWNLOADS.has(download.state) && download.job_id && !download.abandonable) {
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "quiet";
    cancel.textContent = download.cancel_requested ? "Cancel again" : "Cancel";
    cancel.addEventListener("click", () => downloadAction(
      cancel, "/api/downloads/" + download.operation_id + "/cancel", {}));
    const actions = document.createElement("div");
    actions.className = "actions";
    actions.append(cancel);
    item.append(actions);
  }
  // Asking again is the operator's press; the engine still refuses a file
  // already asked for on this connection (2026-10-22).
  if (TERMINAL_DOWNLOADS.has(download.state) && download.state !== "complete") {
    const retry = document.createElement("button");
    retry.type = "button";
    retry.className = "quiet";
    retry.textContent = "Try again";
    retry.addEventListener("click", () => retryDownload(download.operation_id, retry));
    const actions = document.createElement("div");
    actions.className = "actions";
    actions.append(retry);
    item.append(actions);
  }
  if (download.abandonable && download.abandon_confirmation) item.append(renderAbandon(download));
  // An ended download's record can be deleted (2026-10-29); the file stays.
  if (TERMINAL_DOWNLOADS.has(download.state)) {
    let actions = item.querySelector(":scope > .actions");
    if (!actions) {
      actions = document.createElement("div");
      actions.className = "actions";
      item.append(actions);
    }
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "quiet";
    remove.textContent = "Delete";
    remove.title = "Delete this record; a saved file stays where it is";
    remove.addEventListener("click", () => deleteDownload(download.operation_id, remove));
    actions.append(remove);
  }
  return item;
}

async function deleteDownload(operationId, button) {
  setText($("download-error"), "");
  button.disabled = true;
  try {
    await api("DELETE", `/api/downloads/${encodeURIComponent(operationId)}`);
  } catch (error) {
    setText($("download-error"), error.message);
    button.disabled = false;
    return;
  }
  await refreshDownloads();
}

$("downloads-clear").addEventListener("click", async () => {
  if (!window.confirm("Delete the records of every download that has ended? " +
      "Saved files stay where they are; downloads still going are kept.")) return;
  setText($("download-error"), "");
  const button = $("downloads-clear");
  button.disabled = true;
  try {
    await api("POST", "/api/downloads/clear", {});
  } catch (error) {
    setText($("download-error"), error.message);
  } finally {
    button.disabled = false;
  }
  await refreshDownloads();
});

async function retryDownload(operationId, button) {
  setText($("download-error"), "");
  button.disabled = true;
  const key = downloadKeys.get(operationId) || randomKey();
  downloadKeys.set(operationId, key);
  try {
    await api("POST", `/api/downloads/${encodeURIComponent(operationId)}/retry`,
      { idempotency_key: key });
    downloadKeys.delete(operationId);
    await refreshDownloads();
  } catch (error) {
    if (error.status !== 0 && error.status < 500) downloadKeys.delete(operationId);
    setText($("download-error"), error.message);
    button.disabled = false;
  }
}

function renderAbandon(download) {
  const box = document.createElement("div");
  box.className = "abandon";
  const warning = document.createElement("p");
  warning.className = "hint";
  warning.textContent = "The outcome of this request is unknown and it blocks new downloads. " +
    "Retiring it only clears this record: the server may still have queued or sent the file, " +
    "nothing is cancelled, and the request is never sent again. To retire it, type this phrase exactly:";
  const phrase = document.createElement("code");
  phrase.textContent = download.abandon_confirmation;
  const input = document.createElement("input");
  input.setAttribute("aria-label", "Confirmation phrase");
  input.autocomplete = "off";
  input.spellcheck = false;
  const retire = document.createElement("button");
  retire.type = "button";
  retire.className = "danger";
  retire.textContent = "Retire this record";
  retire.disabled = true;
  input.addEventListener("input", () => {
    retire.disabled = input.value !== download.abandon_confirmation;
  });
  retire.addEventListener("click", () => {
    const confirmation = input.value;
    input.blur();
    downloadAction(retire, "/api/downloads/" + download.operation_id + "/abandon", { confirmation });
  });
  const actions = document.createElement("div");
  actions.className = "actions";
  actions.append(input, retire);
  box.append(warning, phrase, actions);
  return box;
}

async function downloadAction(button, path, body) {
  setText($("download-error"), "");
  button.disabled = true;
  try {
    await api("POST", path, body);
  } catch (error) {
    setText($("download-error"), error.message);
  }
  lastDownloadsStamp = "";   // the pressed button is disabled; draw it afresh
  await refreshDownloads();
}
