// AgentSync Desktop v4 – canvas-first control surface.
//
// One thin line at the top carries the whole setup flow: the chosen project,
// then "choose model" → tight bubbles of ranked agent/model/level choices →
// the chosen setup with a Switch chip, plus status chips (running agents,
// quotas, engine). Anything that needs a sentence of explanation slides
// into that line horizontally. The optional validation agent has one small,
// dedicated floating window controlled from the left rail.
//
// Below it: the output canvas fills the free space, a small wish field asks
// the resolver for ranked choices, and the larger instruction field sends the
// actual task. Agents still run like their own CLI launched in the project
// folder, so native session state and .agent-state routing stay correct.

const invoke = window.__TAURI__?.core?.invoke;
const byId = (id) => document.getElementById(id);

const AGENT_ORDER = ["claude", "codex", "opencode", "antigravity", "cline", "aider"];
const AGENT_LABELS = {
  claude: "Claude Code",
  codex: "OpenAI Codex",
  opencode: "OpenCode",
  antigravity: "Antigravity",
  cline: "Cline",
  aider: "Aider (Spark)"
};
const AGENT_SHORT_LABELS = {
  claude: "Claude",
  codex: "Codex",
  opencode: "OpenCode",
  antigravity: "Antigravity",
  cline: "Cline",
  aider: "Aider"
};
// Same marks as the classic view, so an agent is recognisable at a glance.
const AGENT_MARKS = { claude: "✳", codex: "◉", opencode: "OC", antigravity: "A", cline: "C", aider: "ai", ollama: "OL" };
const LEVEL_LABELS = { "": "Standard", normal: "Normal", max: "Max", ultra: "Ultra" };
const POLL_ACTIVE_MS = 1200;
const POLL_TRAILING_ROUNDS = 2;
// While a reply streams, Markdown is re-rendered at most this often.
const MARKDOWN_RENDER_MS = 900;
// Activity lines ("Verktøy: read …", "Hendelse: step update") are context,
// not the reply: while running only the newest few show, when finished the
// first and last few, and a small link unfolds the rest.
const ACTIVITY_LIVE_TAIL = 6;
const ACTIVITY_DONE_EDGE = 3;
// Stderr from provider CLIs can contain hundreds of timestamped copies of the
// same warning. Keep the stored stderr untouched, but make the canvas useful
// before the reader explicitly asks for that raw technical log. The native
// buffer marks its own older truncation when its safety limit is reached.
const TECHNICAL_LOG_PREVIEW_LINES = 6;
const TECHNICAL_LOG_PREVIEW_CHARS = 1600;
// How many earlier runs of a project are replayed into the canvas when the
// project is chosen (at start-up or from the drawer).
const HISTORY_LIMIT = 12;
const RETAINED_FINISHED_VIEWS = 24;
// The canvas notes (setup choices, warnings, errors) are the part of the
// picture that lives nowhere else, so they are kept per project and merged
// back in among the runs.
const NOTE_LOG_LIMIT = 80;
const NOTE_LOG_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;
const NOTE_TEXT_LIMIT = 400;
// The status chips refresh quotas and engine status this often.
const STATUS_POLL_MS = 60_000;
const CATALOG_MAX_AGE_MS = 60_000;
const ZOOM_MIN = 50;
const ZOOM_MAX = 200;
const ZOOM_STEP = 10;

const state = {
  catalog: null,
  catalogLoadedAt: 0,
  catalogObservedAt: 0,
  catalogRequest: 0,
  selection: { project: "", agent: "", model: "", level: "" },
  missions: new Map(),
  historyLoaded: new Set(),
  historyLoading: new Set(),
  activeMissions: [],
  quotas: [],
  engineRunning: null,
  engineDiagnostics: null,
  validator: { enabled: false, generation: 0, activeControls: 0, changing: false },
  statusUnsubscribe: null,
  statusTimer: null,
  statusInFlight: null,
  railQuotaSignature: "",
  statusWarning: "",
  // Alt+Q changes only what the canvas shows. It never changes the setup for
  // the next mission. The order is snapshotted while cycling so the view does
  // not jump when an agent starts or finishes midway through a round.
  canvasFocus: { agent: "", order: [], positions: new Map() },
  pollTimer: null,
  pollInFlight: null,
  pollTrailing: 0,
  // Signature of the running set; the top line and rail only rebuild when it changes.
  runningSignature: "",
  // Whether the reader was last seen at the bottom; used only to keep the
  // bottom anchored through canvas resizes (drawer sliding, field grips).
  stickToBottom: true,
  // Setup flow in the top line: idle | resolving | choosing | chosen.
  setupMode: "idle",
  barChoices: [],
  barChoicesSource: "",
  barChoicesRanked: false,
  // "agents" (the main choice) or "ranked" (suggestions from a wish).
  barChoicesKind: "agents",
  barInfo: null,
  barInfoGeneration: 0,
  projectAuthorReads: new Map(),
  forceNext: false,
  resolving: false,
  intentRequestId: 0,
  intentRequestProject: "",
  starting: false
};

const canvas = byId("canvas");
const stream = byId("canvasStream");
const intentInput = byId("intentInput");
const instructionInput = byId("instructionInput");
const drawer = byId("projectDrawer");

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function readPreference(key, fallback = "") {
  try {
    const value = window.localStorage.getItem(key);
    return value === null ? fallback : value;
  } catch {
    return fallback;
  }
}

function writePreference(key, value) {
  try {
    if (value === null || value === undefined || value === "") window.localStorage.removeItem(key);
    else window.localStorage.setItem(key, String(value));
  } catch {
    // Storage can be unavailable; preferences are a convenience only.
  }
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function timeElement(unixMs, withDate = false) {
  const node = element("time", "", `[${clock(unixMs, withDate)}]`);
  node.dateTime = new Date(Number(unixMs) || Date.now()).toISOString();
  return node;
}

function clock(unixMs, withDate = false) {
  const date = new Date(Number(unixMs) || Date.now());
  const time = date.toLocaleTimeString("no-NO", { hour12: false });
  if (!withDate) return time;
  const day = new Intl.DateTimeFormat("nb-NO", { day: "2-digit", month: "2-digit" }).format(date);
  return `${day} ${time}`;
}

function formatCompactDate(iso) {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat("nb-NO", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }).format(date);
}

function formatDuration(ms) {
  const totalSeconds = Math.max(0, Math.round(Number(ms) / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours) return `${hours}t ${String(minutes).padStart(2, "0")}m`;
  if (minutes) return `${minutes}m ${String(seconds).padStart(2, "0")}s`;
  return `${seconds}s`;
}

function formatSeconds(ms) {
  return `${(Number(ms) / 1000).toLocaleString("nb-NO", { maximumFractionDigits: 1 })} s`;
}

function describeWindow(minutes) {
  const value = Number(minutes) || 0;
  if (value >= 1440) return `${Math.round(value / 1440)} dager`;
  if (value >= 60) return `${Math.round(value / 60)} timer`;
  return `${value} min`;
}

const escapeHtml = (value) => String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);

// Safe local Markdown for agent replies (ported from the classic view). The
// text is HTML-escaped first; only a small set of constructs is rebuilt on
// top of it (fenced and inline code, bold/italic, headings, lists, task
// lists, tables, quotes and GitHub-style alerts). No raw HTML gets through.
function markdownToHtml(value) {
  const escaped = escapeHtml(value || "");
  const codeBlocks = [];
  const text = escaped.replace(/```([^\n]*)\n([\s\S]*?)```/g, (_match, language, code) => {
    const token = `@@CODEBLOCK${codeBlocks.length}@@`;
    codeBlocks.push(`<pre><code${language.trim() ? ` data-language="${escapeHtml(language.trim())}"` : ""}>${code.trimEnd()}</code></pre>`);
    return `\n${token}\n`;
  });
  const inline = (line) => line
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>");

  const lines = text.split(/\r?\n/);
  const blocks = [];
  let list = null;
  let table = null;
  let quote = null;

  const flushList = () => {
    if (!list) return;
    blocks.push(`<${list.type}>${list.items.map((item) => `<li>${item}</li>`).join("")}</${list.type}>`);
    list = null;
  };
  const flushTable = () => {
    if (!table) return;
    let html = '<div class="markdown-table-wrap"><table>';
    if (table.headers.length) html += `<thead><tr>${table.headers.map((cell) => `<th>${inline(cell)}</th>`).join("")}</tr></thead>`;
    if (table.rows.length) html += `<tbody>${table.rows.map((row) => `<tr>${row.map((cell) => `<td>${inline(cell)}</td>`).join("")}</tr>`).join("")}</tbody>`;
    html += "</table></div>";
    blocks.push(html);
    table = null;
  };
  const flushQuote = () => {
    if (!quote) return;
    if (quote.alertType) {
      blocks.push(`<div class="markdown-alert markdown-alert-${quote.alertType.toLowerCase()}"><div class="alert-title"><span class="alert-icon">!</span><strong>${escapeHtml(quote.alertType)}</strong></div><div class="alert-content">${quote.lines.map((line) => `<p>${inline(line)}</p>`).join("")}</div></div>`);
    } else {
      blocks.push(`<blockquote>${quote.lines.map((line) => `<p>${inline(line)}</p>`).join("")}</blockquote>`);
    }
    quote = null;
  };
  const flushAll = () => {
    flushList();
    flushTable();
    flushQuote();
  };

  for (const rawLine of lines) {
    const line = rawLine.trimEnd();
    const trimmed = line.trim();

    const codeToken = trimmed.match(/^@@CODEBLOCK(\d+)@@$/);
    if (codeToken) {
      flushAll();
      blocks.push(codeBlocks[Number(codeToken[1])]);
      continue;
    }

    const quoteMatch = line.match(/^\s*>\s?(.*)$/);
    if (quoteMatch) {
      flushList();
      flushTable();
      const quoteText = quoteMatch[1];
      const alertMatch = quoteText.match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]$/i);
      if (alertMatch) {
        flushQuote();
        quote = { alertType: alertMatch[1].toUpperCase(), lines: [] };
      } else {
        if (!quote) quote = { alertType: null, lines: [] };
        if (quoteText.trim()) quote.lines.push(quoteText);
      }
      continue;
    }
    flushQuote();

    if (trimmed.startsWith("|") && trimmed.endsWith("|")) {
      flushList();
      const cells = trimmed.split("|").slice(1, -1).map((cell) => cell.trim());
      const isSeparator = cells.every((cell) => /^:?-+:?$/.test(cell));
      if (!table) table = { headers: cells, rows: [] };
      else if (!isSeparator) table.rows.push(cells);
      continue;
    }
    flushTable();

    const heading = line.match(/^(#{1,4})\s+(.+)$/);
    if (heading) {
      flushAll();
      blocks.push(`<h${heading[1].length}>${inline(heading[2])}</h${heading[1].length}>`);
      continue;
    }

    const taskMatch = line.match(/^\s*[-*]\s+\[([ xX])\]\s+(.+)$/);
    if (taskMatch) {
      flushTable();
      flushQuote();
      if (!list || list.type !== "ul") {
        flushList();
        list = { type: "ul", items: [] };
      }
      list.items.push(`<input type="checkbox" ${taskMatch[1].toLowerCase() === "x" ? "checked" : ""} disabled> ${inline(taskMatch[2])}`);
      continue;
    }

    const unordered = line.match(/^\s*[-*]\s+(.+)$/);
    const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/);
    if (unordered || ordered) {
      flushTable();
      flushQuote();
      const type = unordered ? "ul" : "ol";
      if (!list || list.type !== type) {
        flushList();
        list = { type, items: [] };
      }
      list.items.push(inline((unordered || ordered)[1]));
      continue;
    }
    flushList();

    if (!trimmed) continue;
    blocks.push(`<p>${inline(line)}</p>`);
  }

  flushAll();
  return blocks.join("");
}

function agentLabel(agent) {
  return AGENT_LABELS[agent] || agent || "agent";
}

function agentShortLabel(agent) {
  return AGENT_SHORT_LABELS[agent] || agentLabel(agent);
}

// Hover explanations use the app's own frame, never the browser's tooltip.
// The box is the one the validation findings already use, shared across the
// window so two can never be open at once.
function tip(node, text, head = "") {
  window.AgentSyncPeek?.attach(node, text, { head });
  return node;
}

// Who said it, as its own layer between the separator rule and the text. The
// rule is a rule; this carries identity, and the colour alone is enough once
// you know it. Hover says which, so it never has to be memorised.
function actorStripe(label) {
  const stripe = element("span", "entry-actor");
  stripe.tabIndex = 0;
  stripe.setAttribute("role", "img");
  return tip(stripe, label, "Hvem");
}

function agentMark(agent) {
  return AGENT_MARKS[agent] || "•";
}

function missionPurpose(mission) {
  const purpose = String(mission?.purpose || "");
  if (["writer", "manualControl", "validator"].includes(purpose)) return purpose;
  return mission?.mode === "blind" ? "manualControl" : "writer";
}

function markNode(agent) {
  return element("span", "agent-mark", agentMark(agent));
}

// "◉ Codex": the symbol as its own span right before the name, so both read
// together in the canvas head lines.
function agentNameNode(agent, label) {
  const node = element("b");
  node.append(markNode(agent), " ", label || agentLabel(agent));
  return node;
}

function projectByPath(path) {
  if (!path || !state.catalog) return null;
  return state.catalog.projects.find((project) => samePath(project.path, path)) || null;
}

function projectName(path) {
  const project = projectByPath(path);
  if (project) return project.name;
  const parts = plainPath(path).split(/[\\/]/).filter(Boolean);
  return parts[parts.length - 1] || "prosjekt";
}

// A bare final folder such as "code" is ambiguous. The top line therefore
// carries one parent when the catalog has it, while shallow projects keep
// their simple name.
function projectDisplayName(projectOrPath) {
  const project = typeof projectOrPath === "string" ? projectByPath(projectOrPath) : projectOrPath;
  if (!project) return projectName(projectOrPath);
  const parts = String(project.label || "").split(" / ").map((part) => part.trim()).filter(Boolean);
  return parts.length >= 3 ? parts.slice(-2).join(" / ") : project.name;
}

// Exact model ids remain in values, titles and mission requests. Only their
// visual label is shortened so several honest choices fit in a narrow window.
function shortModelLabel(model) {
  let label = String(model || "").trim();
  if (!label) return "Standard";
  if (label.includes("/")) label = label.slice(label.lastIndexOf("/") + 1);
  label = label.replace(/:(?:q\d+(?:_\d+)?|latest)$/i, "");
  return label
    .replace(/^gpt-/i, "GPT ")
    .replace(/^claude-/i, "Claude ")
    .replace(/^gemini-/i, "Gemini ")
    .replace(/^qwen/i, "Qwen")
    .replace(/^deepseek-/i, "DeepSeek ")
    .replace(/^kimi-/i, "Kimi ")
    .replace(/-/g, " ")
    .replace(/:/g, " ")
    .replace(/\s+/g, " ")
    .replace(/\b\w/g, (character) => character.toUpperCase());
}

function projectParentLabel(project) {
  const label = String(project.label || "");
  const separator = label.lastIndexOf(" / ");
  return separator > 0 ? label.slice(0, separator) : "";
}

const VERBATIM_PREFIX = "\\\\?\\";

function plainPath(value) {
  const text = String(value || "");
  return text.startsWith(VERBATIM_PREFIX) ? text.slice(VERBATIM_PREFIX.length) : text;
}

function samePath(left, right) {
  return plainPath(left).toLowerCase() === plainPath(right).toLowerCase();
}

function currentZoomFactor() {
  const zoom = Number.parseFloat(document.documentElement.style.zoom || "1");
  return Number.isFinite(zoom) && zoom > 0 ? zoom : 1;
}

// ---------------------------------------------------------------------------
// Canvas: fills from the top and follows new text only while the reader is at
// the bottom. The decision is purely geometric and taken *before* each
// mutation ("was the reader at the bottom?"), never from the asynchronous
// scroll event, so a poll landing between a wheel movement and its scroll
// event can never yank the reader back down. Scrolling up detaches; scrolling
// back to the bottom, or the jump pill, re-attaches.
// ---------------------------------------------------------------------------

function isAtBottom() {
  if (document.hidden) return state.stickToBottom;
  return canvas.scrollHeight - canvas.scrollTop - canvas.clientHeight <= 6;
}

function scrollToBottom() {
  if (!document.hidden) canvas.scrollTop = canvas.scrollHeight;
  state.stickToBottom = true;
  byId("canvasJump").hidden = true;
}

// Pass the value of isAtBottom() measured before the DOM changed.
function afterCanvasChange(wasFollowing) {
  if (document.hidden) return;
  if (wasFollowing) {
    scrollToBottom();
  } else {
    state.stickToBottom = isAtBottom();
    if (!state.stickToBottom) byId("canvasJump").hidden = false;
  }
}

// A resize (the project drawer sliding, a field grip, the window) re-wraps
// the text without any mutation; keep the bottom anchored when the reader
// was there.
function watchCanvasSize() {
  if (typeof window.ResizeObserver !== "function") return;
  new window.ResizeObserver(() => {
    if (state.stickToBottom) scrollToBottom();
  }).observe(canvas);
}

function appendToCanvas(node) {
  const following = isAtBottom();
  stream.append(node);
  refreshCanvasProjectVisibility();
  afterCanvasChange(following);
  return node;
}

function tagProjectNode(node, path = state.selection.project) {
  if (path) node.dataset.projectPath = plainPath(path);
  return node;
}

function focusPositionKey(agent = state.canvasFocus.agent) {
  return `${projectSetupKey(state.selection.project)}#${agent || "all"}`;
}

function writerAgentsActiveInMax() {
  const firstSeen = new Map();
  for (const mission of state.activeMissions) {
    if (!samePath(mission.projectPath, state.selection.project)
      || (mission.status !== "queued" && mission.status !== "running")
      || missionPurpose(mission) !== "writer") continue;
    if (!firstSeen.has(mission.agent)) firstSeen.set(mission.agent, Number(mission.startedUnixMs) || 0);
  }
  return [...firstSeen].sort((left, right) => left[1] - right[1]).map(([agent]) => agent);
}

function focusRecordForAgent(agent) {
  return [...state.missions.values()]
    .filter((record) => samePath(record.projectPath, state.selection.project) && record.agentId === agent && record.purpose === "writer")
    .sort((left, right) => (Number(right.startedUnixMs) || 0) - (Number(left.startedUnixMs) || 0))[0] || null;
}

function nodeBelongsToFocusedAgent(node, focusedAgent) {
  const missionId = node.dataset.mission;
  if (!missionId) return false;
  const record = state.missions.get(missionId);
  if (!record) return (node.dataset.agent === focusedAgent && node.dataset.purpose === "writer")
    || (node.dataset.purpose === "validator" && node.dataset.sourceAgent === focusedAgent);
  if (record.agentId === focusedAgent && record.purpose === "writer") return true;
  if (record.purpose !== "validator" || !record.sourceMissionId) return false;
  const source = state.missions.get(record.sourceMissionId)
    || state.activeMissions.find((mission) => mission.id === record.sourceMissionId);
  if (source?.agentId || source?.agent) record.sourceAgentId = source.agentId || source.agent;
  return record.sourceAgentId === focusedAgent;
}

function renderCanvasFocusIndicator() {
  const focused = state.canvasFocus.agent;
  const active = writerAgentsActiveInMax();
  let text = `Visning: Alle · ${active.length} ${active.length === 1 ? "aktiv agent" : "aktive agenter"} i MAX · Alt+Q`;
  if (focused) {
    const record = focusRecordForAgent(focused);
    const activeNow = active.includes(focused);
    const position = Math.max(0, state.canvasFocus.order.indexOf(focused)) + 1;
    const of = state.canvasFocus.order.length;
    let status = activeNow ? "arbeider" : "ferdig";
    if (record?.status === "failed") status = "feilet";
    else if (record?.status === "canceled") status = "avbrutt";
    const changed = Number.isFinite(record?.changedFiles)
      ? ` · ${record.changedFiles === 1 ? "1 fil" : `${record.changedFiles} filer`}`
      : "";
    text = `Visning: ${agentShortLabel(focused)} · ${status}${changed}${of ? ` · ${position} av ${of}` : ""} · Alt+Q`;
  }
  const badge = byId("canvasFocusBadge");
  if (badge.textContent !== text) badge.textContent = text;
  byId("canvasWrap").classList.toggle("agent-focus", Boolean(focused));
}

function refreshCanvasFocusVisibility() {
  const focused = state.canvasFocus.agent;
  for (const node of stream.children) {
    const inProject = !node.hidden;
    node.classList.toggle("canvas-focus-excluded", Boolean(focused) && inProject && !nodeBelongsToFocusedAgent(node, focused));
  }
  renderCanvasFocusIndicator();
  flushVisibleMissionContent();
}

