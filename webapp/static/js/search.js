// Search: the form, its places, results and earlier searches.

import { $, badge, formatBytes, PAGE_SIZE, setText, shared, show, STATE_LABELS } from "./core.js";
import { api } from "./api.js";
import { listWhen } from "./lists.js";
import { sourceEntries, tickedLists, tickedSources } from "./sources.js";
import { runSaved } from "./saved.js";
import { startBrowse } from "./browse.js";
import { addToQueue, startDownload } from "./transfers.js";

let currentSearch = null;      // { id, offset, live }
let lastSearchStamp = "";
let searchPollFailed = false;

// Where the next search looks: the ticked places, or the only source.
export function chosenPlaces() {
  if ($("search-sources").hidden) {
    return { asked: sourceEntries.map((entry) => entry.configuration.source_id), lists: [] };
  }
  return { asked: [...tickedSources], lists: [...tickedLists] };
}

$("search-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  setText($("search-error"), "");
  try {
    const terms = $("terms").value;
    // With a choice of places the operator ticks where to look. Each
    // ticked source gets one query; nothing is ticked for them.
    const { asked, lists } = chosenPlaces();
    if (!asked.length && !lists.length) {
      setText($("search-error"), "Tick where to look.");
      return;
    }
    if (asked.length > 1 || lists.length) {
      const group = await api("POST", "/api/search-groups",
        { terms, source_ids: asked, list_keys: lists });
      openSearch(group.group_id, 0, true);
    } else {
      const body = { terms };
      if (asked.length) body.source_id = asked[0];
      const search = await api("POST", "/api/searches", body);
      openSearch(search.search_id, 0);
    }
  } catch (error) {
    setText($("search-error"), error.message);
  }
});

function openSearch(searchId, offset, group = false) {
  currentSearch = { id: searchId, offset, group };
  lastSearchStamp = "";
  clearTimeout(shared.searchTimer);
  pollSearch();
  refreshSearchHistory();
}

async function pollSearch() {
  if (!currentSearch) return;
  const search = currentSearch;
  try {
    const base = (search.group ? "/api/search-groups/" : "/api/searches/") + search.id;
    const summary = await api("GET", base);
    if (search !== currentSearch) return;
    if (searchPollFailed) {
      searchPollFailed = false;
      setText($("search-error"), "");
    }
    const stamp = [summary.state, summary.engine_state, summary.result_count,
                   summary.historical, search.offset,
                   ...(summary.members || []).map((member) => [
                     member.state, member.engine_state, member.result_count,
                     member.historical].join(","))].join("|");
    if (stamp !== lastSearchStamp) {
      const page = await api(
        "GET", `${base}/results?offset=${search.offset}&limit=${PAGE_SIZE}`);
      if (search !== currentSearch) return;
      lastSearchStamp = stamp;
      renderSearch(page);
    }
    if (summary.state === "collecting" || summary.state === "dispatch_pending" ||
        summary.state === "running") {
      search.live = true;
      shared.searchTimer = setTimeout(pollSearch, 700);
    } else if (search.live) {
      search.live = false;
      refreshSearchHistory();   // its entry still says "Searching"
    }
  } catch (error) {
    if (search !== currentSearch) return;
    if (error.code === "poll_too_fast") {
      shared.searchTimer = setTimeout(pollSearch, 400);
      return;
    }
    setText($("search-error"), error.message);
    // A lost poll must not leave a running search frozen on screen.
    if (error.status === 0 || error.status >= 500) {
      searchPollFailed = true;
      shared.searchTimer = setTimeout(pollSearch, 2000);
    }
  }
}

// How a row was found. The three ways differ in how fresh the row is and
// in what a download does, so every row says which it was.
function foundBy(item) {
  if (item.provider === "file_list") return "file list of " + listWhen(item.listed_at);
  if (item.provider === "searchbot") return "search bot";
  return "@find";
}

