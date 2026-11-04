// Polling the server while the page is open.

import { $, setText, shared } from "./core.js";
import { SECTIONS, showSection, showView } from "./sections.js";
import { listImportsPending, refreshFileLists } from "./lists.js";
import { ADVERT_POLL_TICKS, refreshAdverts, refreshAsked } from "./servers.js";
import { refreshStatus } from "./sources.js";
import { refreshSearchHistory } from "./search.js";
import { refreshProwlarr, refreshSettings } from "./settings.js";
import { refreshSavedSearches } from "./saved.js";
import { refreshDownloads, refreshQueue } from "./transfers.js";
import { refreshLog } from "./log.js";

export function startApp() {
  setText($("notice"), "");
  showView("app");
  shared.sectionChosen = SECTIONS.includes(location.hash.slice(1));
  showSection(location.hash.slice(1));
  refreshAll();
  refreshSearchHistory();
  refreshSavedSearches();
  refreshSettings();
  refreshProwlarr();
  refreshFileLists();
  shared.pollTimer = setInterval(refreshAll, 2000);
}

export function stopPolling() {
  clearInterval(shared.pollTimer);
  clearTimeout(shared.searchTimer);
  shared.pollTimer = null;
  shared.searchTimer = null;
}

export async function refreshAll() {
  if (document.hidden) return;
  await Promise.allSettled([refreshStatus(), refreshDownloads(), refreshQueue(), refreshLog()]);
  // A list being fetched or read is followed until it is added.
  if (listImportsPending && advertTick % 5 === 0) await refreshFileLists();
  if (advertTick++ % ADVERT_POLL_TICKS === 0) await refreshAdverts();
  await refreshAsked();
}

let advertTick = 0;