function setCanvasFocus(agent, rememberPosition = true) {
  if (rememberPosition) {
    state.canvasFocus.positions.set(focusPositionKey(), {
      top: canvas.scrollTop,
      bottom: isAtBottom(),
    });
  }
  state.canvasFocus.agent = agent || "";
  canvas.setAttribute("aria-busy", "true");
  refreshCanvasFocusVisibility();
  window.requestAnimationFrame(() => {
    const saved = state.canvasFocus.positions.get(focusPositionKey());
    if (saved?.bottom || (!saved && state.canvasFocus.agent)) canvas.scrollTop = canvas.scrollHeight;
    else if (saved) canvas.scrollTop = saved.top;
    state.stickToBottom = isAtBottom();
    canvas.setAttribute("aria-busy", "false");
  });
}

function resetCanvasFocus() {
  state.canvasFocus.order = [];
  setCanvasFocus("");
}

function cycleCanvasFocus(reverse = false) {
  const current = state.canvasFocus.agent;
  if (!current) {
    const order = writerAgentsActiveInMax();
    if (!order.length) {
      renderCanvasFocusIndicator();
      showBarInfo("Ingen skrivende agent er aktiv i MAX akkurat nå.");
      return;
    }
    state.canvasFocus.order = order;
    setCanvasFocus(reverse ? order[order.length - 1] : order[0]);
    return;
  }
  const order = state.canvasFocus.order;
  const index = order.indexOf(current);
  const next = reverse ? index - 1 : index + 1;
  if (index < 0 || next < 0 || next >= order.length) {
    state.canvasFocus.order = [];
    setCanvasFocus("");
    return;
  }
  setCanvasFocus(order[next]);
}

// The selected project is a hard visual boundary. Work in other projects may
// continue in the background and still lights their status dot, but its text
// must never appear beneath the wrong project heading.
function refreshCanvasProjectVisibility() {
  const selected = state.selection.project;
  let visible = 0;
  for (const node of stream.children) {
    const path = node.dataset.projectPath || "";
    const show = !path || Boolean(selected && samePath(path, selected));
    node.hidden = !show;
    if (show) visible += 1;
  }
  byId("canvasEmpty").hidden = visible > 0;
  refreshCanvasFocusVisibility();
}

// Finished mission DOM can be reconstructed from the archive. Releasing it
// on project switches prevents a tour through many projects from retaining
// every long answer in memory. Running records stay alive for delta polling.
function releaseFinishedProjectView(path) {
  if (!path) return;
  const keep = new Set();
  for (const [id, record] of state.missions) {
    if (!samePath(record.projectPath, path)) continue;
    if (!record.finished || record.persistenceError) {
      keep.add(record.user);
      keep.add(record.agent);
      continue;
    }
    window.clearTimeout(record.finalRenderTimer);
    record.user.remove();
    record.agent.remove();
    state.missions.delete(id);
  }
  for (const node of [...stream.children]) {
    if (samePath(node.dataset.projectPath || "", path) && !keep.has(node)) node.remove();
  }
  state.historyLoaded.delete(projectSetupKey(path));
}

// Compact references keep older work reopenable without retaining every
// answer, activity node and Markdown tree for a whole working day.
function compactFinishedViews() {
  if (!isAtBottom()) return;
  const finished = [...state.missions.values()].filter((record) => record.finished && !record.persistenceError
    && Date.now() - (record.finishedUnixMs || Date.now()) > 60000)
    .sort((left, right) => right.startedUnixMs - left.startedUnixMs);
  for (const record of finished.slice(RETAINED_FINISHED_VIEWS)) {
    window.clearTimeout(record.finalRenderTimer);
    const link = missionReopenLink({
      id: record.id, projectPath: record.projectPath, agent: record.agentId,
      purpose: record.purpose, startedUnixMs: record.startedUnixMs, sourceAgent: record.sourceAgentId,
    });
    stream.insertBefore(link, record.user);
    record.user.remove();
    record.agent.remove();
    state.missions.delete(record.id);
  }
}

function missionReopenLink(summary) {
  // Capture identifiers, never a large mission buffer, in the click closure.
  const missionId = summary.id;
  const projectPath = summary.projectPath;
  const link = tagProjectNode(element("button", "activity-more", `Åpne tidligere oppdrag · ${agentLabel(summary.agent)} · ${clock(summary.startedUnixMs, true)}`), projectPath);
  link.type = "button";
  link.dataset.mission = missionId;
  link.dataset.agent = summary.agent || "";
  link.dataset.purpose = missionPurpose(summary);
  link.dataset.sourceAgent = summary.sourceAgent || "";
  link.addEventListener("click", async () => {
    link.disabled = true;
    try {
      const mission = await invoke("get_mission_session", { missionId });
      if (!link.isConnected) return;
      if (!mission || mission.id !== missionId || !samePath(mission.projectPath, projectPath)) throw new Error("Oppdraget tilhører ikke valgt prosjekt.");
      const restored = ensureMissionBlock(mission, true);
      stream.insertBefore(restored.user, link);
      stream.insertBefore(restored.agent, link);
      renderMission(mission);
      link.remove();
      refreshCanvasProjectVisibility();
    } catch (error) {
      link.disabled = false;
      link.textContent = `Kunne ikke åpne oppdraget: ${error}. Klikk for å prøve igjen.`;
    }
  });
  return link;
}

function olderHistoryButton(path, initialOffset) {
  const button = tagProjectNode(element("button", "activity-more", "Vis eldre oppdrag"), path);
  button.type = "button";
  let offset = initialOffset;
  button.addEventListener("click", async () => {
    button.disabled = true;
    button.textContent = "Henter eldre oppdrag…";
    try {
      const page = await invoke("get_mission_summaries", { request: { projectPath: path, offset, limit: 30 } });
      if (!button.isConnected || !samePath(state.selection.project, path)) return;
      const rows = Array.isArray(page?.history) ? page.history : [];
      offset += rows.length;
      const fragment = document.createDocumentFragment();
      const shown = new Set([...stream.children].map((node) => node.dataset.mission).filter(Boolean));
      for (const summary of [...rows].reverse()) {
        if (!summary?.id || shown.has(summary.id) || !samePath(summary.projectPath, path)
          || ["queued", "running"].includes(summary.status)) continue;
        fragment.append(missionReopenLink(summary));
        shown.add(summary.id);
      }
      stream.insertBefore(fragment, button.nextSibling);
      if (!page.hasMore || !rows.length) button.remove();
      else { button.disabled = false; button.textContent = "Vis enda eldre oppdrag"; }
      refreshCanvasProjectVisibility();
      if (page.warning) canvasNote(`Historikken er ufullstendig: ${page.warning}`, "warn");
    } catch (error) {
      button.disabled = false;
      button.textContent = `Kunne ikke hente historikk: ${error}. Prøv igjen.`;
    }
  });
  return button;
}

function noteLogKey(path) {
  return `agentsync.v4.notes.${String(path).toLowerCase()}`;
}

function readNoteLog(path) {
  if (!path) return [];
  try {
    const stored = JSON.parse(readPreference(noteLogKey(path), "[]"));
    if (!Array.isArray(stored)) return [];
    const oldest = Date.now() - NOTE_LOG_MAX_AGE_MS;
    return stored.filter((entry) => entry && typeof entry.x === "string" && Number(entry.t) > oldest);
  } catch {
    return [];
  }
}

// Notes belong to the project that was open when they appeared; without one
// there is nowhere to put them, so they stay on screen only.
function rememberNote(text, kind = "") {
  const path = state.selection.project;
  if (!path || !text) return;
  const log = readNoteLog(path);
  log.push({ t: Date.now(), k: kind, x: String(text).slice(0, NOTE_TEXT_LIMIT) });
  writePreference(noteLogKey(path), JSON.stringify(log.slice(-NOTE_LOG_LIMIT)));
}

function canvasNote(text, kind = "", remember = true) {
  const note = tagProjectNode(element("p", `note${kind ? ` ${kind}` : ""}`));
  note.append(timeElement(Date.now()), text);
  if (remember) rememberNote(text, kind);
  return appendToCanvas(note);
}

function setupSummary(selection = state.selection) {
  const parts = [selection.agent ? `${agentMark(selection.agent)} ${agentLabel(selection.agent)}` : "ingen agent"];
  // Name the default when the catalog knows it; "standardmodell" is a label
  // on nothing when read back later.
  const info = selection.agent ? agentInfo(selection.agent) : null;
  parts.push(selection.model || (info?.model ? `${info.model} (standard)` : "standardmodell"));
  parts.push(LEVEL_LABELS[selection.level || ""] || selection.level);
  parts.push(selection.project ? projectDisplayName(selection.project) : "ingen prosjekt");
  return parts.join(" · ");
}

canvas.addEventListener("scroll", () => {
  state.stickToBottom = isAtBottom();
  if (state.stickToBottom) byId("canvasJump").hidden = true;
});

byId("canvasJump").addEventListener("click", scrollToBottom);

// ---------------------------------------------------------------------------
// Catalog (projects, agents, models) and the persisted selection
// ---------------------------------------------------------------------------

async function loadCatalog(force = false) {
  if (!invoke) return null;
  if (!force && state.catalog && Date.now() - state.catalogLoadedAt < CATALOG_MAX_AGE_MS) return state.catalog;
  const request = state.catalogRequest = (state.catalogRequest || 0) + 1;
  // An upper boundary for this read, not the later time somebody opens its UI.
  const observedAt = Date.now();
  try {
    const catalog = await invoke("get_intent_catalog");
    if (request !== state.catalogRequest) return state.catalog;
    state.catalog = {
      projects: Array.isArray(catalog?.projects) ? catalog.projects : [],
      agents: Array.isArray(catalog?.agents) ? catalog.agents : [],
      agentRecords: Array.isArray(catalog?.agentRecords) ? catalog.agentRecords : [],
      agentRecordsWarning: catalog?.agentRecordsWarning || "",
      runtimeHost: catalog?.runtimeHost || "",
      recentMissions: Array.isArray(catalog?.recentMissions) ? catalog.recentMissions : [],
      recentMissionsTruncated: catalog?.recentMissionsTruncated !== false,
      models: catalog?.models && typeof catalog.models === "object" ? catalog.models : {},
      levels: Array.isArray(catalog?.levels) ? catalog.levels : ["normal", "max", "ultra"],
      resolverModel: catalog?.resolverModel || null,
      resolverCandidates: Array.isArray(catalog?.resolverCandidates) ? catalog.resolverCandidates : [],
      resolverEndpoint: catalog?.resolverEndpoint || ""
    };
    state.catalogLoadedAt = Date.now();
    state.catalogObservedAt = observedAt;
    renderAll();
    return state.catalog;
  } catch (error) {
    if (request !== state.catalogRequest) return state.catalog;
    canvasNote(`Kunne ikke lese katalogen over prosjekter og agenter: ${error}`, "error");
    return state.catalog;
  }
}

function restoreSelection() {
  const project = readPreference("agentsync.v4.project");
  state.selection = { project: projectByPath(project)?.path || "", agent: "", model: "", level: "" };
  const restored = restoreProjectSetup(state.selection.project);
  // One-time migration from the earlier global setup. It is assigned only to
  // the project that was selected then; a new project must not inherit it.
  if (!restored && state.selection.project) {
    state.selection.agent = readPreference("agentsync.v4.agent");
    state.selection.model = readPreference("agentsync.v4.model");
    state.selection.level = readPreference("agentsync.v4.level");
    normalizeSelectedSetup();
    persistSelection();
  }
  writePreference("agentsync.v4.agent", null);
  writePreference("agentsync.v4.model", null);
  writePreference("agentsync.v4.level", null);
  state.setupMode = state.selection.agent ? "chosen" : "idle";
}

const PROJECT_SETUPS_KEY = "agentsync.v4.projectSetups";

function readProjectSetups() {
  try {
    const stored = JSON.parse(readPreference(PROJECT_SETUPS_KEY, "{}"));
    return stored && typeof stored === "object" && !Array.isArray(stored) ? stored : {};
  } catch {
    return {};
  }
}

function projectSetupKey(path) {
  return plainPath(path).toLowerCase();
}

function normalizeSelectedSetup() {
  const agent = String(state.selection.agent || "").toLowerCase();
  const info = agentInfo(agent);
  if (!AGENT_ORDER.includes(agent) || !info?.available) {
    state.selection.agent = "";
    state.selection.model = "";
    state.selection.level = "";
    return;
  }
  state.selection.agent = agent;
  const known = modelsForAgent(agent);
  if (state.selection.model && !known.includes(state.selection.model)) state.selection.model = "";
  if (!Object.prototype.hasOwnProperty.call(LEVEL_LABELS, state.selection.level || "")) state.selection.level = "";
}

function restoreProjectSetup(path) {
  if (!path) return false;
  const setup = readProjectSetups()[projectSetupKey(path)];
  if (!setup || typeof setup !== "object") return false;
  state.selection.agent = String(setup.agent || "");
  state.selection.model = String(setup.model || "");
  state.selection.level = String(setup.level || "");
  normalizeSelectedSetup();
  return true;
}

function persistSelection() {
  writePreference("agentsync.v4.project", state.selection.project);
  if (!state.selection.project) return;
  const setups = readProjectSetups();
  const key = projectSetupKey(state.selection.project);
  delete setups[key];
  setups[key] = {
    agent: state.selection.agent || "",
    model: state.selection.model || "",
    level: state.selection.level || ""
  };
  const entries = Object.entries(setups).slice(-100);
  writePreference(PROJECT_SETUPS_KEY, JSON.stringify(Object.fromEntries(entries)));
}

function agentInfo(agent) {
  return state.catalog?.agents.find((item) => item.id === agent) || null;
}

function renderAll() {
  if (state.selection.project && !projectByPath(state.selection.project)) clearSelectedProject();
  updateProjectLabels();
  renderTopBar();
}

// ---------------------------------------------------------------------------
// Project drawer: a separate window on the left that slides in and out. Slid
// in, only a slim handle with the chosen project name remains visible.
// ---------------------------------------------------------------------------

function drawerOpen() {
  return drawer.classList.contains("open");
}

function setDrawerOpen(open, persist = true) {
  const panel = byId("projectDrawerPanel");
  const returnFocus = !open && panel.contains(document.activeElement);
  drawer.classList.toggle("open", open);
  byId("railToggle").setAttribute("aria-expanded", String(open));
  panel.toggleAttribute("inert", !open);
  panel.setAttribute("aria-hidden", String(!open));
  if (persist) writePreference("agentsync.v4.drawerOpen", open ? "1" : "");
  if (open) {
    renderProjectList();
    byId("projectSearch").focus();
  } else if (returnFocus) {
    byId("railToggle").focus();
  }
}

function toggleDrawer() {
  setDrawerOpen(!drawerOpen());
}

function syncProjectGate() {
  const project = projectByPath(state.selection.project);
  const hasProject = Boolean(project);

  intentInput.readOnly = !hasProject || state.resolving;
  intentInput.classList.toggle("needs-project", !hasProject);
  intentInput.placeholder = hasProject
    ? (state.selection.agent ? "Nytt ønske? fagfelt, styrke, fart, pris, lokal – Enter" : "Hva trenger du? fagfelt, styrke, fart, pris, lokal modell – Enter gir forslag")
    : "Velg prosjekt";
  intentInput.setAttribute("aria-label", hasProject ? "Beskriv ønsket oppsett" : "Velg prosjekt først");
  intentInput.setAttribute("aria-readonly", String(intentInput.readOnly));

  instructionInput.disabled = !hasProject || state.starting;
  instructionInput.placeholder = hasProject
    ? "Instruksjoner til agenten. Ctrl+Enter eller Kjør starter oppdraget."
    : "Velg prosjekt før du skriver oppdrag";

  const startButton = byId("missionStartButton");
  const hasPrompt = Boolean(instructionInput.value.trim());
  startButton.disabled = !hasProject || state.starting || !hasPrompt;
  startButton.textContent = state.starting ? "Starter …" : "Kjør";
  tip(startButton, !hasProject
    ? "Velg prosjekt først"
    : hasPrompt ? "Start oppdrag (Ctrl+Enter)" : "Skriv et oppdrag først", "Start");

  const contextButton = byId("projectContextButton");
  contextButton.classList.toggle("needs-project", !hasProject);
  tip(contextButton, () => (project ? `${project.path} · klikk for å bytte (Ctrl+P)` : "Velg prosjekt (Ctrl+P)"), "Prosjekt");
  contextButton.setAttribute("aria-label", project ? `Valgt prosjekt: ${projectDisplayName(project)}. Klikk for å bytte.` : "Velg prosjekt");
  byId("projectContextName").textContent = project ? projectDisplayName(project) : "Velg prosjekt";

  if (!hasProject) intentInput.value = "";
  if (!stream.children.length) {
    byId("canvasEmpty").textContent = hasProject
      ? "Beskriv ønsket oppsett i linjen øverst, velg en boble og skriv deretter oppdraget i feltet under."
      : "Velg et prosjekt først. Deretter kan AgentSync anbefale agent, modell og nivå.";
  }
}

function updateProjectLabels() {
  const project = projectByPath(state.selection.project);
  const handle = byId("projectDrawerHandle");
  byId("projectDrawerLabel").textContent = project ? projectDisplayName(project) : "Velg prosjekt";
  handle.classList.toggle("has-project", Boolean(project));
  tip(byId("railProjectButton"), () => {
    const current = projectByPath(state.selection.project);
    return current ? `${current.path} – klikk for detaljer` : "Ingen prosjekt valgt – klikk for å velge";
  }, "Prosjekt");
  syncProjectGate();
  renderRail();
}

// An Ollama tag ("nemotron-3-super:latest") rather than a vendor model id.
function looksLikeOllamaTag(model) {
  const name = String(model || "");
  return name.includes(":") && !name.startsWith("claude") && !name.startsWith("gpt");
}

function levelHint(agent, level, model) {
  const chosen = LEVEL_LABELS[level || ""] || "Standard";
  if (!level) {
    if (agent === "aider" || agent === "opencode") {
      return { text: "standard hos leverandøren", detail: `Uten et nivå sender AgentSync ingen innsats-parameter, så ${agentLabel(agent)} bruker modellens egen standard.` };
    }
    return { text: "agentens standard", detail: `Uten et nivå sender AgentSync ingen innsats-parameter til ${agentLabel(agent)}.` };
  }
  switch (agent) {
    case "codex": {
      const value = { normal: "medium", max: "high", ultra: "xhigh" }[level];
      return { text: `model_reasoning_effort=${value}`, detail: `${chosen} settes som -c model_reasoning_effort=${value} på codex exec. Codex har hele skalaen medium, high og xhigh, så nivåvalget slår fullt ut.` };
    }
    case "claude": {
      const value = { normal: "medium", max: "high", ultra: "max" }[level];
      return { text: `--effort ${value}`, detail: `${chosen} blir --effort ${value}. Claude Code kjenner low, medium, high, xhigh og max, så det er rom over Max-nivået her.` };
    }
    case "antigravity": {
      // The model name can carry the effort ("gemini-3.7-flash-high"); agy
      // rejects a --effort that disagrees, so the name wins.
      if (/-(?:low|medium|high)$/i.test(model || "")) {
        return {
          text: "modellen bestemmer nivået",
          caveat: true,
          detail: `Modellnavnet ${model} sier selv hvilken innsats den bruker, og Antigravity avviser et nivå som ikke stemmer med navnet. AgentSync sender derfor ingen --effort for denne modellen; velg en annen modellvariant for å endre innsatsen.`
        };
      }
      const value = { normal: "medium", max: "high", ultra: "high" }[level];
      const capped = level === "ultra";
      return {
        text: `--effort ${value}${capped ? " · Ultra = Max" : ""}`,
        caveat: capped,
        detail: capped
          ? "Antigravity kjenner bare low, medium og high, så Ultra og Max gir samme innsats (--effort high)."
          : `${chosen} blir --effort ${value}. Antigravity kjenner low, medium og high.`
      };
    }
    case "cline": {
      const value = { normal: "medium", max: "high", ultra: "xhigh" }[level];
      const local = looksLikeOllamaTag(model);
      return {
        text: `--thinking ${value}${local ? " · Ollama: av/på" : ""}`,
        caveat: local,
        detail: local
          ? `${chosen} sendes som --thinking ${value}, men Clines Ollama-lag støtter bare tenkning av eller på og oversetter alle nivåer til det samme. Nivået har derfor liten reell effekt for ${model}.`
          : `${chosen} blir --thinking ${value}. Cline kjenner none, low, medium, high og xhigh.`
      };
    }
    case "opencode": {
      const value = { max: "high", ultra: "max" }[level];
      if (!value) {
        return { text: "leverandørens standard", detail: "Normal sender ingen --variant, så modellens leverandør bruker sin egen standard. Max og Ultra sender --variant high og max." };
      }
      return {
        text: `--variant ${value}`,
        caveat: true,
        detail: `${chosen} blir --variant ${value}. Flagget er leverandørspesifikt: hvor mye det betyr avhenger av modellen bak, og noen leverandører overser det.`
      };
    }
    case "aider": {
      const value = { normal: "medium", max: "high", ultra: "high" }[level];
      const capped = level === "ultra";
      return {
        text: `--reasoning-effort ${value}${capped ? " · Ultra = Max" : ""}`,
        caveat: capped,
        detail: `${chosen} blir --reasoning-effort ${value}. Aider har ingenting over high, og dropper parameteren helt hvis modellen ikke godtar den.`
      };
    }
    default:
      return null;
  }
}

