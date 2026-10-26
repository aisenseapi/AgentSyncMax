const invoke = window.__TAURI__?.core?.invoke;
const listen = window.__TAURI__?.event?.listen;

const agents = [
  { key: "Claude", slug: "claude", label: "Claude", mark: "✳" },
  { key: "Codex", slug: "codex", label: "Codex", mark: "◉" },
  { key: "Antigravity", slug: "antigravity", label: "Antigravity", mark: "A" },
  { key: "OpenCode", slug: "opencode", label: "OpenCode", mark: "OC" },
  { key: "Cline", slug: "cline", label: "Cline", mark: "C" }
];
const missionAgentVisuals = [
  ...agents,
  { key: "Aider", slug: "aider", label: "Aider", mark: "ai" }
];

const state = {
  payload: null,
  activeView: "mission",
  loading: false,
  dismissedEngineEventId: null,
  missionControl: null,
  missionWorkspace: null,
  selectedMissionAgent: null,
  missionLoading: false,
  missionProjects: [],
  conversationAgentFilter: "all",
  conversationSessionCache: {},
  pendingForceRequest: null,
  sparkModelNames: null,
  selectedProjectPath: "",
  projectSidebarSignature: "",
  missionFocusOpen: false,
  missionFocusMission: null,
  missionFocusResponseMissionId: null,
  missionFocusResponseFollow: true,
  missionSessionLoading: null,
  lastObservedMissionId: null,
  missionDockSignature: "",
  missionPromptHistorySignature: "",
  missionArchiveOpen: false,
  missionFocusReturn: null,
  missionArchiveReturn: null,
  recoveryProjects: [],
  statusProjects: [],
  intelligenceSessions: [],
  intelligenceVisible: 50,
  diffViewMode: "unified",
  sparkModels: [],
  selectedSparkModel: "qwen3-coder-next:q8_0",
  codeReviewLoading: false,
  codeReviewLoadingMissionId: null,
  codeReviewResult: null,
  activeDiffText: "",
  diffSignatures: {}
};
const byId = (id) => document.getElementById(id);
const pick = (object, ...keys) => {
  for (const key of keys) if (object && object[key] !== undefined && object[key] !== null) return object[key];
  return undefined;
};
const array = (value) => Array.isArray(value) ? value : [];
const number = (value) => Number(value || 0);
const escapeHtml = (value) => String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);
const displayPath = (value) => String(value || "").replace(/^\\\\\?\\/, "");
const plural = (count, singular, pluralForm = `${singular}er`) => `${number(count).toLocaleString("nb-NO")} ${number(count) === 1 ? singular : pluralForm}`;

function formatCompactDate(value) {
  if (!value) return "Ukjent tid";
  const date = new Date(number(value) || value);
  if (Number.isNaN(date.getTime())) return "Ukjent tid";
  return new Intl.DateTimeFormat("nb-NO", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }).format(date);
}

function markdownToHtml(value) {
  const escaped = escapeHtml(value || "");
  const codeBlocks = [];
  let text = escaped.replace(/```([^\n]*)\n([\s\S]*?)```/g, (_match, language, code) => {
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
    if (table.headers.length) {
      html += `<thead><tr>${table.headers.map((h) => `<th>${inline(h)}</th>`).join("")}</tr></thead>`;
    }
    if (table.rows.length) {
      html += `<tbody>${table.rows.map((row) => `<tr>${row.map((cell) => `<td>${inline(cell)}</td>`).join("")}</tr>`).join("")}</tbody>`;
    }
    html += '</table></div>';
    blocks.push(html);
    table = null;
  };

  const flushQuote = () => {
    if (!quote) return;
    if (quote.alertType) {
      const typeClass = quote.alertType.toLowerCase();
      blocks.push(`<div class="markdown-alert markdown-alert-${typeClass}"><div class="alert-title"><span class="alert-icon">!</span><strong>${escapeHtml(quote.alertType)}</strong></div><div class="alert-content">${quote.lines.map((l) => `<p>${inline(l)}</p>`).join("")}</div></div>`);
    } else {
      blocks.push(`<blockquote>${quote.lines.map((l) => `<p>${inline(l)}</p>`).join("")}</blockquote>`);
    }
    quote = null;
  };

  const flushAll = () => {
    flushList();
    flushTable();
    flushQuote();
  };

  for (let i = 0; i < lines.length; i++) {
    const rawLine = lines[i];
    const line = rawLine.trimEnd();
    const trimmed = line.trim();

    const codeToken = trimmed.match(/^@@CODEBLOCK(\d+)@@$/);
    if (codeToken) {
      flushAll();
      blocks.push(codeBlocks[number(codeToken[1])]);
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
    } else {
      flushQuote();
    }

    if (trimmed.startsWith("|") && trimmed.endsWith("|")) {
      flushList();
      const cells = trimmed.split("|").slice(1, -1).map((c) => c.trim());
      const isSeparator = cells.every((c) => /^:?-+:?$/.test(c));
      if (!table) {
        table = { headers: cells, rows: [] };
      } else if (!isSeparator) {
        table.rows.push(cells);
      }
      continue;
    } else {
      flushTable();
    }

    const heading = line.match(/^(#{1,4})\s+(.+)$/);
    if (heading) {
      flushAll();
      const level = heading[1].length;
      blocks.push(`<h${level}>${inline(heading[2])}</h${level}>`);
      continue;
    }

    const taskMatch = line.match(/^\s*[-*]\s+\[([ xX])\]\s+(.+)$/);
    if (taskMatch) {
      flushTable();
      flushQuote();
      const checked = taskMatch[1].toLowerCase() === "x";
      const itemContent = `<input type="checkbox" ${checked ? "checked" : ""} disabled> ${inline(taskMatch[2])}`;
      if (!list || list.type !== "ul") {
        flushList();
        list = { type: "ul", items: [] };
      }
      list.items.push(itemContent);
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
    } else {
      flushList();
    }

    if (!trimmed) continue;
    blocks.push(`<p>${inline(line)}</p>`);
  }

  flushAll();
  return blocks.join("") || "<p>Ingen tekst registrert.</p>";
}

// Interface zoom. CSS zoom scales the whole surface proportionally - text,
// icons and layout together - so high factors stay coherent instead of only
// inflating fonts inside fixed boxes.
const ZOOM_MIN = 50;
const ZOOM_MAX = 200;
const ZOOM_STEP = 10;
const legacyFontSizeZoom = { small: 90, normal: 100, large: 120, xlarge: 130 };
let activePeekPanel = null;
let activePeekPlaceholder = null;
let peekOpenTimer = null;
let peekCloseTimer = null;
let peekMinimumTimer = null;
let peekMinimumElapsed = false;
const panelPeekResizeObserver = typeof window.ResizeObserver === "function"
  ? new window.ResizeObserver((entries) => entries.forEach((entry) => updatePanelPeekEligibility(entry.target)))
  : null;

function readPreference(key, fallback) {
  try { return window.localStorage.getItem(key) || fallback; } catch { return fallback; }
}

function writePreference(key, value) {
  try { window.localStorage.setItem(key, value); } catch { /* Preferences remain session-local. */ }
}

function applyTheme(theme, persist = true) {
  const selected = theme === "light" ? "light" : "dark";
  document.documentElement.dataset.theme = selected;
  document.querySelector('meta[name="color-scheme"]')?.setAttribute("content", selected);
  const isLight = selected === "light";
  byId("themeIcon").textContent = isLight ? "☾" : "☀";
  byId("themeToggle").setAttribute("aria-label", isLight ? "Bytt til mørkt tema" : "Bytt til lyst tema");
  byId("themeToggle").setAttribute("aria-pressed", String(isLight));
  if (persist) writePreference("agentsync.theme", selected);
}

// User-resizable panels (native bottom-right grip via CSS resize) and the
// sidebar width handle. Sizes persist per viewer in localStorage.
const RESIZABLE_PANEL_IDS = ["conversationTimeline", "missionOutput", "missionFinalOutput", "missionErrors", "missionDiffContainer"];
const SIDEBAR_MIN_WIDTH = 180;
const SIDEBAR_MAX_WIDTH = 620;

function currentZoomFactor() {
  const zoom = Number.parseFloat(document.documentElement.style.zoom || "1");
  return Number.isFinite(zoom) && zoom > 0 ? zoom : 1;
}

function restorePanelSizes() {
  for (const id of RESIZABLE_PANEL_IDS) {
    const element = byId(id);
    const stored = Number.parseInt(readPreference(`agentsync.panelHeight.${id}`, ""), 10);
    if (element && Number.isFinite(stored) && stored >= 80) element.style.height = `${stored}px`;
  }
  const sidebarWidth = Number.parseInt(readPreference("agentsync.sidebarWidth", ""), 10);
  if (Number.isFinite(sidebarWidth)) applySidebarWidth(sidebarWidth, false);
}

function watchPanelSizes() {
  if (typeof window.ResizeObserver !== "function") return;
  const timers = new Map();
  const observer = new window.ResizeObserver((entries) => {
    for (const entry of entries) {
      const element = entry.target;
      // Only sizes the user set through the grip live as inline height.
      if (!element.style.height) continue;
      window.clearTimeout(timers.get(element.id));
      timers.set(element.id, window.setTimeout(() => {
        writePreference(`agentsync.panelHeight.${element.id}`, String(Math.round(element.getBoundingClientRect().height / currentZoomFactor())));
      }, 300));
    }
  });
  for (const id of RESIZABLE_PANEL_IDS) {
    const element = byId(id);
    if (element) observer.observe(element);
  }
}

function applySidebarWidth(width, persist = true) {
  const clamped = Math.min(SIDEBAR_MAX_WIDTH, Math.max(SIDEBAR_MIN_WIDTH, Math.round(width)));
  document.documentElement.style.setProperty("--project-sidebar-width", `${clamped}px`);
  if (persist) writePreference("agentsync.sidebarWidth", String(clamped));
}

function resetSidebarWidth() {
  document.documentElement.style.removeProperty("--project-sidebar-width");
  try { window.localStorage.removeItem("agentsync.sidebarWidth"); } catch { /* session-local */ }
}

function wireSidebarResizer() {
  const handle = byId("projectSidebarResizer");
  const sidebar = byId("projectSidebar");
  if (!handle || !sidebar) return;
  let dragging = false;
  handle.addEventListener("pointerdown", (event) => {
    if (document.body.classList.contains("project-sidebar-collapsed")) return;
    dragging = true;
    handle.setPointerCapture(event.pointerId);
    document.body.classList.add("is-resizing-sidebar");
    event.preventDefault();
  });
  handle.addEventListener("pointermove", (event) => {
    if (!dragging) return;
    // The sidebar starts at the window's left edge, so the pointer's x in
    // layout pixels is the new width. Divide by the interface zoom because
    // pointer coordinates are reported in unzoomed device space.
    applySidebarWidth(event.clientX / currentZoomFactor(), false);
  });
  const stop = () => {
    if (!dragging) return;
    dragging = false;
    document.body.classList.remove("is-resizing-sidebar");
    const width = Number.parseFloat(getComputedStyle(sidebar).width);
    if (Number.isFinite(width)) applySidebarWidth(width);
  };
  handle.addEventListener("pointerup", stop);
  handle.addEventListener("pointercancel", stop);
  handle.addEventListener("dblclick", resetSidebarWidth);
}

function normalizeZoom(value) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) return 100;
  return Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, Math.round(parsed / ZOOM_STEP) * ZOOM_STEP));
}

function applyZoom(value, persist = true) {
  const migrated = Object.prototype.hasOwnProperty.call(legacyFontSizeZoom, value)
    ? legacyFontSizeZoom[value]
    : value;
  const zoom = normalizeZoom(migrated);
  document.documentElement.style.zoom = String(zoom / 100);
  byId("fontSizeValue").textContent = `${zoom}%`;
  byId("fontDecrease").disabled = zoom <= ZOOM_MIN;
  byId("fontIncrease").disabled = zoom >= ZOOM_MAX;
  if (persist) writePreference("agentsync.zoom", String(zoom));
}

function shiftFontSize(direction) {
  const current = normalizeZoom(byId("fontSizeValue").textContent);
  applyZoom(current + direction * ZOOM_STEP);
}

function updatePanelPeekEligibility(panel) {
  const button = panel.querySelector(":scope > .panel-peek");
  if (!button) return;
  if (panel === activePeekPanel) {
    button.hidden = true;
    return;
  }
  const rect = panel.getBoundingClientRect();
  const appArea = Math.max(1, document.documentElement.clientWidth * document.documentElement.clientHeight);
  const panelArea = Math.max(0, rect.width * rect.height);
  button.hidden = panelArea === 0 || panelArea / appArea >= 0.75;
}

function updatePanelPeekEligibilityForAll() {
  document.querySelectorAll(".panel").forEach(updatePanelPeekEligibility);
}

function closePanelPeek(force = false) {
  window.clearTimeout(peekOpenTimer);
  window.clearTimeout(peekCloseTimer);
  if (activePeekPanel && !force && !peekMinimumElapsed) return;
  window.clearTimeout(peekMinimumTimer);
  if (!activePeekPanel) return;
  const closedPanel = activePeekPanel;
  closedPanel.classList.remove("is-peeking");
  closedPanel.querySelector(":scope > .panel-peek")?.setAttribute("aria-expanded", "false");
  activePeekPanel = null;
  activePeekPlaceholder?.remove();
  activePeekPlaceholder = null;
  peekMinimumElapsed = false;
  document.body.classList.remove("panel-peek-active");
  updatePanelPeekEligibility(closedPanel);
}

function openPanelPeek(panel) {
  window.clearTimeout(peekOpenTimer);
  window.clearTimeout(peekCloseTimer);
  window.clearTimeout(peekMinimumTimer);
  if (activePeekPanel === panel) return;
  if (activePeekPanel) closePanelPeek(true);
  closeDetail();
  if (!activePeekPlaceholder) {
    const panelRect = panel.getBoundingClientRect();
    activePeekPlaceholder = document.createElement("div");
    activePeekPlaceholder.className = "panel-peek-placeholder";
    activePeekPlaceholder.style.height = `${panelRect.height}px`;
    panel.parentNode.insertBefore(activePeekPlaceholder, panel);
  }
  activePeekPanel = panel;
  peekMinimumElapsed = false;
  panel.querySelector(":scope > .panel-peek").hidden = false;
  panel.classList.add("is-peeking");
  panel.querySelector(":scope > .panel-peek")?.setAttribute("aria-expanded", "true");
  panel.querySelector(":scope > .panel-peek").hidden = true;
  document.body.classList.add("panel-peek-active");
  peekMinimumTimer = window.setTimeout(() => {
    peekMinimumElapsed = true;
    if (!panel.matches(":hover")) closePanelPeek();
  }, 1200);
}

function enhancePanelsWithPeek() {
  document.querySelectorAll(".panel").forEach((panel) => {
    if (panel.querySelector(":scope > .panel-peek")) return;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "panel-peek";
    button.innerHTML = '<span aria-hidden="true">⤢</span>';
    button.setAttribute("aria-label", "Forstørr panelet midlertidig");
    button.setAttribute("aria-expanded", "false");
    button.title = "Hold pekeren her for fokus. Panelet forblir stort i minst 1,2 sekunder.";
    panel.appendChild(button);
    panelPeekResizeObserver?.observe(panel);
    updatePanelPeekEligibility(panel);

    button.addEventListener("mouseenter", () => {
      window.clearTimeout(peekCloseTimer);
      peekOpenTimer = window.setTimeout(() => openPanelPeek(panel), 240);
    });
    button.addEventListener("mouseleave", () => window.clearTimeout(peekOpenTimer));
    button.addEventListener("focus", () => openPanelPeek(panel));
    button.addEventListener("blur", () => {
      peekCloseTimer = window.setTimeout(closePanelPeek, 140);
    });
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      if (activePeekPanel === panel) {
        closePanelPeek();
      } else {
        openPanelPeek(panel);
      }
    });
    panel.addEventListener("mouseenter", () => window.clearTimeout(peekCloseTimer));
    panel.addEventListener("mouseleave", () => {
      peekCloseTimer = window.setTimeout(closePanelPeek, 140);
    });
  });
}

