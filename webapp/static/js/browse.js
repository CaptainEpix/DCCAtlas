// Browsing a file server.

import { $, badge, formatBytes, setText, show, stateTone } from "./core.js";
import { api } from "./api.js";
import { openSection } from "./sections.js";
import { addToQueue, startDownload } from "./transfers.js";

let currentBrowse = null;   // { id, path, find }
let browseTimer = null;
const BROWSE_STATES = { browsing: "Reading folders", complete: "Read", failed: "Stopped" };

// What to browse: { result_id } for a search result, or { source_id, nick,
// trigger } for a file server seen announcing itself.
export async function startBrowse(what, button) {
  setText($("browse-error"), "");
  button.disabled = true;
  try {
    const view = await api("POST", "/api/browse", typeof what === "string" ? { result_id: what } : what);
    currentBrowse = { id: view.browse_id, path: view.start_path, find: "" };
    $("browse-find-terms").value = "";
    renderBrowse(view);
    openSection("browse");
  } catch (error) {
    show($("browse-card"), true);
    setText($("browse-error"), error.message);
    openSection("browse");
  }
  button.disabled = false;
}

async function browseFromHere() {
  setText($("browse-error"), "");
  $("browse-here").disabled = true;
  try {
    const view = await api("POST", "/api/browse",
      { browse_id: currentBrowse.id, path: currentBrowse.path });
    currentBrowse = { id: view.browse_id, path: view.start_path, find: "" };
    $("browse-find-terms").value = "";
    renderBrowse(view);
  } catch (error) {
    setText($("browse-error"), error.message);
  }
  $("browse-here").disabled = false;
}
$("browse-here").addEventListener("click", browseFromHere);

// A browse that stopped (the engine restarted, or the session ended early)
// is started again from where it started, at the operator's press.
$("browse-again").addEventListener("click", async () => {
  if (!currentBrowse) return;
  currentBrowse.path = currentBrowse.start || currentBrowse.path;
  await browseFromHere();
});

async function refreshBrowse() {
  clearTimeout(browseTimer);
  if (!currentBrowse) return;
  try {
    if (currentBrowse.find) {
      renderBrowseFound(await api("GET", `/api/browse/${currentBrowse.id}?find=` +
        encodeURIComponent(currentBrowse.find)));
    } else {
      renderBrowse(await api("GET", `/api/browse/${currentBrowse.id}?path=` +
        encodeURIComponent(currentBrowse.path)));
    }
  } catch (error) {
    setText($("browse-error"), error.message);
  }
}

function openBrowseFolder(path) {
  currentBrowse.path = path;
  currentBrowse.find = "";
  refreshBrowse();
}

// Finding looks through what the browse already read; nothing is sent.
$("browse-find").addEventListener("submit", (event) => {
  event.preventDefault();
  if (!currentBrowse) return;
  currentBrowse.find = $("browse-find-terms").value;
  refreshBrowse();
});

$("browse-find-clear").addEventListener("click", () => {
  $("browse-find-terms").value = "";
  openBrowseFolder(currentBrowse.path);
});

function browseFileRow(file, withFolder) {
  const row = document.createElement("tr");
  const name = row.insertCell();
  name.className = "path";
  name.textContent = file.name;
  if (withFolder) {
    const folder = row.insertCell();
    folder.className = "path";
    const open = document.createElement("button");
    open.type = "button";
    open.className = "quiet";
    open.textContent = file.folder;
    open.addEventListener("click", () => {
      $("browse-find-terms").value = "";
      openBrowseFolder(file.folder);
    });
    folder.append(open);
  }
  const size = row.insertCell();
  size.className = "num";
  size.textContent = typeof file.size_bytes === "number"
    ? formatBytes(file.size_bytes) : (file.size_text || "unknown");
  const action = row.insertCell();
  const get = document.createElement("button");
  get.type = "button";
  get.textContent = "Download";
  get.addEventListener("click", () => startDownload(file.result_id, get));
  const later = document.createElement("button");
  later.type = "button";
  later.className = "quiet";
  later.textContent = "Add to queue";
  later.addEventListener("click", () => addToQueue(file.result_id, later));
  action.append(get, later);
  return row;
}

function renderBrowseFound(view) {
  setText($("browse-error"), "");
  show($("browse-find-clear"), true);
  setText($("browse-crumbs"), `Files with “${view.terms}” anywhere in what was read: ${view.total}`);
  $("browse-folders").replaceChildren();
  show($("browse-folder-col"), true);
  $("browse-files").tBodies[0].replaceChildren(...view.files.map((file) => browseFileRow(file, true)));
  show($("browse-files"), view.files.length > 0);
  show($("browse-unread"), false);
  setText($("browse-more"), view.more_files ? `And ${view.more_files} more, not shown here.` : "");
  show($("browse-empty"), false);
}

function renderBrowse(view) {
  show($("browse-card"), true);
  setText($("browse-error"), "");
  badge($("browse-state"), view.state === "browsing" ? "receiving" : view.state,
    BROWSE_STATES[view.state] || view.state);
  $("nav-browse").className = "dot " + (view.state === "browsing" ? "warn" : stateTone(view.state));
  show($("nav-browse"), true);
  setText($("browse-title"), `Folders of ${view.sender} (${view.trigger})` +
    (view.state === "browsing" ? ` · ${view.folders_read} read so far` : ""));
  setText($("browse-note"), view.note);
  show($("browse-find"), view.state !== "browsing");
  show($("browse-find-clear"), false);
  show($("browse-folder-col"), false);
  const crumbs = $("browse-crumbs");
  const parts = view.path === "/" ? [] : view.path.slice(1).split("/");
  const steps = [["/", "Top"]].concat(parts.map((name, index) =>
    ["/" + parts.slice(0, index + 1).join("/"), name]));
  crumbs.replaceChildren(...steps.map(([path, name], index) => {
    if (index === steps.length - 1) {
      const here = document.createElement("strong");
      here.textContent = name;
      return here;
    }
    const step = document.createElement("button");
    step.type = "button";
    step.className = "quiet";
    step.textContent = name + " /";
    step.addEventListener("click", () => openBrowseFolder(path));
    return step;
  }));
  const done = view.state !== "browsing";
  $("browse-folders").replaceChildren(...view.folders.map((folder) => {
    const item = document.createElement("li");
    const open = document.createElement("button");
    open.type = "button";
    open.className = "quiet";
    open.textContent = folder.name + "/" + (done && !folder.read ? " (not read)" : "");
    open.addEventListener("click", () => openBrowseFolder(folder.path));
    item.append(open);
    return item;
  }));
  $("browse-files").tBodies[0].replaceChildren(...view.files.map((file) => browseFileRow(file, false)));
  show($("browse-files"), view.files.length > 0);
  show($("browse-unread"), done && !view.read && view.state !== "failed");
  show($("browse-stopped"), view.state === "failed");
  if (currentBrowse) currentBrowse.start = view.start_path;
  const more = [view.more_folders ? `${view.more_folders} more folders` : "",
    view.more_files ? `${view.more_files} more files` : ""].filter(Boolean).join(" and ");
  setText($("browse-more"), more ? `And ${more}, not shown here.` : "");
  show($("browse-empty"), done && view.read && !view.folders.length && !view.files.length);
  if (!done) browseTimer = setTimeout(refreshBrowse, 2000);
}