function quotaTone(percent) {
  if (percent >= 90) return "red";
  if (percent >= 70) return "amber";
  return "green";
}

// The slim rail works for us: agent symbol, run dot, the rotated project name
// (scrolling when long), quota bars and the engine dot. A click on any of them
// slides the explanation horizontally into the top line.
function renderRail() {
  const agent = state.selection.agent;
  const agentIcon = byId("railAgent");
  agentIcon.textContent = agent ? agentMark(agent) : "";
  tip(agentIcon, () => (state.selection.agent ? `${agentLabel(state.selection.agent)} – klikk for detaljer` : ""), "Agent");
  agentIcon.hidden = !agent;

  const running = activeMissionsForProject(state.selection.project);
  byId("railRun").className = `rail-dot${running.length ? " running" : ""}`;
  tip(byId("railRunButton"), () => {
    const live = activeMissionsForProject(state.selection.project);
    return live.length
      ? live.map((mission) => `${mission.agentLabel} · ${formatDuration(Date.now() - mission.startedUnixMs)}`).join(", ")
      : "Ingen agent kjører i prosjektet";
  }, "Kjører nå");

  const validatorButton = byId("railValidatorButton");
  const automaticValidation = window.AgentSyncSettings?.own("validation.auto") !== false;
  const validatorRunning = state.validator.enabled && state.validator.activeControls > 0;
  validatorButton.classList.toggle("on", state.validator.enabled);
  validatorButton.classList.toggle("running", validatorRunning);
  validatorButton.classList.toggle("changing", state.validator.changing);
  validatorButton.setAttribute("aria-checked", String(state.validator.enabled));
  validatorButton.disabled = state.validator.changing;
  byId("railValidatorDot").className = `rail-validator-dot${validatorRunning ? " running" : state.validator.enabled ? " on" : ""}`;
  tip(validatorButton, state.validator.enabled
    ? (validatorRunning
      ? "Valideringsagenten arbeider. Klikk for å slå av, stoppe og lukke vinduet."
      : automaticValidation ? "Valideringsagenten er på og venter på neste endring. Klikk for å slå av."
        : "Valideringsagenten er på for manuell kontroll. Automatisk start er av. Klikk for å slå av.")
    : automaticValidation ? "Valideringsagent av. Klikk for å åpne vinduet og validere etter endringer."
      : "Valideringsagent av. Klikk for å åpne vinduet for manuell kontroll. Automatisk start er av.", "Valideringsagent");

  const quotas = byId("railQuotas");
  const quotaSignature = JSON.stringify(state.quotas);
  if (quotaSignature !== state.railQuotaSignature) {
    state.railQuotaSignature = quotaSignature;
    const focusedQuota = quotas.contains(document.activeElement) ? document.activeElement.dataset.quota : null;
    quotas.replaceChildren();
    state.quotas.forEach((quota, quotaIndex) => {
    const windows = Array.isArray(quota.windows) ? quota.windows : [];
    const status = quota.status || (windows.length ? "measured" : quota.source === "local" ? "unlimited" : "unavailable");
    if (!windows.length) {
      const item = element("button", "rail-item rail-quota");
      item.type = "button";
      item.dataset.rail = "quota";
      item.dataset.quota = `${quotaIndex}:-1`;
      item.classList.toggle("unavailable", status === "unavailable");
      const value = status === "unlimited" ? "∞" : "?";
      item.append(element("span", "rail-quota-text", `${agentMark(quota.agent)} ${value}`));
      tip(item, `${quota.label}: ${quota.note || (status === "unlimited" ? "ingen kvote" : "kvote utilgjengelig")}`, "Kvote");
      quotas.append(item);
      return;
    }
    windows.forEach((quotaWindow, windowIndex) => {
      const item = element("button", "rail-item rail-quota");
      item.type = "button";
      item.dataset.rail = "quota";
      item.dataset.quota = `${quotaIndex}:${windowIndex}`;
      item.classList.toggle("stale", status === "stale");
      const rawPercent = quotaWindow.usedPercent;
      const hasPercent = rawPercent !== null && rawPercent !== undefined && Number.isFinite(Number(rawPercent));
      const rawAmount = quotaWindow.usedAmount;
      const hasAmount = rawAmount !== null && rawAmount !== undefined && Number.isFinite(Number(rawAmount));
      if (hasPercent) {
        const percent = Math.max(0, Math.min(100, Number(rawPercent)));
        const bar = element("span", "rail-quota-bar");
        const fill = element("span", `rail-quota-fill ${quotaTone(percent)}`);
        fill.style.height = `${Math.max(2, percent)}%`;
        bar.append(fill);
        item.append(bar, element("span", "rail-quota-text", `${agentMark(quota.agent)} ${Math.round(percent)} %${status === "stale" ? " *" : ""}`));
        tip(item, `${quota.label}: ${Math.round(percent)} % av ${quotaWindow.name}-kvoten brukt${status === "stale" ? ", eldre måling" : ""}, klikk for detaljer`, "Kvote");
      } else if (hasAmount) {
        const amount = Number(rawAmount);
        const unit = quotaWindow.amountUnit === "USD" ? "$" : `${quotaWindow.amountUnit || ""} `;
        item.classList.toggle("amount", true);
        item.append(element("span", "rail-quota-text", `${agentMark(quota.agent)} ${unit}${amount.toFixed(2)}${status === "stale" ? " *" : ""}`));
        tip(item, `${quota.label}: ${amount.toFixed(2)} ${quotaWindow.amountUnit || ""} brukt i ${quotaWindow.name}${status === "stale" ? ", eldre måling" : ""}, klikk for detaljer`, "Kvote");
      } else {
        item.classList.toggle("unavailable", true);
        item.append(element("span", "rail-quota-text", `${agentMark(quota.agent)} ?`));
        tip(item, `${quota.label}: ukjent måleenhet, klikk for detaljer`, "Kvote");
      }
      quotas.append(item);
    });
    });
    if (focusedQuota) [...quotas.children].find((item) => item.dataset.quota === focusedQuota)?.focus();
  }

  byId("railEngine").className = `rail-dot engine${state.engineRunning === true ? " ok" : state.engineRunning === false ? " down" : ""}`;
  tip(byId("railEngineButton"), () => (state.engineRunning === true ? "AgentSync-motoren kjører – klikk for detaljer" : state.engineRunning === false ? "AgentSync-motoren kjører ikke" : "Motorstatus ukjent"), "Motor");

  updateRailScroll();
}

function showRailInfo(kind, key, anchor) {
  byId("projectDrawerHandle").querySelectorAll(".rail-item.active").forEach((item) => item.classList.remove("active"));
  if (anchor) anchor.classList.add("active");
  switch (kind) {
    case "agent": showAgentInfo(); break;
    case "run": showRunInfo(); break;
    case "project": showProjectInfo(); break;
    case "engine": showEngineInfo(); break;
    case "quota": {
      const [quotaIndex, windowIndex] = String(key).split(":").map(Number);
      showQuotaInfo(quotaIndex, windowIndex);
      break;
    }
    default: break;
  }
}

byId("railToggle").addEventListener("click", toggleDrawer);

async function handleValidatorRailClick() {
  const panel = byId("controlPanel");
  // K can remain open underneath V. If K is currently in front, one V click
  // restores the already enabled panel instead of unexpectedly switching the
  // validator off. A second V click still performs the normal off action.
  if (state.validator.enabled && !panel.hidden && window.AgentSyncKnowledgeReviews?.isFront?.()) {
    window.AgentSyncKnowledgeReviews.sendToBack();
    setControlPanelMinimized(false);
    restoreControlPanelPosition({ fallback: "current" });
    return;
  }
  await setValidatorEnabled(!state.validator.enabled);
}

byId("railValidatorButton").addEventListener("click", async (event) => {
  event.stopPropagation();
  await handleValidatorRailClick();
});
byId("projectDrawerHandle").addEventListener("click", (event) => {
  const item = event.target.closest(".rail-item");
  if (!item) return;
  showRailInfo(item.dataset.rail, item.dataset.quota || "", item);
});

// A project name longer than the free part of the rail glides back and forth
// so the whole name can be read on the small surface.
let railScrollFrame = null;
let railScrollSignature = "";
function updateRailScroll() {
  if (document.hidden || railScrollFrame !== null) return;
  const clip = byId("railLabelClip");
  const label = byId("projectDrawerLabel");
  railScrollFrame = window.requestAnimationFrame(() => {
    railScrollFrame = null;
    const labelHeight = Math.round(label.getBoundingClientRect().height);
    const clipHeight = Math.round(clip.getBoundingClientRect().height);
    const signature = `${label.textContent}|${labelHeight}|${clipHeight}`;
    if (signature === railScrollSignature) return;
    railScrollSignature = signature;
    label.classList.remove("scrolling");
    label.style.removeProperty("--rail-overflow");
    label.style.removeProperty("--rail-duration");
    const overflow = labelHeight - clipHeight;
    if (overflow > 4) {
      label.style.setProperty("--rail-overflow", `${overflow}px`);
      label.style.setProperty("--rail-duration", `${Math.max(4, Math.min(14, overflow / 10))}s`);
      label.classList.add("scrolling");
    }
  });
}

window.addEventListener("resize", updateRailScroll);

function renderProjectList() {
  const list = byId("projectList");
  const query = byId("projectSearch").value.trim().toLowerCase();
  const projects = (state.catalog?.projects || []).filter((project) => !query
    || project.name.toLowerCase().includes(query)
    || String(project.label || "").toLowerCase().includes(query)
    || project.path.toLowerCase().includes(query));
  byId("projectCount").textContent = projects.length === 1 ? "1 prosjekt" : `${projects.length} prosjekter`;
  if (!projects.length) {
    list.replaceChildren(element("p", "drawer-empty", state.catalog?.projects?.length ? "Ingen prosjekter passer søket." : "AgentSync har ikke registrert noen prosjekter ennå."));
    return;
  }
  const fragment = document.createDocumentFragment();
  for (const project of projects) {
    const button = element("button", "drawer-project");
    button.type = "button";
    button.dataset.path = project.path;
    tip(button, project.path, "Prosjekt");
    button.setAttribute("role", "option");
    const selected = samePath(project.path, state.selection.project);
    button.classList.toggle("selected", selected);
    button.setAttribute("aria-selected", String(selected));
    const running = activeMissionsForProject(project.path).length > 0;
    const stateDot = element("span", `drawer-project-state${running ? " running" : ""}`);
    if (running) tip(stateDot, "En agent kjører her nå", "Status");
    const copy = element("span", "drawer-project-copy");
    copy.append(element("strong", "", project.name), element("small", "", projectParentLabel(project) || project.path));
    button.append(stateDot, copy, element("span", "drawer-project-meta", formatCompactDate(project.latestIso)));
    button.addEventListener("click", () => selectProject(project.path));
    fragment.append(button);
  }
  list.replaceChildren(fragment);
}

// Project-bound surfaces must cross the same boundary as the canvas. Close
// transient work surfaces and invalidate their pending reads before anything
// from the newly selected project is shown. The validator itself stays on when
// enabled, but its visible state is synchronously moved to the new project.
function resetProjectBoundSurfaces(nextProject) {
  window.AgentSyncActiveMemory?.projectChanged?.(nextProject);
  window.AgentSyncPeek?.hide?.({ force: true });
  window.AgentSyncEvaluations?.close?.();
  window.AgentSyncKnowledgeReviews?.close?.();
  window.AgentSyncControl?.projectChanged?.(nextProject);
}

function clearSelectedProject() {
  const previousProject = state.selection.project;
  if (previousProject) {
    cancelResolving();
    closeScopeStrip();
    state.forceNext = false;
    intentInput.value = "";
    resetCanvasFocus();
    releaseFinishedProjectView(previousProject);
  }
  state.selection.project = "";
  state.selection.agent = "";
  state.selection.model = "";
  state.selection.level = "";
  state.setupMode = "idle";
  persistSelection();
  if (previousProject) resetProjectBoundSurfaces("");
  closeBarInfo();
  refreshCanvasProjectVisibility();
}

function selectProject(path) {
  const project = projectByPath(path);
  if (!project) return;
  const previousProject = state.selection.project;
  const changed = !samePath(project.path, state.selection.project);
  if (changed) {
    cancelResolving();
    closeScopeStrip();
    state.forceNext = false;
    intentInput.value = "";
    resetCanvasFocus();
    releaseFinishedProjectView(previousProject);
  }
  state.selection.project = project.path;
  if (changed) {
    state.selection.agent = "";
    state.selection.model = "";
    state.selection.level = "";
    restoreProjectSetup(project.path);
  }
  state.setupMode = state.selection.agent ? "chosen" : "idle";
  persistSelection();
  if (changed) resetProjectBoundSurfaces(project.path);
  closeBarInfo();
  refreshCanvasProjectVisibility();
  updateProjectLabels();
  renderProjectList();
  renderTopBar();
  setDrawerOpen(false);
  intentInput.focus();
  showProjectHistory(project.path);
  window.AgentSyncActiveMemory?.prepare?.(project.path);
}

byId("projectDrawerClose").addEventListener("click", () => setDrawerOpen(false));
byId("projectContextButton").addEventListener("click", () => setDrawerOpen(true));
byId("projectSearch").addEventListener("input", renderProjectList);
byId("projectSearch").addEventListener("keydown", (event) => {
  const items = [...byId("projectList").querySelectorAll(".drawer-project")];
  if (!items.length) return;
  if (event.key === "Enter") selectProject(items[0].dataset.path);
  else if (event.key === "ArrowDown") {
    event.preventDefault();
    (items.find((item) => item.classList.contains("selected")) || items[0]).focus();
  }
});

byId("projectList").addEventListener("keydown", (event) => {
  const items = [...byId("projectList").querySelectorAll(".drawer-project")];
  const index = items.indexOf(document.activeElement);
  if (index < 0) return;
  let next = null;
  if (event.key === "ArrowDown") next = Math.min(items.length - 1, index + 1);
  else if (event.key === "ArrowUp") next = Math.max(0, index - 1);
  else if (event.key === "Home") next = 0;
  else if (event.key === "End") next = items.length - 1;
  if (next !== null) {
    event.preventDefault();
    items[next].focus();
    items[next].scrollIntoView({ block: "nearest" });
  }
});

// ---------------------------------------------------------------------------
// The top line: setup flow and status chips, one sentence high.
// ---------------------------------------------------------------------------

function chip(text, { className = "", title = "", ariaLabel = "", onClick = null, mark = null } = {}) {
  const button = element("button", `bar-chip${className ? ` ${className}` : ""}`);
  button.type = "button";
  if (mark) button.append(markNode(mark));
  if (text) button.append(text);
  if (title) tip(button, title);
  if (ariaLabel) button.setAttribute("aria-label", ariaLabel);
  if (onClick) button.addEventListener("click", onClick);
  return button;
}

function renderTopBar() {
  renderSetupBar();
  renderRail();
}

function updateSetupOverflowCue() {
  const setup = byId("setupBar");
  const max = Math.max(0, setup.scrollWidth - setup.clientWidth);
  setup.classList.toggle("overflow-left", setup.scrollLeft > 2);
  setup.classList.toggle("overflow-right", setup.scrollLeft < max - 2);
}

function renderSetupBar() {
  const container = byId("setupBar");
  container.replaceChildren();
  container.classList.remove("overflow-left", "overflow-right");
  // While bubbles are shown (or being fetched) they take the wish field's room.
  const busyChoosing = state.setupMode === "choosing" || state.setupMode === "resolving";
  container.classList.toggle("choosing", busyChoosing);
  intentInput.hidden = busyChoosing;
  const project = projectByPath(state.selection.project);
  if (!project) {
    container.append(chip("Velg prosjekt", { className: "primary", title: "Agenten kjører i prosjektmappen (Ctrl+P)", onClick: () => setDrawerOpen(true) }));
    return;
  }
  const agent = state.selection.agent;
  const info = agentInfo(agent);

  if (state.setupMode === "resolving") {
    container.append(element("span", "bar-text busy", "Finner forslag …"));
    container.append(chip("Avbryt", { className: "quiet", title: "Stopp tolkingen og gå tilbake", onClick: cancelResolving }));
    return;
  }

  if (state.setupMode === "choosing") {
    container.append(chip("‹", { className: "quiet", title: "Tilbake (Escape)", onClick: leaveChoosing }));
    // Which model interprets the wish is a choice too; switching re-ranks.
    const candidates = state.catalog?.resolverCandidates || [];
    if (state.barChoicesRanked && candidates.length) {
      const current = preferredResolverModel();
      const resolverSelect = element("select", "bar-select");
      tip(resolverSelect, "Modellen som tolker ønsket ditt til forslag", "Tolkemodell");
      resolverSelect.setAttribute("aria-label", "Tolkemodell");
      const options = current && !candidates.includes(current) ? [current, ...candidates] : candidates;
      for (const name of options) {
        const option = new Option(`tolk: ${shortModelLabel(name)}`, name);
        resolverSelect.append(option);
      }
      resolverSelect.value = current || options[0];
      resolverSelect.addEventListener("change", () => {
        writePreference("agentsync.v4.resolverModel", resolverSelect.value);
        if (intentInput.value.trim()) resolveIntent();
      });
      container.append(resolverSelect);
    }
    if (state.barChoicesSource) container.append(element("span", "bar-muted", state.barChoicesSource));
    if (!state.barChoices.length) {
      container.append(element("span", "bar-text", "Ingen forslag – skriv et ønske i det lille feltet."));
      return;
    }
    const agentsOnly = state.barChoicesKind === "agents";
    state.barChoices.forEach((choice, index) => {
      const current = agentsOnly && choice.agent === state.selection.agent;
      const blocked = agentsOnly && choice.available === false;
      const bubble = chip("", {
        className: `bubble${index === 0 && state.barChoicesRanked ? " recommended" : ""}${current ? " current" : ""}${blocked ? " unavailable" : ""}`,
        title: [choice.rationale, agentsOnly ? "" : `${agentLabel(choice.agent)} · ${choice.model || "agentens standard"} · ${LEVEL_LABELS[choice.level || ""]}`].filter(Boolean).join(" · "),
        ariaLabel: agentsOnly
          ? `${blocked ? "Ikke tilgjengelig: " : "Velg "}${agentLabel(choice.agent)}${choice.rationale ? `. ${choice.rationale}` : ""}`
          : `Velg ${agentLabel(choice.agent)}, modell ${choice.model || "agentens standard"}, nivå ${LEVEL_LABELS[choice.level || ""]}${choice.rationale ? `. ${choice.rationale}` : ""}`,
        onClick: blocked
          ? () => showBarInfo(`${agentMark(choice.agent)} ${agentLabel(choice.agent)} er ikke klar: ${choice.rationale}`, { kind: "warn" })
          : () => applyChoice(choice)
      });
      const label = agentsOnly
        ? agentLabel(choice.agent)
        : `${agentShortLabel(choice.agent)} · ${shortModelLabel(choice.model || "Standard")}`;
      bubble.append(markNode(choice.agent), element("span", "bubble-label", label));
      if (!agentsOnly) bubble.append(" ", element("span", "bar-level", `· ${LEVEL_LABELS[choice.level || ""]}`));
      container.append(bubble);
    });
    window.requestAnimationFrame(updateSetupOverflowCue);
    return;
  }

  if (!agent) {
    container.append(chip("Velg agent", { className: "primary", title: "Vis agentene som er klare i dette prosjektet (Ctrl+O)", onClick: () => enterChoosing(agentChoices(), "agenter", false, "agents") }));
    return;
  }

  container.append(chip(agentLabel(agent), {
    mark: agent,
    className: "agent",
    title: "Klikk for å velge en annen agent; modellen velges i nedtrekket",
    onClick: () => enterChoosing(agentChoices(), "agenter", false, "agents")
  }));
  const known = modelsForAgent(agent);
  const chosenModel = state.selection.model || "";
  if (known.length || chosenModel) {
    const modelSelect = element("select", "bar-select model");
    modelSelect.setAttribute("aria-label", "Modell");
    modelSelect.append(new Option(info?.model ? `Standard (${info.model})` : "Agentens standard", ""));
    for (const name of known) {
      const option = new Option(shortModelLabel(name), name);
      modelSelect.append(option);
    }
    // A model that came from a wish may not be in the catalog list.
    if (chosenModel && !known.some((name) => name === chosenModel)) modelSelect.append(new Option(shortModelLabel(chosenModel), chosenModel));
    modelSelect.value = chosenModel;
    tip(modelSelect, () => (modelSelect.value ? `Modell ${modelSelect.value}` : "Agentens standardmodell"), "Modell");
    modelSelect.addEventListener("change", () => {
      state.selection.model = modelSelect.value;
      persistSelection();
    });
    container.append(modelSelect);
  } else {
    container.append(chip("standardmodell", { className: "mono", title: "Agentens standardmodell", onClick: () => showBarInfo("AgentSync har ingen registrerte modeller for denne agenten ennå, så agentens egen standard brukes.") }));
  }

  const level = element("select", "bar-select");
  tip(level, "Nivå: normal, max eller ultra – oversettes til agentens eget innsatsflagg", "Nivå");
  level.setAttribute("aria-label", "Nivå");
  for (const [value, label] of Object.entries(LEVEL_LABELS)) level.append(new Option(label, value));
  level.value = state.selection.level || "";
  level.addEventListener("change", () => {
    state.selection.level = level.value;
    persistSelection();
  });
  container.append(level);

  const hint = levelHint(agent, state.selection.level || "", state.selection.model || info?.model || "");
  if (hint) {
    const node = element("button", `bar-hint${hint.caveat ? " caveat" : ""}`, hint.text);
    node.type = "button";
    tip(node, hint.detail);
    node.setAttribute("aria-label", `${hint.text}. ${hint.detail}`);
    node.addEventListener("click", () => showBarInfo(hint.detail, { kind: hint.caveat ? "warn" : "" }));
    container.append(node);
  }

  const running = activeMissionsForProject(project.path);
  if (running.length || state.forceNext) {
    container.append(chip(state.forceNext ? "Tving ✓" : "Tving", {
      className: `warn${state.forceNext ? " active" : ""}`,
      title: "Kjør parallelt selv om en agent allerede kjører i prosjektet",
      onClick: () => {
        state.forceNext = !state.forceNext;
        renderSetupBar();
      }
    }));
  }
  if (running.length) {
    container.append(chip(running.length === 1 ? `Stopp ${running[0].agentLabel}` : "Stopp alle", { className: "danger", title: "Send avbryt-signal", onClick: stopRunning }));
  }
}

