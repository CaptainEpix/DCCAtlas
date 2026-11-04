// Download settings and the apps (Prowlarr).

import { $, setText, show } from "./core.js";
import { api } from "./api.js";

function renderSettings(settings) {
  const retry = $("retry-before-request");
  retry.checked = settings.retry_before_request;
  retry.disabled = false;
  const atOnce = $("downloads-at-once");
  atOnce.value = String(settings.downloads_at_once);
  atOnce.disabled = false;
}

$("downloads-at-once").addEventListener("change", async (event) => {
  const box = event.target;
  box.disabled = true;
  try {
    renderSettings(await api("PUT", "/api/settings", { downloads_at_once: Number(box.value) }));
  } catch (error) {
    setText($("download-error"), error.message);
    refreshSettings();
  }
});

export async function refreshSettings() {
  try {
    renderSettings(await api("GET", "/api/settings"));
  } catch (error) {
    // The engine may not be up yet; try again with the next status.
    setTimeout(refreshSettings, 5000);
  }
}

$("retry-before-request").addEventListener("change", async (event) => {
  const box = event.target;
  box.disabled = true;
  try {
    renderSettings(await api("PUT", "/api/settings", { retry_before_request: box.checked }));
  } catch (error) {
    box.checked = !box.checked;
    box.disabled = false;
    setText($("download-error"), error.message);
  }
});

function renderProwlarr(view) {
  const box = $("prowlarr-enabled");
  box.checked = view.enabled;
  box.disabled = false;
  show($("prowlarr-setup"), view.enabled);
  setText($("prowlarr-key"), view.api_key || "");
  setText($("prowlarr-error"), "");
  const form = $("prowlarr-settings");
  // Not while being edited: the page asks for the view every few seconds.
  if (!form.contains(document.activeElement)) {
    form.elements.searches_per_hour.value = view.searches_per_hour;
    form.elements.connect_sources.checked = view.connect_sources;
    form.elements.idle_minutes.value = view.idle_minutes;
    form.elements.category_folders.checked = view.category_folders;
    form.elements.lists_only.checked = view.lists_only;
  }
}

$("prowlarr-settings").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  setText($("prowlarr-error"), "");
  setText($("prowlarr-note"), "");
  try {
    renderProwlarr(await api("PUT", "/api/prowlarr", {
      searches_per_hour: Number(form.elements.searches_per_hour.value),
      connect_sources: form.elements.connect_sources.checked,
      idle_minutes: Number(form.elements.idle_minutes.value),
      category_folders: form.elements.category_folders.checked,
      lists_only: form.elements.lists_only.checked,
    }));
    setText($("prowlarr-note"), "Saved.");
  } catch (error) {
    setText($("prowlarr-error"), error.message);
  }
});

export async function refreshProwlarr() {
  try {
    renderProwlarr(await api("GET", "/api/prowlarr"));
  } catch (error) {
    setTimeout(refreshProwlarr, 5000);
  }
}

$("prowlarr-enabled").addEventListener("change", async (event) => {
  const box = event.target;
  box.disabled = true;
  try {
    renderProwlarr(await api("PUT", "/api/prowlarr", { enabled: box.checked }));
  } catch (error) {
    box.checked = !box.checked;
    box.disabled = false;
    setText($("prowlarr-error"), error.message);
  }
});

$("prowlarr-new-key").addEventListener("click", async () => {
  if (!confirm("Prowlarr stops working with DCCAtlas until the new key is put in both " +
               "its indexer and its download client. Make a new key?")) return;
  try {
    renderProwlarr(await api("POST", "/api/prowlarr/key", {}));
  } catch (error) {
    setText($("prowlarr-error"), error.message);
  }
});
