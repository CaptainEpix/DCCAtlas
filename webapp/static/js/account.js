// Setting, resetting and changing the password.

import { $, setText, shared, show } from "./core.js";
import { api } from "./api.js";
import { newPassword, showLogin, signedIn } from "./sections.js";
import { ago } from "./servers.js";

$("setup-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  setText($("setup-error"), "");
  try {
    signedIn(await api("POST", "/api/setup", {
      code: form.elements.code.value, password: newPassword(form) }), form);
  } catch (error) {
    setText($("setup-error"), error.message);
  }
});

export function showResetForm(visible) {
  show($("login-form"), !visible);
  show($("reset-form"), visible);
  setText($("reset-error"), "");
  if (visible) $("reset-form").elements.code.focus();
}

$("forgot").addEventListener("click", async () => {
  setText($("login-error"), "");
  try {
    await api("POST", "/api/password/reset-code");
    showResetForm(true);
  } catch (error) {
    if (error.code !== "code_requested_recently") {
      setText($("login-error"), error.message);
      return;
    }
    // The code written a moment ago still works.
    showResetForm(true);
    setText($("reset-error"), error.message);
  }
});

$("reset-back").addEventListener("click", () => {
  showResetForm(false);
  $("password").focus();
});

$("reset-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  setText($("reset-error"), "");
  try {
    signedIn(await api("POST", "/api/password/reset", {
      code: form.elements.code.value, password: newPassword(form) }), form);
  } catch (error) {
    setText($("reset-error"), error.message);
  }
});

$("password-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  setText($("password-error"), "");
  setText($("password-note"), "");
  const button = form.querySelector("button[type=submit]");
  button.disabled = true;
  try {
    const session = await api("POST", "/api/password", {
      current_password: form.elements.current.value, password: newPassword(form) });
    form.reset();
    shared.csrfToken = session.csrf_token;   // this browser's new session
    setText($("password-note"), "Changed. Any other browser signed in has been signed out.");
  } catch (error) {
    setText($("password-error"), error.message);
  }
  button.disabled = false;
});

$("logout").addEventListener("click", async () => {
  try { await api("POST", "/api/logout"); } catch (error) { /* signed out locally either way */ }
  showLogin();
});