// Explanations slide into the top line as one sentence; long text scrolls
// sideways inside it rather than growing the line.
function showBarInfo(text, { kind = "", actions = [] } = {}) {
  state.barInfoGeneration = (state.barInfoGeneration || 0) + 1;
  const info = byId("barInfo");
  const wasOpen = !info.hidden;
  state.barInfo = { text, kind, actions };
  byId("barInfoText").textContent = text;
  tip(byId("barInfoText"), text);
  byId("barInfoText").scrollLeft = 0;
  const actionHost = byId("barInfoActions");
  actionHost.replaceChildren();
  for (const action of actions) {
    actionHost.append(chip(action.label, {
      className: action.danger ? "danger" : "",
      onClick: () => {
        closeBarInfo();
        action.run();
      }
    }));
  }
  info.className = `bar-info${kind ? ` ${kind}` : ""}`;
  info.style.left = `${byId("projectContextButton").offsetWidth + 14}px`;
  info.hidden = false;
  if (!wasOpen) {
    // Force a layout pass between un-hiding and the class change so the
    // slide-in transition runs.
    void info.offsetWidth;
  }
  info.classList.add("open");
}

function closeBarInfo() {
  state.barInfoGeneration = (state.barInfoGeneration || 0) + 1;
  if (!state.barInfo) return;
  state.barInfo = null;
  const info = byId("barInfo");
  info.classList.remove("open");
  info.hidden = true;
  byId("projectDrawerHandle").querySelectorAll(".rail-item.active").forEach((item) => item.classList.remove("active"));
}

// What the register already knows about an agent, so the choice can rest on
// what it has actually done here rather than on a hunch. Read from the
// missions in hand; nothing is counted that is not written down.
function agentRecord(agent) {
  // Counted in the backend, where every mission record lives. The frontend
  // only ever sees a page of history, so counting here would undercount.
  const record = (state.catalog?.agentRecords || []).find((item) => item.agent === agent);
  if (!record || !record.runs) return null;
  return {
    runs: record.runs,
    percent: record.completedPercent,
    changedFiles: record.changedFiles,
    recentFailures: record.recentFailures || 0,
    days: record.lastRunUnixMs ? (Date.now() - record.lastRunUnixMs) / 86400000 : null,
  };
}

function agentRecordText(agent) {
  if (window.AgentSyncSettings?.enabled("record.agent") === false) return "";
  const record = agentRecord(agent);
  if (!record) return "";
  window.AgentSyncSettings?.used("record.agent");
  const runs = `${record.percent} % fullført av ${record.runs} ${record.runs === 1 ? "oppdrag" : "oppdrag"}`;
  if (record.days === null) return ` · ${runs}`;
  // An agent nobody has run for weeks is usually broken without anyone knowing.
  const idle = record.days < 1 ? "i dag"
    : record.days < 2 ? "i går"
    : `for ${Math.round(record.days)} dager siden`;
  const stale = record.days >= 14 ? " · ikke brukt på to uker" : "";
  // The rate is over the whole history, so an agent that broke yesterday can
  // still show a good one. Two failures in a row is the point where it is
  // worth saying out loud rather than letting the next run find out.
  const warn = record.recentFailures >= 2 && window.AgentSyncSettings?.enabled("record.failures") !== false;
  if (warn) window.AgentSyncSettings?.used("record.failures");
  const broken = warn ? ` · de ${record.recentFailures} siste kjøringene feilet` : "";
  return ` · ${runs} · sist ${idle}${stale}${broken}`;
}

function showAgentInfo() {
  const agent = state.selection.agent;
  if (!agent) {
    showBarInfo("Ingen agent er valgt ennå – klikk «Velg agent» i linjen eller skriv et ønske i ønskefeltet.", { actions: [{ label: "Velg agent", run: () => enterChoosing(agentChoices(), "agenter", false, "agents") }] });
    return;
  }
  const info = agentInfo(agent);
  const model = state.selection.model || info?.model || "agentens standard";
  const recordWarning = window.AgentSyncSettings?.enabled("record.agent") !== false ? state.catalog?.agentRecordsWarning || "" : "";
  showBarInfo(`${agentMark(agent)} ${agentLabel(agent)} · modell ${model} · nivå ${LEVEL_LABELS[state.selection.level || ""]}${agentRecordText(agent)}${info?.note ? ` · ${info.note}` : ""}${recordWarning ? ` · Registeret er ufullstendig: ${recordWarning}` : ""}`, {
    kind: recordWarning ? "warn" : "",
    actions: [{ label: "Bytt agent", run: () => enterChoosing(agentChoices(), "agenter", false, "agents") }]
  });
}

// With six agents in one tree, "who wrote this last" is the question asked
// most often and answered least. The record has known all along.
function fileAuthorSummary(authors) {
  if (!Array.isArray(authors) || !authors.length) return "";
  const counts = new Map();
  for (const author of authors) {
    counts.set(author.agent, (counts.get(author.agent) || 0) + 1);
  }
  const named = [...counts.entries()]
    .sort((left, right) => right[1] - left[1])
    .map(([agent, count]) => `${agentLabel(agent)} ${count}`)
    .join(" · ");
  // A file two agents have written is where they can undo each other, and it
  // has already happened once here.
  const shared = authors.filter((author) => Array.isArray(author.also) && author.also.length > 1).length;
  const overlap = shared ? ` · ${shared} ${shared === 1 ? "fil" : "filer"} registrert i oppdrag hos flere agenter` : "";
  return ` · filendringer sist registrert i oppdrag: ${named}${overlap}`;
}

// A sequence of recorded file changes, not proof of who authored the content.
function handoverSummary(handovers) {
  if (!Array.isArray(handovers) || !handovers.length) return "";
  if (window.AgentSyncSettings?.enabled("collab.handovers") === false) return "";
  const latest = handovers[0];
  const file = String(latest.file || "");
  const when = latest.atUnixMs ? formatDuration(Date.now() - latest.atUnixMs) : "";
  const more = handovers.length > 1
    ? ` · ${handovers.length - 1} ${handovers.length === 2 ? "til" : "til"} før det`
    : "";
  return ` · siste registrerte overgang: ${agentLabel(latest.fromAgent)} → ${agentLabel(latest.toAgent)} i ${file}${when ? ` for ${when} siden` : ""}${more}. Oppdragsregistrering, ikke bevist forfatterskap`;
}

async function projectFileAuthors(path) {
  if (!invoke || !path) return { files: [], warning: "Historikken kunne ikke leses." };
  const key = projectSetupKey(path);
  if (!state.projectAuthorReads.has(key)) {
    state.projectAuthorReads.set(key, invoke("get_project_file_authors", { projectPath: path })
      .catch(error => ({ files: [], warning: `Historikken er utilgjengelig: ${error}` }))
      .finally(() => state.projectAuthorReads.delete(key)));
  }
  return state.projectAuthorReads.get(key);
}

// With ten projects in rotation, the first question on returning to one is
// what happened while you were away. The record can answer it; nothing was
// keeping track of when you last looked.
const PROJECT_SEEN_KEY = "agentsync.v4.projectSeen";

function projectLastSeen(path) {
  try {
    const seen = JSON.parse(readPreference(PROJECT_SEEN_KEY, "{}"));
    const value = seen?.[plainPath(path).toLowerCase()];
    return Number.isFinite(value) ? value : 0;
  } catch {
    return 0;
  }
}

function rememberProjectSeen(path, coveredUntil) {
  if (!path || !Number.isFinite(coveredUntil) || coveredUntil <= 0) return;
  try {
    const stored = JSON.parse(readPreference(PROJECT_SEEN_KEY, "{}"));
    const seen = stored && typeof stored === "object" && !Array.isArray(stored) ? stored : {};
    const key = plainPath(path).toLowerCase();
    const previous = Number.isFinite(seen[key]) ? seen[key] : 0;
    seen[key] = Math.max(previous, Math.min(coveredUntil, Date.now()));
    writePreference(PROJECT_SEEN_KEY, JSON.stringify(Object.fromEntries(Object.entries(seen).slice(-200))));
  } catch {
    // Losing this costs a line of context, never correctness.
  }
}

function newSinceLastVisit(path, missions) {
  if (window.AgentSyncSettings?.enabled("record.sinceLast") === false) return "";
  const since = projectLastSeen(path);
  if (!since) return "";
  // Only this project. The list spans every project, and counting them all
  // would report other work as if it had happened here.
  const wanted = plainPath(path).toLowerCase();
  const fresh = (missions || []).filter((mission) => Number(mission.startedUnixMs) > since
    && plainPath(mission.projectPath || "").toLowerCase() === wanted);
  const incomplete = state.catalog?.recentMissionsTruncated === true || Boolean(state.catalog?.agentRecordsWarning);
  if (!fresh.length) return incomplete ? " · siste oppdragsoversikt er ufullstendig; antall nye kjøringer er ukjent" : "";
  window.AgentSyncSettings?.used("record.sinceLast");
  const agents = [...new Set(fresh.map((mission) => agentLabel(mission.agent)))];
  return ` · ${incomplete ? "minst " : ""}${fresh.length} ${fresh.length === 1 ? "kjøring" : "kjøringer"} siden sist, av ${agents.join(" og ")}${incomplete ? " (ufullstendig oppdragsoversikt)" : ""}`;
}

async function showProjectInfo() {
  const project = projectByPath(state.selection.project);
  if (!project) {
    showBarInfo("Velg mappen agenten skal jobbe i – agenten kjører som sin egen CLI i den mappen, så native økter og .agent-state havner riktig.", { actions: [{ label: "Velg prosjekt", run: () => setDrawerOpen(true) }] });
    return;
  }
  const parent = projectParentLabel(project);
  const latest = project.latestIso ? formatCompactDate(project.latestIso) : "";
  const running = activeMissionsForProject(project.path);
  const parts = [
    `${projectDisplayName(project)} · ${project.path}`,
    parent ? `under ${parent}` : "",
    latest ? `siste agentaktivitet ${latest}` : "ingen registrert agentaktivitet ennå",
    running.length ? `${running.length === 1 ? "1 agent" : `${running.length} agenter`} kjører her nå` : ""
  ].filter(Boolean);
  parts.push(newSinceLastVisit(project.path, state.catalog?.recentMissions).replace(/^ · /, ""));
  const shown = parts.filter(Boolean);
  showBarInfo(`${shown.join(" · ")}.`, { actions: [{ label: "Bytt prosjekt", run: () => setDrawerOpen(true) }] });
  // Only this cached snapshot was shown. A mission started after its read
  // must remain new when a later catalog finally includes it.
  rememberProjectSeen(project.path, state.catalogObservedAt);
  const viewGeneration = state.barInfoGeneration;
  // Read after the line is up, so a slow lookup never delays the answer.
  const showAuthors = window.AgentSyncSettings?.enabled("record.authors") !== false;
  const showHandovers = window.AgentSyncSettings?.enabled("collab.handovers") !== false;
  if (!showAuthors && !showHandovers) return;
  const result = await projectFileAuthors(project.path);
  const authorText = showAuthors ? fileAuthorSummary(Array.isArray(result) ? result : result?.files) : "";
  const handoverText = showHandovers ? handoverSummary(result?.handovers) : "";
  const summary = authorText + handoverText;
  const warning = result?.warning || "";
  if ((summary || warning) && state.barInfoGeneration === viewGeneration
    && projectByPath(state.selection.project)?.path === project.path) {
    if (authorText) window.AgentSyncSettings?.used("record.authors");
    if (handoverText) window.AgentSyncSettings?.used("collab.handovers");
    showBarInfo(`${shown.join(" · ")}${summary}.${warning ? ` ${warning}` : ""}`, { kind: warning ? "warn" : "", actions: [{ label: "Bytt prosjekt", run: () => setDrawerOpen(true) }] });
  }
}

function showRunInfo() {
  const project = projectByPath(state.selection.project);
  const running = activeMissionsForProject(state.selection.project);
  if (!running.length) {
    showBarInfo(`Ingen agent kjører i ${project ? projectDisplayName(project) : "valgt prosjekt"} nå. Skriv et oppdrag i det store feltet for å starte en.`);
    return;
  }
  const text = running.map((mission) => `${agentMark(mission.agent)} ${mission.agentLabel} · ${mission.phase || "arbeider"} · ${formatDuration(Date.now() - mission.startedUnixMs)}`).join("   ·   ");
  showBarInfo(text, { actions: [{ label: running.length === 1 ? `Stopp ${running[0].agentLabel}` : "Stopp alle", danger: true, run: stopRunning }] });
}

function showQuotaInfo(quotaIndex, windowIndex) {
  const quota = state.quotas[quotaIndex];
  if (!quota) return;
  const source = quota.source === "codex-sessions"
    ? "Codex' egne øktlogger på denne maskinen"
    : quota.source === "ollama-cloud-api"
      ? "Ollama Cloud-konto via OpenCode-nøkkelen"
      : quota.source === "local"
        ? "lokal konfigurasjon"
        : quota.source;
  const quotaWindow = windowIndex >= 0 ? quota.windows?.[windowIndex] : null;
  if (!quotaWindow) {
    showBarInfo(`${agentMark(quota.agent)} ${quota.label}: ${quota.note || "ingen kvote registrert"} · kilde: ${source}.`);
    return;
  }
  const rawPercent = quotaWindow.usedPercent;
  const hasPercent = rawPercent !== null && rawPercent !== undefined && Number.isFinite(Number(rawPercent));
  const rawAmount = quotaWindow.usedAmount;
  const hasAmount = rawAmount !== null && rawAmount !== undefined && Number.isFinite(Number(rawAmount));
  const percent = hasPercent ? Math.round(Number(rawPercent)) : null;
  const resets = quotaWindow.resetsAtUnix ? new Date(Number(quotaWindow.resetsAtUnix) * 1000) : null;
  const measurement = hasPercent
    ? `${percent} % brukt av ${quotaWindow.name}-kvoten${quotaWindow.windowMinutes ? ` (vindu på ${describeWindow(quotaWindow.windowMinutes)})` : ""}`
    : hasAmount
      ? `${Number(rawAmount).toFixed(2).replace(".", ",")} ${quotaWindow.amountUnit || ""} brukt i ${quotaWindow.name}, grensen er ikke oppgitt av Ollama`
      : `ukjent måleenhet for ${quotaWindow.name}`;
  const parts = [
    `${agentMark(quota.agent)} ${quota.label}: ${measurement}`,
    quota.status === "stale" ? "eldre måling, siste oppdatering feilet" : "",
    resets ? `nullstilles ${formatCompactDate(resets.toISOString())}${resets.getTime() > Date.now() ? ` – om ${formatDuration(resets.getTime() - Date.now())}` : ""}` : "",
    quota.note || "",
    `sist sett ${clock(quota.observedUnixMs, true)} · kilde: ${source}.`
  ].filter(Boolean);
  showBarInfo(parts.join(" · "), { kind: quota.status === "stale" || (percent !== null && percent >= 90) ? "warn" : "" });
}

function showEngineInfo() {
  const diagnostics = state.engineDiagnostics;
  const running = state.engineRunning;
  const parts = [running === true ? "AgentSync-motoren kjører og synkroniserer agentøktene" : running === false ? "AgentSync-motoren kjører ikke" : "Motorstatus er ukjent"];
  if (diagnostics) {
    if (diagnostics.daemonStartedUtc) parts.push(`startet ${formatCompactDate(diagnostics.daemonStartedUtc)}`);
    if (Number.isFinite(Number(diagnostics.cycles))) parts.push(`${diagnostics.cycles} sykluser (${diagnostics.incrementalCycles ?? 0} inkrementelle) · ${diagnostics.errorsSinceStart ?? 0} feil siden start`);
    const last = diagnostics.lastCycle;
    if (last && typeof last === "object") {
      const agents = Array.isArray(last.agents) && last.agents.length ? ` · ${last.agents.join(", ")}` : "";
      parts.push(`siste syklus ${last.mode || "ukjent"} · ${formatDuration(last.durationMs || 0)}${agents}${last.completedUtc ? ` · ferdig ${formatCompactDate(last.completedUtc)}` : ""}`);
    }
    if (Number(diagnostics.errorJournalBytes) > 0) parts.push(`feiljournal ${Math.max(1, Math.round(Number(diagnostics.errorJournalBytes) / 1024))} KB`);
  }
  showBarInfo(`${parts.join(" · ")}.`, {
    kind: running === false ? "error" : "",
    actions: running === false ? [{ label: "Start motoren", run: startEngine }] : []
  });
}

async function startEngine() {
  if (!invoke) return;
  try {
    const result = await invoke("start_agent_sync");
    canvasNote(result?.message || "Motoren er startet.", result?.accepted === false ? "warn" : "");
    state.engineRunning = null;
    loadStatusChips();
  } catch (error) {
    canvasNote(`Kunne ikke starte motoren: ${error}`, "error");
  }
}

function loadStatusChips() {
  if (!invoke) return;
  if (state.statusInFlight) return state.statusInFlight;
  window.clearTimeout(state.statusTimer);
  state.statusTimer = null;
  state.statusInFlight = (async () => {
    const [quotas, health] = await Promise.allSettled([invoke("get_agent_quotas"), invoke("get_engine_health")]);
    if (quotas.status === "fulfilled") state.quotas = Array.isArray(quotas.value) ? quotas.value : [];
    if (health.status === "fulfilled") {
      state.engineRunning = Boolean(health.value?.isRunning);
      if (health.value?.diagnostics && typeof health.value.diagnostics === "object") state.engineDiagnostics = health.value.diagnostics;
    } else state.engineRunning = null;
    if (!document.hidden) renderRail();
  })().finally(() => {
    state.statusInFlight = null;
    state.statusTimer = window.setTimeout(loadStatusChips, STATUS_POLL_MS);
  });
  return state.statusInFlight;
}

// ---------------------------------------------------------------------------
// The validation panel
//
// It floats inside this window wearing the app's own frame, not the operating
// system's. The V switch in the rail is its only control, so the panel being
// there always means the same thing: the validator is on. Dragged by its own
// bar, kept inside the stage, and remembered where it was left.

const CONTROL_PANEL_POSITION_KEY = "agentsync.v4.controlPanelPosition";
const CONTROL_PANEL_SIZE_KEY = "agentsync.v4.controlPanelSize";
const CONTROL_PANEL_MINIMIZED_KEY = "agentsync.v4.controlPanelMinimized";
const CONTROL_PANEL_FOLDED_POSITION_KEY = "agentsync.v4.controlPanelPositionFolded";

// Open and folded each remember their own place. The small bar tends to live
// in a corner and the open panel over the lower canvas; with one shared key,
// folding dragged one to the other.
function controlPanelPositionKey() {
  return byId("controlPanel").classList.contains("minimized")
    ? CONTROL_PANEL_FOLDED_POSITION_KEY
    : CONTROL_PANEL_POSITION_KEY;
}
const CONTROL_PANEL_MARGIN = 8;
const CONTROL_PANEL_MIN_WIDTH = 360;
const CONTROL_PANEL_MIN_HEIGHT = 160;

