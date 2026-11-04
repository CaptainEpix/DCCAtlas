// Sources and their logins.

import { $, badge, setText, shared, show, STATE_LABELS, stateTone } from "./core.js";
import { api } from "./api.js";
import { openSection, renderRailSources } from "./sections.js";
import { fileLists, fillPlacedSources, listLabel, listWhen } from "./lists.js";
import { renderSavedSearches } from "./saved.js";
import { fillLogSources } from "./log.js";

let sourceFormDirty = false;

const MAX_SOURCES = 8;
const sourceForm = $("source-form");
sourceForm.addEventListener("input", () => {
  sourceFormDirty = true;
  showFormHints();
});

export let selectedSourceId = null;   // the source the form edits
export let addingSource = false;      // the form is blank and Save adds a source
// Which source the form was last filled from. It starts blank, as the form for
// a new source, so what is typed before the first status is kept.
let formSourceId = null;
export let sourceEntries = [];        // [{ configuration, source }] from the last status
let lastSourceListStamp = "";
let removeArmed = null;

export function entryState(entry) {
  return entry.source ? entry.source.state : "configured";
}

// The nick Irssi has on the server, when it is not the configured one.
function nickInUse(entry) {
  const source = entry && entry.source;
  if (!source || !source.connected || !source.current_nick) return "";
  return source.current_nick.toLowerCase() === entry.configuration.nickname.toLowerCase()
    ? "" : source.current_nick;
}

function fillSourceForm(configuration) {
  const id = configuration ? configuration.source_id : null;
  // Keep what the operator is typing, unless the form now shows another source.
  if (sourceFormDirty && formSourceId === id) return;
  formSourceId = id;
  sourceFormDirty = false;
  for (const name of ["label", "host", "port", "nickname", "channel"]) {
    sourceForm.elements[name].value = configuration ? configuration[name] : "";
  }
  sourceForm.elements.tls.checked = Boolean(configuration && configuration.tls);
  sourceForm.elements.provider.value = configuration ? configuration.provider : "sysreset_find";
  sourceForm.elements.category.value = String(configuration ? configuration.category : 7000);
  sourceForm.elements.search_bot.value = configuration ? (configuration.search_bot || "") : "";
  showSearchBotField();
  showFormHints();
}

// What the form holds, as Save sends it.
function formValues() {
  const fields = sourceForm.elements;
  const values = {
    label: fields.label.value, host: fields.host.value.trim(),
    port: Number(fields.port.value), tls: fields.tls.checked,
    nickname: fields.nickname.value, channel: fields.channel.value,
    provider: fields.provider.value, category: Number(fields.category.value),
  };
  if (values.provider === "searchbot") values.search_bot = fields.search_bot.value.trim();
  return values;
}

function selectedEntry() {
  if (addingSource) return null;
  return sourceEntries.find((entry) => entry.configuration.source_id === selectedSourceId) || null;
}

// True when the form shows something other than the saved settings.
function formDiffers(configuration) {
  if (!configuration) return false;
  const values = formValues();
  const bot = values.provider === "searchbot" ? configuration.search_bot || "" : "";
  return ["label", "host", "port", "nickname", "channel", "provider", "category"].some(
    (name) => values[name] !== configuration[name])
    || values.tls !== Boolean(configuration.tls)
    || (values.search_bot || "") !== bot;
}

// Connect uses the saved settings, so with changes in the form it saves them first.
function showFormHints() {
  const entry = selectedEntry();
  const unsaved = Boolean(entry) && formDiffers(entry.configuration);
  $("connect").textContent = unsaved ? "Save and connect" : "Connect";
  const port = Number(sourceForm.elements.port.value);
  const tls = sourceForm.elements.tls.checked;
  let hint = "";
  if (port === 6697 && !tls) {
    hint = "Port 6697 is normally for TLS. With TLS off, the server usually waits and then " +
      "closes the connection. Tick TLS, or use port 6667.";
  } else if (port === 6667 && tls) {
    hint = "Port 6667 is normally for plain connections. With TLS on, the connection usually " +
      "fails at once. Untick TLS, or use port 6697.";
  }
  setText($("port-hint"), hint);
}

