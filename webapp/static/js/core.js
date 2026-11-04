// What every part of the page uses: small helpers, and shared state.

// Everything received from the server or from IRC is written with
// textContent; nothing remote is ever interpreted as markup.

export const $ = (id) => document.getElementById(id);
export const PAGE_SIZE = 10;
export const TERMINAL_DOWNLOADS = new Set([
  "complete", "failed", "cancelled", "expired", "stale",
  "refused_without_queue", "abandoned_uncertain",
]);
export const STATE_LABELS = {
  configured: "Not connected", connecting: "Connecting", joining: "Joining channel",
  ready: "Ready", leaving: "Disconnecting", disconnected: "Disconnected", failed: "Failed",
  dispatch_pending: "Starting", collecting: "Searching", complete: "Complete",
  interrupted: "Interrupted", cancelled: "Cancelled",
  held: "Waiting", preparing: "Preparing", backoff: "Waiting to retry",
  dispatch_intent: "Requesting", awaiting_offer: "Waiting for the file offer",
  remote_queued: "Queued on the server", receiving: "Receiving", finalizing: "Verifying",
  resume_pending: "Needs attention", needs_attention: "Needs attention",
  expired: "Expired", stale: "No longer valid", refused_without_queue: "Refused",
  abandoned_uncertain: "Retired, outcome unknown",
};
// Shown after the reason, which carries what the file server said: a
// session that never opened is not tried again by itself (2026-10-22).
export const SESSION_HINTS = {
  session_not_opened: "The file server may be full, busy, off, or serving only some users. " +
    "Try again later if you think it is back.",
  session_unreachable: "This usually means the file server cannot take connections from " +
    "outside its own network; trying again will most likely fail the same way.",
};
// Plain-language guidance for engine outcomes the operator can act on.
export const DOWNLOAD_HINTS = {
  tuple_preflight_refused: "This file, or one of the same name with underscores for spaces, " +
    "was already requested from this server on the current connection. To ask for it " +
    "again, disconnect, connect and search again.",
  live_parent_file_missing: "The file server's current listing of that folder does not " +
    "contain this file.",
  interrupted: "The transfer stopped early and is not resumed. Cancel it to allow another download.",
  remote_queued: "The file server will send the file when it has a free slot. " +
    "DCCAtlas waits up to 15 minutes; nothing is asked again.",
  remote_queue_deadline: "The file server queued this request but did not send the file " +
    "within 15 minutes.",
  refused_without_queue: "Nothing will be sent for this request. If the file server's queue " +
    "for you is full, disconnecting and connecting again normally clears it.",
};
export const NOT_REQUESTED = new Set(["tuple_preflight_refused", "live_parent_file_missing"]);
// The file server's session never started or could not be used; no file was asked for.
export const NOT_STARTED = new Set(["session_not_opened", "session_unreachable", "session_port_in_use",
  "session_not_fserve"]);

// What more than one part of the page changes.
export const shared = {
  csrfToken: null,
  pollTimer: null,
  searchTimer: null,
  sectionChosen: false,   // until the operator picks one, the first status may pick Sources
  queuedCount: 0,   // queue items not yet started
  activeDownloads: 0,   // downloads not yet finished
};

export class RequestError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function show(element, visible) { element.hidden = !visible; }

export function setText(element, text) {
  element.textContent = text || "";
  show(element, Boolean(text));
}

export function stateTone(state) {
  if (["ready", "complete"].includes(state)) return "good";
  if (["failed", "needs_attention", "resume_pending", "interrupted",
       "abandoned_uncertain", "refused_without_queue"].includes(state)) return "bad";
  if (state && !["configured", "disconnected", "cancelled", "expired", "stale"].includes(state)) {
    return "warn";
  }
  return "";
}

export function badge(element, state, label) {
  element.textContent = label || STATE_LABELS[state] || state || "Unknown";
  element.className = "badge";
  const tone = stateTone(state);
  if (tone) element.classList.add(tone);
  show(element, true);
}

export function formatBytes(value) {
  if (typeof value !== "number") return "";
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  let amount = value;
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) { amount /= 1024; unit += 1; }
  if (unit === 0) return value === 1 ? "1 byte" : `${value} bytes`;
  return `${amount.toFixed(amount < 10 ? 1 : 0)} ${units[unit]}`;
}

export function randomKey() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return "ui-" + Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