// Layout pixels throughout, because that is the space style.left and
// style.top are written in. getBoundingClientRect() reports viewport pixels,
// which differ from layout pixels whenever the UI is zoomed - and this app
// has a zoom control. Mixing the two let the panel outrun the pointer by the
// zoom factor, worse the further it was dragged.
function controlPanelBounds() {
  const stage = byId("stage");
  const panel = byId("controlPanel");
  return {
    stage: { width: stage.clientWidth, height: stage.clientHeight },
    width: panel.offsetWidth,
    height: panel.offsetHeight,
  };
}

// How many viewport pixels one layout pixel is right now. Measured rather
// than read from the zoom setting, so it stays right whichever convention the
// engine uses for getBoundingClientRect under CSS zoom.
function viewportPerLayoutPixel(element) {
  const layout = element.offsetWidth;
  const viewport = element.getBoundingClientRect().width;
  return layout > 0 && viewport > 0 ? viewport / layout : 1;
}

// Clamped against a size handed in, not one measured now: during a drag the
// panel's own height can change under us as findings arrive, and re-measuring
// mid-gesture is what makes a panel appear to jump.
function clampPanelPosition(left, top, size = null) {
  const bounds = size || controlPanelBounds();
  const stage = bounds.stage || controlPanelBounds().stage;
  const maxLeft = Math.max(CONTROL_PANEL_MARGIN, stage.width - bounds.width - CONTROL_PANEL_MARGIN);
  const maxTop = Math.max(CONTROL_PANEL_MARGIN, stage.height - bounds.height - CONTROL_PANEL_MARGIN);
  return {
    left: Math.round(Math.min(Math.max(left, CONTROL_PANEL_MARGIN), maxLeft)),
    top: Math.round(Math.min(Math.max(top, CONTROL_PANEL_MARGIN), maxTop)),
  };
}

function placeControlPanel(left, top, { remember = true, size = null } = {}) {
  const position = clampPanelPosition(left, top, size);
  const panel = byId("controlPanel");
  panel.style.left = `${position.left}px`;
  panel.style.top = `${position.top}px`;
  if (remember) writePreference(controlPanelPositionKey(), JSON.stringify(position));
  return position;
}

function readStoredJson(key) {
  try {
    const value = JSON.parse(readPreference(key, "null"));
    return value && typeof value === "object" ? value : null;
  } catch {
    return null;
  }
}

// The size the user dragged the corner to, kept within what the stage can hold.
function restoreControlPanelSize() {
  const panel = byId("controlPanel");
  // Layout pixels, like the width and height about to be written.
  const stage = controlPanelBounds().stage;
  const stored = readStoredJson(CONTROL_PANEL_SIZE_KEY);
  if (!stored) return;
  const maxWidth = Math.max(CONTROL_PANEL_MIN_WIDTH, stage.width - 2 * CONTROL_PANEL_MARGIN);
  const maxHeight = Math.max(CONTROL_PANEL_MIN_HEIGHT, stage.height - 2 * CONTROL_PANEL_MARGIN);
  const folded = panel.classList.contains("minimized");
  if (Number.isFinite(stored.width)) {
    const width = `${Math.round(Math.min(Math.max(stored.width, CONTROL_PANEL_MIN_WIDTH), maxWidth))}px`;
    if (folded) panel.dataset.restoreWidth = width;
    else panel.style.width = width;
  }
  if (Number.isFinite(stored.height)) {
    const height = `${Math.round(Math.min(Math.max(stored.height, CONTROL_PANEL_MIN_HEIGHT), maxHeight))}px`;
    // Folded, the panel is only its title bar. Writing the stored height here
    // re-opened the frame around a hidden body on every window resize: a tall,
    // empty amber rectangle. The height waits in restoreHeight for the unfold.
    if (folded) panel.dataset.restoreHeight = height;
    else panel.style.height = height;
  }
}

function rememberControlPanelSize() {
  const panel = byId("controlPanel");
  if (panel.classList.contains("minimized")) return;
  // offsetWidth/Height, not getBoundingClientRect(): the stored size is
  // written back as style.width/height in layout pixels. Under 140 % zoom the
  // viewport measurement stored a 560 px panel as 784, and every restart
  // restored it 40 % wider than it was left.
  writePreference(
    CONTROL_PANEL_SIZE_KEY,
    JSON.stringify({ width: panel.offsetWidth, height: panel.offsetHeight })
  );
}

// `fallback` says what to do when nothing is remembered for this state:
// "default" puts the open panel lower right, clear of the instruction field,
// and the folded bar upper right; "current" leaves the panel where it is,
// clamped. Nothing here writes - only a drag does.
function restoreControlPanelPosition({ fallback = "default" } = {}) {
  const panel = byId("controlPanel");
  const bounds = controlPanelBounds();
  const folded = panel.classList.contains("minimized");
  const stored = readStoredJson(controlPanelPositionKey());
  let left;
  let top;
  if (Number.isFinite(stored?.left) && Number.isFinite(stored?.top)) {
    ({ left, top } = stored);
  } else if (fallback === "current" && panel.style.left) {
    left = parseFloat(panel.style.left) || 0;
    top = parseFloat(panel.style.top) || 0;
  } else {
    left = bounds.stage.width - bounds.width - 16;
    top = folded ? 16 : bounds.stage.height - bounds.height - 16;
  }
  placeControlPanel(left, top, { remember: false, size: bounds });
}

// Minimised, only the title bar is left: the panel is nearly as tall as the
// stage when it is full, so getting it out of the way matters more here than
// in a window the operating system could move off-screen.
function setControlPanelMinimized(minimized, remember = true) {
  const panel = byId("controlPanel");
  const button = byId("controlPanelMinimize");
  if (minimized) {
    if (!panel.classList.contains("minimized")) {
      // Both dimensions step aside: the folded bar is as wide as its content,
      // and the open size comes back untouched on unfold.
      panel.dataset.restoreHeight = panel.style.height || "";
      panel.dataset.restoreWidth = panel.style.width || "";
      panel.style.height = "";
      panel.style.width = "";
    }
    panel.classList.add("minimized");
  } else {
    panel.classList.remove("minimized");
    if (panel.dataset.restoreHeight) panel.style.height = panel.dataset.restoreHeight;
    if (panel.dataset.restoreWidth) panel.style.width = panel.dataset.restoreWidth;
    delete panel.dataset.restoreHeight;
    delete panel.dataset.restoreWidth;
  }
  const buttonLabel = minimized ? "Åpne valideringspanelet" : "Minimer til tittellinjen";
  tip(button, buttonLabel, "Panel");
  button.setAttribute("aria-label", buttonLabel);
  button.setAttribute("aria-expanded", String(!minimized));
  if (remember) writePreference(CONTROL_PANEL_MINIMIZED_KEY, minimized ? "1" : "");
  // Each state returns to its own remembered place. The first fold, with
  // nothing remembered yet, stays where the panel is.
  if (!panel.hidden) restoreControlPanelPosition({ fallback: "current" });
  window.dispatchEvent(new CustomEvent("agentsync:control-visibility"));
}

let controlPanelResizeObserver = null;

async function showControlPanel({ forceExpanded = false } = {}) {
  const panel = byId("controlPanel");
  if (forceExpanded) window.AgentSyncKnowledgeReviews?.sendToBack?.();
  if (!panel.hidden) {
    if (forceExpanded) setControlPanelMinimized(false);
    restoreControlPanelPosition({ fallback: "current" });
    return;
  }
  panel.hidden = false;
  restoreControlPanelSize();
  // A remembered fold is useful when the panel is restored with a still-live
  // validator. A deliberate V-on is different: it is a request to present the
  // controls, so clear the old fold instead of reopening as a title bar.
  setControlPanelMinimized(
    forceExpanded ? false : readPreference(CONTROL_PANEL_MINIMIZED_KEY) === "1",
    forceExpanded
  );
  restoreControlPanelPosition();
  await window.AgentSyncControl?.open();
  // The panel was empty when it was unhidden, so its height was not yet real.
  restoreControlPanelPosition();
  if (!controlPanelResizeObserver && typeof ResizeObserver === "function") {
    // Findings and run lists keep changing its height, and the corner handle
    // changes both. Either way it must stay inside the stage.
    controlPanelResizeObserver = new ResizeObserver(() => {
      if (panel.hidden) return;
      placeControlPanel(parseFloat(panel.style.left) || 0, parseFloat(panel.style.top) || 0, { remember: false });
    });
    controlPanelResizeObserver.observe(panel);
  }
}

function hideControlPanel() {
  const panel = byId("controlPanel");
  if (panel.hidden) return;
  rememberControlPanelSize();
  panel.hidden = true;
  window.AgentSyncControl?.close();
}

function syncControlPanel(options = {}) {
  if (state.validator.enabled) showControlPanel(options);
  else hideControlPanel();
}

// The panel lives in its own closure and needs exactly one way back: the
// finding the user picked, sent to whichever agent is running in the canvas.
// That agent may not be the one that wrote the code, which is why the critique
// text carries its own context.
window.AgentSyncHost = {
  selectedProject() {
    return state.selection.project || "";
  },
  missionText(missionId) {
    const record = state.missions.get(missionId);
    return record ? { id: missionId, status: record.status, finalOutput: record.finalOutput, persistenceError: record.persistenceError || "" } : null;
  },
  selectedAgent() {
    const agent = state.selection.agent;
    if (!agent) return null;
    return {
      id: agent,
      label: agentLabel(agent),
      model: state.selection.model || agentInfo(agent)?.model || "",
    };
  },
  async sendToAgent(prompt, expectedProject, expectedAgent, { allowDifferentAgent = false } = {}) {
    const { project, agent } = state.selection;
    if (!prompt || !invoke) return false;
    if (!samePath(project, expectedProject) || (!allowDifferentAgent && agent !== expectedAgent)) {
      showBarInfo("Prosjekt eller agent er byttet. Velg funnet på nytt i det oppdaterte panelet.", { kind: "warn" });
      return false;
    }
    if (!projectByPath(project)) {
      canvasNote("Velg et prosjekt før du sender et funn videre.", "warn");
      return false;
    }
    const target = agentInfo(expectedAgent);
    if (!expectedAgent || !target?.available) {
      showBarInfo("Målagenten er ikke tilgjengelig. Velg en tilgjengelig agent før du sender funnet.", { kind: "warn" });
      return false;
    }
    return await launchMission({
      project,
      agent: expectedAgent,
      model: expectedAgent === agent ? state.selection.model || "" : target.model || "",
      level: expectedAgent === agent ? state.selection.level || null : null,
      force: false,
      prompt,
    });
  },
};

window.AgentSyncActiveMemory?.init({ button: byId("activeMemoryButton"), parent: byId("stage"), markdown: markdownToHtml });

// ---------------------------------------------------------------------------
// The switch panel. Every row says what it does in the user's terms, and a row
// whose master is off says which master, rather than going quietly grey.
// ---------------------------------------------------------------------------
function renderSettings() {
  const settings = window.AgentSyncSettings;
  const body = byId("settingsBody");
  if (!settings || !body) return;
  // V is runtime state, not a remembered promise to start it at next boot.
  if (settings.own("validation") !== state.validator.enabled) settings.set("validation", state.validator.enabled, { notify: false });
  const focusedId = body.contains(document.activeElement) ? document.activeElement?.dataset.settingId : null;
  body.replaceChildren();
  for (const group of settings.groups()) {
    const section = element("section", "settings-group");
    section.append(element("h2", "settings-group-name", group.name));
    for (const item of group.items) {
      const row = element("div", "settings-row" + (item.under ? " child" : ""));
      const blocked = settings.blockedBy(item.id);
      const toggle = element("button", "settings-toggle");
      toggle.type = "button";
      toggle.dataset.settingId = item.id;
      toggle.id = `setting-${item.id}`;
      toggle.setAttribute("role", "switch");
      toggle.setAttribute("aria-label", item.label);
      toggle.setAttribute("aria-describedby", `setting-help-${item.id}${blocked ? ` setting-blocked-${item.id}` : ""}`);
      toggle.setAttribute("aria-checked", String(settings.own(item.id)));
      toggle.disabled = item.id === "validation" && state.validator.changing;
      toggle.textContent = settings.own(item.id) ? "på" : "av";
      toggle.addEventListener("click", () => {
        settings.set(item.id, !settings.own(item.id));
      });
      const text = element("div", "settings-text");
      text.append(element("div", "settings-label", item.label));
      const help = element("div", "settings-help", item.help);
      help.id = `setting-help-${item.id}`;
      text.append(help);
      // Three weeks without a single use is the case worth seeing. Anything
      // less says nothing: a switch can be right and rarely reached.
      const use = settings.lastUsed?.(item.id);
      if (!blocked) {
        const days = use ? (Date.now() - use.at) / 86400000 : null;
        if (days === null) {
          text.append(element("div", "settings-use", "Ikke registrert brukt siden telleren ble innført."));
        } else if (days >= 21) {
          text.append(element("div", "settings-use stale", `Siste registrerte aktivitet for ${Math.round(days)} dager siden. Dette sier ikke om funksjonen fortsatt er viktig.`));
        }
      }
      if (blocked) {
        row.classList.add("blocked");
        const reason = element("div", "settings-blocked", `Uten virkning så lenge «${blocked.label}» er av. Verdien her huskes.`);
        reason.id = `setting-blocked-${item.id}`;
        text.append(reason);
      }
      row.append(toggle, text);
      section.append(row);
    }
    body.append(section);
  }
  body.append(element("p", "settings-help", "Sikkerhetskopier og motorvarsler følger motorens faste trygghetsregler. Det tas checkpoint før arbeid; bare bekreftet uendrede kopier kan ryddes. Varsler skjules ikke av disse innstillingene. Tidligere kostnads- og motorbrytere uten virkning er fjernet."));
  body.append(element("p", "settings-help", "Bruk betyr registrert effekt i grensesnittet eller et akseptert oppstartsvalg, ikke antall klikk eller oppdrag. Gjentatte observasjoner samles per minutt. Manglende registrering er ikke bevis på manglende nytte."));
  const changed = settings.changedCount();
  window.AgentSyncExternalWatch?.mount(body);
  window.AgentSyncActiveMemory?.mountSettings(body);
  byId("settingsChanged").textContent = changed
    ? `${changed} ${changed === 1 ? "appbryter" : "appbrytere"} er ikke standard · vakt og minne styres separat`
    : "appbryterne står på standard · vakt og minne styres separat";
  const dot = byId("railSettingsDot");
  if (dot) dot.hidden = changed === 0;
  if (focusedId) byId(`setting-${focusedId}`)?.focus();
}

function setSettingsOpen(open) {
  const panel = byId("settingsPanel");
  panel.hidden = !open;
  byId("railSettingsButton").setAttribute("aria-expanded", String(open));
  byId("railSettingsButton").classList.toggle("active", open);
  if (open) renderSettings();
}

byId("railSettingsButton").addEventListener("click", () => setSettingsOpen(byId("settingsPanel").hidden));
byId("settingsClose").addEventListener("click", () => setSettingsOpen(false));
byId("settingsReset").addEventListener("click", () => {
  window.AgentSyncSettings?.reset();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !byId("settingsPanel").hidden) setSettingsOpen(false);
});
// The validator switch in the rail and its switch here are the same thing.
window.addEventListener("agentsync:settings", (event) => {
  if (event.detail?.id === "collab" || event.detail?.id === "collab.posts" || event.detail?.id === null) {
    window.AgentSyncActiveMemory?.prepare?.(state.selection.project);
  }
  if (event.detail?.id === "validation" || event.detail?.id === null) {
    const on = event.detail?.id === null ? state.validator.enabled : Boolean(event.detail?.value);
    if (typeof setValidatorEnabled === "function" && on !== state.validator.enabled) setValidatorEnabled(Boolean(on));
  }
  // Presentation changes take effect immediately without discarding outputs.
  for (const record of state.missions.values()) {
    layoutActivity(record);
    if (record.userMeta && record.metadata) record.userMeta.textContent = missionUserMeta(record.metadata);
  }
  state.barInfoGeneration = (state.barInfoGeneration || 0) + 1;
  closeBarInfo();
  if (!document.hidden) renderRail();
  renderSettings();
});
renderSettings();

document.addEventListener("pointerdown", (event) => {
  const panel = byId("controlPanel");
  if (!panel || panel.hidden || panel.classList.contains("minimized")) return;
  if (!panel.contains(event.target) && !event.target.closest("#railValidatorButton")) {
    setControlPanelMinimized(true);
  }
});

byId("controlPanelClose").addEventListener("click", (event) => {
  event.stopPropagation();
  setValidatorEnabled(false);
});

byId("controlPanelMinimize").addEventListener("click", (event) => {
  event.stopPropagation();
  const panel = byId("controlPanel");
  setControlPanelMinimized(!panel.classList.contains("minimized"));
});

byId("controlPanelMove").addEventListener("click", (event) => event.stopPropagation());

function handleControlPanelMoveKeydown(event) {
  const directions = {
    ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1]
  };
  const direction = directions[event.key];
  const panel = byId("controlPanel");
  if (!direction || !panel.classList.contains("minimized")) return;
  event.preventDefault();
  event.stopPropagation();
  const step = event.shiftKey ? 32 : 8;
  placeControlPanel(
    (parseFloat(panel.style.left) || 0) + direction[0] * step,
    (parseFloat(panel.style.top) || 0) + direction[1] * step
  );
}

byId("controlPanelMove").addEventListener("keydown", handleControlPanelMoveKeydown);

let controlPanelSuppressOpenClick = false;

function handleControlPanelBarClick(event) {
  const panel = byId("controlPanel");
  if (controlPanelSuppressOpenClick) {
    controlPanelSuppressOpenClick = false;
    event.preventDefault();
    event.stopPropagation();
    return;
  }
  const moveHandle = event.target.closest("#controlPanelMove");
  const closeButton = event.target.closest("#controlPanelClose");
  if (panel.classList.contains("minimized") && !moveHandle && !closeButton) {
    setControlPanelMinimized(false);
  }
}

byId("controlPanelBar").addEventListener("click", handleControlPanelBarClick);

byId("controlPanel").addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;
  event.preventDefault();
  setValidatorEnabled(false);
});

byId("controlPanel").addEventListener("pointerdown", () => {
  window.AgentSyncKnowledgeReviews?.sendToBack?.();
});

// Dragging is pure delta arithmetic from what was measured at the moment of
// the grab. Nothing is re-measured while the pointer is down, so a panel that
// grows or shrinks mid-drag cannot pull itself out from under the cursor.
function beginControlPanelDrag(event) {
  if (event.button !== 0) return;
  const panel = byId("controlPanel");
  const isMoveHandle = event.target.closest("#controlPanelMove");
  const isMinimized = panel.classList.contains("minimized");
  // Folded, only the explicit four-way handle moves the panel. The rest of
  // the bar is an open target. Expanded, the ordinary title bar remains the
  // move surface while its buttons retain their own actions.
  if (isMinimized ? !isMoveHandle : event.target.closest("button")) return;
  const bar = event.currentTarget;
  const start = {
    bounds: controlPanelBounds(),
    left: parseFloat(panel.style.left) || 0,
    top: parseFloat(panel.style.top) || 0,
    pointerX: event.clientX,
    pointerY: event.clientY,
    // clientX/Y arrive in viewport pixels; the panel is placed in layout
    // pixels. Under zoom the two differ by exactly this factor.
    scale: viewportPerLayoutPixel(panel),
    moved: false,
  };
  bar.setPointerCapture(event.pointerId);
  const move = (moveEvent) => {
    const deltaX = moveEvent.clientX - start.pointerX;
    const deltaY = moveEvent.clientY - start.pointerY;
    if (!start.moved) {
      if (Math.hypot(deltaX, deltaY) < 3) return;
      start.moved = true;
      panel.classList.add("dragging");
    }
    placeControlPanel(
      start.left + deltaX / start.scale,
      start.top + deltaY / start.scale,
      { remember: false, size: start.bounds }
    );
  };
  const release = () => {
    if (start.moved || (isMinimized && isMoveHandle)) {
      // Pointer capture can retarget the synthetic click from the handle to
      // the title bar. Consume that one click so moving can never unfold it.
      controlPanelSuppressOpenClick = true;
      window.setTimeout(() => { controlPanelSuppressOpenClick = false; }, 0);
    }
    panel.classList.remove("dragging");
    if (bar.hasPointerCapture(event.pointerId)) bar.releasePointerCapture(event.pointerId);
    bar.removeEventListener("pointermove", move);
    bar.removeEventListener("pointerup", release);
    bar.removeEventListener("pointercancel", release);
    // One write at the end of the gesture, not one per pixel.
    if (start.moved) {
      writePreference(
        controlPanelPositionKey(),
        JSON.stringify({ left: parseFloat(panel.style.left) || 0, top: parseFloat(panel.style.top) || 0 })
      );
    }
  };
  bar.addEventListener("pointermove", move);
  bar.addEventListener("pointerup", release);
  bar.addEventListener("pointercancel", release);
}

