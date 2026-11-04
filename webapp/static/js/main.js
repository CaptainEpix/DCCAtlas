// The page: each part registers its controls as it loads, then the
// page starts (2026-11-03).

import "./core.js";
import "./api.js";
import "./sections.js";
import "./account.js";
import "./polling.js";
import "./lists.js";
import "./servers.js";
import "./sources.js";
import "./search.js";
import "./settings.js";
import "./saved.js";
import "./browse.js";
import "./transfers.js";
import "./log.js";
import { boot } from "./sections.js";

boot();