// Only a search-bot source names a search bot.
function showSearchBotField() {
  const wanted = sourceForm.elements.provider.value === "searchbot";
  show($("search-bot-field"), wanted);
  sourceForm.elements.search_bot.required = wanted;
}
sourceForm.elements.provider.addEventListener("change", showSearchBotField);

export function selectSource(sourceId) {
  addingSource = false;
  selectedSourceId = sourceId;
  sourceFormDirty = false;
  setText($("source-error"), "");
  refreshStatus();
}

function renderSourceList(entries) {
  show($("source-tabs"), entries.length > 0);
  $("add-source").setAttribute("aria-pressed", String(addingSource && entries.length > 0));
  const stamp = entries.map((entry) => [
    entry.configuration.source_id, entry.configuration.label, entryState(entry),
  ].join("\u0001")).join("\u0002") + "|" + (addingSource ? "" : selectedSourceId);
  if (stamp === lastSourceListStamp) return;   // do not replace tabs under the pointer
  lastSourceListStamp = stamp;
  const list = $("source-tab-list");
  list.replaceChildren();
  for (const entry of entries) {
    const config = entry.configuration;
    const state = entryState(entry);
    const current = !addingSource && config.source_id === selectedSourceId;
    const tab = document.createElement("button");
    tab.type = "button";
    tab.className = "tab";
    tab.setAttribute("role", "tab");
    tab.setAttribute("aria-selected", String(current));
    tab.title = `${config.label}: ${STATE_LABELS[state] || state}`;
    const dot = document.createElement("span");
    dot.className = "dot " + stateTone(state);
    const name = document.createElement("span");
    name.className = "tab-name";
    name.textContent = config.label;
    tab.append(dot, name);
    if (!current) tab.addEventListener("click", () => selectSource(config.source_id));
    list.append(tab);
  }
}

// Newznab's numbers for what a source holds (webapp/categories.py).
const CATEGORY_NAMES = {
  7000: "Books", 7020: "Books/EBook", 7030: "Books/Comics", 3030: "Audio/Audiobook",
  3000: "Audio", 2000: "Movies", 5000: "TV", 4000: "PC", 1000: "Console", 8000: "Other",
};

// Where the selected source connects, shown under its tab.
function sourceWhere(entry) {
  if (!entry) return "";
  const config = entry.configuration;
  return `${config.host} port ${config.port}, TLS ${config.tls ? "on" : "off"} · ${config.channel}` +
    (config.provider === "searchbot" ? ` · search bot ${config.search_bot}` : " · file servers") +
    ` · ${CATEGORY_NAMES[config.category] || "category " + config.category}` +
    (nickInUse(entry) ? ` · connected as ${nickInUse(entry)}` : "");
}

const MAX_SOURCES_PER_SEARCH = 5;
export const tickedSources = new Set();   // sources the next search asks; none to begin with
export const tickedLists = new Set();     // stored file lists the next search looks in