byId("controlPanelBar").addEventListener("pointerdown", beginControlPanelDrag);

// The corner handle is the browser's own; remember where the user left it.
byId("controlPanel").addEventListener("pointerup", (event) => {
  if (event.target !== byId("controlPanel")) return;
  rememberControlPanelSize();
});

// A resized window can leave the panel hanging outside the stage.
window.addEventListener("resize", () => {
  const panel = byId("controlPanel");
  if (panel.hidden) return;
  restoreControlPanelSize();
  // Clamp into the new window without forgetting the remembered place: when
  // the window grows back, the panel returns to it.
  restoreControlPanelPosition({ fallback: "current" });
});
function readValidatorControl(snapshot) {
  if (!invoke || state.validator.changing) return;
  if (!snapshot?.runtime || snapshot.runtimeError) return;
  const status = snapshot.runtime;
  const enabled = Boolean(status.enabled);
  const generation = Number(status.generation) || 0;
  const activeControls = Number(status.activeControls) || 0;
  const runtimeChanged = enabled !== state.validator.enabled
    || generation !== state.validator.generation
    || activeControls !== state.validator.activeControls;
  const panel = byId("controlPanel");
  // Runtime state is authoritative, but the in-window panel can still drift
  // after a WebView restore or an interrupted presentation update. Reconcile
  // that invariant even when the next backend snapshot itself is unchanged.
  // Without this, an enabled validator could remain invisible forever because
  // the early return below suppressed the only call that could reopen it.
  const presentationDrifted = Boolean(panel && panel.hidden === enabled);
  if (!runtimeChanged && !presentationDrifted) return;
  if (runtimeChanged) {
    Object.assign(state.validator, { enabled, generation, activeControls });
    renderSettings();
    if (!document.hidden) renderRail();
  }
  syncControlPanel();
}

function pollValidatorControl() {
  if (state.statusUnsubscribe || !window.AgentSyncStatus) return;
  state.statusUnsubscribe = window.AgentSyncStatus.subscribe((snapshot) => {
    readValidatorControl(snapshot);
    const warning = snapshot.summariesError || snapshot.runtimeError || snapshot.summariesWarning || "";
    if (warning !== state.statusWarning) {
      state.statusWarning = warning;
      if (warning) canvasNote(`Status eller historikk kunne ikke leses fullstendig: ${warning}`, "warn");
    }
    if (snapshot.missions.some((mission) => mission.status === "running" || mission.status === "queued" || mission.persistenceError)
      || [...state.missions.values()].some((record) => record.persistenceError)) ensurePolling();
    if (!document.hidden) compactFinishedViews();
  });
}

async function setValidatorEnabled(enabled) {
  if (!invoke || state.validator.changing) return;
  if (enabled && !projectByPath(state.selection.project)) {
    canvasNote("Velg et prosjekt før valideringsagenten slås på.", "warn");
    setDrawerOpen(true);
    return;
  }
  state.validator.changing = true;
  renderRail();
  renderSettings();
  try {
    const status = await invoke("set_validator_control", { enabled });
    state.validator.enabled = Boolean(status?.enabled);
    state.validator.generation = Number(status?.generation) || 0;
    state.validator.activeControls = Number(status?.activeControls) || 0;
    syncControlPanel({ forceExpanded: enabled && state.validator.enabled });
    showBarInfo(enabled
      ? window.AgentSyncSettings?.own("validation.auto") === false
        ? "Valideringsagenten er på for manuell kontroll. Automatisk start er av, og ingen nye kontroller settes i kø. Velg Kontroller nå når du ønsker det."
        : "Valideringsagenten er på. Den bruker en annen agent og validerer automatisk etter fullførte skriveoppdrag som endret filer."
      : "Valideringsagenten er av. Kontrollvinduet er lukket og aktive kontroller er stoppet.", { kind: enabled ? "" : "warn" });
    ensurePolling();
    window.AgentSyncStatus?.refresh();
  } catch (error) {
    canvasNote(`Kunne ikke ${enabled ? "slå på" : "slå av"} valideringsagenten: ${error}`, "error");
  } finally {
    state.validator.changing = false;
    renderRail();
    renderSettings();
  }
}

byId("barInfoClose").addEventListener("click", () => {
  closeBarInfo();
  intentInput.focus();
});

document.addEventListener("click", (event) => {
  if (state.barInfo && !event.target.closest("#topBar") && !event.target.closest("#projectDrawerHandle")) closeBarInfo();
});

// ---------------------------------------------------------------------------
// Choices: from the resolver (ranked) or straight from the catalog.
// ---------------------------------------------------------------------------

function agentChoices() {
  const level = state.selection.level || "";
  return AGENT_ORDER.map((agent) => {
    const info = agentInfo(agent);
    return {
      agent,
      // Re-picking the same agent keeps its model; another agent starts clean.
      model: agent === state.selection.agent ? state.selection.model : "",
      level,
      force: false,
      available: Boolean(info?.available),
      rationale: info?.note || agentLabel(agent)
    };
  });
}

function modelsForAgent(agent) {
  return Array.isArray(state.catalog?.models?.[agent]) ? state.catalog.models[agent] : [];
}


function enterChoosing(choices, source, ranked, kind = "ranked") {
  closeBarInfo();
  state.barChoices = Array.isArray(choices) ? choices : [];
  state.barChoicesSource = source || "";
  state.barChoicesRanked = Boolean(ranked);
  state.barChoicesKind = kind;
  state.setupMode = "choosing";
  renderSetupBar();
  byId("setupBar").querySelector(".bubble")?.focus();
}

function leaveChoosing() {
  state.setupMode = state.selection.agent ? "chosen" : "idle";
  renderSetupBar();
  intentInput.focus();
}

function applyChoice(choice, result = null) {
  const project = projectByPath(state.selection.project);
  if (!project) {
    setDrawerOpen(true);
    return;
  }
  state.selection.agent = choice.agent;
  state.selection.model = choice.model || "";
  state.selection.level = choice.level || "";
  state.forceNext = Boolean(choice.force);
  persistSelection();
  state.setupMode = "chosen";
  closeBarInfo();
  renderTopBar();
  renderRail();
  const note = tagProjectNode(element("p", "note setup"), project.path);
  const summary = setupSummary();
  const source = state.barChoicesSource || "manuelt";
  note.append(timeElement(Date.now()), "Oppsett valgt: ", element("b", "", summary), element("span", "source", ` (${source})`));
  appendToCanvas(note);
  rememberNote(`Oppsett valgt: ${summary} (${source})`, "setup");
  if (result?.warning) {
    showBarInfo(result.warning, { kind: "warn" });
  } else if (choice.rationale) {
    showBarInfo(`${summary}. Hvorfor dette forslaget: ${choice.rationale}`, {
      actions: [{ label: "Andre forslag", run: () => enterChoosing(state.barChoices, state.barChoicesSource, state.barChoicesRanked, state.barChoicesKind) }]
    });
  }
  intentInput.value = "";
  instructionInput.focus();
}

function describeSource(result) {
  if (result.source === "ollama" && result.resolverModel) return `AI · ${formatSeconds(result.elapsedMs)}`;
  return `lokal tolkning · ${formatSeconds(result.elapsedMs)}`;
}

// The user's own pick of interpreting model wins over the backend's choice.
function preferredResolverModel() {
  return readPreference("agentsync.v4.resolverModel") || state.catalog?.resolverModel || "";
}

// Only real combinations survive: an available agent, a model that exists in
// that agent's catalog (or none), and the currently selected project.
function normalizeIntentChoices(result) {
  const rawChoices = Array.isArray(result?.choices) && result.choices.length
    ? result.choices
    : Array.isArray(result?.recommendations) && result.recommendations.length
      ? result.recommendations
      : result?.fields ? [result.fields] : [];
  const project = projectByPath(state.selection.project);
  if (!project) return [];
  const choices = [];
  const seen = new Set();

  for (const rawChoice of rawChoices) {
    const raw = rawChoice?.fields && typeof rawChoice.fields === "object" ? rawChoice.fields : rawChoice;
    if (!raw || typeof raw !== "object") continue;
    if (raw.project && !samePath(raw.project, project.path)) continue;
    const agent = String(raw.agent || "").trim().toLowerCase();
    const info = agentInfo(agent);
    if (!AGENT_ORDER.includes(agent) || !info || !info.available) continue;

    let model = String(raw.model || "").trim();
    if (model) {
      const known = Array.isArray(state.catalog?.models?.[agent]) ? state.catalog.models[agent] : [];
      const wanted = model.toLowerCase();
      // Exact id first; a bare id without provider ("qwen3.5:397b") still maps
      // onto the provider-qualified catalog entry OpenCode actually accepts.
      const canonical = known.find((candidate) => candidate.toLowerCase() === wanted)
        || known.find((candidate) => candidate.toLowerCase().endsWith(`/${wanted}`));
      if (!canonical) continue;
      model = canonical;
    }
    const level = LEVEL_LABELS[String(raw.level || "").toLowerCase()] !== undefined
      ? String(raw.level || "").toLowerCase()
      : "";
    const signature = `${agent}\u0000${model.toLowerCase()}\u0000${level}`;
    if (seen.has(signature)) continue;
    seen.add(signature);
    choices.push({
      project: project.path,
      agent,
      model,
      level,
      force: raw.force === true,
      rationale: String(raw.rationale || rawChoice?.rationale || "").trim().slice(0, 240)
    });
    if (choices.length >= 4) break;
  }
  return choices;
}

function cancelResolving() {
  if (!state.resolving) return;
  state.intentRequestId += 1;
  state.resolving = false;
  if (state.setupMode === "resolving") state.setupMode = state.selection.agent ? "chosen" : "idle";
  syncProjectGate();
  renderSetupBar();
}

async function resolveIntent() {
  const selectedProject = projectByPath(state.selection.project);
  if (!selectedProject) {
    setDrawerOpen(true);
    return;
  }
  const text = intentInput.value.trim();
  if (!text) {
    // An empty wish is the same request as clicking the agent chip.
    enterChoosing(agentChoices(), "agenter", false, "agents");
    return;
  }
  if (!invoke || state.resolving) return;
  const requestId = state.intentRequestId + 1;
  state.intentRequestId = requestId;
  state.intentRequestProject = selectedProject.path;
  state.resolving = true;
  state.setupMode = "resolving";
  closeBarInfo();
  syncProjectGate();
  renderSetupBar();
  try {
    await loadCatalog();
    const currentProject = projectByPath(state.selection.project);
    if (!currentProject || !samePath(currentProject.path, selectedProject.path)) throw new Error("Prosjektet er ikke lenger tilgjengelig. Velg prosjekt på nytt.");
    const result = await invoke("resolve_intent", {
      request: {
        text,
        currentProject: currentProject.path,
        currentAgent: state.selection.agent || null,
        resolverModel: readPreference("agentsync.v4.resolverModel") || null
      }
    });
    if (requestId !== state.intentRequestId || !samePath(state.intentRequestProject, state.selection.project)) return;
    const choices = normalizeIntentChoices(result);
    state.resolving = false;
    if (!choices.length) {
      state.setupMode = state.selection.agent ? "chosen" : "idle";
      renderSetupBar();
      showBarInfo("Ingen tilgjengelige agent- og modellkombinasjoner passet ønsket – prøv å beskrive det annerledes.", { kind: "warn" });
      return;
    }
    enterChoosing(choices, describeSource(result), true);
    if (result.warning) showBarInfo(result.warning, { kind: "warn" });
  } catch (error) {
    if (requestId !== state.intentRequestId) return;
    state.resolving = false;
    state.setupMode = state.selection.agent ? "chosen" : "idle";
    renderSetupBar();
    showBarInfo(`Kunne ikke lage forslag: ${error}`, { kind: "error" });
  } finally {
    if (requestId === state.intentRequestId) {
      state.resolving = false;
      syncProjectGate();
    }
  }
}

// ---------------------------------------------------------------------------
// Missions: start, stream into the canvas, stop
// ---------------------------------------------------------------------------

function activeMissionsForProject(path) {
  return state.activeMissions.filter((mission) => (mission.status === "queued" || mission.status === "running") && samePath(mission.projectPath, path));
}

// Rebuilding chips and lists every poll is what made the window feel heavy
// while an agent worked; now only a changed running set rebuilds them, and a
// quiet poll just refreshes the durations in the tooltips.
function updateRunningControls() {
  const signature = `${state.selection.project}#${state.activeMissions
    .filter((mission) => mission.status === "queued" || mission.status === "running")
    .map((mission) => `${mission.id}:${mission.status}`)
    .join("|")}`;
  if (signature !== state.runningSignature) {
    state.runningSignature = signature;
    renderTopBar();
    if (drawerOpen()) renderProjectList();
    return;
  }
  const running = activeMissionsForProject(state.selection.project);
  tip(byId("railRunButton"), () => {
    const live = activeMissionsForProject(state.selection.project);
    return live.length
      ? live.map((mission) => `${mission.agentLabel} · ${formatDuration(Date.now() - mission.startedUnixMs)}`).join(", ")
      : "Ingen agent kjører i prosjektet";
  }, "Kjører nå");
}

// ---------------------------------------------------------------------------
// Scope before start. A one-word prompt like "ok?" once sent an agent into a
// nine-minute production audit; nothing had told it how far to go. Before a
// run starts the resolver says what the agent will do with the prompt. When
// the smallest and largest readings differ they become buttons in the bar and
// the run waits for a pick. "Som skrevet" and Ctrl+Shift+Enter skip this.

// The readings of a vague prompt sit between the canvas and the text field,
// in the line of sight, not up in the bar. Enter picks the focused reading,
// Escape puts the cursor back in the text without starting anything.
function showScopeStrip(text, actions) {
  const strip = byId("scopeStrip");
  byId("scopeStripText").textContent = text;
  const host = byId("scopeStripActions");
  host.replaceChildren();
  for (const action of actions) {
    host.append(chip(action.label, {
      className: action.plain ? "plain" : "",
      title: action.title || "",
      onClick: () => {
        closeScopeStrip();
        action.run();
      }
    }));
  }
  strip.hidden = false;
  // A layout pass between un-hiding and the class change runs the slide-in.
  void strip.offsetWidth;
  strip.classList.add("open");
  host.querySelector(".bar-chip")?.focus();
}

function closeScopeStrip() {
  const strip = byId("scopeStrip");
  if (strip.hidden) return;
  strip.classList.remove("open");
  strip.hidden = true;
}

function scopeChoiceNote(scope, original) {
  const note = tagProjectNode(element("p", "note setup"));
  note.append(timeElement(Date.now()), `«${original}» kan bety flere ting – velg nedenfor: `);
  scope.options.forEach((option, index) => {
    if (index) note.append(" · ");
    note.append(element("b", "", option.label));
  });
  appendToCanvas(note);
  rememberNote(`«${original}» kan bety flere ting: ${scope.options.map((option) => option.label).join(" · ")}`, "setup");
}

// `options` may be a click event when the run button calls this directly;
// only an explicit { skipScope: true } skips the scoping step.
function composerLaunchCurrent(launch, checkDraft = true) {
  return samePath(state.selection.project, launch.project)
    && state.selection.agent === launch.agent
    && (state.selection.model || "") === (launch.model || "")
    && (state.selection.level || "") === (launch.level || "")
    && (!checkDraft || instructionInput.value === launch.composerDraft);
}

async function startMission(options) {
  const skipScope = options?.skipScope === true;
  const prompt = instructionInput.value.trim();
  if (!prompt || !invoke || state.starting) return;
  const { project, agent } = state.selection;
  if (!projectByPath(project)) {
    clearSelectedProject();
    updateProjectLabels();
    renderTopBar();
    canvasNote("Velg et prosjekt i vinduet til venstre først – agenten må kjøre i en prosjektmappe.", "warn");
    setDrawerOpen(true);
    return;
  }
  if (!agent) {
    enterChoosing(agentChoices(), "agenter", false, "agents");
    showBarInfo("Velg en agent først – klikk en boble i linjen øverst, eller skriv et ønske i ønskefeltet.", { kind: "warn" });
    return;
  }
  const model = state.selection.model || "";
  const level = state.selection.level || null;
  const force = state.forceNext;
  const launch = { project, agent, model, level, force, composerDraft: instructionInput.value };

  if (!skipScope) {
    state.starting = true;
    syncProjectGate();
    let scope = null;
    try {
      scope = await invoke("scope_mission", {
        request: { prompt, agent, resolverModel: preferredResolverModel() || null }
      });
    } catch (_) {
      // Scoping is advisory; a resolver that is down must not stop a run.
      scope = null;
    } finally {
      state.starting = false;
      syncProjectGate();
    }
    if (!composerLaunchCurrent(launch)) {
      showBarInfo("Prosjekt, oppsett eller utkast ble endret. Kontroller valgene og start på nytt.", { kind: "warn" });
      return;
    }
    if (scope && scope.spread === "wide" && Array.isArray(scope.options) && scope.options.length >= 2) {
      const actions = scope.options.map((option) => ({
        label: option.label,
        title: option.description,
        run: () => {
          canvasNote(`Valgt: ${option.label} – ${option.description}`, "setup");
          launchMission({ ...launch, prompt: option.prompt });
        }
      }));
      actions.push({ label: "Som skrevet", plain: true, title: "Send oppdraget uendret", run: () => launchMission({ ...launch, prompt }) });
      showScopeStrip(scope.summary || `«${prompt}» kan leses på flere måter.`, actions);
      scopeChoiceNote(scope, prompt);
      return;
    }
    // A resolver that stopped answering used to look exactly like one that
    // worked: the same note, from the local rules. Now it says which.
    if (scope?.warning) canvasNote(scope.warning, "warn");
    if (scope && scope.summary && scope.source !== "disabled") {
      canvasNote(`Tolket som: ${scope.summary}`, "setup");
    }
  }
  await launchMission({ ...launch, prompt });
}

async function launchMission({ project, agent, model, level, force, prompt, composerDraft }) {
  if (!invoke || state.starting) return;
  const launch = { project, agent, model, level, composerDraft };
  if (composerDraft !== undefined && !composerLaunchCurrent(launch)) {
    showBarInfo("Dette valget tilhører et tidligere oppsett eller utkast. Start fra det gjeldende skrivefeltet.", { kind: "warn" });
    return;
  }
  state.starting = true;
  syncProjectGate();
  try {
    const mission = await invoke("start_mission", {
      request: { projectPath: project, prompt, agent, model: model || null, level, force, mode: "shared", purpose: "writer",
        sharePosts: window.AgentSyncSettings?.enabled("collab.posts") !== false }
    });
    if (mission?.missionId) window.AgentSyncSettings?.used("collab.posts");
    // A finding forwarded from another panel is not the unsent composer draft.
    if (composerDraft !== undefined && composerLaunchCurrent(launch, false)) {
      if (instructionInput.value === composerDraft) instructionInput.value = "";
      state.forceNext = false;
    }
    const inOriginalProject = samePath(state.selection.project, project);
    if (inOriginalProject) {
      closeBarInfo();
      closeScopeStrip();
    }
    // A run the user just started is always worth following from its start.
    if (inOriginalProject) scrollToBottom();
    await pollMissions();
    return mission;
  } catch (error) {
    const message = String(error);
    if (message.includes("AGENT_BUSY")) {
      const detail = message.replace(/^.*AGENT_BUSY:\s*/s, "");
      if (composerDraft !== undefined && composerLaunchCurrent(launch)) {
        state.forceNext = true;
        renderSetupBar();
        showBarInfo(`${detail} Tving er nå slått på – trykk Enter igjen for å kjøre parallelt.`, { kind: "warn" });
      } else if (composerDraft === undefined) {
        showBarInfo(`${detail} Funnet ble ikke sendt. Prøv igjen når agenten er ledig, eller velg en annen agent.`, { kind: "warn" });
      } else {
        showBarInfo(`${detail} Oppdraget i ${project} startet ikke. Gjeldende prosjekt og utkast er uendret.`, { kind: "warn" });
      }
      canvasNote(detail, "warn");
    } else {
      canvasNote(`Kunne ikke starte ${agentLabel(agent)}: ${message}`, "error");
    }
  } finally {
    state.starting = false;
    syncProjectGate();
    if (samePath(state.selection.project, project) && projectByPath(state.selection.project)) instructionInput.focus();
  }
}

async function stopRunning() {
  const running = activeMissionsForProject(state.selection.project);
  if (!running.length || !invoke) return;
  for (const mission of running) {
    try {
      await invoke("cancel_mission", { missionId: mission.id });
      canvasNote(`Avbryt-signal sendt til ${mission.agentLabel}.`, "warn");
    } catch (error) {
      canvasNote(`Kunne ikke stoppe ${mission.agentLabel}: ${error}`, "error");
    }
  }
  ensurePolling();
}

// Events that carry no detail of their own: they say something happened, not
// what. Kept, but dimmed, so the eye finds the tool calls.
const ACTIVITY_NOISE = /^(Hendelse: |Agentøkten er initialisert$|Starter arbeidssteg$|Agenten bruker et verktøy$)/;

