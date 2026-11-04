// Saved searches.

import { $, setText, show } from "./core.js";
import { api } from "./api.js";
import { fileLists } from "./lists.js";
import {
  entryState,
  renderSearchSources,
  sourceEntries,
  tickedLists,
  tickedSources,
} from "./sources.js";
import { chosenPlaces } from "./search.js";

// Pressing Search beside one puts its terms and places back in the form and
// submits it, so it is sent exactly as a typed search is. Nothing runs by itself.

let savedSearches = [];

function savedPlaces(saved) {
  const names = saved.source_ids.map((id) => {
    const entry = sourceEntries.find((item) => item.configuration.source_id === id);
    return entry ? entry.configuration.label : "a removed source";
  });
  for (const key of saved.list_keys) {
    const list = fileLists.find((item) => item.route_key === key);
    names.push(list ? `file list of ${list.sender} ${list.trigger}` : "a removed file list");
  }
  return names.join(", ");
}

export async function refreshSavedSearches() {
  try {
    savedSearches = (await api("GET", "/api/saved-searches")).saved;
  } catch (error) { return; }
  renderSavedSearches();
}

export function renderSavedSearches() {
  const list = $("saved-searches");
  const stamp = savedSearches.map((saved) => saved.saved_id + savedPlaces(saved)).join("|");
  if (stamp === list.dataset.stamp) return;   // do not replace buttons under the pointer
  list.dataset.stamp = stamp;
  list.replaceChildren();
  for (const saved of savedSearches) {
    const item = document.createElement("li");
    const terms = document.createElement("strong");
    terms.textContent = saved.terms;
    const places = document.createElement("span");
    places.className = "hint";
    places.textContent = ` in ${savedPlaces(saved)} `;
    const run = document.createElement("button");
    run.type = "button";
    run.textContent = "Search";
    run.addEventListener("click", () => runSaved(saved));
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "quiet";
    remove.textContent = "Remove";
    remove.addEventListener("click", async () => {
      try {
        savedSearches = (await api("DELETE",
          `/api/saved-searches/${encodeURIComponent(saved.saved_id)}`)).saved;
        renderSavedSearches();
      } catch (error) { setText($("search-error"), error.message); }
    });
    item.append(terms, places, run, " ", remove);
    list.append(item);
  }
  show($("saved-box"), savedSearches.length > 0);
}

export function runSaved(saved) {
  setText($("search-error"), "");
  const ready = new Set(sourceEntries.filter((entry) => entryState(entry) === "ready")
    .map((entry) => entry.configuration.source_id));
  const lists = new Set(fileLists.filter((item) => item.source_label).map((item) => item.route_key));
  const asked = saved.source_ids.filter((id) => ready.has(id));
  const looked = saved.list_keys.filter((key) => lists.has(key));
  const missing = saved.source_ids.length + saved.list_keys.length - asked.length - looked.length;
  $("terms").value = saved.terms;
  tickedSources.clear();
  tickedLists.clear();
  if (!asked.length && !looked.length) {
    setText($("search-error"), "None of the places this search looked in is connected or stored now.");
    return;
  }
  for (const id of asked) tickedSources.add(id);
  for (const key of looked) tickedLists.add(key);
  renderSearchSources(sourceEntries);
  if (missing) {
    // Searching fewer places than were saved is the operator's choice.
    setText($("search-error"), `${missing} of its places ${missing === 1 ? "is" : "are"} not ` +
      "connected or stored now, so the form has the rest ticked. Press Search to look there.");
    $("terms").focus();
    return;
  }
  $("search-form").requestSubmit();
}

$("save-search").addEventListener("click", async () => {
  setText($("search-error"), "");
  const { asked, lists } = chosenPlaces();
  if (!asked.length && !lists.length) {
    setText($("search-error"), "Tick where to look, then save.");
    return;
  }
  try {
    await api("POST", "/api/saved-searches",
      { terms: $("terms").value, source_ids: asked, list_keys: lists });
    await refreshSavedSearches();
  } catch (error) { setText($("search-error"), error.message); }
});