function initializeUxControls() {
  applyTheme(readPreference("agentsync.theme", "dark"), false);
  // New numeric preference wins; the old discrete font-size key migrates
  // through the legacy map inside applyZoom.
  applyZoom(readPreference("agentsync.zoom", readPreference("agentsync.fontSize", "100")), false);
  restorePanelSizes();
  state.selectedSparkModel = readPreference(
    "agentsync.sparkModel",
    readPreference("agentsync_spark_model", "qwen3-coder-next:q8_0")
  );
  enhancePanelsWithPeek();
}

function formatBytes(bytes) {
  let value = number(bytes);
  const units = ["B", "KB", "MB", "GB", "TB"];
  let index = 0;
  while (value >= 1024 && index < units.length - 1) { value /= 1024; index += 1; }
  return `${value.toLocaleString("nb-NO", { maximumFractionDigits: index ? 1 : 0 })} ${units[index]}`;
}

function formatDate(value) {
  if (!value) return "Ikke registrert";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return new Intl.DateTimeFormat("nb-NO", { dateStyle: "short", timeStyle: "medium" }).format(date);
}

function ageSeconds(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? Infinity : Math.max(0, (Date.now() - date.getTime()) / 1000);
}

function agentTag(agent, metric, interactive = true) {
  const files = number(pick(metric, "Files", "files"));
  if (!files) return "";
  const model = pick(metric, "Model", "model") || "Ikke registrert";
  const provider = pick(metric, "Provider", "provider") || "Ikke registrert";
  const sessions = number(pick(metric, "Sessions", "sessions"));
  const bytes = number(pick(metric, "Bytes", "bytes"));
  const tag = `<span class="agent-mark" aria-hidden="true">${escapeHtml(agent.mark)}</span>${escapeHtml(agent.label)}`;
  if (!interactive) return `<span class="agent-tag ${agent.slug}">${tag}</span>`;
  const detail = encodeURIComponent(JSON.stringify({
    kicker: "Agentkobling",
    title: agent.label,
    description: "Provider-native state registrert for denne eksakte prosjektmappen.",
    rows: [["Sist registrerte modell", model], ["Provider", provider], ["Sesjoner", sessions], ["State-filer", files], ["Datamengde", formatBytes(bytes)]]
  }));
  return `<button type="button" class="agent-tag ${agent.slug} detail-button" data-detail="${detail}">${tag}</button>`;
}

function metricCard(label, value, note = "", detailOverride = {}) {
  const detail = encodeURIComponent(JSON.stringify({
    kicker: detailOverride.kicker || "Nøkkeltall",
    title: detailOverride.title || label,
    description: detailOverride.description || note || "Avledet metadata fra AgentSync sine lokale rapporter.",
    rows: detailOverride.rows || [["Verdi", value], ["Datakilde", "AgentSync metadata"]]
  }));
  return `<button type="button" class="metric-card detail-button" data-detail="${detail}"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong>${note ? `<small>${escapeHtml(note)}</small>` : ""}</button>`;
}

function showMessage(message, type = "") {
  const area = byId("messageArea");
  area.textContent = message;
  area.className = `message-area ${type}`;
  area.hidden = false;
  window.clearTimeout(showMessage.timeout);
  showMessage.timeout = window.setTimeout(() => { area.hidden = true; }, 7000);
}

function showEngineEvent(event) {
  if (!event || event.id === state.dismissedEngineEventId) return;
  const notice = byId("engineNotice");
  const failed = event.level === "error";
  notice.className = `engine-notice${failed ? " error" : ""}`;
  notice.dataset.eventId = String(event.id);
  byId("engineNoticeTitle").textContent = failed
    ? "AgentSync kunne ikke starte automatisk"
    : event.reason === "startup"
      ? "AgentSync ble startet automatisk ved åpning"
      : "AgentSync ble startet automatisk på nytt";
  byId("engineNoticeText").textContent = event.message || "Motorstatusen ble endret automatisk.";
  byId("engineNoticeTime").textContent = `Registrert ${formatDate(event.occurredUnixMs)}`;
  notice.hidden = false;
}

function setServiceState(status, engine) {
  const pill = byId("servicePill");
  const generated = pick(status, "generatedUtc");
  const staleAfter = number(pick(status, "staleAfterSeconds")) || 180;
  const age = ageSeconds(generated);
  if (engine?.isRunning) {
    pill.className = "service-pill ok";
    pill.querySelector("span").textContent = "AgentSync kjører";
  } else if (!generated) {
    pill.className = "service-pill warn";
    pill.querySelector("span").textContent = "Status mangler";
  } else if (age > staleAfter) {
    pill.className = "service-pill warn";
    pill.querySelector("span").textContent = "Status er gammel";
  } else {
    pill.className = "service-pill ok";
    pill.querySelector("span").textContent = "AgentSync kjører";
  }
  byId("startButton").hidden = Boolean(engine?.isRunning);
}

function renderStatus(documentState) {
  const status = documentState?.data || {};
  const summary = status.summary || {};
  const projects = array(status.projects);
  state.statusProjects = projects;
  setServiceState(status, state.payload?.engine);
  byId("statusGenerated").textContent = pick(status, "generatedUtc") ? `${status.fallback ? "Midlertidig visning fra Recovery" : "Generert"} ${formatDate(status.generatedUtc)} på ${status.machine || "ukjent maskin"}` : "AgentSync-Status.json finnes ikke ennå";
  byId("footerMachine").textContent = status.machine || "Lokal kontrollflate";

  const cards = [
    ["Agentprosjekter", number(summary.projects), "eksakte prosjektmapper"],
    ["Kun én agent", number(summary.singleAgent), "én provider-kobling"],
    ["Flere agenter", number(summary.multiAgent), "to eller flere"],
    ["Agentfiler", number(summary.files).toLocaleString("nb-NO"), "lokalt bevart agenttilstand"],
    ["Samlet størrelse", formatBytes(summary.bytes), "uten samtaleinnhold i UI"],
    ["Uten prosjektsti", number(summary.unresolved), "trenger metadata"],
    ["Konfliktkopier", number(summary.conflicts).toLocaleString("nb-NO"), "bevarte synkspor", {
      kicker: "Bevarte synkspor",
      title: "Konfliktkopier",
      description: "Dette er kopier AgentSync har bevart da to synkkilder hadde ulikt innhold. De er ikke Git-konflikter og stopper ikke prosjektene. Tallet kan vokse over tid fordi sporene beholdes for recovery.",
      rows: [["Bevarte kopier", number(summary.conflicts).toLocaleString("nb-NO")], ["Påvirker Git", "Nei"], ["Anbefalt handling", "Undersøk bare hvis Recovery viser et konkret problem"]]
    }]
  ];
  const cardGrid = byId("statusCards");
  cardGrid.classList.remove("skeleton-grid");
  cardGrid.innerHTML = cards.map((item) => metricCard(...item)).join("");

  renderAudit(array(status.selfAudit));
  renderProjects(projects);
  renderMissionProjectOptions(projects);
  renderProjectSidebar();
}

function renderAudit(rows) {
  const grid = byId("auditGrid");
  const summary = byId("auditSummary");
  if (!rows.length) {
    grid.className = "audit-grid empty-state";
    grid.textContent = "Ingen selvkontroll er tilgjengelig.";
    summary.className = "state-chip neutral";
    summary.textContent = "Ikke tilgjengelig";
    return;
  }
  grid.className = "audit-grid";
  let worst = "ok";
  grid.innerHTML = rows.map((row) => {
    const agent = agents.find((item) => item.label.toLowerCase() === String(pick(row, "Agent", "agent")).toLowerCase()) || { slug: "", label: pick(row, "Agent", "agent"), mark: "•" };
    const statusClass = pick(row, "StatusClass", "statusClass") || "ok";
    if (statusClass === "error") worst = "error";
    else if (statusClass === "warn" && worst !== "error") worst = "warn";
    const missing = number(pick(row, "MissingCount", "missingCount"));
    const unavailable = number(pick(row, "UnavailableCount", "unavailableCount"));
    const noMetadata = number(pick(row, "NoMetadata", "noMetadata"));
    const label = statusClass === "error" ? "Mangler prosjekt" : statusClass === "warn" ? (unavailable ? "Gammel prosjektsti" : "Mangler metadata") : "Alt stemmer";
    const missingPaths = array(pick(row, "MissingProjects", "missingProjects"));
    const unavailablePaths = array(pick(row, "UnavailableProjects", "unavailableProjects"));
    const outsidePaths = array(pick(row, "OutsideProjectPaths", "outsideProjectPaths"));
    const rows = [["Lokalt oppdaget", pick(row, "LocalProjects", "localProjects")], ["Vist i rapporten", pick(row, "ReportProjects", "reportProjects")], ["Mangler", missing], ["Gamle stier", unavailable], ["Uten metadata", noMetadata], ["Utenfor synkeroten", number(pick(row, "OutsideProjects", "outsideProjects"))]];
    if (missingPaths.length) rows.push(["Manglende koblinger", missingPaths.join(" · ")]);
    if (unavailablePaths.length) rows.push(["Stier som ikke finnes", unavailablePaths.join(" · ")]);
    if (outsidePaths.length) rows.push(["Stier utenfor synkeroten", outsidePaths.join(" · ")]);
    if (noMetadata) rows.push(["Hva betyr dette", "Agenten er funnet, men minst én post mangler nok cwd/workspace til å vise en sikker prosjektsti."]);
    const detail = encodeURIComponent(JSON.stringify({ kicker: "Fast selvkontroll", title: `${agent.label}-kontroll`, description: statusClass === "ok" ? "Alle oppdagede prosjektkoblinger er representert i rapporten." : "Kontrollen viser det konkrete avviket og hvilke stier som er berørt når de er tilgjengelige.", rows }));
    return `<button type="button" class="audit-card detail-button" data-detail="${detail}">${agentTag(agent, { Files: 1 }, false)}<strong>${number(pick(row, "LocalProjects", "localProjects"))} / ${number(pick(row, "ReportProjects", "reportProjects"))}</strong><small>lokalt oppdaget / vist</small><span class="audit-state ${statusClass}">${escapeHtml(label)}</span></button>`;
  }).join("");
  summary.className = `state-chip ${worst}`;
  summary.textContent = worst === "ok" ? "Alt stemmer" : worst === "warn" ? "Trenger oppmerksomhet" : "Mangler koblinger";
}

function projectAgentData(row) {
  return agents.map((agent) => ({ agent, metric: pick(row, agent.key, agent.key.toLowerCase()) || {} })).filter((item) => number(pick(item.metric, "Files", "files")) > 0);
}

function renderProjects(projects) {
  const query = byId("projectSearch").value.trim().toLowerCase();
  const filtered = projects.filter((row) => [pick(row, "Project", "project"), pick(row, "ProjectPath", "projectPath"), pick(row, "Machines", "machines")].some((value) => String(value || "").toLowerCase().includes(query)));
  const body = byId("projectRows");
  if (!filtered.length) {
    body.innerHTML = `<tr><td colspan="7" class="empty-cell">${projects.length ? "Ingen prosjekter matcher søket." : "Ingen prosjektdata er registrert."}</td></tr>`;
    return;
  }
  body.innerHTML = filtered.map((row) => {
    const linked = projectAgentData(row);
    const sessions = linked.reduce((total, item) => total + number(pick(item.metric, "Sessions", "sessions")), 0);
    const latest = pick(row, "Latest", "latest") || {};
    const projectName = pick(row, "Project", "project");
    const projectPath = pick(row, "ProjectPath", "projectPath");
    const projectDetail = encodeURIComponent(JSON.stringify({
      kicker: "Eksakt prosjektidentitet",
      title: projectName,
      description: "Prosjektet er utledet fra agentenes cwd, workspace eller directory. En undermappe kan derfor være et eget prosjekt.",
      rows: [["Prosjektsti", projectPath], ["Agenter", linked.map((item) => item.agent.label).join(" · ") || "Ingen"], ["Sesjoner", sessions], ["State-filer", number(pick(row, "TotalFiles", "totalFiles"))], ["Datamengde", formatBytes(pick(row, "TotalBytes", "totalBytes"))], ["Siste data", pick(latest, "Display", "display") || "-"]]
    }));
    return `<tr><td><button type="button" class="project-button detail-button" data-detail="${projectDetail}"><strong class="project-name" title="${escapeHtml(projectName)}">${escapeHtml(projectName)}</strong><span class="project-path" title="${escapeHtml(projectPath)}">${escapeHtml(projectPath)}</span></button></td><td><div class="agent-tags">${linked.map(({ agent, metric }) => agentTag(agent, metric)).join("")}</div></td><td class="number-cell">${sessions.toLocaleString("nb-NO")}</td><td class="number-cell">${number(pick(row, "TotalFiles", "totalFiles")).toLocaleString("nb-NO")}</td><td class="number-cell">${formatBytes(pick(row, "TotalBytes", "totalBytes"))}</td><td class="number-cell">${escapeHtml(pick(latest, "Display", "display") || "-")}</td><td>${escapeHtml(pick(row, "Machines", "machines") || "-")}</td></tr>`;
  }).join("");
}

function renderMissionProjectOptions(projects) {
  const seen = new Set();
  state.missionProjects = projects.map((project) => {
    const path = String(pick(project, "ProjectPath", "projectPath") || "").trim();
    const fallbackName = path.split(/[\\/]/).filter(Boolean).pop() || path;
    return { path, name: String(pick(project, "Project", "project") || fallbackName).trim() };
  }).filter((project) => {
    const key = project.path.toLocaleLowerCase("nb-NO");
    if (!project.path || seen.has(key)) return false;
    seen.add(key);
    return true;
  }).sort((left, right) => left.name.localeCompare(right.name, "nb-NO"));
  renderMissionProjectPicker(byId("missionProject").value);
}