function activityLine(line, startedUnixMs) {
  // The backend stamps activity with elapsed seconds ("[+ 12s] ..."); the
  // canvas shows wall-clock time so every line reads [H:I:S].
  const { seconds, text } = activityParts(line);
  const noise = ACTIVITY_NOISE.test(text);
  const node = element("div", `activity-line${noise ? " noise" : ""}`);
  node.dataset.text = text;
  node.dataset.command = String(/^Kommando:/.test(text));
  node.dataset.count = "1";
  if (seconds !== null) node.append(timeElement(Number(startedUnixMs) + seconds * 1000, false));
  if (noise) {
    node.dataset.group = "noise";
    node.groupCounts = new Map([[text, 1]]);
    node.groupTotal = 1;
    node.append(element("span", "activity-group", text));
  } else {
    node.append(text);
  }
  return node;
}

function activityParts(line) {
  const match = /^\[\+\s*(\d+)s\]\s?(.*)$/.exec(line);
  return { seconds: match ? Number(match[1]) : null, text: match ? match[2] : line };
}

// "1 354 hendelser uten detaljer · hook event ×677, agent event ×677"
function noiseGroupText(node) {
  if (node.groupTotal === 1) return [...node.groupCounts.keys()][0];
  const breakdown = [...node.groupCounts]
    .sort((left, right) => right[1] - left[1])
    .slice(0, 4)
    .map(([text, count]) => `${text.replace(/^Hendelse: /, "")} ×${count}`)
    .join(", ");
  return `${node.groupTotal.toLocaleString("nb-NO")} hendelser uten detaljer · ${breakdown}`;
}

// Two kinds of shortening, both keeping the count: a run of detail-free events
// becomes one line, and an identical line repeated in a row gets a multiplier.
function mergeActivity(record, line) {
  const { text } = activityParts(line);
  const last = record.activityNodes[record.activityNodes.length - 1];
  if (!last) return false;
  if (ACTIVITY_NOISE.test(text) && last.dataset.group === "noise") {
    last.groupCounts.set(text, (last.groupCounts.get(text) || 0) + 1);
    last.groupTotal += 1;
    last.lastElementChild.textContent = noiseGroupText(last);
    return true;
  }
  if (last.dataset.text !== text || last.dataset.group === "noise") return false;
  const count = Number(last.dataset.count || 1) + 1;
  last.dataset.count = String(count);
  let badge = last.querySelector(".activity-count");
  if (!badge) {
    badge = element("span", "activity-count");
    last.append(badge);
  }
  badge.textContent = ` ×${count}`;
  return true;
}

function ensureMissionBlock(mission, history = false) {
  if (state.missions.has(mission.id)) return state.missions.get(mission.id);

  const purpose = missionPurpose(mission);

  // Replayed runs carry their date; live runs only need the clock.
  const stamp = () => timeElement(mission.startedUnixMs, history);
  const user = element("article", `entry entry-user${history ? " history" : ""}`);
  user.append(actorStripe(`Du. Sendt til ${mission.agentLabel || agentLabel(mission.agent)}.`));
  user.dataset.mission = mission.id;
  user.dataset.agent = mission.agent || "";
  user.dataset.purpose = purpose;
  if (mission.sourceMissionId) user.dataset.sourceMissionId = mission.sourceMissionId;
  tagProjectNode(user, mission.projectPath);
  const userHead = element("div", "entry-head");
  const userMetaNode = element("span", "entry-meta", missionUserMeta(mission));
  const userName = element("b");
  userName.append("Du → ", markNode(mission.agent), " ", mission.agentLabel);
  userHead.append(stamp(), userName, userMetaNode);
  user.append(userHead, element("pre", "entry-body", mission.prompt || ""));

  const agent = element("article", `entry entry-agent${history ? " history" : ""}`);
  agent.append(actorStripe(() => [
    mission.agentLabel || agentLabel(mission.agent),
    window.AgentSyncStatus?.modelLabel(mission) || mission.model || "modell ikke registrert",
    purpose === "validator" ? "automatisk kontroll" : purpose === "manualControl" ? "manuell kontroll" : "skriveoppdrag",
  ].filter(Boolean).join(" · ")));
  agent.dataset.mission = mission.id;
  agent.dataset.agent = mission.agent || "";
  agent.dataset.purpose = purpose;
  if (mission.sourceMissionId) agent.dataset.sourceMissionId = mission.sourceMissionId;
  agent.setAttribute("aria-busy", String(mission.status === "queued" || mission.status === "running"));
  tagProjectNode(agent, mission.projectPath);
  const agentHead = element("div", "entry-head");
  const meta = element("span", "entry-meta live", "starter");
  agentHead.append(stamp(), agentNameNode(mission.agent, mission.agentLabel), meta);
  const activity = element("div", "entry-activity");
  activity.hidden = true;
  const activityMore = element("button", "activity-more");
  activityMore.type = "button";
  activityMore.hidden = true;
  const text = element("div", "entry-text markdown");
  const expand = element("button", "entry-expand", "Vis hele svaret");
  expand.type = "button";
  expand.hidden = true;
  expand.addEventListener("click", () => {
    text.classList.add("expanded");
    text.classList.remove("truncated");
    expand.hidden = true;
  });
  const errors = element("pre", "entry-errors");
  errors.hidden = true;
  errors.id = `mission-errors-${String(mission.id).replace(/[^A-Za-z0-9_-]/g, "_")}`;
  const errorExpand = element("button", "entry-expand entry-error-expand");
  errorExpand.type = "button";
  errorExpand.hidden = true;
  errorExpand.setAttribute("aria-controls", errors.id);
  const foot = element("div", "entry-foot");
  foot.hidden = true;
  agent.append(agentHead, activity, text, expand, errors, errorExpand, foot);

  const following = isAtBottom();
  stream.append(user, agent);
  refreshCanvasProjectVisibility();

  const record = {
    id: mission.id, projectPath: mission.projectPath, user, agent, meta, userMeta: userMetaNode, activity, activityMore, activityNodes: [], activityExpanded: false,
    text, expand, errors, errorExpand, errorExpanded: false, foot, history,
    agentId: mission.agent || "", purpose, sourceMissionId: mission.sourceMissionId || "", status: mission.status || "", phase: mission.phase || "",
    sourceAgentId: state.missions.get(mission.sourceMissionId)?.agentId || "",
    startedUnixMs: Number(mission.startedUnixMs) || 0, changedFiles: Number.isFinite(mission.workspaceAfter?.changedFiles) ? mission.workspaceAfter.changedFiles : null,
    output: "", finalOutput: "", errorOutput: "", finished: false,
    // Byte cursors for delta polling and the partial activity line between polls.
    outputBytes: 0, finalOutputBytes: 0, errorOutputBytes: 0, generation: 0, outputPending: "",
    finalRenderTimer: null, finalRenderedAt: 0
  };
  state.missions.set(mission.id, record);
  errorExpand.addEventListener("click", () => toggleTechnicalLog(record));
  activityMore.addEventListener("click", () => {
    record.activityExpanded = !record.activityExpanded;
    layoutActivity(record);
  });
  afterCanvasChange(following);
  return record;
}

function technicalLineKey(line) {
  return String(line || "")
    .replace(/\u001b\[[0-?]*[ -\/]*[@-~]/g, "")
    .replace(/^\s*(?:\[\d{2}:\d{2}:\d{2}(?:\.\d+)?\]|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?)\s*/, "")
    .trim();
}

function technicalOutputView(value) {
  const raw = String(value || "");
  const rawLines = raw.split(/\r?\n/).filter((line) => line.trim());
  const groups = new Map();
  for (const line of rawLines) {
    const key = technicalLineKey(line) || line.trim();
    const known = groups.get(key);
    if (known) known.count += 1;
    else groups.set(key, { line, count: 1 });
  }

  const groupedLines = [...groups.values()].map(({ line, count }) => (
    count > 1 ? `${line}  ×${count}` : line
  ));
  let previewLines = groupedLines;
  let omittedLines = 0;
  if (groupedLines.length > TECHNICAL_LOG_PREVIEW_LINES) {
    const head = Math.ceil((TECHNICAL_LOG_PREVIEW_LINES - 1) / 2);
    const tail = TECHNICAL_LOG_PREVIEW_LINES - 1 - head;
    omittedLines = groupedLines.length - head - tail;
    previewLines = [
      ...groupedLines.slice(0, head),
      `… ${omittedLines.toLocaleString("nb-NO")} tekniske linjer skjult …`,
      ...groupedLines.slice(-tail),
    ];
  }

  let preview = previewLines.join("\n");
  let omittedCharacters = 0;
  if (preview.length > TECHNICAL_LOG_PREVIEW_CHARS) {
    const markerRoom = 80;
    const visible = Math.max(200, TECHNICAL_LOG_PREVIEW_CHARS - markerRoom);
    const head = Math.ceil(visible / 2);
    const tail = Math.floor(visible / 2);
    omittedCharacters = preview.length - head - tail;
    preview = `${preview.slice(0, head)}\n… ${omittedCharacters.toLocaleString("nb-NO")} tegn skjult …\n${preview.slice(-tail)}`;
  }

  return {
    raw,
    rawLines,
    preview,
    groupedLines,
    omittedLines,
    omittedCharacters,
    shortened: rawLines.length !== groupedLines.length || omittedLines > 0 || omittedCharacters > 0,
  };
}

function renderErrors(record) {
  if (!missionContentVisible(record)) { record.errorsDirty = true; return; }
  record.errorsDirty = false;
  const view = technicalOutputView(record.errorText);
  const hasOutput = view.rawLines.length > 0;
  if (!hasOutput) record.errorExpanded = false;
  const expanded = hasOutput && record.errorExpanded === true;
  record.errors.textContent = expanded ? view.raw : view.preview;
  record.errors.hidden = !hasOutput;
  record.errors.classList.toggle("collapsed", hasOutput && view.shortened && !expanded);
  record.errorExpand.hidden = !hasOutput || !view.shortened;
  record.errorExpand.textContent = expanded
    ? "Vis mindre"
    : `Vis hele den tekniske loggen (${view.rawLines.length.toLocaleString("nb-NO")} linjer)`;
  record.errorExpand.setAttribute("aria-expanded", String(expanded));
}

function toggleTechnicalLog(record) {
  const following = isAtBottom();
  record.errorExpanded = !record.errorExpanded;
  renderErrors(record);
  afterCanvasChange(following);
}

function applyTechnicalOutput(record, reset, outputDelta) {
  if (!reset && !outputDelta) return false;
  if (reset) record.errorText = "";
  record.errorText = (record.errorText || "") + (outputDelta || "");
  // A reset normally means that the bounded native buffer rolled over. It is
  // not a new user choice, so keep an explicitly expanded log expanded. An
  // actually empty replacement is reset by renderErrors itself.
  renderErrors(record);
  return true;
}

function resetActivity(record) {
  record.activityNodes = [];
  record.pendingActivity = [];
  record.activity.replaceChildren();
  record.activity.hidden = true;
  record.activityMore.hidden = true;
}

function appendActivity(record, line, startedUnixMs) {
  if (!missionContentVisible(record)) {
    (record.pendingActivity ||= []).push({ line, startedUnixMs });
    return;
  }
  if (mergeActivity(record, line)) return;
  const node = activityLine(line, startedUnixMs);
  record.activityNodes.push(node);
  record.activity.append(node);
  if (node.dataset.command === "true" && window.AgentSyncSettings?.enabled("record.command") === false) {
    node.hidden = true;
    if (!record.deferActivityLayout) layoutActivity(record);
    return;
  }
  if (node.dataset.command === "true") window.AgentSyncSettings?.used("record.command");
  record.activity.hidden = false;
  if (record.activityExpanded || record.finished) {
    if (!record.deferActivityLayout) layoutActivity(record);
    return;
  }
  // Live and folded: only the node that just fell out of the tail changes.
  const total = record.activityNodes.length;
  if (total > ACTIVITY_LIVE_TAIL) {
    record.activityNodes[total - ACTIVITY_LIVE_TAIL - 1].hidden = true;
    record.activityMore.hidden = false;
    record.activityMore.textContent = "… " + (total - ACTIVITY_LIVE_TAIL) + " tidligere hendelser";
    if (record.activity.firstElementChild !== record.activityMore) record.activity.prepend(record.activityMore);
  }
}

// Full pass: called on finish, on unfold/fold and on a reset.
function layoutActivity(record) {
  const showCommand = window.AgentSyncSettings?.enabled("record.command") !== false;
  const nodes = record.activityNodes.filter(node => {
    if (showCommand || node.dataset.command !== "true") return true;
    node.hidden = true;
    return false;
  });
  const total = nodes.length;
  const more = record.activityMore;
  record.activity.hidden = total === 0;
  if (!total) { more.hidden = true; return; }
  const limit = record.finished ? ACTIVITY_DONE_EDGE * 2 : ACTIVITY_LIVE_TAIL;
  if (record.activityExpanded || total <= limit) {
    for (const node of nodes) node.hidden = false;
    more.hidden = total <= limit;
    if (!more.hidden) {
      more.textContent = "Vis færre hendelser";
      record.activity.append(more);
    }
    return;
  }
  if (record.finished) {
    nodes.forEach((node, index) => {
      node.hidden = index >= ACTIVITY_DONE_EDGE && index < total - ACTIVITY_DONE_EDGE;
    });
    more.textContent = "… " + (total - ACTIVITY_DONE_EDGE * 2) + " hendelser til";
    record.activity.insertBefore(more, nodes[total - ACTIVITY_DONE_EDGE]);
  } else {
    nodes.forEach((node, index) => {
      node.hidden = index < total - ACTIVITY_LIVE_TAIL;
    });
    more.textContent = "… " + (total - ACTIVITY_LIVE_TAIL) + " tidligere hendelser";
    record.activity.prepend(more);
  }
  more.hidden = false;
}

// Markdown for a streaming reply is re-rendered at most every MARKDOWN_RENDER_MS;
// the final render happens immediately when the run ends.
function missionContentVisible(record) {
  return !document.hidden && samePath(record.projectPath, state.selection.project)
    && (!state.canvasFocus.agent || nodeBelongsToFocusedAgent(record.agent, state.canvasFocus.agent));
}

function patchMarkdownContent(record) {
  const html = markdownToHtml(record.finalOutput);
  if (html === record.renderedHtml) return;
  const template = document.createElement("template");
  template.innerHTML = html;
  const incoming = [...template.content.childNodes];
  const current = [...record.text.childNodes];
  let prefix = 0;
  while (prefix < current.length && prefix < incoming.length && current[prefix].isEqualNode(incoming[prefix])) prefix += 1;
  // Completed leading blocks survive streaming updates, preserving their
  // selection and avoiding needless mutation of the whole live document.
  for (let index = current.length - 1; index >= prefix; index -= 1) current[index].remove();
  record.text.append(...incoming.slice(prefix));
  record.renderedHtml = html;
}

function flushVisibleMissionContent() {
  for (const record of state.missions.values()) {
    if (!missionContentVisible(record)) continue;
    const pending = record.pendingActivity || [];
    record.pendingActivity = [];
    // Restoring a hidden finished log is one layout pass, not one growing
    // pass per line (which would become quadratic in the retained log size).
    record.deferActivityLayout = true;
    for (const item of pending) appendActivity(record, item.line, item.startedUnixMs);
    record.deferActivityLayout = false;
    if (pending.length) layoutActivity(record);
    if (record.errorsDirty) renderErrors(record);
    if (record.markdownDirty) scheduleMarkdownRender(record, true);
  }
}

function scheduleMarkdownRender(record, immediate = false) {
  record.markdownDirty = true;
  if (!missionContentVisible(record)) {
    window.clearTimeout(record.finalRenderTimer);
    record.finalRenderTimer = null;
    return;
  }
  const render = () => {
    record.finalRenderTimer = null;
    if (!missionContentVisible(record)) return;
    record.finalRenderedAt = Date.now();
    const following = isAtBottom();
    patchMarkdownContent(record);
    record.markdownDirty = false;
    afterCanvasChange(following);
  };
  if (immediate || Date.now() - record.finalRenderedAt >= MARKDOWN_RENDER_MS) {
    window.clearTimeout(record.finalRenderTimer);
    render();
    return;
  }
  if (!record.finalRenderTimer) record.finalRenderTimer = window.setTimeout(render, Math.max(0, MARKDOWN_RENDER_MS - (Date.now() - record.finalRenderedAt)));
}

// "Agentens standard" says nothing ten days later. The header names the model
// the agent actually ran with: the user's pick, else the default the backend
// resolved from configuration or from the agent's own stream, marked as such.
function missionUserMeta(mission) {
  const model = window.AgentSyncStatus?.modelLabel(mission) || mission.model || "modell ikke registrert";
  // A blind run saw the code and none of the other agents' history; the
  // record must say so wherever the run is shown.
  const purpose = missionPurpose(mission);
  const mode = purpose === "validator"
    ? mission.mode === "blind" ? "automatisk blind validering" : "automatisk delt validering"
    : mission.mode === "blind" ? "blind kontroll" : null;
  // Records follow the sync between machines. One written elsewhere reads as
  // local unless it says otherwise, and then a line about "your" run is not
  // about this machine at all.
  const elsewhere = window.AgentSyncSettings?.enabled("record.machine") !== false
    && mission.runtimeHost
    && state.catalog?.runtimeHost
    && mission.runtimeHost !== state.catalog.runtimeHost
    ? `kjørt på ${mission.runtimeHost}`
    : null;
  if (elsewhere && !document.hidden) window.AgentSyncSettings?.used("record.machine");
  const changes = (mission.observedModels || []).map(item => item.model).filter(Boolean);
  const modelChanges = changes.length > 1 ? `registrerte modellnavn underveis: ${changes.join(" → ")}${mission.observedModelsTruncated ? " (eldre navn er forkortet)" : ""}` : null;
  return [mode, model, modelChanges, LEVEL_LABELS[mission.level || ""] || mission.level, projectDisplayName(mission.projectPath), elsewhere].filter(Boolean).join(" · ");
}

function applyMissionStatus(record, mission, changedFiles) {
  const wasActive = record.status === "running" || record.status === "queued";
  record.metadata = Object.fromEntries(["projectPath", "purpose", "mode", "model", "resolvedModel", "modelSource", "level", "runtimeHost", "observedModels", "observedModelsTruncated"]
    .map(key => [key, mission[key] ?? record.metadata?.[key]]));
  const previousPersistenceError = record.persistenceError || "";
  record.agentId = mission.agent || record.agentId;
  record.purpose = missionPurpose(mission);
  record.sourceMissionId = mission.sourceMissionId || record.sourceMissionId || "";
  record.status = mission.status || record.status;
  record.phase = mission.phase || record.phase;
  record.persistenceError = mission.persistenceError || "";
  record.startedUnixMs = Number(mission.startedUnixMs) || record.startedUnixMs;
  if (Number.isFinite(changedFiles)) record.changedFiles = changedFiles;
  for (const node of [record.user, record.agent]) {
    node.dataset.agent = record.agentId;
    node.dataset.purpose = record.purpose;
    if (record.sourceMissionId) node.dataset.sourceMissionId = record.sourceMissionId;
  }
  // The stream may name the model after the header was drawn.
  if (record.userMeta) {
    const text = missionUserMeta(record.metadata);
    if (record.userMeta.textContent !== text) record.userMeta.textContent = text;
  }
  const active = mission.status === "queued" || mission.status === "running";
  record.agent.setAttribute("aria-busy", String(active));
  if (active) {
    record.meta.className = "entry-meta live";
    record.meta.textContent = `${mission.phase || "arbeider"} · ${formatDuration(Date.now() - mission.startedUnixMs)}`;
    return false;
  }
  if (record.finished && previousPersistenceError === record.persistenceError) return false;
  record.finished = true;
  record.finishedUnixMs = Number(mission.finishedUnixMs) || Date.now();
  record.meta.className = "entry-meta";
  record.meta.textContent = formatDuration((mission.finishedUnixMs || Date.now()) - mission.startedUnixMs);
  // The backend phase already reads "Ferdig, …" / "Avbrutt av brukeren";
  // only add a status word when the phase does not carry it.
  const statusWord = mission.status === "completed" ? "Ferdig" : mission.status === "canceled" ? "Avbrutt" : "Feilet";
  const parts = [];
  if (mission.phase && mission.phase.toLowerCase().startsWith(statusWord.toLowerCase())) parts.push(mission.phase);
  else parts.push(statusWord, mission.phase);
  if (Number.isFinite(changedFiles)) parts.push(changedFiles === 1 ? "1 fil endret" : `${changedFiles} filer endret`);
  if (mission.error) parts.push(mission.error);
  if (record.persistenceError) parts.push(`Lagringsfeil: ${record.persistenceError}`);
  record.foot.hidden = false;
  record.foot.className = `entry-foot ${mission.status}`;
  record.foot.replaceChildren(timeElement(mission.finishedUnixMs || Date.now()), parts.filter(Boolean).join(" · "));
  if (wasActive && !record.history && mission.status === "completed" && record.purpose === "writer"
    && !record.persistenceError && samePath(record.projectPath, state.selection.project)) {
    window.AgentSyncActiveMemory?.invalidateAndPrepare?.(record.projectPath);
  }
  return true;
}

// A delta from poll_missions: only the new bytes since the cursors we sent,
// or a full replacement when the backend says reset.
function applyMissionDelta(delta) {
  if (!delta || typeof delta.id !== "string") return;
  let record = state.missions.get(delta.id);
  if (!record) {
    record = ensureMissionBlock({
      id: delta.id,
      projectPath: delta.projectPath,
      prompt: delta.prompt || "",
      agent: delta.agent,
      agentLabel: delta.agentLabel,
      model: delta.model,
      resolvedModel: delta.resolvedModel || null,
      modelSource: delta.modelSource || "unknown",
      mode: delta.mode || "shared",
      purpose: delta.purpose,
      sourceMissionId: delta.sourceMissionId || null,
      level: delta.level,
      status: delta.status,
      phase: delta.phase,
      startedUnixMs: delta.startedUnixMs
    });
  }
  const following = isAtBottom();
  let changed = false;

  if (delta.reset) {
    resetActivity(record);
    record.outputPending = "";
    record.finalOutput = "";
    changed = true;
  }
  if (delta.outputDelta) {
    changed = true;
    const lines = (record.outputPending + delta.outputDelta).split("\n");
    record.outputPending = lines.pop();
    record.deferActivityLayout = true;
    for (const line of lines) if (line) appendActivity(record, line, delta.startedUnixMs);
    record.deferActivityLayout = false;
    if (missionContentVisible(record) && (record.finished || record.activityExpanded)) layoutActivity(record);
  }
  if (delta.finalOutputDelta || delta.reset) {
    changed = true;
    record.finalOutput += delta.finalOutputDelta || "";
    scheduleMarkdownRender(record, false);
  }
  changed = applyTechnicalOutput(record, delta.reset, delta.errorOutputDelta) || changed;
  record.outputBytes = delta.outputBytes;
  record.finalOutputBytes = delta.finalOutputBytes;
  record.errorOutputBytes = delta.errorOutputBytes;
  record.generation = delta.generation;

  if (applyMissionStatus(record, delta, delta.changedFiles)) {
    changed = true;
    if (record.outputPending) {
      appendActivity(record, record.outputPending, delta.startedUnixMs);
      record.outputPending = "";
    }
    layoutActivity(record);
    scheduleMarkdownRender(record, true);
  }
  if (changed) afterCanvasChange(following);
  if (changed) window.dispatchEvent(new CustomEvent("agentsync:mission-text", { detail: { missionId: record.id } }));
}

// Replays the latest finished runs of a project into the canvas so a restart
// does not start from nothing. Each project is replayed once per session and
// runs already on the canvas are skipped.
async function showProjectHistory(path) {
  if (!path || !invoke) return;
  const key = String(path).toLowerCase();
  if (state.historyLoaded.has(key) || state.historyLoading.has(key)) return;
  state.historyLoading.add(key);
  try {
    const payload = await invoke("get_mission_summaries", { request: { projectPath: path, offset: 0, limit: HISTORY_LIMIT } });
    if (!samePath(state.selection.project, path)) return;
    if (payload.warning) canvasNote(`Historikken er ufullstendig: ${payload.warning}`, "warn");
    const finished = (Array.isArray(payload?.history) ? payload.history : [])
      .filter((item) => samePath(item?.projectPath, path) && typeof item?.id === "string" && item.id && !state.missions.has(item.id) && item.status !== "queued" && item.status !== "running")
      .sort((left, right) => (Number(left.startedUnixMs) || 0) - (Number(right.startedUnixMs) || 0));
    const recent = finished.slice(-HISTORY_LIMIT);
    const sessions = [];
    for (const item of recent) {
      const mission = await invoke("get_mission_session", { missionId: item.id });
      if (!samePath(state.selection.project, path)) return;
      if (!mission || typeof mission !== "object" || typeof mission.id !== "string" || !mission.id || state.missions.has(mission.id)) continue;
      sessions.push(mission);
    }
    if (!samePath(state.selection.project, path)) return;
    const notes = readNoteLog(path);
    const timeline = [
      ...sessions.map((mission) => ({ at: Number(mission.startedUnixMs) || 0, mission })),
      ...notes.map((note) => ({ at: Number(note.t) || 0, note }))
    ].sort((left, right) => left.at - right.at);
    if (payload?.hasMore) appendToCanvas(olderHistoryButton(path, (payload.history || []).length));
    if (timeline.length) {
      const divider = tagProjectNode(element("p", "note history-divider"), path);
      const runs = sessions.length === 1 ? "1 oppdrag" : `${sessions.length} oppdrag`;
      const scope = Number(payload.total) > sessions.length ? `${runs} av ${payload.total}` : runs;
      divider.append(timeElement(Date.now()), `Tidligere i ${projectDisplayName(path)} · ${scope}`);
      appendToCanvas(divider);
      for (const item of timeline) {
        if (item.mission) {
          if (state.missions.has(item.mission.id)) continue;
          ensureMissionBlock(item.mission, true);
          renderMission(item.mission);
        } else {
          const note = tagProjectNode(element("p", `note history${item.note.k ? ` ${item.note.k}` : ""}`), path);
          note.append(timeElement(item.at, true), item.note.x);
          appendToCanvas(note);
        }
      }
    }
    // Only a complete, current-project read is cached. Temporary backend
    // errors and fast A -> B project switches can therefore be retried.
    state.historyLoaded.add(key);
  } catch {
    // History is helpful context, not a boot dependency. A later project
    // selection retries it while polling and the rest of the UI stay alive.
  } finally {
    state.historyLoading.delete(key);
  }
}

function appendDelta(record, key, incoming, apply) {
  const previous = typeof record[key] === "string" ? record[key] : "";
  const next = typeof incoming === "string" ? incoming : "";
  if (next === previous) return false;
  const delta = next.startsWith(previous) ? next.slice(previous.length) : null;
  apply(delta, next);
  record[key] = next;
  return true;
}

function renderMission(mission) {
  if (!mission || typeof mission !== "object" || typeof mission.id !== "string" || !mission.id) return;
  const record = ensureMissionBlock(mission);
  const following = isAtBottom();
  let changed = false;

  changed = appendDelta(record, "output", mission.output || "", (delta, full) => {
    if (delta === null) resetActivity(record);
    for (const line of (delta ?? full).split("\n").filter(Boolean)) appendActivity(record, line, mission.startedUnixMs);
  }) || changed;

  changed = appendDelta(record, "finalOutput", mission.finalOutput || "", (_delta, full) => {
    // Parse only visible, changed replies and preserve completed DOM blocks.
    record.finalOutput = full;
    scheduleMarkdownRender(record, true);
    if (record.history && missionContentVisible(record)) {
      // Long replayed replies stay folded until asked for.
      const expanded = record.text.classList.contains("expanded");
      record.text.classList.remove("truncated");
      const truncated = !expanded && record.text.scrollHeight > record.text.clientHeight + 4;
      record.text.classList.toggle("truncated", truncated);
      record.expand.hidden = !truncated;
    }
  }) || changed;

  changed = appendDelta(record, "errorOutput", mission.errorOutput || "", (_delta, full) => {
    record.errorText = full;
    renderErrors(record);
  }) || changed;

  if (applyMissionStatus(record, mission, mission.workspaceAfter?.changedFiles)) {
    changed = true;
    layoutActivity(record);
  }

  if (changed) afterCanvasChange(following);
}

function ensurePolling() {
  if (state.pollTimer) return;
  state.pollTrailing = 0;
  state.pollTimer = window.setTimeout(pollMissions, 50);
}

async function pollMissions() {
  window.clearTimeout(state.pollTimer);
  state.pollTimer = null;
  if (!invoke) return;
  if (state.pollInFlight) return state.pollInFlight;
  state.pollInFlight = pollMissionsOnce();
  try {
    return await state.pollInFlight;
  } finally {
    state.pollInFlight = null;
  }
}

async function pollMissionsOnce() {
  try {
    const known = [...state.missions.values()]
      .filter((record) => !record.history)
      .map((record) => ({
        id: record.id,
        outputBytes: record.outputBytes || 0,
        finalOutputBytes: record.finalOutputBytes || 0,
        errorOutputBytes: record.errorOutputBytes || 0,
        generation: record.generation || 0
      }));
    const deltas = await invoke("poll_missions", { known });
    const list = Array.isArray(deltas) ? deltas : [];
    state.activeMissions = list.map((delta) => ({
      id: delta.id,
      projectPath: delta.projectPath,
      agent: delta.agent,
      agentLabel: delta.agentLabel,
      model: delta.model,
      resolvedModel: delta.resolvedModel,
      modelSource: delta.modelSource || "unknown",
      mode: delta.mode || "shared",
      purpose: missionPurpose(delta),
      sourceMissionId: delta.sourceMissionId || null,
      status: delta.status,
      phase: delta.phase,
      startedUnixMs: delta.startedUnixMs,
      changedFiles: delta.changedFiles
    }));
    for (const delta of list) applyMissionDelta(delta);
    updateRunningControls();
    refreshCanvasFocusVisibility();
  } catch (error) {
    canvasNote(`Kunne ikke lese agentstatus: ${error}`, "error");
  }
  const anyActive = state.activeMissions.some((mission) => mission.status === "queued" || mission.status === "running");
  if (anyActive) {
    state.pollTrailing = 0;
    state.pollTimer = window.setTimeout(pollMissions, document.hidden ? 5000 : POLL_ACTIVE_MS);
  } else if (state.pollTrailing < POLL_TRAILING_ROUNDS) {
    state.pollTrailing += 1;
    state.pollTimer = window.setTimeout(pollMissions, POLL_ACTIVE_MS);
  }
}

// ---------------------------------------------------------------------------
// Theme, zoom and field heights
// ---------------------------------------------------------------------------

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    for (const record of state.missions.values()) {
      if (!record.finalRenderTimer) continue;
      window.clearTimeout(record.finalRenderTimer);
      record.finalRenderTimer = null;
      record.markdownDirty = true;
    }
    return;
  }
  flushVisibleMissionContent();
  renderRail();
  ensurePolling();
});

