// The log.

import { $, setText, shared, show } from "./core.js";
import { api } from "./api.js";
import { openSection } from "./sections.js";
import { refreshAll } from "./polling.js";
import { selectedSourceId } from "./sources.js";

const LOG_KEEP = 2000;
const LOG_KIND_LABELS = {
  received: "in", sent: "out", irssi: "irssi", error: "error", state: "state",
  engine: "engine", web: "web",
};
let logAfter = 0;         // the last line id shown
let logFilter = "";       // a source id, or "" for all
let logBusy = false;

function logTime(seconds) {
  const when = new Date(seconds * 1000);
  return [when.getHours(), when.getMinutes(), when.getSeconds()]
    .map((part) => String(part).padStart(2, "0")).join(":");
}

function renderLogLine(line) {
  const row = document.createElement("div");
  row.className = "log-line " + (LOG_KIND_LABELS[line.kind] ? line.kind : "engine");
  const time = document.createElement("span");
  time.className = "log-time";
  time.textContent = logTime(line.time) + " ";
  row.append(time);
  if (!logFilter && line.labels && line.labels.length) {
    const where = document.createElement("span");
    where.className = "log-where";
    where.textContent = `[${line.labels.join(", ")}] `;
    row.append(where);
  }
  const text = document.createElement("span");
  text.className = "log-text";
  text.textContent = `${LOG_KIND_LABELS[line.kind] || line.kind}: ${line.text}`;
  row.append(text);
  return row;
}

export async function refreshLog() {
  if (logBusy) return;
  logBusy = true;
  const box = $("log-box");
  const filter = logFilter;
  try {
    for (let round = 0; round < 5; round += 1) {
      const query = `/api/log?after=${logAfter}` + (filter ? `&source=${encodeURIComponent(filter)}` : "");
      const page = await api("GET", query);
      if (filter !== logFilter) break;   // the filter changed meanwhile; drawn afresh
      const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 24;
      for (const line of page.lines) box.append(renderLogLine(line));
      while (box.childElementCount > LOG_KEEP) box.firstElementChild.remove();
      if (page.lines.length) logAfter = page.lines[page.lines.length - 1].id;
      else logAfter = Math.max(logAfter, page.last_id);
      if (page.lines.length && $("log-follow").checked && (atBottom || round === 0)) {
        box.scrollTop = box.scrollHeight;
      }
      if (!page.more) break;
    }
    setText($("log-error"), "");
  } catch (error) {
    setText($("log-error"), error.message);
  } finally {
    logBusy = false;
  }
  show($("log-empty"), !box.childElementCount);
}

export function fillLogSources(entries) {
  const select = $("log-source");
  const stamp = entries.map((entry) =>
    entry.configuration.source_id + "\u0001" + entry.configuration.label).join("\u0002");
  if (select.dataset.stamp === stamp) return;
  select.dataset.stamp = stamp;
  const keep = select.value;
  select.replaceChildren(new Option("All sources", ""));
  for (const entry of entries) {
    select.append(new Option(entry.configuration.label, entry.configuration.source_id));
  }
  select.value = entries.some((entry) => entry.configuration.source_id === keep) ? keep : "";
  if (select.value !== logFilter) setLogFilter(select.value);
}

function setLogFilter(sourceId) {
  logFilter = sourceId;
  $("log-source").value = sourceId;
  logAfter = 0;
  $("log-box").replaceChildren();
  refreshLog();
}

$("log-source").addEventListener("change", (event) => setLogFilter(event.target.value));

$("log-clear").addEventListener("click", () => {
  $("log-box").replaceChildren();
  show($("log-empty"), true);
});

$("show-source-log").addEventListener("click", () => {
  if (selectedSourceId) setLogFilter(selectedSourceId);
  openSection("log");
});

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && shared.pollTimer) refreshAll();
});