// What one place of a combined search is doing, in a few words.
function memberProgress(member) {
  if (member.kind === "list") {
    if (member.state === "complete") {
      return `${member.result_count} match(es)` +
        (member.capped ? ", the first 1,000" : "") +
        (member.historical ? ", list since replaced or removed" : "");
    }
    if (member.state === "waiting") return "looking";
    return member.note ? `not searched (${member.note})` : "not searched";
  }
  if (member.state === "waiting") return "waiting its turn";
  if (member.state === "collecting") {
    return member.engine_state === "dispatch_pending" ? "waiting to send" : "searching";
  }
  if (member.state === "complete") {
    return `${member.result_count} result(s)` +
      (member.historical ? ", no longer downloadable" : "");
  }
  const label = (STATE_LABELS[member.state] || member.state || "not asked").toLowerCase();
  return member.note ? `${label} (${member.note})` : label;
}

function renderSearch(page) {
  const grouped = Array.isArray(page.members);
  let parts;
  if (grouped) {
    badge($("search-state"), page.state === "running" ? "collecting" : page.state,
      page.state === "running" ? "Searching" : null);
    parts = [`"${page.terms}"`, `${page.result_count} result(s)`,
      ...page.members.map((member) =>
        `${member.kind === "list" ? "List of " : ""}${member.label}: ${memberProgress(member)}`)];
    if (page.state === "running" &&
        page.members.filter((member) => member.kind !== "list").length > 1) {
      parts.push("Sources are asked at the same time; a search bot's after the others.");
    }
  } else {
    // The engine spaces searches on one channel 30 seconds apart.
    const waiting = page.state === "collecting" && page.engine_state === "dispatch_pending";
    badge($("search-state"), page.state, waiting ? "Waiting to send" : null);
    parts = [`"${page.terms}" in ${page.channel}` +
      (page.provider === "searchbot" ? " through its search bot" : ""),
      `${page.result_count} result(s)`];
    if (waiting) parts.push("Searches on a channel are sent at least 30 seconds apart; this one is waiting its turn.");
    if (page.provider === "searchbot" && page.state === "collecting" && !waiting) {
      parts.push("Waiting for the search bot's result list.");
    }
    if (page.note) parts.push(page.note);
    if (page.cap_notice) parts.push(page.cap_notice);
    if (page.historical && page.state === "complete") {
      parts.push("Shown from history; run the search again to download.");
    }
  }
  setText($("search-summary"), parts.join(" · "));

  $("results").classList.toggle("single-source", !grouped);
  const body = $("results").tBodies[0];
  body.replaceChildren();
  for (const result of page.results) {
    const row = body.insertRow();
    const from = row.insertCell();
    from.className = "source-col";
    if (grouped) {
      const how = document.createElement("span");
      how.className = "hint via";
      how.textContent = foundBy(result);
      from.append(result.source_label || "", how);
    }
    const path = row.insertCell();
    path.className = "path";
    path.textContent = result.path;
    const size = row.insertCell();
    size.className = "num";
    if (typeof result.size_bytes_exact === "number") size.textContent = formatBytes(result.size_bytes_exact);
    else if (typeof result.size_bytes_estimate === "number") size.textContent = "about " + formatBytes(result.size_bytes_estimate);
    else size.textContent = result.size_text || "unknown";
    row.insertCell().textContent = result.sender;
    row.insertCell().textContent = result.trigger;
    const action = row.insertCell();
    if (result.selection_available && result.result_id) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = "Download";
      button.addEventListener("click", () => startDownload(result.result_id, button));
      action.append(button);
      const later = document.createElement("button");
      later.type = "button";
      later.className = "quiet";
      later.textContent = "Add to queue";
      later.addEventListener("click", () => addToQueue(result.result_id, later));
      action.append(later);
    }
    // A file server with a session can be browsed; a row to post back cannot.
    if (result.result_id && ["channel_text", "ctcp"].includes(result.trigger_mode) &&
        !String(result.result_id).startsWith("mrow-")) {
      const browse = document.createElement("button");
      browse.type = "button";
      browse.className = "quiet";
      browse.textContent = "Browse";
      browse.title = `Read the folders of ${result.sender}`;
      browse.addEventListener("click", () => startBrowse(result.result_id, browse));
      action.append(browse);
    }
  }
  show($("results"), page.results.length > 0);

  const stored = grouped ? page.result_count
    : Math.min(page.result_count, page.stored_result_limit);
  show($("pager"), stored > PAGE_SIZE);
  $("page-prev").disabled = page.offset === 0;
  $("page-next").disabled = page.offset + PAGE_SIZE >= stored;
  $("page-label").textContent = stored
    ? `${page.offset + 1}–${Math.min(page.offset + PAGE_SIZE, stored)} of ${stored}` : "";
}