function projectLatestDate(project) {
  const latest = pick(project, "Latest", "latest") || {};
  const value = pick(latest, "Iso", "iso") || "";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function projectSidebarGroup(date) {
  if (!date) return { key: "unknown", label: "Uten tidspunkt", order: Number.NEGATIVE_INFINITY };
  const today = new Date();
  const todayStart = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  const dateStart = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  const ageDays = Math.floor((todayStart.getTime() - dateStart.getTime()) / 86400000);
  if (ageDays <= 0) return { key: "today", label: "I dag", order: dateStart.getTime() };
  if (ageDays <= 7) {
    const label = new Intl.DateTimeFormat("nb-NO", { day: "numeric", month: "short" }).format(date).replace(/\.$/, "");
    return { key: dateStart.toISOString(), label, order: dateStart.getTime() };
  }
  return { key: "older", label: "Eldre", order: 0 };
}

function projectRecoveryState(path) {
  const key = normalizedMissionProjectPath(path);
  const recovery = state.recoveryProjects.find((project) => normalizedMissionProjectPath(project.path) === key);
  if (!recovery) return { status: "unknown", label: "Recovery ikke kontrollert", detail: "Recovery-status mangler." };
  const status = String(recovery.status || "unknown").toLowerCase();
  const findings = recoveryProjectFindings(recovery);
  const label = status === "error" ? "Recovery-feil" : status === "warning" ? "Recovery-advarsel" : status === "ready" ? "Recovery klar" : "Recovery ukjent";
  const statusClass = status === "warning" ? "warn" : status;
  return { status: statusClass, label, detail: findings[0]?.message || label };
}

function projectSidebarName(project) {
  const path = displayPath(pick(project, "ProjectPath", "projectPath"));
  const parts = path.split(/[\\/]/).filter(Boolean);
  return {
    name: parts.at(-1) || String(pick(project, "Project", "project") || "Ukjent prosjekt"),
    parent: parts.at(-2) || "Prosjektrot",
    path
  };
}

function renderProjectSidebar() {
  const container = byId("projectSidebarList");
  if (!container) return;
  const query = byId("projectSidebarSearch").value.trim().toLocaleLowerCase("nb-NO");
  const projects = state.statusProjects
    .map((project) => ({ project, latest: projectLatestDate(project), identity: projectSidebarName(project) }))
    .filter(({ project, identity }) => !query
      || identity.name.toLocaleLowerCase("nb-NO").includes(query)
      || identity.parent.toLocaleLowerCase("nb-NO").includes(query)
      || identity.path.toLocaleLowerCase("nb-NO").includes(query)
      || String(pick(project, "Project", "project") || "").toLocaleLowerCase("nb-NO").includes(query))
    .sort((left, right) => (right.latest?.getTime() || 0) - (left.latest?.getTime() || 0) || left.identity.name.localeCompare(right.identity.name, "nb-NO"));

  const groups = new Map();
  projects.forEach((item) => {
    const group = projectSidebarGroup(item.latest);
    if (!groups.has(group.key)) groups.set(group.key, { ...group, projects: [] });
    groups.get(group.key).projects.push(item);
  });
  const selected = normalizedMissionProjectPath(state.selectedProjectPath || byId("missionProject").value);
  const signature = JSON.stringify({
    query,
    selected,
    projects: projects.map(({ project, latest, identity }) => [identity.path, latest?.getTime() || 0, pick(project, "AgentCount", "agentCount"), projectRecoveryState(identity.path).status])
  });
  if (signature !== state.projectSidebarSignature) {
    const scrollTop = container.scrollTop;
    state.projectSidebarSignature = signature;
    container.innerHTML = projects.length ? [...groups.values()].map((group) => {
      const rows = group.projects.map(({ project, latest, identity }) => {
        const recovery = projectRecoveryState(identity.path);
        const selectedProject = normalizedMissionProjectPath(identity.path) === selected;
        const agentCount = number(pick(project, "AgentCount", "agentCount"));
        const latestText = latest ? formatCompactDate(latest) : "Ukjent tid";
        const title = `${identity.path}\n${recovery.label}: ${recovery.detail}\nSist registrert: ${latestText}`;
        return `<button type="button" class="project-sidebar-project${selectedProject ? " selected" : ""}" role="option" aria-selected="${selectedProject}" data-sidebar-project="${encodeURIComponent(identity.path)}" title="${escapeHtml(title)}"><i class="project-sidebar-state ${escapeHtml(recovery.status)}" aria-hidden="true"></i><span class="project-sidebar-project-copy"><strong>${escapeHtml(identity.name)}</strong><small>${escapeHtml(identity.parent)}</small></span><span class="project-sidebar-project-meta">${agentCount ? `${agentCount} ag.` : "ingen"}</span></button>`;
      }).join("");
      return `<section class="project-sidebar-group" aria-label="${escapeHtml(group.label)}"><h2 class="project-sidebar-group-title">${escapeHtml(group.label)}</h2>${rows}</section>`;
    }).join("") : `<p class="project-sidebar-empty">${state.statusProjects.length ? "Ingen prosjekter matcher søket." : "Ingen AgentSync-prosjekter er registrert."}</p>`;
    container.scrollTop = scrollTop;
  }

  setTextIfChanged(byId("projectSidebarCount"), plural(state.statusProjects.length, "prosjekt", "prosjekter"));
  const generated = pick(state.payload?.status?.data, "generatedUtc") || pick(state.payload?.recovery?.data, "generatedUtc");
  setTextIfChanged(byId("projectSidebarFreshness"), generated ? `Oppdatert ${formatCompactDate(generated)}` : "Ikke oppdatert");
  byId("sidebarProjectOverview").classList.toggle("active", state.activeView === "status");
  byId("sidebarNewMission").classList.toggle("active", state.activeView === "mission");
}

function activateView(view) {
  state.activeView = view;
  document.querySelectorAll(".view-tab").forEach((item) => item.classList.toggle("active", item.dataset.view === view));
  document.querySelectorAll(".view").forEach((item) => item.classList.toggle("active", item.id === `${view}View`));
  renderProjectSidebar();
}

function selectProjectFromSidebar(path) {
  const projectPath = displayPath(path);
  state.selectedProjectPath = projectPath;
  byId("missionProject").value = projectPath;
  state.projectSidebarSignature = "";
  setMissionProjectPickerOpen(false);
  renderMissionWorkspace(null);
  activateView("mission");
  renderProjectSidebar();
  inspectMissionWorkspace();
  byId("missionPrompt").focus();
}

function applyProjectSidebarCollapsed(collapsed, persist = true) {
  document.body.classList.toggle("project-sidebar-collapsed", collapsed);
  const button = byId("projectSidebarToggle");
  button.setAttribute("aria-expanded", String(!collapsed));
  button.setAttribute("aria-label", collapsed ? "Vis prosjektnavigatoren" : "Skjul prosjektnavigatoren");
  button.title = collapsed ? "Vis prosjektnavigatoren" : "Skjul prosjektnavigatoren";
  if (persist) writePreference("agentsync.projectSidebar", collapsed ? "collapsed" : "expanded");
}

function renderMissionProjectPicker(query = "") {
  const picker = byId("missionProjectPicker");
  const needle = query.trim().toLocaleLowerCase("nb-NO");
  const matches = state.missionProjects.filter((project) => !needle
    || project.name.toLocaleLowerCase("nb-NO").includes(needle)
    || project.path.toLocaleLowerCase("nb-NO").includes(needle)).slice(0, 100);
  picker.innerHTML = matches.length
    ? matches.map((project) => `<button type="button" class="mission-project-option" role="option" data-project-path="${encodeURIComponent(project.path)}"><strong>${escapeHtml(project.name)}</strong><span>${escapeHtml(project.path)}</span></button>`).join("")
    : `<div class="mission-project-empty">Ingen AgentSync-prosjekter matcher teksten.</div>`;
}

function setMissionProjectPickerOpen(open) {
  const input = byId("missionProject");
  const picker = byId("missionProjectPicker");
  const shouldOpen = open && !input.disabled;
  if (shouldOpen) renderMissionProjectPicker(input.value);
  picker.hidden = !shouldOpen;
  input.setAttribute("aria-expanded", String(shouldOpen));
}

function missionHistoryStatusLabel(status) {
  if (status === "completed") return "Ferdig";
  if (status === "completed_warning") return "Ferdig med varsel";
  if (status === "running") return "Pågår";
  if (status === "queued") return "Klargjør";
  if (status === "failed") return "Feilet";
  if (status === "canceled") return "Avbrutt";
  return "Lagret";
}

function renderMissionPromptHistory(history) {
  const items = array(history);
  const button = byId("missionHistoryButton");
  const picker = byId("missionPromptHistory");
  button.textContent = `Historikk ${items.length}`;
  button.disabled = missionRunning() || items.length === 0;
  const signature = JSON.stringify(items.map((item) => [item.id, item.prompt, item.agentLabel, item.status, item.startedUnixMs]));
  if (signature === state.missionPromptHistorySignature) return;
  state.missionPromptHistorySignature = signature;
  picker.innerHTML = items.map((item) => `<button type="button" class="mission-history-item" role="option" data-mission-history-id="${encodeURIComponent(item.id)}"><span class="mission-history-meta"><span>${escapeHtml(item.agentLabel || "Ukjent agent")} · ${escapeHtml(missionHistoryStatusLabel(item.status))}</span><time>${escapeHtml(formatDate(item.startedUnixMs))}</time></span><pre>${escapeHtml(item.prompt)}</pre></button>`).join("");
  if (!items.length || button.disabled) setMissionPromptHistoryOpen(false);
}

function setMissionPromptHistoryOpen(open) {
  const button = byId("missionHistoryButton");
  const picker = byId("missionPromptHistory");
  const shouldOpen = open && !button.disabled && picker.children.length > 0;
  picker.hidden = !shouldOpen;
  button.setAttribute("aria-expanded", String(shouldOpen));
}

function missionAgentTag(agent) {
  const known = missionAgentVisuals.find((item) => item.slug === agent.id) || { slug: agent.id, label: agent.label, mark: "•" };
  return agentTag(known, { Files: 1 }, false);
}

function renderMissionAgents(agentList) {
  const container = byId("missionAgents");
  const available = agentList.filter((agent) => agent.available);
  if (!available.some((agent) => agent.id === state.selectedMissionAgent)) {
    state.selectedMissionAgent = available[0]?.id || null;
  }
  container.innerHTML = agentList.map((agent) => {
    const selected = agent.id === state.selectedMissionAgent;
    const status = agent.available ? (selected ? "Valgt" : "CLI klar") : "CLI mangler";
    const local = agent.hostLabel || agent.transport || agent.requiresApiKey === false;
    const access = local ? `${agent.hostLabel || "Lokal modell"}${agent.requiresApiKey === false ? " · uten API-token" : ""}` : "Providerkonto / CLI";
    const detail = agent.model ? `${agent.model} · ${access}` : `${status} · ${access}`;
    return `<button type="button" class="mission-agent${selected ? " selected" : ""}" data-mission-agent="${escapeHtml(agent.id)}" title="${escapeHtml(agent.note)}" ${agent.available ? "" : "disabled"}><span class="mission-agent-head">${missionAgentTag(agent)}<span class="mission-agent-runtime" hidden><i aria-hidden="true"></i><time data-mission-agent-elapsed>0s</time></span></span><strong>${escapeHtml(agent.label)}</strong><small>${escapeHtml(detail)}</small></button>`;
  }).join("");
  container.querySelectorAll("[data-mission-agent]").forEach((button) => button.addEventListener("click", () => {
    state.selectedMissionAgent = button.dataset.missionAgent;
    renderMissionAgents(agentList);
    updateMissionStartState();
  }));
  updateMissionStartState();
  updateMissionModelHint();
}

async function updateMissionModelHint() {
  const input = byId("missionModel");
  const datalist = byId("missionModelOptions");
  const agent = array(state.missionControl?.agents).find((candidate) => candidate.id === state.selectedMissionAgent);
  input.placeholder = agent?.model ? `Standard: ${agent.model}` : "Agentens standard";
  if (state.selectedMissionAgent !== "aider") {
    datalist.innerHTML = "";
    return;
  }
  if (!state.sparkModelNames && invoke) {
    try {
      const models = await invoke("get_spark_models");
      state.sparkModelNames = array(models).map((model) => String(model.name || "")).filter(Boolean);
    } catch {
      state.sparkModelNames = [];
    }
  }
  datalist.innerHTML = (state.sparkModelNames || [])
    .map((name) => `<option value="${escapeHtml(`ollama_chat/${name}`)}"></option>`)
    .join("");
}

function missionRunning(mission = state.missionControl?.mission) {
  return mission?.status === "queued" || mission?.status === "running";
}

function activeMissions() {
  return array(state.missionControl?.missions).filter((mission) => mission.status === "queued" || mission.status === "running");
}

function updateMissionStartState() {
  const hasPrompt = byId("missionPrompt").value.trim().length >= 3;
  const readyWorkspace = Boolean(state.missionWorkspace && !state.missionWorkspace.error);
  // Concurrency is per project and enforced by the backend (AGENT_BUSY +
  // force). The composer itself never blocks on other missions.
  byId("missionStartButton").disabled = !state.selectedMissionAgent || !hasPrompt || !readyWorkspace;
}

function renderMissionWorkspace(workspace, afterMission = false) {
  state.missionWorkspace = workspace;
  const area = byId("missionWorkspace");
  if (!workspace) {
    area.className = "mission-workspace neutral";
    area.textContent = "Velg et prosjekt fra AgentSync eller skriv inn en eksakt mappe.";
  } else if (workspace.error) {
    area.className = "mission-workspace error";
    area.textContent = workspace.error;
  } else if (workspace.controlMode === "checkpoint") {
    area.className = workspace.warning ? "mission-workspace warn" : "mission-workspace ok";
    if (afterMission) {
      area.textContent = `AgentSync-checkpoint: ${number(workspace.changedFiles)} endringer fra oppdraget er målt mot førtilstanden.${workspace.warning ? ` ${workspace.warning}` : ""}`;
    } else if (workspace.isGit) {
      area.textContent = `${workspace.branch || "Git"}: ${number(workspace.changedFiles)} eksisterende Git-endringer bevares i et før-checkpoint. Oppdraget kan starte.`;
    } else {
      area.textContent = "Prosjektet har ingen Git-baseline. AgentSync lager et før-checkpoint med filhash og sikkerhetskopi. Oppdraget kan starte.";
    }
  } else {
    area.className = "mission-workspace ok";
    area.textContent = `${workspace.branch || "Git"}: Git-baseline ved ${String(workspace.headCommit || "").slice(0, 10)}. Klar for én skrivende agent.`;
  }
  updateMissionStartState();
}

async function inspectMissionWorkspace() {
  if (!invoke || state.missionLoading) return;
  const projectPath = byId("missionProject").value.trim();
  if (!projectPath) return renderMissionWorkspace(null);
  state.missionLoading = true;
  byId("missionInspectButton").disabled = true;
  const area = byId("missionWorkspace");
  area.className = "mission-workspace neutral";
  area.textContent = "Kontrollerer sikkerhetsgrunnlag...";
  try {
    const workspace = await invoke("inspect_mission_workspace", { projectPath });
    renderMissionWorkspace(workspace);
  } catch (error) {
    renderMissionWorkspace({ isGit: false, clean: false, controlMode: "checkpoint", error: String(error) });
  } finally {
    state.missionLoading = false;
    byId("missionInspectButton").disabled = missionRunning();
  }
}

function missionStatusPresentation(status) {
  if (status === "completed") return ["Ferdig", "ok"];
  if (status === "completed_warning") return ["Ferdig med varsel", "warn"];
  if (status === "failed") return ["Feilet", "error"];
  if (status === "canceled") return ["Avbrutt", "warn"];
  if (status === "running") return ["Arbeider", "warn"];
  if (status === "queued") return ["Klargjør", "warn"];
  return ["Klar for oppdrag", "neutral"];
}

function missionEffectiveStatus(mission) {
  const status = mission?.status || "unknown";
  const finalOutput = String(mission?.finalOutput || "").trim();
  const errors = [mission?.error, mission?.errorOutput].filter(Boolean).join("\n").trim();
  if (status === "completed" && errors && !finalOutput) return "failed";
  if (status === "completed" && errors) return "completed_warning";
  return status;
}

function missionErrorExplanation(mission) {
  const raw = [mission?.error, mission?.errorOutput, mission?.errorSummary].filter(Boolean).join("\n");
  const lower = raw.toLowerCase();
  if (!raw.trim()) return "";
  if (lower.includes("permission") || lower.includes("tillatelse") || lower.includes("auto-denied")) {
    return "Agenten manglet en nødvendig tillatelse og kunne derfor ikke fullføre. Juster agentens tillatelser eller velg en annen agent før du prøver igjen.";
  }
  if (lower.includes("api") && (lower.includes("key") || lower.includes("token"))) {
    return "Agenten manglet gyldig tilgang til modellen. Kontroller lokal modelltilkobling eller API-oppsett før ny kjøring.";
  }
  if ((lower.includes("took") && lower.includes("as its prompt"))
    || lower.includes("cannot be used with")
    || lower.includes("unexpected argument")
    || lower.includes("unrecognized argument")
    || lower.includes("unknown argument")
    || lower.includes("unknown option")
    || lower.includes("found argument")
    || lower.includes("usage:")) {
    return "Agentens CLI avviste AgentSync-kommandoprofilen før modellen startet. Se de tekniske feildetaljene.";
  }
  return String(mission?.error || mission?.errorSummary || raw.split(/\r?\n/).find((line) => line.trim()) || "Oppdraget stoppet med feil.").trim();
}

function setTextIfChanged(element, value) {
  const text = String(value ?? "");
  if (element.textContent !== text) element.textContent = text;
}

function formatMissionElapsed(mission) {
  if (!mission?.startedUnixMs) return "Ikke startet";
  const end = mission.finishedUnixMs || Date.now();
  const totalSeconds = Math.max(0, Math.floor((end - mission.startedUnixMs) / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const parts = [];
  if (hours) parts.push(`${hours}t`);
  if (minutes || hours) parts.push(`${minutes}m`);
  parts.push(`${seconds}s`);
  return `${missionRunning(mission) ? "Arbeider" : "Arbeidet"} i ${parts.join(" ")}`;
}

function updateMissionFocusElapsed() {
  if (!state.missionFocusMission) return;
  setTextIfChanged(byId("missionFocusElapsed"), formatMissionElapsed(state.missionFocusMission));
}

function updateMissionAgentRuntime(mission = state.missionControl?.mission) {
  const running = missionRunning(mission);
  const elapsed = running ? formatMissionElapsed(mission).replace(/^Arbeider i /, "") : "";
  byId("missionAgents").querySelectorAll("[data-mission-agent]").forEach((button) => {
    const active = running && button.dataset.missionAgent === mission.agent;
    button.classList.toggle("running", active);
    const runtime = button.querySelector(".mission-agent-runtime");
    if (!runtime) return;
    runtime.hidden = !active;
    if (active) {
      runtime.title = formatMissionElapsed(mission);
      setTextIfChanged(runtime.querySelector("time"), elapsed);
    }
  });
}

function updateMissionFocusTaskSummaryVisibility() {
  const summary = byId("missionFocusTaskSummary");
  summary.hidden = !state.missionFocusOpen || byId("missionFocusScroller").scrollTop < 170;
}

function missionResponseNearBottom(element, threshold = 48) {
  return element.scrollHeight - element.scrollTop - element.clientHeight <= threshold;
}

function updateMissionFocusResponseFollow() {
  state.missionFocusResponseFollow = missionResponseNearBottom(byId("missionFocusText"));
}

function missionAgentVisual(mission) {
  return missionAgentVisuals.find((item) => item.slug === mission?.agent)
    || { slug: mission?.agent || "unknown", label: mission?.agentLabel || mission?.agent || "Agent", mark: "•" };
}

function normalizedMissionProjectPath(value) {
  return displayPath(value).replace(/[\\/]+$/, "").toLowerCase();
}

function missionModelPresentation(mission, agentInfo = null) {
  const explicit = String(mission?.model || agentInfo?.model || "").trim();
  if (explicit) return { name: explicit, fallback: false };
  const projectPath = normalizedMissionProjectPath(mission?.projectPath);
  const agent = String(mission?.agent || "").toLowerCase();
  const registered = state.intelligenceSessions.find((session) => {
    const model = String(session?.model || "").trim();
    return model
      && model !== "<synthetic>"
      && String(session?.agent || "").toLowerCase() === agent
      && normalizedMissionProjectPath(session?.projectPath) === projectPath;
  });
  return registered
    ? { name: String(registered.model).trim(), fallback: true }
    : { name: "Ikke registrert", fallback: true };
}

function inlineMissionModel(presentation) {
  if (presentation.name === "Ikke registrert") return "(Ikke registrert)";
  return presentation.fallback
    ? `(${presentation.name}, sist registrert)`
    : `(${presentation.name})`;
}

function newestLinesFirst(value, fallback = "") {
  const lines = String(value || "").split(/\r?\n/).filter((line) => line.trim());
  return lines.length ? lines.reverse().join("\n") : fallback;
}

function updateMissionFocusChangesAction() {
  const panel = byId("missionFocusChangesPanel");
  const hasDiff = panel.dataset.hasDiff === "true";
  setTextIfChanged(byId("missionFocusChangesAction"), hasDiff ? (panel.open ? "Lukk diff" : "Åpne diff") : "Ingen diff");
}

function renderMissionSessionDock(history) {
  const sessions = array(history);
  const dock = byId("missionSessionDock");
  const tabs = byId("missionSessionTabs");
  dock.hidden = sessions.length === 0;
  document.body.classList.toggle("mission-session-dock-active", sessions.length > 0);
  byId("missionSessionCount").textContent = String(sessions.length);
  byId("missionSessionAllCount").textContent = String(sessions.length);
  const selectedId = state.missionFocusMission?.id;
  byId("missionSessionDashboard").classList.toggle("active", !state.missionFocusOpen);
  byId("missionSessionDashboard").setAttribute("aria-pressed", String(!state.missionFocusOpen));
  const recent = sessions.slice(0, 6);
  const signature = JSON.stringify({ recent, selectedId, open: state.missionFocusOpen, loading: state.missionSessionLoading });
  if (signature === state.missionDockSignature) return;
  state.missionDockSignature = signature;
  tabs.innerHTML = recent.map((session) => {
    const [statusLabel, statusClass] = missionStatusPresentation(session.status);
    const selected = state.missionFocusOpen && session.id === selectedId;
    const prompt = String(session.prompt || "Uten oppdrag").trim();
    const shortPrompt = prompt.replace(/\s+/g, " ");
    const loading = state.missionSessionLoading === session.id;
    const project = displayPath(session.projectPath || "").split(/[\\/]/).filter(Boolean).pop() || "Ukjent prosjekt";
    const time = formatCompactDate(session.startedUnixMs);
    return `<button class="mission-session-tab ${statusClass}${selected ? " selected" : ""}" type="button" aria-pressed="${selected}" data-session-id="${escapeHtml(session.id)}" title="${escapeHtml(`${project}: ${prompt}`)}"><i aria-hidden="true"></i><span><strong>${escapeHtml(`${session.agentLabel || "Agent"} · ${project}`)}</strong><small>${escapeHtml(shortPrompt || session.id)}</small></span><em>${escapeHtml(loading ? "Laster" : `${statusLabel} · ${time}`)}</em></button>`;
  }).join("");
  if (state.missionArchiveOpen) renderMissionArchive();
}

function renderMissionArchive() {
  const sessions = array(state.missionControl?.history);
  const query = byId("missionArchiveSearch").value.trim().toLowerCase();
  const filtered = sessions.filter((session) => [session.prompt, session.projectPath, session.agentLabel, session.model, session.errorSummary].some((value) => String(value || "").toLowerCase().includes(query)));
  byId("missionArchiveCount").textContent = `${plural(filtered.length, "oppdrag", "oppdrag")} vist av ${sessions.length.toLocaleString("nb-NO")}`;
  byId("missionArchiveList").innerHTML = filtered.length ? filtered.map((session) => {
    const [statusLabel, statusClass] = missionStatusPresentation(session.status);
    const projectPath = displayPath(session.projectPath);
    const project = projectPath.split(/[\\/]/).filter(Boolean).pop() || "Ukjent prosjekt";
    const changed = session.changedFiles ? plural(session.changedFiles, "endret fil", "endrede filer") : "Ingen filendringer";
    const prompt = String(session.prompt || "Uten oppdrag").replace(/\s+/g, " ");
    return `<button type="button" class="mission-archive-item ${statusClass}" data-session-id="${escapeHtml(session.id)}"><i aria-hidden="true"></i><span class="mission-archive-main"><strong>${escapeHtml(prompt)}</strong><span>${escapeHtml(`${session.agentLabel || "Agent"} · ${project}`)}</span><small>${escapeHtml(projectPath || "Prosjektsti mangler")}</small></span><span class="mission-archive-meta"><strong>${escapeHtml(statusLabel)}</strong><small>${escapeHtml(`${formatCompactDate(session.startedUnixMs)} · ${changed}`)}</small></span></button>`;
  }).join("") : '<div class="empty-state">Ingen oppdrag matcher søket.</div>';
}

function setSurfaceInert(element, inert) {
  if (!element) return;
  element.inert = inert;
  if (inert) element.setAttribute("aria-hidden", "true");
  else element.removeAttribute("aria-hidden");
}

function openMissionArchive() {
  state.missionArchiveReturn = document.activeElement;
  state.missionArchiveOpen = true;
  byId("missionArchive").hidden = false;
  byId("missionSessionAll").setAttribute("aria-expanded", "true");
  setSurfaceInert(document.querySelector(".app-shell"), true);
  setSurfaceInert(byId("missionFocusLayer"), true);
  setSurfaceInert(byId("missionSessionDock"), true);
  renderMissionArchive();
  byId("missionArchiveSearch").focus();
}

function closeMissionArchive() {
  if (!state.missionArchiveOpen) return;
  state.missionArchiveOpen = false;
  byId("missionArchive").hidden = true;
  byId("missionSessionAll").setAttribute("aria-expanded", "false");
  setSurfaceInert(document.querySelector(".app-shell"), state.missionFocusOpen);
  setSurfaceInert(byId("missionFocusLayer"), false);
  setSurfaceInert(byId("missionSessionDock"), false);
  state.missionArchiveReturn?.focus?.();
}

function renderMissionFocus(mission) {
  if (!mission) return;
  const scroller = byId("missionFocusScroller");
  const nearBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 180;
  const running = missionRunning(mission);
  const effectiveStatus = missionEffectiveStatus(mission);
  const [statusLabel, statusClass] = missionStatusPresentation(effectiveStatus);
  const visual = missionAgentVisual(mission);
  const activeMission = state.missionControl?.mission;
  const viewingHistoricalMission = Boolean(activeMission?.id && activeMission.id !== mission.id);
  const activeSessionButton = byId("missionFocusActiveSession");
  byId("missionFocusHistoryState").hidden = !viewingHistoricalMission;
  activeSessionButton.hidden = !viewingHistoricalMission;
  if (viewingHistoricalMission) {
    setTextIfChanged(activeSessionButton, missionRunning(activeMission) ? "Åpne oppdraget som arbeider" : "Åpne nyeste oppdrag");
    activeSessionButton.title = `Bytt fra dette historiske oppdraget til ${activeMission.agentLabel || activeMission.agent || "det nyeste oppdraget"}.`;
  }
  const badge = byId("missionFocusAgent");
  badge.className = `agent-tag ${visual.slug}`;
  badge.innerHTML = `<span class="agent-mark" aria-hidden="true">${escapeHtml(visual.mark)}</span>${escapeHtml(mission.agentLabel || visual.label)}`;
  const agentInfo = array(state.missionControl?.agents).find((agent) => agent.id === mission.agent);
  setTextIfChanged(byId("missionFocusProject"), displayPath(mission.projectPath) || "Prosjektsti mangler");
  const model = missionModelPresentation(mission, agentInfo);
  const runtime = agentInfo?.hostLabel ? ` · ${agentInfo.hostLabel}${agentInfo.transport ? ` via ${agentInfo.transport}` : ""}` : "";
  const modelSource = model.fallback && model.name !== "Ikke registrert" ? " (sist registrert)" : "";
  setTextIfChanged(byId("missionFocusModel"), `Modell: ${model.name}${modelSource}${runtime}`);
  setTextIfChanged(byId("missionFocusResponseModel"), inlineMissionModel(model));
  byId("missionFocusSpinner").hidden = !running;
  byId("missionFocusText").closest(".mission-focus-response").setAttribute("aria-busy", String(running));
  byId("missionFocusStatus").className = `state-chip ${statusClass}`;
  setTextIfChanged(byId("missionFocusStatus"), statusLabel);
  byId("missionFocusCancel").hidden = !running || mission.id !== state.missionControl?.mission?.id;
  setTextIfChanged(byId("missionFocusPrompt"), mission.prompt || "Uten oppdragstekst");
  setTextIfChanged(byId("missionFocusTaskSummary"), String(mission.prompt || "Uten oppdrag").replace(/\s+/g, " "));
  setTextIfChanged(byId("missionFocusTitle"), running ? `${mission.agentLabel || visual.label} arbeider` : "Sluttresultat");
  setTextIfChanged(byId("missionFocusPhase"), effectiveStatus === "failed" ? "Stoppet før sluttresultat" : mission.phase || statusLabel);
  const response = String(mission.finalOutput || "").trim()
    || (running ? `${mission.agentLabel || visual.label} arbeider. Teksten vises her så snart agenten svarer.` : effectiveStatus === "failed" ? "Oppdraget stoppet før agenten kunne levere et sluttresultat." : "Agenten fullførte uten en egen slutttekst. Se aktivitetsloggen for det som ble registrert.");
  const responseArea = byId("missionFocusText");
  const responseMissionChanged = state.missionFocusResponseMissionId !== mission.id;
  if (responseMissionChanged) {
    state.missionFocusResponseMissionId = mission.id || null;
    state.missionFocusResponseFollow = running;
  }
  const followResponse = state.missionFocusResponseFollow;
  const renderedResponse = markdownToHtml(response);
  const responseChanged = responseArea.innerHTML !== renderedResponse;
  if (responseChanged) responseArea.innerHTML = renderedResponse;
  if (responseChanged || responseMissionChanged) {
    window.requestAnimationFrame(() => {
      if (running && followResponse) {
        responseArea.scrollTop = responseArea.scrollHeight;
      } else if (responseMissionChanged && !running) {
        responseArea.scrollTop = 0;
      }
    });
  }
  const errors = newestLinesFirst([mission.error, mission.errorOutput].filter(Boolean).join("\n").trim());
  const errorPanel = byId("missionFocusErrorPanel");
  if (errorPanel.dataset.missionId !== mission.id) {
    errorPanel.dataset.missionId = mission.id || "";
    errorPanel.dataset.autoOpened = "";
    errorPanel.open = false;
  }
  errorPanel.hidden = !errors;
  if (effectiveStatus === "failed" && errors && errorPanel.dataset.autoOpened !== "true") {
    errorPanel.open = true;
    errorPanel.dataset.autoOpened = "true";
  }
  setTextIfChanged(byId("missionFocusErrors"), errors);
  byId("missionFocusErrors").scrollTop = 0;
  const explanation = missionErrorExplanation(mission);
  const outcome = byId("missionFocusOutcome");
  outcome.hidden = running || (!explanation && effectiveStatus === "completed");
  outcome.className = `mission-outcome ${statusClass}`;
  setTextIfChanged(byId("missionFocusOutcomeTitle"), effectiveStatus === "failed" ? "Oppdraget ble ikke fullført" : effectiveStatus === "completed_warning" ? "Ferdig med et varsel" : "Oppdraget er ferdig");
  setTextIfChanged(byId("missionFocusOutcomeText"), explanation || "Agenten leverte et sluttresultat og endringskontrollen er klar.");
  byId("missionFocusResultActions").hidden = false;
  byId("missionFocusFollowUp").disabled = running;
  byId("missionFocusFollowUp").title = running ? "Vent til det aktive oppdraget er ferdig" : "Start et nytt oppdrag i samme prosjekt";
  const activity = newestLinesFirst(
    mission.output,
    running ? "Venter på første aktivitet..." : "Ingen aktivitet ble registrert."
  );
  setTextIfChanged(byId("missionFocusActivity"), activity);
  byId("missionFocusActivity").scrollTop = 0;
  setTextIfChanged(byId("missionFocusActivitySummary"), running ? "Nyeste først · oppdateres løpende" : "Nyeste først · verktøy og arbeidssteg");
  const workspace = mission.workspaceAfter;
  const focusFiles = parseUnifiedDiff(workspace?.diff || "");
  const changedFileCount = workspace ? Math.max(number(workspace.changedFiles), focusFiles.length) : 0;
  const changes = workspace ? `${changedFileCount} endrede filer${workspace.diffTruncated ? ", diff forkortet" : ""}` : (running ? "Endringer beregnes etterpå" : "Ingen endringer registrert");
  setTextIfChanged(byId("missionFocusChangesTitle"), changes);
  const focusDiff = workspace?.diff || workspace?.diffStat || (running ? "Diffen blir tilgjengelig når agentprosessen avsluttes." : "Oppdraget gjorde ingen filendringer.");
  setTextIfChanged(byId("missionFocusDiff"), focusDiff);
  renderInteractiveDiff(focusDiff, "missionFocusDiffRendered", "missionFocusFileList", state.diffViewMode, "missionFocusDiff");
  const hasFocusDiff = !running && focusFiles.length > 0;
  byId("missionFocusDiffToolbar").hidden = !hasFocusDiff;
  byId("missionFocusReviewButton").hidden = !hasFocusDiff;
  byId("missionFocusChangesPanel").dataset.hasDiff = String(hasFocusDiff);
  updateMissionFocusChangesAction();
  renderCodeReviewPanel(mission.codeReview, true, mission.id);

  updateMissionFocusElapsed();
  updateMissionFocusTaskSummaryVisibility();
  if (state.missionFocusOpen && running && nearBottom) {
    window.requestAnimationFrame(() => { scroller.scrollTop = scroller.scrollHeight; });
  }
}

function parseUnifiedDiff(diffText) {
  if (!diffText || typeof diffText !== "string" || diffText.includes("Ingen diff") || diffText.includes("Diffen vises når") || diffText.includes("Oppdraget gjorde ingen filendringer")) {
    return [];
  }
  const lines = diffText.split(/\r?\n/);
  const files = [];
  let currentFile = null;
  let currentHunk = null;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (line.startsWith("diff --git ") || (line.startsWith("--- ") && !currentFile)) {
      let filePath = "";
      if (line.startsWith("diff --git ")) {
        const parts = line.split(" ");
        filePath = (parts[3] || parts[2] || "").replace(/^[ab]\//, "");
      } else if (line.startsWith("--- ")) {
        filePath = line.slice(4).replace(/^[ab]\//, "");
      }

      currentFile = {
        fileId: `file-${files.length}`,
        filePath: filePath || "Ukjent fil",
        status: "modified",
        additions: 0,
        deletions: 0,
        hunks: []
      };
      files.push(currentFile);
      currentHunk = null;
      continue;
    }

    if (!currentFile) continue;

    if (line.startsWith("new file mode")) {
      currentFile.status = "added";
      continue;
    }
    if (line.startsWith("deleted file mode")) {
      currentFile.status = "deleted";
      continue;
    }
    if (line.startsWith("+++ b/") || line.startsWith("+++ ")) {
      const newPath = line.slice(4).replace(/^[ab]\//, "");
      if (newPath && newPath !== "/dev/null") {
        currentFile.filePath = newPath;
      }
      continue;
    }

    const hunkMatch = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/);
    if (hunkMatch) {
      currentHunk = {
        header: line,
        oldNum: parseInt(hunkMatch[1], 10),
        newNum: parseInt(hunkMatch[2], 10),
        lines: []
      };
      currentFile.hunks.push(currentHunk);
      continue;
    }

    if (currentHunk) {
      if (line.startsWith("+")) {
        currentFile.additions++;
        currentHunk.lines.push({ type: "add", oldNum: null, newNum: currentHunk.newNum++, text: line.slice(1) });
      } else if (line.startsWith("-")) {
        currentFile.deletions++;
        currentHunk.lines.push({ type: "del", oldNum: currentHunk.oldNum++, newNum: null, text: line.slice(1) });
      } else if (line.startsWith(" ") || line === "") {
        currentHunk.lines.push({ type: "ctx", oldNum: currentHunk.oldNum++, newNum: currentHunk.newNum++, text: line.startsWith(" ") ? line.slice(1) : line });
      }
    }
  }

  return files.filter((f) => f.hunks.length > 0 || f.additions > 0 || f.deletions > 0);
}

function renderInteractiveDiff(diffText, containerId = "missionDiffRendered", fileListId = "diffFileList", viewMode = state.diffViewMode, rawElementId = "missionDiff") {
  const normalizedDiff = diffText || "";
  if (containerId === "missionDiffRendered") state.activeDiffText = normalizedDiff;
  const rawElement = byId(rawElementId);
  const renderedContainer = byId(containerId);
  const fileListContainer = byId(fileListId);
  if (!renderedContainer || !fileListContainer) return;

  const signature = `${viewMode}\u0000${normalizedDiff}`;
  if (state.diffSignatures[containerId] === signature) return;
  state.diffSignatures[containerId] = signature;

  const files = parseUnifiedDiff(normalizedDiff);
  if (!files.length) {
    if (rawElement) rawElement.hidden = false;
    renderedContainer.hidden = true;
    renderedContainer.replaceChildren();
    fileListContainer.hidden = true;
    fileListContainer.replaceChildren();
    return;
  }

  if (rawElement) rawElement.hidden = true;
  renderedContainer.hidden = false;
  fileListContainer.hidden = false;

  fileListContainer.innerHTML = files.map((file) => {
    const statusLabel = file.status === "added" ? "NY" : file.status === "deleted" ? "SLETTET" : "ENDRET";
    const statusClass = file.status === "added" ? "ok" : file.status === "deleted" ? "error" : "warn";
    const fileName = file.filePath.split(/[\\/]/).pop();
    return `<button type="button" class="diff-file-pill" data-scroll-to="${escapeHtml(`${containerId}-${file.fileId}`)}" title="${escapeHtml(file.filePath)}"><span class="diff-pill-name">${escapeHtml(fileName)}</span><span class="diff-pill-stat"><em class="diff-add">+${file.additions}</em><em class="diff-del">-${file.deletions}</em></span><span class="state-chip ${statusClass} mini">${statusLabel}</span></button>`;
  }).join("");

  fileListContainer.querySelectorAll("[data-scroll-to]").forEach((button) => {
    button.addEventListener("click", () => {
      const targetId = button.dataset.scrollTo;
      const target = document.getElementById(targetId);
      if (target) {
        target.scrollIntoView({ behavior: "smooth", block: "nearest" });
        target.classList.add("diff-card-highlight");
        setTimeout(() => target.classList.remove("diff-card-highlight"), 1500);
      }
    });
  });

  renderedContainer.innerHTML = files.map((file) => {
    const isSplit = viewMode === "split";
    const hunkHtml = file.hunks.map((hunk) => {
      if (isSplit) {
        const rows = [];
        let i = 0;
        while (i < hunk.lines.length) {
          const line = hunk.lines[i];
          if (line.type === "ctx") {
            rows.push(`<tr><td class="diff-num">${line.oldNum}</td><td class="diff-code diff-ctx">${escapeHtml(line.text)}</td><td class="diff-num">${line.newNum}</td><td class="diff-code diff-ctx">${escapeHtml(line.text)}</td></tr>`);
            i++;
          } else if (line.type === "del") {
            const next = hunk.lines[i + 1];
            if (next && next.type === "add") {
              rows.push(`<tr><td class="diff-num">${line.oldNum}</td><td class="diff-code diff-del">-${escapeHtml(line.text)}</td><td class="diff-num">${next.newNum}</td><td class="diff-code diff-add">+${escapeHtml(next.text)}</td></tr>`);
              i += 2;
            } else {
              rows.push(`<tr><td class="diff-num">${line.oldNum}</td><td class="diff-code diff-del">-${escapeHtml(line.text)}</td><td class="diff-num empty"></td><td class="diff-code empty"></td></tr>`);
              i++;
            }
          } else if (line.type === "add") {
            rows.push(`<tr><td class="diff-num empty"></td><td class="diff-code empty"></td><td class="diff-num">${line.newNum}</td><td class="diff-code diff-add">+${escapeHtml(line.text)}</td></tr>`);
            i++;
          }
        }
        return `<div class="diff-hunk"><div class="diff-hunk-header">${escapeHtml(hunk.header)}</div><table class="diff-table split-diff-table"><tbody>${rows.join("")}</tbody></table></div>`;
      } else {
        const rows = hunk.lines.map((line) => {
          const cls = line.type === "add" ? "diff-add" : line.type === "del" ? "diff-del" : "diff-ctx";
          const sign = line.type === "add" ? "+" : line.type === "del" ? "-" : " ";
          return `<tr><td class="diff-num old-num">${line.oldNum || ""}</td><td class="diff-num new-num">${line.newNum || ""}</td><td class="diff-code ${cls}"><span class="diff-sign">${sign}</span>${escapeHtml(line.text)}</td></tr>`;
        }).join("");
        return `<div class="diff-hunk"><div class="diff-hunk-header">${escapeHtml(hunk.header)}</div><table class="diff-table unified-diff-table"><tbody>${rows.join("")}</tbody></table></div>`;
      }
    }).join("");

    return `<div id="${escapeHtml(`${containerId}-${file.fileId}`)}" class="diff-file-card"><header class="diff-file-header"><div class="diff-file-info"><span class="file-icon" aria-hidden="true">📄</span><strong class="diff-file-path">${escapeHtml(file.filePath)}</strong><span class="diff-pill-stat"><em class="diff-add">+${file.additions}</em><em class="diff-del">-${file.deletions}</em></span></div><button type="button" class="diff-fold-btn" aria-label="Fold sammen fil">Skjul</button></header><div class="diff-file-body">${hunkHtml}</div></div>`;
  }).join("");

  renderedContainer.querySelectorAll(".diff-fold-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const card = btn.closest(".diff-file-card");
      const body = card.querySelector(".diff-file-body");
      const isHidden = body.hidden;
      body.hidden = !isHidden;
      btn.textContent = isHidden ? "Skjul" : "Vis";
    });
  });
}

async function loadSparkModels() {
  if (!invoke) return;
  const select = byId("sparkModelSelect");
  if (!select) return;
  try {
    const models = await invoke("get_spark_models");
    state.sparkModels = array(models);
    if (!state.sparkModels.length) {
      select.innerHTML = '<option value="qwen3-coder-next:q8_0">qwen3-coder-next:q8_0 (DGX Spark)</option>';
      return;
    }
    select.innerHTML = state.sparkModels.map((m) => {
      const param = m.parameterSize ? ` (${m.parameterSize}${m.quantization ? ` · ${m.quantization}` : ""})` : "";
      const selected = m.name === state.selectedSparkModel || m.model === state.selectedSparkModel ? "selected" : "";
      return `<option value="${escapeHtml(m.name)}" ${selected}>${escapeHtml(m.name)}${escapeHtml(param)}</option>`;
    }).join("");
    state.selectedSparkModel = select.value || state.selectedSparkModel;
  } catch {
    select.innerHTML = '<option value="qwen3-coder-next:q8_0">qwen3-coder-next:q8_0 (DGX Spark)</option>';
  }
}

function renderCodeReviewPanel(result, focus = false, missionId = null) {
  const panel = byId(focus ? "missionFocusReviewPanel" : "codeReviewPanel");
  const badge = byId(focus ? "missionFocusReviewBadge" : "codeReviewBadge");
  const model = byId(focus ? "missionFocusReviewModel" : "codeReviewModel");
  const content = byId(focus ? "missionFocusReviewContent" : "codeReviewContent");
  const time = focus ? null : byId("codeReviewTime");
  if (!panel || !badge || !model || !content) return;

  const loading = Boolean(missionId && state.codeReviewLoadingMissionId === missionId);
  if (loading) {
    panel.hidden = false;
    badge.className = "state-chip warn";
    badge.textContent = "Analyserer";
    model.textContent = state.selectedSparkModel;
    if (time) time.textContent = "";
    content.innerHTML = '<div class="review-loading-spinner"><span class="spark-icon">⚡</span> Kjører lokal sikkerhets- og kodekontroll på NVIDIA DGX Spark...</div>';
    return;
  }
  if (!result) {
    panel.hidden = true;
    content.textContent = "";
    return;
  }

  const statusClass = result.status === "blocked" ? "error" : result.status === "warning" ? "warn" : "ok";
  const statusLabel = result.status === "blocked" ? "BLOKKERT" : result.status === "warning" ? "ADVARSLER" : "GODKJENT";
  panel.hidden = false;
  badge.className = `state-chip ${statusClass}`;
  badge.textContent = statusLabel;
  model.textContent = `${result.model} · ${result.host}`;
  if (time) time.textContent = result.durationMs ? `${(result.durationMs / 1000).toFixed(1)}s` : "";
  content.innerHTML = markdownToHtml(result.rawResponse);
}

function renderCodeReviewError(message, focus = false) {
  const panel = byId(focus ? "missionFocusReviewPanel" : "codeReviewPanel");
  const badge = byId(focus ? "missionFocusReviewBadge" : "codeReviewBadge");
  const content = byId(focus ? "missionFocusReviewContent" : "codeReviewContent");
  if (!panel || !badge || !content) return;
  panel.hidden = false;
  badge.className = "state-chip error";
  badge.textContent = "Feilet";
  content.innerHTML = `<p class="error-msg">Kunne ikke fullføre review: ${escapeHtml(message)}</p>`;
}

async function runCodeReview(mission, triggerButton) {
  if (!invoke || state.codeReviewLoading) return;
  const missionId = mission?.id;
  const targetDiff = mission?.workspaceAfter?.diff;
  if (!missionId) {
    showMessage("Velg et lagret oppdrag før du starter Code Review.", "neutral");
    return;
  }
  if (!targetDiff || targetDiff.includes("Ingen endringer ennå")) {
    showMessage("Ingen endringer i diffen å gjennomgå.", "neutral");
    return;
  }

  state.codeReviewLoading = true;
  state.codeReviewLoadingMissionId = missionId;
  if (triggerButton) {
    triggerButton.disabled = true;
    triggerButton.classList.add("loading");
  }

  if (state.missionControl?.mission?.id === missionId) renderCodeReviewPanel(mission.codeReview, false, missionId);
  if (state.missionFocusMission?.id === missionId) renderCodeReviewPanel(mission.codeReview, true, missionId);

  const selectedModel = byId("sparkModelSelect")?.value || state.selectedSparkModel || "qwen3-coder-next:q8_0";

  try {
    const result = await invoke("review_workspace_changes", {
      missionId,
      selectedModel
    });

    state.codeReviewResult = result;
    const statusClass = result.status === "blocked" ? "error" : result.status === "warning" ? "warn" : "ok";
    const statusLabel = result.status === "blocked" ? "BLOKKERT" : result.status === "warning" ? "ADVARSLER" : "GODKJENT";
    const duration = result.durationMs ? `${(result.durationMs / 1000).toFixed(1)}s` : "";
    if (state.missionControl?.mission?.id === missionId) state.missionControl.mission.codeReview = result;
    if (state.missionFocusMission?.id === missionId) state.missionFocusMission.codeReview = result;
    state.codeReviewLoadingMissionId = null;
    if (state.missionControl?.mission?.id === missionId) renderCodeReviewPanel(result, false, missionId);
    if (state.missionFocusMission?.id === missionId) renderCodeReviewPanel(result, true, missionId);
    showMessage(`Lokal Spark Code Review: ${statusLabel} (${duration})`, statusClass === "error" ? "error" : "success");
  } catch (error) {
    state.codeReviewLoadingMissionId = null;
    if (state.missionControl?.mission?.id === missionId) renderCodeReviewError(String(error), false);
    if (state.missionFocusMission?.id === missionId) renderCodeReviewError(String(error), true);
    showMessage(`Code review feilet: ${String(error)}`, "error");
  } finally {
    state.codeReviewLoading = false;
    state.codeReviewLoadingMissionId = null;
    if (triggerButton) {
      triggerButton.disabled = false;
      triggerButton.classList.remove("loading");
    }
  }
}

function openMissionFocus(mission, resetScroll = true) {
  if (!mission) return;
  if (!state.missionFocusOpen) state.missionFocusReturn = document.activeElement;
  state.missionFocusMission = mission;
  state.missionFocusOpen = true;
  byId("missionFocusLayer").hidden = false;
  document.body.classList.add("mission-focus-active");
  setSurfaceInert(document.querySelector(".app-shell"), true);
  renderMissionFocus(mission);
  renderMissionSessionDock(state.missionControl?.history);
  if (resetScroll) byId("missionFocusScroller").scrollTop = 0;
  updateMissionFocusTaskSummaryVisibility();
  byId("missionFocusOverview").focus();
}

function closeMissionFocus() {
  state.missionFocusOpen = false;
  byId("missionFocusLayer").hidden = true;
  document.body.classList.remove("mission-focus-active");
  setSurfaceInert(document.querySelector(".app-shell"), false);
  renderMissionSessionDock(state.missionControl?.history);
  state.missionFocusReturn?.focus?.();
}

async function openMissionSession(missionId) {
  if (!invoke || !missionId) return;
  if (state.missionArchiveOpen) closeMissionArchive();
  const active = state.missionControl?.mission;
  if (active?.id === missionId) {
    openMissionFocus(active);
    return;
  }
  state.missionSessionLoading = missionId;
  renderMissionSessionDock(state.missionControl?.history);
  try {
    const mission = await invoke("get_mission_session", { missionId });
    openMissionFocus(mission);
  } catch (error) {
    showMessage(`Kan ikke åpne oppdraget: ${String(error)}`, "error");
  } finally {
    state.missionSessionLoading = null;
    renderMissionSessionDock(state.missionControl?.history);
  }
}

function renderMission(mission) {
  const running = missionRunning(mission);
  const effectiveStatus = missionEffectiveStatus(mission);
  const [statusLabel, statusClass] = missionStatusPresentation(effectiveStatus);
  const stateChip = byId("missionState");
  stateChip.className = `state-chip ${statusClass}`;
  stateChip.textContent = statusLabel;
  byId("missionCancelButton").hidden = !running;
  byId("missionStartButton").hidden = running;
  byId("missionProject").disabled = running;
  byId("missionPrompt").disabled = running;
  byId("missionHistoryButton").disabled = running || !array(state.missionControl?.history).length;
  if (running) setMissionPromptHistoryOpen(false);
  byId("missionInspectButton").disabled = running || state.missionLoading;
  byId("missionAgents").querySelectorAll("button").forEach((button) => { button.disabled = running || !state.missionControl?.agents?.find((agent) => agent.id === button.dataset.missionAgent)?.available; });
  updateMissionAgentRuntime(mission);

  if (!mission) {
    byId("missionRuntimeTitle").textContent = "Ingen aktivt oppdrag";
    byId("missionAgentBadge").className = "state-chip neutral";
    byId("missionAgentBadge").textContent = "Venter";
    byId("missionMeta").innerHTML = "<dt>Fase</dt><dd>Velg prosjekt, agent og oppdrag.</dd><dt>Startet</dt><dd>Ikke startet</dd>";
    byId("missionFinalPanel").hidden = true;
    byId("missionFinalModel").textContent = "";
    byId("missionFinalSpinner").hidden = true;
    byId("missionFinalOutput").textContent = "";
    byId("missionActivityState").className = "live-indicator stopped";
    byId("missionActivityState").innerHTML = "<i></i>Venter";
    byId("missionOutput").textContent = "Agentens verktøybruk og arbeidssteg vises her.";
    byId("missionErrors").hidden = true;
    byId("missionDiffSummary").textContent = "Ingen endringer ennå";
    byId("missionDiff").textContent = "Diffen vises når agenten har skrevet noe.";
    renderInteractiveDiff("Diffen vises når agenten har skrevet noe.");
    byId("runCodeReviewButton").hidden = true;
    renderCodeReviewPanel(null, false, null);
    renderMissionSessionDock(state.missionControl?.history);
    updateMissionStartState();
    return;
  }

  byId("missionRuntimeTitle").textContent = mission.prompt || mission.id;
  byId("missionAgentBadge").className = `state-chip ${statusClass}`;
  byId("missionAgentBadge").textContent = mission.agentLabel || mission.agent;
  const agentInfo = array(state.missionControl?.agents).find((agent) => agent.id === mission.agent);
  const model = missionModelPresentation(mission, agentInfo);
  const controlLabel = mission.workspaceBefore?.controlMode === "git" ? "Git-baseline" : "AgentSync-checkpoint";
  byId("missionMeta").innerHTML = [
    ["Fase", mission.phase || statusLabel],
    ["Prosjekt", displayPath(mission.projectPath)],
    ["Modell", model.fallback && model.name !== "Ikke registrert" ? `${model.name} (sist registrert)` : model.name],
    ["Kontroll", controlLabel],
    ["Startet", formatDate(mission.startedUnixMs)],
    ["Avsluttet", mission.finishedUnixMs ? formatDate(mission.finishedUnixMs) : "Pågår"],
    ["Startcommit", String(mission.workspaceBefore?.headCommit || "-").slice(0, 12)],
    ["Checkpoint", mission.checkpoint?.directory || "-"]
  ].map(([label, value]) => `<dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value)}</dd>`).join("");
  const finalOutput = String(mission.finalOutput || "").trim();
  byId("missionFinalPanel").hidden = !running && !finalOutput;
  byId("missionFinalModel").textContent = inlineMissionModel(model);
  byId("missionFinalSpinner").hidden = !running;
  byId("missionFinalHeading").textContent = running ? "Agentens tekst" : "Sluttresultat";
  byId("missionFinalState").className = `state-chip ${statusClass}`;
  byId("missionFinalState").textContent = running ? "Oppdateres" : statusLabel;
  byId("missionFinalOutput").textContent = finalOutput || (running ? `${mission.agentLabel || mission.agent} arbeider. Teksten vises her når agenten svarer.` : "");
  byId("missionFinalOutput").scrollTop = byId("missionFinalOutput").scrollHeight;
  byId("missionActivityState").className = `live-indicator${running ? "" : " stopped"}`;
  byId("missionActivityState").innerHTML = `<i></i>${running ? "Løpende" : "Fullført"}`;
  byId("missionOutput").textContent = newestLinesFirst(
    mission.output,
    running ? `${mission.agentLabel} starter...` : "Ingen strukturerte aktivitetshendelser ble registrert."
  );
  byId("missionOutput").scrollTop = 0;
  const errors = newestLinesFirst([mission.error, mission.errorOutput].filter(Boolean).join("\n").trim());
  byId("missionErrors").hidden = !errors;
  byId("missionErrors").textContent = errors;
  byId("missionErrors").scrollTop = 0;

  const workspace = mission.workspaceAfter;
  let currentDiff = "";
  if (workspace) {
    const headChanged = workspace.headCommit && workspace.headCommit !== mission.workspaceBefore?.headCommit;
    renderMissionWorkspace(headChanged ? { ...workspace, clean: false, error: "Agenten endret HEAD selv om oppdraget forbød commit. Kontroller Git-historikken manuelt." } : workspace, true);
    const summary = [`${number(workspace.changedFiles)} endrede filer`];
    if (workspace.diffTruncated) summary.push("diff forkortet");
    if (mission.checkpoint && !mission.checkpoint.complete) summary.push("checkpoint med advarsel");
    if (headChanged) summary.push("agenten endret HEAD");
    byId("missionDiffSummary").textContent = summary.join(" · ");
    currentDiff = workspace.diff || workspace.diffStat || "Oppdraget gjorde ingen filendringer.";
    byId("missionDiff").textContent = currentDiff;
  } else {
    byId("missionDiffSummary").textContent = running ? "Agenten arbeider" : "Ingen diff tilgjengelig";
    currentDiff = running ? "Endringsdiff beregnes når agentprosessen avsluttes." : "Ingen diff tilgjengelig.";
    byId("missionDiff").textContent = currentDiff;
  }
  renderInteractiveDiff(currentDiff);
  const reviewAvailable = !running && Boolean(workspace?.diff) && parseUnifiedDiff(workspace.diff).length > 0;
  byId("runCodeReviewButton").hidden = !reviewAvailable;
  byId("runCodeReviewButton").disabled = !reviewAvailable || state.codeReviewLoading;
  renderCodeReviewPanel(mission.codeReview, false, mission.id);
  const isNewRunningMission = missionRunning(mission) && mission.id !== state.lastObservedMissionId;
  if (state.missionFocusMission?.id === mission.id) {
    state.missionFocusMission = mission;
    renderMissionFocus(mission);
  }
  if (isNewRunningMission) openMissionFocus(mission);
  state.lastObservedMissionId = mission.id;
  renderMissionSessionDock(state.missionControl?.history);
  updateMissionStartState();
}

function conversationProjectKey(path) {
  return displayPath(String(path || "")).trim().toLowerCase();
}

function conversationTimestamp(unixMs) {
  if (!unixMs) return "--:--:--";
  return new Date(unixMs).toLocaleTimeString("no-NO", { hour12: false });
}

function renderConversationFilters(agentsInTimeline) {
  const container = byId("conversationFilters");
  if (!agentsInTimeline.length) {
    container.innerHTML = "";
    return;
  }
  if (state.conversationAgentFilter !== "all" && !agentsInTimeline.some(([agent]) => agent === state.conversationAgentFilter)) {
    state.conversationAgentFilter = "all";
  }
  const chip = (value, label) =>
    `<button type="button" class="conv-chip${state.conversationAgentFilter === value ? " selected" : ""}" data-conv-filter="${escapeHtml(value)}">${escapeHtml(label)}</button>`;
  container.innerHTML = chip("all", "Alle") + agentsInTimeline.map(([agent, label]) => chip(agent, label)).join("");
  container.querySelectorAll("[data-conv-filter]").forEach((button) => button.addEventListener("click", () => {
    state.conversationAgentFilter = button.dataset.convFilter;
    renderConversation();
  }));
}

async function ensureConversationSession(missionId) {
  if (state.conversationSessionCache[missionId] !== undefined) return;
  state.conversationSessionCache[missionId] = null;
  try {
    const mission = await invoke("get_mission_session", { missionId });
    state.conversationSessionCache[missionId] = {
      final: String(mission.finalOutput || ""),
      error: String(mission.error || "")
    };
  } catch {
    state.conversationSessionCache[missionId] = { final: "", error: "" };
  }
  renderConversation();
}

function renderConversation() {
  const container = byId("conversationTimeline");
  const key = conversationProjectKey(byId("missionProject").value || state.selectedProjectPath);
  if (!key) {
    renderConversationFilters([]);
    container.innerHTML = '<div class="empty-state">Velg et prosjekt for å se samtalen.</div>';
    return;
  }
  const history = array(state.missionControl?.history)
    .filter((item) => conversationProjectKey(item.projectPath) === key)
    .sort((a, b) => a.startedUnixMs - b.startedUnixMs)
    .slice(-40);
  const agentsInTimeline = [...new Map(history.map((item) => [item.agent, item.agentLabel])).entries()];
  renderConversationFilters(agentsInTimeline);
  const filter = state.conversationAgentFilter;
  const visible = history.filter((item) => filter === "all" || item.agent === filter);
  if (!visible.length) {
    container.innerHTML = '<div class="empty-state">Ingen samtale ennå. Velg agent og skriv første oppdrag under.</div>';
    return;
  }
  const liveById = new Map(array(state.missionControl?.missions).map((mission) => [mission.id, mission]));
  const nearBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 80;
  const parts = [];
  for (const item of visible) {
    const live = liveById.get(item.id);
    const running = item.status === "queued" || item.status === "running";
    const meta = [item.model, live?.level].filter(Boolean).join(" · ");
    parts.push(`<article class="conv-entry user"><header><span class="conv-time">[${conversationTimestamp(item.startedUnixMs)}]</span><span class="conv-author">Du → ${escapeHtml(item.agentLabel)}</span>${meta ? `<span class="conv-meta">${escapeHtml(meta)}</span>` : ""}</header><div class="conv-body">${escapeHtml(item.prompt)}</div></article>`);
    if (running && live) {
      const tail = String(live.output || "").split("\n").filter(Boolean).slice(-8).join("\n");
      const body = live.finalOutput
        ? `<div class="conv-text">${escapeHtml(live.finalOutput)}</div>`
        : `<pre class="conv-tail">${escapeHtml(tail || "Starter ...")}</pre>`;
      parts.push(`<article class="conv-entry agent running"><header><span class="conv-time">[${conversationTimestamp(Date.now())}]</span><span class="conv-author">${escapeHtml(item.agentLabel)}</span><span class="conv-meta live">${escapeHtml(live.phase || "arbeider")}</span><button type="button" class="conv-cancel" data-cancel-mission="${escapeHtml(item.id)}">Avbryt</button></header><div class="conv-body">${body}</div></article>`);
    } else {
      const cached = state.conversationSessionCache[item.id];
      let body;
      if (cached === undefined) {
        body = `<button type="button" class="conv-load" data-load-mission="${escapeHtml(item.id)}">Vis svar</button>`;
      } else if (cached === null) {
        body = '<span class="conv-loading">Laster svar ...</span>';
      } else {
        const text = cached.final || cached.error || item.errorSummary || "Ingen tekst registrert.";
        body = `<div class="conv-text">${escapeHtml(text)}</div>`;
      }
      const statusChip = item.status === "completed" ? "" : `<span class="conv-status ${escapeHtml(item.status)}">${escapeHtml(item.status)}</span>`;
      parts.push(`<article class="conv-entry agent"><header><span class="conv-time">[${conversationTimestamp(item.finishedUnixMs || item.startedUnixMs)}]</span><span class="conv-author">${escapeHtml(item.agentLabel)}</span>${statusChip}</header><div class="conv-body">${body}</div></article>`);
    }
  }
  container.innerHTML = parts.join("");
  container.querySelectorAll("[data-load-mission]").forEach((button) => button.addEventListener("click", () => ensureConversationSession(button.dataset.loadMission)));
  container.querySelectorAll("[data-cancel-mission]").forEach((button) => button.addEventListener("click", () => cancelMission(button.dataset.cancelMission)));
  if (nearBottom) container.scrollTop = container.scrollHeight;
  visible.slice(-6).forEach((item) => {
    const finished = item.status !== "queued" && item.status !== "running";
    if (finished && state.conversationSessionCache[item.id] === undefined) ensureConversationSession(item.id);
  });
}

async function refreshMissionControl() {
  if (!invoke) return;
  try {
    const payload = await invoke("get_mission_control");
    const agentsChanged = JSON.stringify(payload.agents) !== JSON.stringify(state.missionControl?.agents);
    state.missionControl = payload;
    if (!state.selectedProjectPath && payload.mission?.projectPath) {
      state.selectedProjectPath = displayPath(payload.mission.projectPath);
      state.projectSidebarSignature = "";
    }
    renderMissionPromptHistory(payload.history);
    if (agentsChanged) renderMissionAgents(array(payload.agents));
    renderMission(payload.mission);
    renderConversation();
    renderProjectSidebar();
  } catch (error) {
    showMessage(`Mission Control: ${String(error)}`, "error");
  }
}

function hideForceBanner() {
  state.pendingForceRequest = null;
  byId("missionForceBanner").hidden = true;
}

async function submitMissionRequest(request) {
  byId("missionStartButton").disabled = true;
  try {
    const result = await invoke("start_mission", { request });
    hideForceBanner();
    showMessage(result.message, "success");
    byId("missionPrompt").value = "";
    setMissionPromptHistoryOpen(false);
    updateMissionStartState();
    await refreshMissionControl();
  } catch (error) {
    const message = String(error);
    if (message.includes("AGENT_BUSY:")) {
      // One agent per project by default; the user decides whether to force
      // a parallel run in the same project.
      state.pendingForceRequest = { ...request, force: true };
      byId("missionForceText").textContent = message.replace("AGENT_BUSY:", "").trim();
      byId("missionForceBanner").hidden = false;
    } else {
      showMessage(message, "error");
    }
    updateMissionStartState();
  }
}

async function startMission() {
  if (!invoke) return;
  const model = byId("missionModel").value.trim();
  const level = byId("missionLevel").value;
  const request = {
    projectPath: byId("missionProject").value.trim(),
    prompt: byId("missionPrompt").value,
    agent: state.selectedMissionAgent,
    model: model || null,
    level: level || null,
    force: false
  };
  state.selectedProjectPath = request.projectPath;
  state.projectSidebarSignature = "";
  hideForceBanner();
  await submitMissionRequest(request);
}

async function cancelMission(missionId = null) {
  if (!invoke) return;
  if (missionId && typeof missionId !== "string") missionId = null;
  byId("missionCancelButton").disabled = true;
  byId("missionFocusCancel").disabled = true;
  try {
    const result = await invoke("cancel_mission", { missionId });
    showMessage(result.message, "success");
  } catch (error) {
    showMessage(String(error), "error");
  } finally {
    byId("missionCancelButton").disabled = false;
    byId("missionFocusCancel").disabled = false;
    await refreshMissionControl();
  }
}

function recoveryProjectFindings(project) {
  const findings = [...array(project.findings)];
  for (const agent of array(project.agents)) {
    for (const finding of array(agent.findings)) findings.push({ ...finding, agent: agent.name });
  }
  return findings;
}

function localizedRecoveryStatus(status) {
  const value = String(status || "unknown").toLowerCase();
  if (value === "ready") return ["Klar", "ok"];
  if (value === "warning") return ["Bør undersøkes", "warn"];
  if (value === "error") return ["Feil", "error"];
  return ["Ukjent", "neutral"];
}

function renderRecoveryRows() {
  const query = byId("recoverySearch").value.trim().toLowerCase();
  const filter = byId("recoveryFilter").value;
  const projects = state.recoveryProjects.filter((project) => {
    const status = String(project.status || "").toLowerCase();
    if (filter === "attention" && status === "ready") return false;
    if (filter === "ready" && status !== "ready") return false;
    return [project.relative, project.path, ...array(project.agents).map((agent) => agent.name)].some((value) => String(value || "").toLowerCase().includes(query));
  });
  byId("recoveryRows").innerHTML = projects.length ? projects.map((project) => {
    const [statusLabel, stateClass] = localizedRecoveryStatus(project.status);
    const agentNames = array(project.agents).filter((agent) => number(agent.files) > 0).map((agent) => agent.name);
    const findings = recoveryProjectFindings(project);
    const detail = encodeURIComponent(JSON.stringify({
      kicker: "Recovery-funn",
      title: project.relative || project.path,
      description: findings.length ? "Advarslene under forteller hvorfor prosjektet ikke står som helt klart. Fallback betyr at kopien er bevart, men prosjektidentiteten bør verifiseres." : "Ingen konkrete avvik ble registrert for prosjektet.",
      rows: findings.length ? findings.map((finding) => [finding.agent ? `${finding.agent}: ${finding.code || "Funn"}` : finding.code || "Funn", finding.message || finding.severity || "Uspesifisert funn"]) : [["Status", statusLabel], ["Kontroll", "Ingen konkrete funn"]]
    }));
    const findingCell = findings.length ? `<button type="button" class="finding-button detail-button ${stateClass}" data-detail="${detail}">${plural(findings.length, "funn", "funn")}</button>` : '<span class="no-findings">Ingen funn</span>';
    return `<tr><td><strong class="project-name">${escapeHtml(project.relative || project.path)}</strong><span class="project-path">${escapeHtml(displayPath(project.path))}</span></td><td><span class="state-chip ${stateClass}">${escapeHtml(statusLabel)}</span></td><td>${escapeHtml(agentNames.join(", ") || "-")}</td><td class="number-cell">${number(project.sessions).toLocaleString("nb-NO")}</td><td class="number-cell">${formatBytes(project.bytes)}</td><td class="number-cell">${findingCell}</td></tr>`;
  }).join("") : '<tr><td colspan="6" class="empty-cell">Ingen Recovery-prosjekter matcher filteret.</td></tr>';
}

function renderRecovery(documentState) {
  const recovery = documentState?.data || {};
  const summary = recovery.summary || {};
  const generatedAge = ageSeconds(recovery.generatedUtc);
  byId("recoveryGenerated").textContent = recovery.generatedUtc ? `Generert ${formatDate(recovery.generatedUtc)}${recovery.deep ? " · dyp kontroll" : " · vanlig kontroll"}` : "Ikke tilgjengelig";
  const freshness = byId("recoveryFreshness");
  freshness.hidden = !(recovery.generatedUtc && generatedAge > 86400);
  freshness.textContent = freshness.hidden ? "" : `Recovery-kontrollen er ${Math.floor(generatedAge / 86400)} døgn gammel. Kjør en ny kontroll før du baserer en gjenoppretting på rapporten.`;
  byId("recoveryCards").innerHTML = [
    ["Prosjekter", number(summary.projects).toLocaleString("nb-NO"), "kontrollert"],
    ["Klare", number(summary.ready).toLocaleString("nb-NO"), "kan gjenopprettes"],
    ["Advarsler", number(summary.warnings).toLocaleString("nb-NO"), "forklares i tabellen"],
    ["Feil", number(summary.errors).toLocaleString("nb-NO"), "blokkerende funn"],
    ["Agentøkter", number(summary.sessions).toLocaleString("nb-NO"), "i recovery-grunnlaget"],
    ["Datamengde", formatBytes(summary.bytes), "bevart agenttilstand"]
  ].map((item) => metricCard(...item)).join("");
  state.recoveryProjects = array(recovery.projects);
  renderRecoveryRows();
  state.projectSidebarSignature = "";
  renderProjectSidebar();
}

function buildFallbackStatus(payload) {
  const recovery = payload.recovery?.data;
  if (!recovery) return null;
  const intelligence = payload.intelligence?.data || {};
  const modelIndex = new Map();
  array(intelligence.sessions).forEach((session) => {
    const key = `${String(session.projectPath || "").toLowerCase()}|${String(session.agent || "").toLowerCase()}`;
    const current = modelIndex.get(key);
    if (!current || String(session.updatedUtc || "") > String(current.updatedUtc || "")) modelIndex.set(key, session);
  });

  const projects = array(recovery.projects).map((project) => {
    const row = {
      Project: project.relative || project.path,
      ProjectPath: project.path,
      Machines: recovery.machine || "-"
    };
    let newestUtc = null;
    let totalFiles = 0;
    let totalBytes = 0;
    let agentCount = 0;
    agents.forEach((knownAgent) => {
      const recovered = array(project.agents).find((agent) => String(agent.name).toLowerCase() === knownAgent.slug) || {};
      const latestModel = modelIndex.get(`${String(project.path || "").toLowerCase()}|${knownAgent.slug}`) || {};
      const metric = {
        Files: number(recovered.files),
        Sessions: number(recovered.sessions),
        Bytes: number(recovered.bytes),
        NewestUtc: recovered.newestUtc || null,
        Model: latestModel.model || "",
        Provider: latestModel.provider || ""
      };
      row[knownAgent.key] = metric;
      totalFiles += metric.Files;
      totalBytes += metric.Bytes;
      if (metric.Files) agentCount += 1;
      if (metric.NewestUtc && (!newestUtc || metric.NewestUtc > newestUtc)) newestUtc = metric.NewestUtc;
    });
    row.AgentCount = agentCount;
    row.TotalFiles = totalFiles;
    row.TotalBytes = totalBytes;
    row.Latest = { Display: newestUtc ? formatDate(newestUtc) : "-", Iso: newestUtc || "" };
    return row;
  });

  return {
    fallback: true,
    generatedUtc: recovery.generatedUtc,
    machine: recovery.machine,
    staleAfterSeconds: 900,
    summary: {
      projects: projects.length,
      singleAgent: projects.filter((project) => project.AgentCount === 1).length,
      multiAgent: projects.filter((project) => project.AgentCount > 1).length,
      files: projects.reduce((total, project) => total + project.TotalFiles, 0),
      bytes: projects.reduce((total, project) => total + project.TotalBytes, 0),
      conflicts: array(recovery.findings).filter((finding) => finding.code === "CONFLICT_COPIES_PRESENT").length,
      unresolved: 0
    },
    selfAudit: [],
    projects
  };
}

function isTechnicalIntelligenceSession(session) {
  const model = String(session.model || "").toLowerCase();
  return model === "codex-auto-review" || model === "<synthetic>" || String(session.subject || "").toLowerCase() === "<synthetic>";
}

function safeSessionSubject(subject) {
  const value = String(subject || "-");
  if (/(^|[\\/.\s])(?:\.env|[^\\/\s]*token[^\\/\s]*|[^\\/\s]*secret[^\\/\s]*|[^\\/\s]*credential[^\\/\s]*|id_rsa)(?:$|[\\/.\s])/i.test(value)) return "Sensitivt filnavn skjult";
  return value;
}

function renderIntelligenceSessions() {
  const query = byId("intelligenceSearch").value.trim().toLowerCase();
  const agentFilter = byId("intelligenceAgentFilter").value;
  const showTechnical = byId("intelligenceTechnical").checked;
  const filtered = state.intelligenceSessions.filter((session) => {
    if (!showTechnical && isTechnicalIntelligenceSession(session)) return false;
    if (agentFilter !== "all" && String(session.agent) !== agentFilter) return false;
    return [session.project, session.projectPath, session.agent, session.model, safeSessionSubject(session.subject)].some((value) => String(value || "").toLowerCase().includes(query));
  });
  const visible = filtered.slice(0, state.intelligenceVisible);
  byId("intelligenceResultCount").textContent = `${visible.length.toLocaleString("nb-NO")} av ${filtered.length.toLocaleString("nb-NO")}`;
  byId("intelligenceMore").hidden = visible.length >= filtered.length;
  byId("intelligenceMore").textContent = `Vis flere (${(filtered.length - visible.length).toLocaleString("nb-NO")} gjenstår)`;
  byId("sessionRows").innerHTML = visible.length ? visible.map((session) => {
    const subject = safeSessionSubject(session.subject);
    const detail = encodeURIComponent(JSON.stringify({
      kicker: "Agentøkt",
      title: subject,
      description: "Avledet metadata fra providerens lokale økt. Rå samtaletekst og kommandoinnhold vises ikke her.",
      rows: [["Prosjekt", session.project || "Uten prosjekt"], ["Agent", session.agent || "-"], ["Modell", session.model || "Ikke registrert"], ["Provider", session.provider || "Ikke registrert"], ["Overflate", session.surface || "Ikke registrert"], ["Stier", number(session.pathCount).toLocaleString("nb-NO")], ["Verktøykall", number(session.toolCalls).toLocaleString("nb-NO")], ["Parsefeil", number(session.parseErrors).toLocaleString("nb-NO")], ["Sist aktiv", formatDate(session.updatedUtc)]]
    }));
    return `<tr><td><strong class="project-name">${escapeHtml(session.project || "Uten prosjekt")}</strong><span class="project-path">${escapeHtml(displayPath(session.projectPath) || "-")}</span></td><td>${escapeHtml(session.agent || "-")}</td><td>${escapeHtml(session.model || "Ikke registrert")}</td><td><button type="button" class="session-subject detail-button" data-detail="${detail}">${escapeHtml(subject)}</button></td><td class="number-cell">${number(session.pathCount).toLocaleString("nb-NO")}</td><td class="number-cell">${escapeHtml(formatDate(session.updatedUtc))}</td></tr>`;
  }).join("") : '<tr><td colspan="6" class="empty-cell">Ingen agentøkter matcher filteret.</td></tr>';
}

function renderIntelligence(documentState) {
  const intelligence = documentState?.data || {};
  const summary = intelligence.summary || {};
  byId("intelligenceGenerated").textContent = intelligence.generatedUtc ? `Oppdatert ${formatDate(intelligence.generatedUtc)} · kun metadata` : "Ikke tilgjengelig";
  byId("intelligenceCards").innerHTML = [
    ["Indekserte prosjekter", number(summary.indexedProjects).toLocaleString("nb-NO"), "med agentmetadata"],
    ["Aktive prosjekter", number(summary.activeProjects).toLocaleString("nb-NO"), "med registrert aktivitet"],
    ["Agentøkter", number(summary.sessions).toLocaleString("nb-NO"), "inkludert tekniske økter"],
    ["Agentkilder", number(summary.agents).toLocaleString("nb-NO"), "koblet"],
    ["Modeller", number(summary.models).toLocaleString("nb-NO"), "registrert"],
    ["Delte stier", number(summary.sharedPaths).toLocaleString("nb-NO"), "sett av flere økter", { description: "Antall strukturerte filstier som forekommer i metadata fra mer enn én agentøkt. Dette viser mulig overlapp, ikke at agentene kommuniserte direkte.", rows: [["Delte stier", number(summary.sharedPaths).toLocaleString("nb-NO")], ["Inneholder filinnhold", "Nei"], ["Bruk", "Finn områder flere agenter har arbeidet rundt"]] }],
    ["Parsefeil", number(summary.parseErrors).toLocaleString("nb-NO"), "poster som ikke kunne leses"]
  ].map((item) => metricCard(...item)).join("");

  const models = array(intelligence.models).filter((model) => !isTechnicalIntelligenceSession(model)).sort((left, right) => number(right.sessions) - number(left.sessions));
  byId("modelList").innerHTML = models.length ? models.slice(0, 12).map((model) => `<div class="rank-row"><strong title="${escapeHtml(model.model)}">${escapeHtml(model.model || "Ikke registrert")}</strong><span>${escapeHtml(model.agent || model.provider || "-")}</span><small>${plural(model.sessions, "økt")}</small></div>`).join("") : '<div class="empty-state">Ingen modelldata.</div>';

  const flows = array(intelligence.flows).sort((left, right) => number(right.count) - number(left.count));
  byId("flowList").innerHTML = flows.length ? flows.slice(0, 12).map((flow) => {
    const detail = encodeURIComponent(JSON.stringify({ kicker: "Agentflyt", title: `${flow.from || "?"} → ${flow.to || "?"}`, description: "Viser at disse agentene var aktive etter hverandre i samme prosjekt. Det betyr ikke at de sendte meldinger direkte til hverandre.", rows: [["Observerte overganger", number(flow.count).toLocaleString("nb-NO")], ["Prosjekter", number(flow.projects).toLocaleString("nb-NO")]] }));
    return `<button type="button" class="flow-row detail-button" data-detail="${detail}"><strong>${escapeHtml(flow.from || "?")}</strong><span class="flow-arrow">→</span><strong>${escapeHtml(flow.to || "?")}</strong><span class="flow-count">${number(flow.count).toLocaleString("nb-NO")}</span></button>`;
  }).join("") : '<div class="empty-state">Ingen agentflyt registrert.</div>';

  state.intelligenceSessions = array(intelligence.sessions).sort((left, right) => String(right.updatedUtc || "").localeCompare(String(left.updatedUtc || "")));
  const agentOptions = [...new Set(state.intelligenceSessions.map((session) => String(session.agent || "")).filter(Boolean))].sort();
  const select = byId("intelligenceAgentFilter");
  const selected = select.value || "all";
  select.innerHTML = '<option value="all">Alle agenter</option>' + agentOptions.map((agent) => `<option value="${escapeHtml(agent)}">${escapeHtml(agent)}</option>`).join("");
  select.value = agentOptions.includes(selected) ? selected : "all";
  renderIntelligenceSessions();
}

function render(payload) {
  closeDetail();
  state.payload = payload;
  showEngineEvent(payload.engine?.event);
  byId("homePath").textContent = payload.agentSyncHome;
  const fallbackStatus = payload.status?.data ? null : buildFallbackStatus(payload);
  renderStatus(fallbackStatus ? { data: fallbackStatus } : payload.status);
  renderRecovery(payload.recovery);
  renderIntelligence(payload.intelligence);
  const errors = [payload.status, payload.recovery, payload.intelligence].filter((item) => item?.error).map((item) => `${item.path}: ${item.error}`);
  if (errors.length) showMessage(errors.join(" | "), "error");
}

function mergeReport(previous, incoming) {
  return incoming?.unchanged && previous ? previous : incoming;
}

async function refresh() {
  if (state.loading) return;
  state.loading = true;
  byId("refreshButton").disabled = true;
  try {
    if (!invoke) throw new Error("Tauri-broen er ikke tilgjengelig. Start siden gjennom AgentSync Max.");
    const previous = state.payload;
    const incoming = await invoke("get_dashboard", {
      statusModifiedUnixMs: previous?.status?.modifiedUnixMs ?? null,
      recoveryModifiedUnixMs: previous?.recovery?.modifiedUnixMs ?? null,
      intelligenceModifiedUnixMs: previous?.intelligence?.modifiedUnixMs ?? null
    });
    const payload = {
      ...incoming,
      status: mergeReport(previous?.status, incoming.status),
      recovery: mergeReport(previous?.recovery, incoming.recovery),
      intelligence: mergeReport(previous?.intelligence, incoming.intelligence)
    };
    const reportsChanged = !previous || !incoming.status?.unchanged || !incoming.recovery?.unchanged || !incoming.intelligence?.unchanged;
    if (reportsChanged) {
      render(payload);
    } else {
      state.payload = payload;
      showEngineEvent(payload.engine?.event);
      const fallbackStatus = payload.status?.data ? null : buildFallbackStatus(payload);
      setServiceState(fallbackStatus || payload.status?.data || {}, payload.engine);
    }
  } catch (error) {
    byId("servicePill").className = "service-pill warn";
    byId("servicePill").querySelector("span").textContent = "Kan ikke lese status";
    showMessage(String(error), "error");
  } finally {
    state.loading = false;
    byId("refreshButton").disabled = false;
  }
}

async function runAction(command, argumentsObject = {}, button) {
  if (!invoke) return showMessage("Tauri-broen er ikke tilgjengelig.", "error");
  if (button) button.disabled = true;
  try {
    const result = await invoke(command, argumentsObject);
    showMessage(result.message, result.accepted !== false ? "success" : "warn");
    window.setTimeout(refresh, 2200);
  } catch (error) {
    showMessage(String(error), "error");
  } finally {
    if (button) button.disabled = false;
  }
}

function formatDate(value) {
  if (!value) return "Ukjent tid";
  const date = new Date(number(value) || value);
  if (Number.isNaN(date.getTime())) return "Ukjent tid";
  return new Intl.DateTimeFormat("nb-NO", { dateStyle: "short", timeStyle: "medium" }).format(date);
}

const detailPopover = byId("detailPopover");
let activeDetailTrigger = null;

function positionDetail(trigger) {
  if (!trigger || detailPopover.hidden) return;
  const triggerBox = trigger.getBoundingClientRect();
  const popupBox = detailPopover.getBoundingClientRect();
  const margin = 12;
  const gap = 8;
  let left = triggerBox.right + gap;
  if (left + popupBox.width > window.innerWidth - margin) left = triggerBox.left - popupBox.width - gap;
  if (left < margin) left = Math.min(Math.max(margin, triggerBox.left), window.innerWidth - popupBox.width - margin);
  const centeredTop = triggerBox.top + (triggerBox.height / 2) - (popupBox.height / 2);
  const top = Math.min(Math.max(margin, centeredTop), Math.max(margin, window.innerHeight - popupBox.height - margin));
  detailPopover.style.left = `${Math.round(left)}px`;
  detailPopover.style.top = `${Math.round(top)}px`;
  detailPopover.style.visibility = "visible";
}

function openDetail(data, trigger) {
  if (activeDetailTrigger && activeDetailTrigger !== trigger) activeDetailTrigger.setAttribute("aria-expanded", "false");
  activeDetailTrigger = trigger;
  trigger.setAttribute("aria-expanded", "true");
  byId("detailKicker").textContent = data.kicker || "Detaljer";
  byId("detailTitle").textContent = data.title || "AgentSync";
  byId("detailDescription").textContent = data.description || "";
  byId("detailRows").innerHTML = array(data.rows).map(([label, value]) => `<dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value)}</dd>`).join("");
  detailPopover.hidden = false;
  detailPopover.style.visibility = "hidden";
  detailPopover.classList.add("pinned");
  positionDetail(trigger);
}

function closeDetail() {
  if (activeDetailTrigger) activeDetailTrigger.setAttribute("aria-expanded", "false");
  activeDetailTrigger = null;
  detailPopover.hidden = true;
}

function detailFromTrigger(trigger) {
  try { return JSON.parse(decodeURIComponent(trigger.dataset.detail)); } catch { return null; }
}

document.addEventListener("click", (event) => {
  if (activePeekPanel && !activePeekPanel.contains(event.target)) closePanelPeek();
  if (!event.target.closest(".mission-project-field")) setMissionProjectPickerOpen(false);
  if (!event.target.closest(".mission-prompt-field") && !event.target.closest("#missionHistoryButton")) setMissionPromptHistoryOpen(false);
  if (event.target.closest("#detailClose")) {
    closeDetail();
    return;
  }
  if (event.target.closest("#engineNoticeClose")) {
    const notice = byId("engineNotice");
    state.dismissedEngineEventId = Number(notice.dataset.eventId);
    notice.hidden = true;
    return;
  }
  const trigger = event.target.closest(".detail-button");
  if (trigger) {
    if (activeDetailTrigger === trigger && !detailPopover.hidden) {
      closeDetail();
      return;
    }
    const data = detailFromTrigger(trigger);
    if (data) openDetail(data, trigger);
    return;
  }
  if (!detailPopover.hidden && !event.target.closest("#detailPopover")) closeDetail();
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    if (state.missionArchiveOpen) closeMissionArchive();
    else if (state.missionFocusOpen) closeMissionFocus();
    closePanelPeek();
    setMissionProjectPickerOpen(false);
    setMissionPromptHistoryOpen(false);
    if (!detailPopover.hidden) closeDetail();
  }
});