function applyTheme(theme, persist = true) {
  const selected = theme === "light" ? "light" : "dark";
  document.documentElement.dataset.theme = selected;
  document.querySelector('meta[name="color-scheme"]')?.setAttribute("content", selected);
  if (persist) writePreference("agentsync.theme", selected);
}

byId("themeToggle").addEventListener("click", () => {
  applyTheme(document.documentElement.dataset.theme === "light" ? "dark" : "light");
});

function normalizeZoom(value) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) return 100;
  return Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, Math.round(parsed / ZOOM_STEP) * ZOOM_STEP));
}

function applyZoom(value, persist = true) {
  const zoom = normalizeZoom(value);
  document.documentElement.style.zoom = String(zoom / 100);
  byId("zoomValue").textContent = `${zoom}%`;
  tip(byId("zoomReset"), zoom === 100
    ? "Tekststørrelse 100 %"
    : `Tekststørrelse ${zoom} %. Klikk for å tilbakestille`, "Zoom");
  if (persist) writePreference("agentsync.zoom", String(zoom));
  return zoom;
}

function shiftZoom(direction) {
  const current = normalizeZoom(readPreference("agentsync.zoom", "100"));
  applyZoom(current + direction * ZOOM_STEP);
}

byId("zoomOut").addEventListener("click", () => shiftZoom(-1));
byId("zoomReset").addEventListener("click", () => applyZoom(100));
byId("zoomIn").addEventListener("click", () => shiftZoom(1));

const FIELD_HEIGHT_KEYS = { instructionInput: "agentsync.v4.height.instruction" };

function restoreFieldHeights() {
  for (const [id, key] of Object.entries(FIELD_HEIGHT_KEYS)) {
    const stored = Number.parseInt(readPreference(key, ""), 10);
    if (Number.isFinite(stored) && stored >= 44) byId(id).style.height = `${stored}px`;
  }
}

function watchFieldHeights() {
  if (typeof window.ResizeObserver !== "function") return;
  const timers = new Map();
  const observer = new window.ResizeObserver((entries) => {
    for (const entry of entries) {
      const field = entry.target;
      if (!field.style.height) continue;
      window.clearTimeout(timers.get(field.id));
      timers.set(field.id, window.setTimeout(() => {
        writePreference(FIELD_HEIGHT_KEYS[field.id], String(Math.round(field.getBoundingClientRect().height / currentZoomFactor())));
      }, 300));
    }
  });
  observer.observe(instructionInput);
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

intentInput.addEventListener("click", () => {
  if (!projectByPath(state.selection.project)) setDrawerOpen(true);
});

function syncIntentWritingState() {
  const writing = document.activeElement === intentInput && Boolean(intentInput.value.trim());
  byId("topBar").classList.toggle("intent-writing", writing);
}

intentInput.addEventListener("focus", syncIntentWritingState);
intentInput.addEventListener("input", syncIntentWritingState);
intentInput.addEventListener("blur", syncIntentWritingState);

intentInput.addEventListener("keydown", (event) => {
  if (event.isComposing) return;
  if (!projectByPath(state.selection.project)) {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      setDrawerOpen(true);
    }
    return;
  }
  if (event.key === "Enter") {
    event.preventDefault();
    resolveIntent();
  } else if (event.key === "Escape") {
    if (state.setupMode === "choosing") leaveChoosing();
    else if (state.setupMode === "resolving") {
      cancelResolving();
      renderSetupBar();
    } else {
      intentInput.value = "";
      syncIntentWritingState();
    }
  }
});

byId("setupBar").addEventListener("keydown", (event) => {
  const bubbles = [...byId("setupBar").querySelectorAll(".bubble")];
  if (!bubbles.length) return;
  const current = Math.max(0, bubbles.indexOf(document.activeElement));
  let next = null;
  if (event.key === "ArrowRight" || event.key === "ArrowDown") next = (current + 1) % bubbles.length;
  else if (event.key === "ArrowLeft" || event.key === "ArrowUp") next = (current - 1 + bubbles.length) % bubbles.length;
  else if (event.key === "Home") next = 0;
  else if (event.key === "End") next = bubbles.length - 1;
  if (next !== null) {
    event.preventDefault();
    bubbles[next].focus();
    bubbles[next].scrollIntoView({ block: "nearest", inline: "nearest" });
  }
});

byId("setupBar").addEventListener("wheel", (event) => {
  const setup = byId("setupBar");
  if (state.setupMode !== "choosing" || setup.scrollWidth <= setup.clientWidth || Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
  event.preventDefault();
  setup.scrollLeft += event.deltaY;
}, { passive: false });
byId("setupBar").addEventListener("scroll", updateSetupOverflowCue);

instructionInput.addEventListener("keydown", (event) => {
  if (event.isComposing) return;
  if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
    event.preventDefault();
    startMission({ skipScope: event.shiftKey });
  }
});

instructionInput.addEventListener("input", syncProjectGate);
// The readings belong to the prompt they were computed for.
instructionInput.addEventListener("input", closeScopeStrip);
byId("scopeStrip").addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault();
    closeScopeStrip();
    instructionInput.focus();
  }
});
byId("missionStartButton").addEventListener("click", startMission);

document.addEventListener("keydown", (event) => {
  if (event.altKey && !event.ctrlKey && !event.metaKey && event.code === "KeyQ" && !event.repeat && !event.isComposing) {
    event.preventDefault();
    cycleCanvasFocus(event.shiftKey);
    return;
  }
  if (event.ctrlKey && !event.altKey) {
    if (event.key === "+" || event.key === "=") {
      event.preventDefault();
      shiftZoom(1);
      return;
    }
    if (event.key === "-") {
      event.preventDefault();
      shiftZoom(-1);
      return;
    }
    if (event.key === "0") {
      event.preventDefault();
      applyZoom(100);
      return;
    }
    if (event.key.toLowerCase() === "o") {
      event.preventDefault();
      if (!projectByPath(state.selection.project)) setDrawerOpen(true);
      else if (state.setupMode === "choosing") leaveChoosing();
      else enterChoosing(agentChoices(), "agenter", false, "agents");
      return;
    }
    if (event.key.toLowerCase() === "k") {
      event.preventDefault();
      if (projectByPath(state.selection.project)) intentInput.focus();
      else setDrawerOpen(true);
      return;
    }
    if (event.key.toLowerCase() === "p") {
      event.preventDefault();
      toggleDrawer();
      return;
    }
  }
  if (event.key !== "Escape") return;
  if (state.barInfo) {
    closeBarInfo();
    intentInput.focus();
  } else if (state.setupMode === "choosing" && byId("setupBar").contains(document.activeElement)) {
    leaveChoosing();
  } else if (drawerOpen() && drawer.contains(document.activeElement)) {
    setDrawerOpen(false);
    instructionInput.focus();
  }
});

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

// The controls that live in the markup rather than in a render function. The
// native title attribute is gone from index.html, so these are wired once here
// instead. Anything that changes with state is wired where it is drawn.
const FIXED_TIPS = [
  ["projectDrawerClose", "Skyv prosjektvinduet inn (Ctrl+P)", "Prosjekter"],
  ["activeMemoryButton", "Kort, lokal inngang til prosjektets kontekst og kilder. Starter ingen modell.", "Prosjektminne"],
  ["railToggle", "Åpne eller lukk prosjektvinduet (Ctrl+P)", "Prosjekter"],
  ["railKnowledgeButton", "Åpne eller lukk kunnskapsutkastene. Starter ingen modell.", "Kunnskapsutkast"],
  ["railEvaluationsButton", "Funn og avklaringer. Starter ingen agent.", "Register"],
  ["railSettingsButton", "Brytere for hva appen gjør og viser. Starter ingen agent.", "Innstillinger"],
  ["barInfoClose", "Lukk informasjonen (Escape)", ""],
  ["zoomOut", "Mindre tekst (Ctrl+-)", "Tekststørrelse"],
  ["zoomIn", "Større tekst (Ctrl++)", "Tekststørrelse"],
  ["themeToggle", "Bytt mellom natt og dag", "Tema"],
  ["settingsReset", "Sett appbryterne tilbake til standard. Endrer ikke ekstern driftsvakt eller prosjektminne.", "Innstillinger"],
  ["settingsClose", "Lukk bryterne (Escape)", ""],
  ["controlPanelClose", "Lukk og slå av valideringsagenten (Escape)", "Valideringsagent"],
  ["controlPanelMove", "Dra fireveisgrepet for å flytte. Piltaster flytter kontrollert.", "Panel"],
];

async function boot() {
  for (const [id, text, head] of FIXED_TIPS) tip(byId(id), text, head);
  applyTheme(readPreference("agentsync.theme", "dark"), false);
  applyZoom(readPreference("agentsync.zoom", "100"), false);
  restoreFieldHeights();
  watchFieldHeights();
  watchCanvasSize();

  if (!invoke) {
    canvasNote("Tauri-broen er ikke tilgjengelig. Start siden gjennom AgentSync Max.", "error");
    return;
  }

  window.__TAURI__?.event?.listen?.("engine-event", (event) => {
    if (event.payload?.reason === "close-blocked") {
      canvasNote(event.payload?.message || "Appen kan ikke lukkes mens et oppdrag arbeider eller en lagring venter. La arbeidet bli ferdig, eller avbryt oppdraget først.", "error");
    }
  })?.catch((error) => console.warn("Could not listen for engine notices", error));

  await loadCatalog(true);
  restoreSelection();
  window.AgentSyncActiveMemory?.projectChanged?.(state.selection.project);
  window.AgentSyncActiveMemory?.prepare?.(state.selection.project);
  renderAll();
  // The drawer stays where the user left it; without a project it slides out
  // so the first step is obvious.
  if (readPreference("agentsync.v4.drawerOpen") || !state.selection.project) setDrawerOpen(true, false);
  await showProjectHistory(state.selection.project);
  // A project without an agent has no reusable setup. Avoid writing a noisy
  // "ingen agent / standardmodell" line every time the app opens.
  if (state.selection.project && state.selection.agent) {
    const note = tagProjectNode(element("p", "note setup"));
    note.append(timeElement(Date.now()), "Oppsett: ", element("b", "", setupSummary()), element("span", "source", " (husket fra sist)"));
    appendToCanvas(note);
    // Deliberately not remembered: it is written fresh on every start.
  }
  await pollMissions();
  pollValidatorControl();
  loadStatusChips();
  // The awaits above take milliseconds in Tauri and seconds in the mock; in
  // either case a user who has already put the cursor somewhere - the
  // instruction field, a scope strip - must not have it yanked away here.
  const active = document.activeElement;
  if (active && active !== document.body) return;
  if (drawerOpen() && !state.selection.project) byId("projectSearch").focus();
  else intentInput.focus();
}

boot();