function turnPage(delta) {
  if (!currentSearch) return;
  currentSearch.offset = Math.max(0, currentSearch.offset + delta);
  clearTimeout(shared.searchTimer);
  pollSearch();
}

$("results").classList.add("single-source");
$("page-prev").addEventListener("click", () => turnPage(-PAGE_SIZE));
$("page-next").addEventListener("click", () => turnPage(PAGE_SIZE));

export async function refreshSearchHistory() {
  try {
    const [{ searches }, grouped] = await Promise.all([
      api("GET", "/api/searches"),
      api("GET", "/api/search-groups").catch(() => ({ groups: [] })),
    ]);
    const groups = grouped.groups || [];
    // A combined search is one entry; its per-source searches are not listed again.
    const inGroup = new Set();
    for (const group of groups) {
      for (const member of group.members) if (member.search_id) inGroup.add(member.search_id);
    }
    const entries = [
      ...groups.map((group) => ({ group, at: group.started_at })),
      ...searches.filter((search) => !inGroup.has(search.search_id))
        .map((search) => ({ search, at: search.started_at })),
    ].sort((a, b) => b.at - a.at).slice(0, 20);
    const list = $("search-history");
    list.replaceChildren();
    for (const entry of entries) {
      const item = document.createElement("li");
      const open = document.createElement("button");
      open.type = "button";
      open.className = "quiet";
      const meta = document.createElement("span");
      meta.className = "hint";
      const when = new Date(entry.at * 1000).toLocaleString();
      let again;
      if (entry.group) {
        const group = entry.group;
        open.textContent = group.terms;
        open.addEventListener("click", () => openSearch(group.group_id, 0, true));
        again = () => runSaved({ terms: group.terms,
          source_ids: group.members.filter((member) => member.kind !== "list")
            .map((member) => member.source_id),
          list_keys: group.members.filter((member) => member.kind === "list")
            .map((member) => member.route_key) });
        const state = group.state === "running" ? "Searching"
          : (STATE_LABELS[group.state] || group.state);
        meta.textContent = ` ${state} · ${group.members.length} place(s) · ` +
          `${group.result_count} result(s) · ${when}`;
      } else {
        const search = entry.search;
        open.textContent = search.terms;
        open.addEventListener("click", () => openSearch(search.search_id, 0));
        again = () => runSaved({ terms: search.terms, source_ids: [search.source_id],
          list_keys: [] });
        meta.textContent = ` ${STATE_LABELS[search.state] || search.state} · ` +
          `${search.result_count} result(s) · ${when}`;
      }
      // Asks again as a typed search would, at the operator's press.
      const repeat = document.createElement("button");
      repeat.type = "button";
      repeat.className = "quiet";
      repeat.textContent = "Search again";
      repeat.addEventListener("click", again);
      item.append(open, meta, " ", repeat);
      list.append(item);
    }
    show($("search-history-box"), entries.length > 0);
  } catch (error) { /* history is optional */ }
}

// Clear all hides the searches listed (2026-10-29); they are kept, as a
// download or a queued file may still come through one of their rows.
$("clear-history").addEventListener("click", async (event) => {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    await api("POST", "/api/searches/history/clear", {});
    await refreshSearchHistory();
  } catch (error) {
    setText($("search-error"), error.message);
  } finally {
    button.disabled = false;
  }
});

$("search-history-box").addEventListener("toggle", (event) => {
  if (event.target.open) refreshSearchHistory();
});
