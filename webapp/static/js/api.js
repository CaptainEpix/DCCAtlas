// Requests to the server; one refused for want of a session signs out.

import { RequestError, shared } from "./core.js";
import { showLogin } from "./sections.js";

export async function api(method, path, body) {
  const headers = {};
  if (method !== "GET") {
    headers["Content-Type"] = "application/json";
    if (shared.csrfToken) headers["X-CSRF-Token"] = shared.csrfToken;
  }
  let response;
  try {
    response = await fetch(path, {
      method, headers, credentials: "same-origin", cache: "no-store",
      body: method === "GET" ? undefined : JSON.stringify(body || {}),
    });
  } catch (error) {
    throw new RequestError(0, "network", "The server could not be reached.");
  }
  let data = null;
  try { data = await response.json(); } catch (error) { data = null; }
  if (!response.ok) {
    const detail = (data && data.error) || {};
    if (response.status === 401 && detail.code === "not_authenticated") showLogin();
    const message = detail.message || "The request failed.";
    throw new RequestError(response.status, detail.code || "error",
      message.charAt(0).toUpperCase() + message.slice(1));
  }
  return data;
}