export function renderSearchSources(entries) {
  const ready = entries.filter((entry) => entryState(entry) === "ready");
  for (const id of [...tickedSources]) {
    if (!ready.some((entry) => entry.configuration.source_id === id)) tickedSources.delete(id);
  }
  // A list whose source was removed, or now names another server, can no
  // longer be downloaded from.
  const lists = fileLists.filter((item) => item.source_label);
  for (const key of [...tickedLists]) {
    if (!lists.some((item) => item.route_key === key)) tickedLists.delete(key);
  }
  renderSavedSearches();
  const box = $("search-sources");
  show(box, entries.length > 1 || lists.length > 0);
  const channels = ready.map((entry) => entry.configuration.source_id);
  const allChannels = channels.length > 0 &&
    channels.slice(0, MAX_SOURCES_PER_SEARCH).every((id) => tickedSources.has(id));
  const allLists = lists.length > 0 && lists.every((item) => tickedLists.has(item.route_key));
  show($("tick-channels"), channels.length > 0);
  show($("tick-lists"), lists.length > 0);
  $("tick-channels").textContent = allChannels ? "No channels"
    : channels.length > MAX_SOURCES_PER_SEARCH
    ? `All channels (the first ${MAX_SOURCES_PER_SEARCH})` : "All channels";
  $("tick-lists").textContent = allLists ? "No file lists" : "All file lists";
  $("tick-channels").dataset.all = allChannels ? "yes" : "";
  $("tick-lists").dataset.all = allLists ? "yes" : "";
  const stamp = ready.map((entry) =>
    entry.configuration.source_id + "\u0001" + entry.configuration.label).join("\u0002") +
    "|" + [...tickedSources].sort().join(",") +
    "|" + lists.map((item) => item.route_key + listLabel(item)).join("\u0002") +
    "|" + [...tickedLists].sort().join(",");
  if (stamp === box.dataset.stamp) return;   // do not replace boxes under the pointer
  box.dataset.stamp = stamp;
  const list = $("search-source-list");
  list.replaceChildren();
  if (!ready.length) {
    const none = document.createElement("span");
    none.className = "hint";
    none.textContent = "No source is connected. ";
    list.append(none);
  }
  const full = tickedSources.size >= MAX_SOURCES_PER_SEARCH;
  for (const entry of ready) {
    const id = entry.configuration.source_id;
    const label = document.createElement("label");
    const tick = document.createElement("input");
    tick.type = "checkbox";
    tick.checked = tickedSources.has(id);
    tick.disabled = full && !tick.checked;
    tick.addEventListener("change", () => {
      if (tick.checked) tickedSources.add(id); else tickedSources.delete(id);
      renderSearchSources(sourceEntries);
    });
    const kind = entry.configuration.provider === "searchbot" ? "search bot" : "file servers";
    label.append(tick, `${entry.configuration.label} (${entry.configuration.channel}, ${kind})`);
    list.append(label);
  }
  for (const item of lists) {
    const label = document.createElement("label");
    const tick = document.createElement("input");
    tick.type = "checkbox";
    tick.checked = tickedLists.has(item.route_key);
    tick.addEventListener("change", () => {
      if (tick.checked) tickedLists.add(item.route_key); else tickedLists.delete(item.route_key);
      renderSearchSources(sourceEntries);
    });
    label.append(tick, `File list of ${item.sender} ${item.trigger} ` +
      `(${item.source_label}, listed ${listWhen(item.listed_at)})`);
    list.append(label);
  }
}

$("tick-channels").addEventListener("click", (event) => {
  const none = event.currentTarget.dataset.all === "yes";
  tickedSources.clear();
  if (!none) {
    for (const entry of sourceEntries.filter((item) => entryState(item) === "ready")
      .slice(0, MAX_SOURCES_PER_SEARCH)) tickedSources.add(entry.configuration.source_id);
  }
  renderSearchSources(sourceEntries);
});
$("tick-lists").addEventListener("click", (event) => {
  const none = event.currentTarget.dataset.all === "yes";
  tickedLists.clear();
  if (!none) {
    for (const item of fileLists.filter((list) => list.source_label)) tickedLists.add(item.route_key);
  }
  renderSearchSources(sourceEntries);
});

