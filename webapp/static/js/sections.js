// The page's sections, the sidebar, and signing in.

import { $, badge, RequestError, setText, shared, show, STATE_LABELS, stateTone } from "./core.js";
import { api } from "./api.js";
import { showResetForm } from "./account.js";
import { startApp, stopPolling } from "./polling.js";
import { addingSource, entryState, selectedSourceId, selectSource } from "./sources.js";

export function showView(name) {
  for (const view of ["loading", "setup", "login", "app"]) show($("view-" + view), view === name);
  show($("rail"), name === "app");
  show($("logout"), name === "app");
  if (name !== "app") {
    show($("engine-badge"), false);
    stopPolling();
  }
}

// One section of the app is shown at a time, named in the address after "#"
// so that Back returns to the one before.

export const SECTIONS = ["search", "servers", "browse", "transfers", "sources", "apps", "log",
  "account"];
// The ones under Settings in the sidebar, which folds open and shut.
const SETTINGS_SECTIONS = ["sources", "apps", "log", "account"];
// Addresses from before a section was renamed.
const SECTION_ALIASES = { prowlarr: "apps", seen: "servers", lists: "servers" };

function showSettingsMenu(open) {
  $("nav-settings").setAttribute("aria-expanded", String(open));
  show($("nav-settings-items"), open);
}

$("nav-settings").addEventListener("click", () => {
  const open = $("nav-settings-items").hidden;
  showSettingsMenu(open);
  try { localStorage.setItem("dccatlas-settings-menu", open ? "open" : "shut"); } catch (error) { /* a convenience only */ }
});

(function restoreSettingsMenu() {
  let open = false;
  try { open = localStorage.getItem("dccatlas-settings-menu") === "open"; } catch (error) { /* shut */ }
  showSettingsMenu(open);
})();

export function showSection(name) {
  name = SECTION_ALIASES[name] || name;
  if (!SECTIONS.includes(name)) name = "search";
  // A Settings page opens the menu that holds it, and marks Settings as where you are.
  if (SETTINGS_SECTIONS.includes(name)) showSettingsMenu(true);
  $("nav-settings").classList.toggle("has-current", SETTINGS_SECTIONS.includes(name));
  for (const id of SECTIONS) show($("section-" + id), id === name);
  for (const link of document.querySelectorAll("#nav a[data-section]")) {
    if (link.dataset.section === name) {
      link.setAttribute("aria-current", "page");
      // On a phone the menu is one row that scrolls sideways: keep the page shown in view.
      link.scrollIntoView({ block: "nearest", inline: "nearest" });
    } else {
      link.removeAttribute("aria-current");
    }
  }
}

export function openSection(name) {
  shared.sectionChosen = true;
  if (location.hash === "#" + name) showSection(name);
  else location.hash = name;   // shown by the hashchange below
}

window.addEventListener("hashchange", () => {
  shared.sectionChosen = true;
  showSection(location.hash.slice(1));
  $("main").scrollTop = 0;
  window.scrollTo(0, 0);
});

// A number beside a section's name; it briefly grows when it goes up.
export function setCount(element, count, live = false) {
  const before = Number(element.textContent) || 0;
  element.textContent = String(count);
  show(element, count > 0);
  element.classList.toggle("live", live && count > 0);
  if (count > before) {
    element.classList.remove("bump");
    void element.offsetWidth;   // restart the animation
    element.classList.add("bump");
  }
}

export function renderTransferCount() {
  setCount($("nav-transfers"), shared.queuedCount + shared.activeDownloads, shared.activeDownloads > 0);
}

// Each source's state in the rail; pressing one opens it under Sources.
let lastRailStamp = "";

export function renderRailSources(entries) {
  show($("rail-sources-empty"), entries.length === 0);
  const stamp = entries.map((entry) => [entry.configuration.source_id,
    entry.configuration.label, entryState(entry)].join("\u0001")).join("\u0002");
  if (stamp === lastRailStamp) return;   // do not replace buttons under the pointer
  lastRailStamp = stamp;
  $("rail-sources").replaceChildren(...entries.map((entry) => {
    const config = entry.configuration;
    const state = entryState(entry);
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.title = `${config.label}: ${STATE_LABELS[state] || state}`;
    const light = document.createElement("span");
    light.className = "signal " + stateTone(state);
    const name = document.createElement("span");
    name.className = "signal-name";
    name.textContent = config.label;
    const where = document.createElement("span");
    where.className = "signal-state";
    where.textContent = `${STATE_LABELS[state] || state} · ${config.channel}`;
    button.append(light, name, where);
    button.addEventListener("click", () => {
      if (addingSource || config.source_id !== selectedSourceId) selectSource(config.source_id);
      openSection("sources");
    });
    item.append(button);
    return item;
  }));
}

export function showLogin() {
  shared.csrfToken = null;
  showView("login");
  showResetForm(false);
  $("password").focus();
}

// The two passwords typed must be the same; the server checks the rest.
export function newPassword(form) {
  const password = form.elements.password.value;
  if (password !== form.elements.again.value) {
    throw new RequestError(0, "mismatch", "The two new passwords are not the same.");
  }
  return password;
}

export function signedIn(session, form) {
  form.reset();
  shared.csrfToken = session.csrf_token;
  startApp();
}

export async function boot() {
  try {
    const session = await api("GET", "/api/session");
    if (session.authenticated) {
      shared.csrfToken = session.csrf_token;
      startApp();
    } else if (session.setup_required) {
      setText($("setup-problem"), session.setup_problem);
      showView("setup");
      $("setup-form").elements.code.focus();
    } else {
      setText($("notice"), session.setup_problem
        ? `The password file was not accepted (${session.setup_problem}). ` +
          "The previous password still applies."
        : "");
      showLogin();
    }
  } catch (error) {
    setText($("notice"), error.message);
    showView("login");
  }
}

$("login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  setText($("login-error"), "");
  try {
    const session = await api("POST", "/api/login", { password: $("password").value });
    $("password").value = "";
    shared.csrfToken = session.csrf_token;
    startApp();
  } catch (error) {
    setText($("login-error"), error.message);
  }
});