window.addEventListener("resize", () => {
  positionDetail(activeDetailTrigger);
  updatePanelPeekEligibilityForAll();
});
window.addEventListener("scroll", () => positionDetail(activeDetailTrigger), true);

document.querySelectorAll(".view-tab").forEach((button) => button.addEventListener("click", () => {
  if (activePeekPanel && !peekMinimumElapsed) return;
  closePanelPeek();
  activateView(button.dataset.view);
}));

byId("projectSidebarSearch").addEventListener("input", () => {
  state.projectSidebarSignature = "";
  renderProjectSidebar();
});
byId("projectSidebarList").addEventListener("click", (event) => {
  const project = event.target.closest("[data-sidebar-project]");
  if (project) selectProjectFromSidebar(decodeURIComponent(project.dataset.sidebarProject));
});
byId("projectSidebarToggle").addEventListener("click", () => applyProjectSidebarCollapsed(!document.body.classList.contains("project-sidebar-collapsed")));
byId("sidebarNewMission").addEventListener("click", () => {
  activateView("mission");
  byId("missionPrompt").focus();
});
byId("sidebarProjectOverview").addEventListener("click", () => activateView("status"));
byId("projectSearch").addEventListener("input", () => renderProjects(state.statusProjects));
byId("recoverySearch").addEventListener("input", renderRecoveryRows);
byId("recoveryFilter").addEventListener("change", renderRecoveryRows);
byId("intelligenceSearch").addEventListener("input", () => { state.intelligenceVisible = 50; renderIntelligenceSessions(); });
byId("intelligenceAgentFilter").addEventListener("change", () => { state.intelligenceVisible = 50; renderIntelligenceSessions(); });
byId("intelligenceTechnical").addEventListener("change", () => { state.intelligenceVisible = 50; renderIntelligenceSessions(); });
byId("intelligenceMore").addEventListener("click", () => { state.intelligenceVisible += 50; renderIntelligenceSessions(); });
byId("themeToggle").addEventListener("click", () => applyTheme(document.documentElement.dataset.theme === "light" ? "dark" : "light"));
byId("fontDecrease").addEventListener("click", () => shiftFontSize(-1));
byId("fontIncrease").addEventListener("click", () => shiftFontSize(1));
byId("missionProject").addEventListener("focus", () => setMissionProjectPickerOpen(true));
byId("missionProject").addEventListener("click", () => setMissionProjectPickerOpen(true));
byId("missionProject").addEventListener("input", () => {
  renderMissionWorkspace(null);
  setMissionProjectPickerOpen(true);
  const exact = state.missionProjects.find((project) => normalizedMissionProjectPath(project.path) === normalizedMissionProjectPath(byId("missionProject").value));
  state.selectedProjectPath = exact?.path || "";
  state.projectSidebarSignature = "";
  renderProjectSidebar();
});
byId("missionProject").addEventListener("keydown", (event) => {
  if (event.key !== "ArrowDown") return;
  setMissionProjectPickerOpen(true);
  const firstOption = byId("missionProjectPicker").querySelector(".mission-project-option");
  if (firstOption) {
    event.preventDefault();
    firstOption.focus();
  }
});
byId("missionProject").addEventListener("change", inspectMissionWorkspace);
byId("missionProjectPicker").addEventListener("click", (event) => {
  const option = event.target.closest(".mission-project-option");
  if (!option) return;
  byId("missionProject").value = decodeURIComponent(option.dataset.projectPath);
  state.selectedProjectPath = byId("missionProject").value;
  state.projectSidebarSignature = "";
  setMissionProjectPickerOpen(false);
  renderMissionWorkspace(null);
  renderProjectSidebar();
  inspectMissionWorkspace();
});
byId("missionPrompt").addEventListener("input", updateMissionStartState);
byId("missionPrompt").addEventListener("keydown", (event) => {
  if (!(event.ctrlKey || event.metaKey) || event.key !== "Enter") return;
  event.preventDefault();
  if (!byId("missionStartButton").disabled) startMission();
});
byId("missionHistoryButton").addEventListener("click", () => {
  setMissionPromptHistoryOpen(byId("missionPromptHistory").hidden);
});
byId("missionPromptHistory").addEventListener("click", (event) => {
  const option = event.target.closest(".mission-history-item");
  if (!option) return;
  const id = decodeURIComponent(option.dataset.missionHistoryId);
  const item = array(state.missionControl?.history).find((entry) => entry.id === id);
  if (!item) return;
  byId("missionPrompt").value = item.prompt;
  setMissionPromptHistoryOpen(false);
  updateMissionStartState();
  byId("missionPrompt").focus();
});
byId("missionInspectButton").addEventListener("click", inspectMissionWorkspace);
byId("missionStartButton").addEventListener("click", startMission);
byId("missionCancelButton").addEventListener("click", cancelMission);
byId("missionFocusCancel").addEventListener("click", cancelMission);
byId("missionFocusActiveSession").addEventListener("click", () => {
  if (state.missionControl?.mission) openMissionFocus(state.missionControl.mission);
});
byId("missionFocusOverview").addEventListener("click", closeMissionFocus);
byId("missionFocusScroller").addEventListener("scroll", updateMissionFocusTaskSummaryVisibility, { passive: true });
byId("missionFocusText").addEventListener("scroll", updateMissionFocusResponseFollow, { passive: true });
byId("missionFocusChangesPanel").addEventListener("toggle", updateMissionFocusChangesAction);
byId("missionSessionDashboard").addEventListener("click", closeMissionFocus);
byId("missionSessionTabs").addEventListener("click", (event) => {
  const tab = event.target.closest("[data-session-id]");
  if (tab) openMissionSession(tab.dataset.sessionId);
});
byId("missionSessionTabs").addEventListener("keydown", (event) => {
  if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
  const tabs = [...byId("missionSessionTabs").querySelectorAll("[data-session-id]")];
  const index = tabs.indexOf(document.activeElement);
  if (index < 0 || !tabs.length) return;
  event.preventDefault();
  tabs[(index + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length].focus();
});
byId("missionSessionAll").addEventListener("click", openMissionArchive);
byId("missionArchiveClose").addEventListener("click", closeMissionArchive);
byId("missionArchiveSearch").addEventListener("input", renderMissionArchive);
byId("missionArchiveList").addEventListener("click", (event) => {
  const item = event.target.closest("[data-session-id]");
  if (item) openMissionSession(item.dataset.sessionId);
});
byId("missionFocusOpenProject").addEventListener("click", (event) => {
  const projectPath = state.missionFocusMission?.projectPath;
  if (projectPath) runAction("open_project_folder", { projectPath: displayPath(projectPath) }, event.currentTarget);
});
byId("missionFocusFollowUp").addEventListener("click", () => {
  const mission = state.missionFocusMission;
  if (!mission) return;
  const projectPath = displayPath(mission.projectPath);
  closeMissionFocus();
  activateView("mission");
  byId("missionProject").value = projectPath;
  state.selectedProjectPath = projectPath;
  state.projectSidebarSignature = "";
  state.selectedMissionAgent = mission.agent || state.selectedMissionAgent;
  renderMissionAgents(array(state.missionControl?.agents));
  renderMissionWorkspace(null);
  renderProjectSidebar();
  inspectMissionWorkspace();
  byId("missionPrompt").focus();
});
byId("refreshButton").addEventListener("click", refresh);
byId("startButton").addEventListener("click", (event) => runAction("start_agent_sync", {}, event.currentTarget));
byId("recoveryButton").addEventListener("click", (event) => runAction("run_recovery_check", { deep: false }, event.currentTarget));
byId("deepRecoveryButton").addEventListener("click", (event) => runAction("run_recovery_check", { deep: true }, event.currentTarget));
byId("folderButton").addEventListener("click", (event) => runAction("open_agentsync_folder", {}, event.currentTarget));

// Diff View and Code Review Event Listeners
byId("diffViewUnified")?.addEventListener("click", () => {
  state.diffViewMode = "unified";
  byId("diffViewUnified").classList.add("active");
  byId("diffViewSplit").classList.remove("active");
  renderInteractiveDiff(state.activeDiffText);
  if (state.missionFocusMission?.workspaceAfter?.diff) {
    renderInteractiveDiff(state.missionFocusMission.workspaceAfter.diff, "missionFocusDiffRendered", "missionFocusFileList", state.diffViewMode, "missionFocusDiff");
  }
});
byId("diffViewSplit")?.addEventListener("click", () => {
  state.diffViewMode = "split";
  byId("diffViewSplit").classList.add("active");
  byId("diffViewUnified").classList.remove("active");
  renderInteractiveDiff(state.activeDiffText);
  if (state.missionFocusMission?.workspaceAfter?.diff) {
    renderInteractiveDiff(state.missionFocusMission.workspaceAfter.diff, "missionFocusDiffRendered", "missionFocusFileList", state.diffViewMode, "missionFocusDiff");
  }
});
byId("sparkModelSelect")?.addEventListener("change", () => {
  state.selectedSparkModel = byId("sparkModelSelect").value;
  writePreference("agentsync.sparkModel", state.selectedSparkModel);
});
byId("runCodeReviewButton")?.addEventListener("click", (event) => {
  runCodeReview(state.missionControl?.mission, event.currentTarget);
});
byId("missionFocusReviewButton")?.addEventListener("click", (event) => {
  runCodeReview(state.missionFocusMission, event.currentTarget);
});

if (listen) {
  listen("engine-event", (event) => showEngineEvent(event.payload)).catch((error) => showMessage(String(error), "error"));
}

async function missionRefreshLoop() {
  await refreshMissionControl();
  window.setTimeout(missionRefreshLoop, missionRunning() ? 2500 : 12000);
}

initializeUxControls();
applyProjectSidebarCollapsed(readPreference("agentsync.projectSidebar", "expanded") === "collapsed", false);
loadSparkModels();
missionRefreshLoop();
refresh();
window.setInterval(() => {
  updateMissionFocusElapsed();
  updateMissionAgentRuntime();
}, 1000);
window.setInterval(refresh, 60000);

// Live conversation cadence: fast polling only while missions are active.
window.setInterval(() => {
  if (activeMissions().length > 0) refreshMissionControl();
}, 2500);

byId("missionForceConfirm").addEventListener("click", async () => {
  const request = state.pendingForceRequest;
  hideForceBanner();
  if (request) await submitMissionRequest(request);
});
byId("missionForceDismiss").addEventListener("click", hideForceBanner);
wireSidebarResizer();
watchPanelSizes();
byId("missionProject").addEventListener("input", () => {
  hideForceBanner();
  renderConversation();
});