function renderStatus(status) {
  const engine = $("engine-badge");
  if (!status.engine_available) {
    badge(engine, "failed", "Engine starting");
    badge($("source-state"), "", "Unavailable");
    setText($("source-reason"), "The download engine is not answering yet.");
    setText($("source-nick"), "");
    for (const id of ["connect", "disconnect", "remove-source", "add-source"]) $(id).disabled = true;
    return;
  }
  show(engine, false);
  const entries = status.sources || [];
  sourceEntries = entries;
  if (!entries.length) addingSource = true;   // nothing yet: the form adds the first source
  // Nothing to search yet: open on the form that adds a source.
  if (!shared.sectionChosen && !entries.length) openSection("sources");
  shared.sectionChosen = true;
  renderRailSources(entries);
  let selected = null;
  if (!addingSource) {
    selected = entries.find((entry) => entry.configuration.source_id === selectedSourceId)
      || entries[0];
    selectedSourceId = selected.configuration.source_id;
  }
  renderSourceList(entries);
  renderSearchSources(entries);
  fillLogSources(entries);
  fillSourceForm(selected ? selected.configuration : null);
  $("source-heading").textContent = entries.length > 1 ? "Sources" : "Source";

  const source = selected ? selected.source : null;
  const state = selected ? entryState(selected) : "";
  badge($("source-state"), state, state ? null : (entries.length ? "New source" : "Not set up"));
  let reason = source && source.reason ? source.reason : "";
  if (status.restore_pending) reason = "Saved settings could not be applied to the engine yet. Save them again.";
  if (!status.journal_ready) reason = "The download journal is unavailable; downloads cannot start.";
  setText($("source-reason"), reason);
  setText($("source-where"), sourceWhere(selected));
  show($("source-log-link"), Boolean(reason && selected));
  const nick = nickInUse(selected);
  setText($("source-nick"), nick ? `Connected as ${nick}: the nickname ` +
    `${selected.configuration.nickname} was taken, so Irssi picked another.` : "");
  fillPlacedSources(entries);
  const busy = ["connecting", "joining", "leaving"].includes(state);
  const atRest = ["configured", "disconnected", "failed"].includes(state);
  $("connect").disabled = !selected || busy || state === "ready";
  $("disconnect").disabled = !source || ["configured", "disconnected"].includes(state);
  show($("remove-source"), Boolean(selected));
  $("remove-source").disabled = !selected || !atRest;
  if (removeArmed !== selectedSourceId) {
    removeArmed = null;
    $("remove-source").textContent = "Remove";
  }
  renderLogin(selected);
  show($("cancel-add"), addingSource && entries.length > 0);
  $("add-source").disabled = entries.length >= MAX_SOURCES;
  showFormHints();
}

const loginForm = $("login-source-form");

function loginText(login) {
  if (!login) return "Login: none";
  if (login.kind === "sasl_plain") return `Login: account ${login.username}`;
  if (login.kind === "certificate") return "Login: client certificate";
  if (login.kind === "nickserv") {
    return "Login: NickServ" + (login.username ? ` as ${login.username}` : "");
  }
  return "Login: server password set";
}

function showLoginUser() {
  const kind = loginForm.elements.kind.value;
  // NickServ takes an account name only when it is not the nick; a
  // certificate takes neither name nor password.
  show($("login-user-field"), kind !== "server_password" && kind !== "certificate");
  show($("login-password-field"), kind !== "certificate");
  loginForm.elements.password.required = kind !== "certificate";
  loginForm.elements.username.required = kind === "sasl_plain";
  loginForm.elements.username.placeholder = kind === "nickserv" ? "the nick, if left empty" : "";
}
loginForm.elements.kind.addEventListener("change", showLoginUser);
showLoginUser();

function renderLogin(selected) {
  show($("login-box"), Boolean(selected));
  if (!selected) return;
  const login = selected.configuration.login;
  $("login-summary").textContent = loginText(login);
  $("login-clear").disabled = !login;
  const certificate = login && login.kind === "certificate";
  show($("login-fingerprints"), Boolean(certificate));
  $("login-sha256").textContent = certificate ? login.sha256 : "";
  $("login-sha512").textContent = certificate ? login.sha512 : "";
}

loginForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  setText($("login-source-error"), "");
  setText($("login-note"), "");
  const kind = loginForm.elements.kind.value;
  const body = kind === "certificate" ? { kind } : { kind, password: loginForm.elements.password.value };
  const username = loginForm.elements.username.value.trim();
  if (kind === "sasl_plain" || (kind === "nickserv" && username)) body.username = username;
  const button = loginForm.querySelector("button[type=submit]");
  button.disabled = true;
  try {
    renderStatus({ engine_available: true, ...(await api(
      "PUT", selectedSourcePath("/login"), body)) });
    loginForm.elements.password.value = "";
    setText($("login-note"), "Saved. It is used from the next Connect.");
  } catch (error) {
    setText($("login-source-error"), error.message);
  }
  button.disabled = false;
});

$("login-clear").addEventListener("click", async () => {
  setText($("login-source-error"), "");
  setText($("login-note"), "");
  try {
    renderStatus({ engine_available: true, ...(await api("DELETE", selectedSourcePath("/login"))) });
    setText($("login-note"), "Cleared. The next Connect logs in without it.");
  } catch (error) {
    setText($("login-source-error"), error.message);
  }
});

// The app's page files as this page found them; if they change, the app was
// updated under an open page, which then runs old code (2026-10-27).
let pageBuild = null;

export async function refreshStatus() {
  let status;
  try { status = await api("GET", "/api/status"); } catch (error) { return; /* shown on next success */ }
  if (status.page_build) {
    pageBuild = pageBuild || status.page_build;
    if (status.page_build !== pageBuild) {
      setText($("notice"), "DCCAtlas has been updated since this page was opened. " +
        "Reload the page to use the new version.");
    }
  }
  renderStatus(status);
}

async function sourceAction(action) {
  setText($("source-error"), "");
  try {
    renderStatus({ engine_available: true, ...(await action()) });
  } catch (error) {
    setText($("source-error"), error.message);
  }
}

function selectedSourcePath(suffix) {
  return "/api/sources/" + encodeURIComponent(selectedSourceId) + (suffix || "");
}

async function saveSourceForm() {
  const body = formValues();
  let saved;
  if (!addingSource) {
    saved = await api("PUT", selectedSourcePath(), body);
  } else if (!sourceEntries.length) {
    saved = await api("PUT", "/api/source", body);
    selectedSourceId = saved.configuration.source_id;
  } else {
    saved = await api("POST", "/api/sources", body);
    selectedSourceId = saved.source_id;
  }
  addingSource = false;
  sourceFormDirty = false;
  return saved;
}

sourceForm.addEventListener("submit", (event) => {
  event.preventDefault();
  sourceAction(saveSourceForm);
});

$("connect").addEventListener("click", () => sourceAction(async () => {
  const entry = selectedEntry();
  if (entry && formDiffers(entry.configuration)) {
    if (!sourceForm.reportValidity()) throw new Error("Correct the highlighted field first.");
    await saveSourceForm();
  }
  return api("POST", selectedSourcePath("/connect"));
}));
$("disconnect").addEventListener("click", () =>
  sourceAction(() => api("POST", selectedSourcePath("/disconnect"))));

$("add-source").addEventListener("click", () => {
  addingSource = true;
  sourceFormDirty = false;
  formSourceId = undefined;
  setText($("source-error"), "");
  refreshStatus();
});

$("cancel-add").addEventListener("click", () => selectSource(selectedSourceId));

// Removing asks twice: the second press, within five seconds, does it.
$("remove-source").addEventListener("click", () => {
  const button = $("remove-source");
  if (removeArmed !== selectedSourceId) {
    const armed = selectedSourceId;
    removeArmed = armed;
    button.textContent = "Remove this source?";
    setTimeout(() => {
      if (removeArmed === armed) {
        removeArmed = null;
        button.textContent = "Remove";
      }
    }, 5000);
    return;
  }
  removeArmed = null;
  button.textContent = "Remove";
  sourceAction(async () => {
    const result = await api("DELETE", selectedSourcePath());
    selectedSourceId = null;
    sourceFormDirty = false;
    return result;
  });
});
