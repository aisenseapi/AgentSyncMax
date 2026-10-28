// Valideringspanelet: en uavhengig kontroll av prosjektet, utfoert av en
// agent brukeren velger. En blind kjoering arbeider i en kopi uten de andre
// agentenes historikk, saa svaret er agentens eget.
//
// Panelet bor inne i hovedvinduet og deler dokument med app.js. De to filene
// har nitten navn felles - state, byId, element, invoke, AGENT_ORDER og flere
// - saa alt her ligger i sin egen lukning. Utad finnes bare
// window.AgentSyncControl, som app.js aapner og lukker panelet med.
(() => {
// Kontroll: an independent check of the current project by an agent of the
// user's choosing. A blind run works in a copy that carries none of the other
// agents' history, so the answer is the agent's own. This window shares its
// origin with the main window, so project and theme follow it through
// localStorage without any plumbing of their own.

const invoke = window.__TAURI__?.core?.invoke && (window.AgentSyncSecretGuard?.invoke || window.__TAURI__.core.invoke);
const AGENT_ORDER = ["claude", "codex", "opencode", "antigravity", "cline", "aider"];
const AGENT_MARKS = { claude: "✳", codex: "◉", opencode: "OC", antigravity: "A", cline: "C", aider: "ai" };
const LEVEL_LABELS = { "": "Standard", normal: "Normal", max: "Max", ultra: "Ultra" };
const PRESETS = [
  "Hva er tilstanden? Feil, svakheter og risiko, med filreferanser.",
  "Er det noe her som ikke burde være i produksjon?",
  "Hvilke tre ting ville du fikset først, og hvorfor?",
];
const VALIDATOR_QUIET_MS = 1200;
const PROJECT_SETUPS_KEY = "agentsync.v4.projectSetups";
const VALIDATOR_SETUPS_KEY = "agentsync.v4.validatorSetups";
const CONTROL_RUNS_KEY = "agentsync.v4.controlRuns";
const VALIDATOR_ROTATION_KEY = "agentsync.v4.validatorRotation";
const VERBATIM_PREFIX = "\\\\?\\";

const state = {
  catalog: null,
  agent: "",
  model: "",
  project: "",
  selectedRun: "",
  started: new Set(),
  runs: [],
  missionsById: new Map(),
  runStatuses: new Map(),
  launchedRuns: new Set(),
  statusReady: false,
  open: false,
  lifecycle: 0,
  unsubscribe: null,
  pollInFlight: null,
  pendingSnapshot: null,
  sessionReads: new Map(),
  catalogLoadedAt: 0,
  presentationDirty: false,
  catalogRequest: 0,
  findingsRequest: 0,
  enabled: false,
  generation: 0,
  enabledSince: 0,
  starting: false,
  writerStates: new Map(),
  writerSetupSignature: "",
  observedAt: Date.now(),
  activeWriter: null,
  pendingSources: new Map(),
  autoMissionIds: new Map(),
  autoError: "",
  autoErrorProject: "",
  automaticWasEnabled: null,
  automaticEnabledSince: 0,
  startingProject: "",
  runsSignature: "",
  // Mission id -> findings report. Read once per finished validation.
  findings: new Map(),
  findingsPending: new Set(),
  findingDeliveries: new Set(),
  // Validations whose findings have already been put in front of the user.
  shownFindings: new Set(),
};

function byId(id) {
  return document.getElementById(id);
}

function readPreference(key, fallback = "") {
  try {
    const value = window.localStorage.getItem(key);
    return value === null ? fallback : value;
  } catch {
    return fallback;
  }
}

function element(tag, className = "", text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function plainPath(path) {
  const text = String(path || "");
  return text.startsWith(VERBATIM_PREFIX) ? text.slice(VERBATIM_PREFIX.length) : text;
}

function comparablePath(path) {
  return plainPath(path).replace(/^UNC\\/i, "\\\\").replace(/[\\/]+$/, "");
}

function samePath(left, right) {
  return comparablePath(left).toLowerCase() === comparablePath(right).toLowerCase();
}

function projectName(path) {
  const parts = String(path || "").split(/[\\/]+/).filter(Boolean);
  return parts.slice(-2).join(" / ") || "Ingen prosjekt valgt";
}

function agentInfo(agent) {
  return (state.catalog?.agents || []).find((info) => info.id === agent) || null;
}

function agentLabel(agent) {
  return agentInfo(agent)?.label || agent || "agent";
}

function formatTime(unixMs) {
  const date = new Date(Number(unixMs) || Date.now());
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

function applyTheme() {
  const theme = readPreference("agentsync.theme", "dark") === "light" ? "light" : "dark";
  if (document.documentElement.dataset.theme === theme) return;
  document.documentElement.dataset.theme = theme;
  document.querySelector('meta[name="color-scheme"]')?.setAttribute("content", theme);
}

// The main window remembers the writer per project. The validator deliberately
// has its own setup, otherwise an "independent" check would default to the same
// agent and model that wrote the change.
function projectSetup(projectPath = state.project) {
  try {
    const setups = JSON.parse(readPreference(PROJECT_SETUPS_KEY, "{}"));
    const wanted = plainPath(projectPath).toLowerCase();
    return wanted && setups && typeof setups === "object" ? setups[wanted] || null : null;
  } catch {
    return null;
  }
}

function validatorSetup(projectPath = state.project) {
  try {
    const setups = JSON.parse(readPreference(VALIDATOR_SETUPS_KEY, "{}"));
    const wanted = plainPath(projectPath).toLowerCase();
    return wanted && setups && typeof setups === "object" ? setups[wanted] || null : null;
  } catch {
    return null;
  }
}

function persistValidatorSetup() {
  if (!state.project) return;
  try {
    const stored = JSON.parse(readPreference(VALIDATOR_SETUPS_KEY, "{}"));
    const setups = stored && typeof stored === "object" && !Array.isArray(stored) ? stored : {};
    setups[plainPath(state.project).toLowerCase()] = {
      agent: state.agent,
      model: state.model,
      level: byId("controlLevel").value || "",
    };
    const entries = Object.entries(setups).slice(-100);
    window.localStorage.setItem(VALIDATOR_SETUPS_KEY, JSON.stringify(Object.fromEntries(entries)));
  } catch {
    // The current selection remains usable even if preferences are unavailable.
  }
}

// Every automatic validation so far was run by the same agent, because the
// remembered choice always went first in the queue. One agent's blind spot then
// becomes every validation's blind spot. Automatic runs now rotate: the agent
// that validated longest ago goes first. A manual control still uses whatever
// the panel is set to.
function validatorRotation(projectPath = state.project) {
  try {
    const stored = JSON.parse(readPreference(VALIDATOR_ROTATION_KEY, "{}"));
    const used = stored?.[plainPath(projectPath).toLowerCase()];
    return Array.isArray(used) ? used.filter((id) => typeof id === "string") : [];
  } catch {
    return [];
  }
}

function rememberValidatorUse(projectPath, agentId) {
  if (!projectPath || !agentId) return;
  try {
    const stored = JSON.parse(readPreference(VALIDATOR_ROTATION_KEY, "{}"));
    const map = stored && typeof stored === "object" && !Array.isArray(stored) ? stored : {};
    const key = plainPath(projectPath).toLowerCase();
    const used = Array.isArray(map[key]) ? map[key].filter((id) => id !== agentId) : [];
    map[key] = [agentId, ...used].slice(0, AGENT_ORDER.length);
    const entries = Object.entries(map).slice(-100);
    window.localStorage.setItem(VALIDATOR_ROTATION_KEY, JSON.stringify(Object.fromEntries(entries)));
  } catch {
    // Rotation is a preference. Losing it costs coverage, never correctness.
  }
}

function availableAgents() {
  return AGENT_ORDER.map(agentInfo).filter((info) => info && info.available);
}

function effectiveModel(agent, selected = "") {
  return selected || agentInfo(agent)?.model || "";
}

function missionPurpose(mission) {
  const purpose = String(mission?.purpose || "");
  if (["writer", "manualControl", "validator"].includes(purpose)) return purpose;
  return mission?.mode === "blind" ? "manualControl" : "writer";
}

function missionActive(mission) {
  return mission?.status === "queued" || mission?.status === "running";
}

function missionChangedFiles(mission) {
  const value = mission?.changedFiles ?? mission?.workspaceAfter?.changedFiles;
  return Number.isFinite(Number(value)) ? Number(value) : 0;
}

function resetWriterObservation() {
  state.writerStates.clear();
  state.observedAt = Date.now();
  state.activeWriter = null;
  state.pendingSources.clear();
  state.autoMissionIds.clear();
  state.autoError = "";
  state.findings.clear();
  state.findingsPending.clear();
  state.shownFindings.clear();
}

function writerSetup(projectPath = state.project) {
  const setup = projectSetup(projectPath) || {};
  const agent = String(setup.agent || "");
  return {
    agent,
    model: effectiveModel(agent, String(setup.model || "")),
  };
}

function validatorDiffersFromWriter(writerAgent = writerSetup().agent) {
  return Boolean(state.agent && (!writerAgent || state.agent !== writerAgent));
}

function chooseValidatorSetup() {
  const saved = validatorSetup() || {};
  const writer = writerSetup();
  const agents = availableAgents();
  const savedAgent = agents.find((info) => info.id === saved.agent && info.id !== writer.agent);
  const chosen = savedAgent || agents.find((info) => info.id !== writer.agent) || null;
  state.agent = chosen?.id || "";
  const known = Array.isArray(state.catalog?.models?.[state.agent]) ? state.catalog.models[state.agent] : [];
  state.model = known.includes(saved.model) ? saved.model : "";
  byId("controlLevel").value = ["", "normal", "max", "ultra"].includes(saved.level) ? saved.level : "";
}

function comparableModel(model) {
  // Match the backend: only documented transport prefixes, never arbitrary
  // namespaces or quantization suffixes. The displayed raw name is preserved.
  return String(model || "").trim().toLowerCase()
    .replace(/^(?:(?:ollama-cloud|ollama_chat|ollama|openai|anthropic|google|openrouter)\/)+/, "");
}

function validatorChoiceForSource(source) {
  const projectPath = plainPath(source?.projectPath || "");
  const saved = validatorSetup(projectPath) || {};
  const configuredWriter = writerSetup(projectPath).agent;
  const sourceAgent = String(source?.agent || "");
  const sourceModel = comparableModel(source?.resolvedModel || source?.model);
  const agents = availableAgents();
  const ordered = [];
  const remember = (info) => {
    if (info && info.id !== sourceAgent && !ordered.some((item) => item.id === info.id)) ordered.push(info);
  };
  // Least recently used first: an agent that has never validated this project
  // comes before one that validated yesterday, which comes before today's.
  const used = window.AgentSyncSettings?.enabled("validation.rotate") !== false ? validatorRotation(projectPath) : [];
  // The list runs newest first, so a higher index means longer ago. An agent
  // that has never validated this project is staler than any that has.
  const staleness = (info) => {
    const index = used.indexOf(info.id);
    return index === -1 ? used.length + 1 : index;
  };
  if (window.AgentSyncSettings?.enabled("validation.rotate") !== false) {
    agents
      .filter((info) => info.id !== configuredWriter)
      .slice()
      .sort((left, right) => staleness(right) - staleness(left))
      .forEach(remember);
  }
  remember(agents.find((info) => info.id === saved.agent));
  agents.forEach(remember);

  for (const info of ordered) {
    const known = Array.isArray(state.catalog?.models?.[info.id]) ? state.catalog.models[info.id] : [];
    const candidates = [info.id === saved.agent ? saved.model : "", info.model, ...known]
      .map((model) => String(model || "").trim())
      .filter((model, index, all) => model && all.indexOf(model) === index);
    const model = candidates.find((candidate) => comparableModel(candidate) !== sourceModel);
    if (!model) continue;
    return {
      project: projectPath,
      agent: info.id,
      model,
      level: ["", "normal", "max", "ultra"].includes(saved.level) ? saved.level : "",
    };
  }
  return null;
}

function renderWriter() {
  const writer = writerSetup();
  byId("controlWriter").textContent = writer.agent
    ? `Skriveagent: ${agentLabel(writer.agent)}${writer.model ? ` · ${writer.model}` : ""}. Velg en annen agent til kontrollen.`
    : "Ingen skriveagent er valgt. Valideringsagenten kan fortsatt styres manuelt.";
}

// Measured on this machine: 72, 86 and 81 seconds per changed file, on changes
// of 2, 3 and 7 files. Rounded down to a minute, because a range that pretends
// to be precise is worse than one that admits it is an estimate.
const SECONDS_PER_CHANGED_FILE = 80;

function estimateMinutes(source) {
  const files = missionChangedFiles(source);
  return files ? Math.max(1, Math.round((files * SECONDS_PER_CHANGED_FILE) / 60)) : 0;
}

function validationEstimate(source) {
  if (window.AgentSyncSettings?.enabled("validation.estimate") === false) return "";
  const files = missionChangedFiles(source);
  if (!files) return "";
  window.AgentSyncSettings?.used("validation.estimate");
  const minutes = estimateMinutes(source);
  return ` ${files === 1 ? "Én fil" : `${files} filer`}, anslagsvis ${minutes} ${minutes === 1 ? "minutt" : "minutter"}.`;
}

function renderLive(text = "", kind = "") {
  if (!presentationVisible()) { state.presentationDirty = true; return; }
  const badge = byId("controlLiveBadge");
  const live = byId("controlLiveText");
  const active = state.runs.find((run) => missionActive(run) && missionPurpose(run) === "validator");
  const writer = state.activeWriter;
  const startingHere = state.starting && (!state.startingProject || samePath(state.startingProject, state.project));
  const autoErrorHere = state.autoError && (!state.autoErrorProject || samePath(state.autoErrorProject, state.project));
  let label = "på · venter";
  let message = text || "Klar. Validerer etter neste fullførte skriveoppdrag som endrer filer.";
  let tone = kind;
  if (!state.enabled) {
    label = "av";
    message = "Valideringsagenten er slått av fra venstreskinnen.";
    tone = "off";
  } else if (active) {
    label = "på · arbeider";
    message = `${active.agentLabel || agentLabel(active.agent)} validerer den siste endringen nå.`;
    tone = "running";
  } else if (startingHere) {
    label = "på · starter";
    message = state.startingMode === "blind" ? "Klargjør en blind kopi for validering." : "Klargjør kontroll i prosjektet selv.";
    tone = "running";
  } else if (window.AgentSyncSettings?.enabled("validation.auto") === false) {
    label = "på · manuelt";
    message = "Automatisk start er av. Du kan fortsatt velge Kontroller nå.";
  } else if (writer) {
    label = "på · følger";
    message = window.AgentSyncSettings?.enabled("validation.auto") === false
      ? "Automatisk start er av. Du kan fortsatt velge Kontroller nå."
      : `${writer.agentLabel || agentLabel(writer.agent)} skriver. Valideringen starter først når filene er stabile.`;
  } else if ([...state.pendingSources.values()].some(({ source }) => samePath(source?.projectPath, state.project))) {
    label = "på · klargjør";
    const pending = [...state.pendingSources.values()]
      .map(({ source }) => source)
      .find((source) => samePath(source?.projectPath, state.project));
    message = `En endring er klar. Venter et kort øyeblikk før valideringen starter.${validationEstimate(pending)}`;
  } else if (autoErrorHere) {
    label = "på · trenger hjelp";
    message = state.autoError;
    tone = "error";
  }
  if (badge.textContent !== label) badge.textContent = label;
  badge.className = `control-pin${tone ? ` ${tone}` : ""}`;
  if (live.textContent !== message) live.textContent = message;
  byId("controlLiveText").closest(".control-live")?.setAttribute("data-state", tone || "waiting");
}

function loadStartedRuns() {
  state.started = new Set();
  if (!state.project) return;
  try {
    const stored = JSON.parse(readPreference(CONTROL_RUNS_KEY, "{}"));
    const ids = stored && typeof stored === "object" ? stored[plainPath(state.project).toLowerCase()] : null;
    if (Array.isArray(ids)) state.started = new Set(ids.filter((id) => typeof id === "string"));
  } catch {
    // A damaged preference must not block new controls.
  }
}

function rememberStartedRun(missionId, projectPath = state.project) {
  if (!projectPath || !missionId) return;
  try {
    const stored = JSON.parse(readPreference(CONTROL_RUNS_KEY, "{}"));
    const runs = stored && typeof stored === "object" && !Array.isArray(stored) ? stored : {};
    const key = plainPath(projectPath).toLowerCase();
    const previous = samePath(projectPath, state.project) ? [...state.started] : Array.isArray(runs[key]) ? runs[key] : [];
    const ids = Array.from(new Set([missionId, ...previous])).slice(0, 100);
    runs[key] = ids;
    window.localStorage.setItem(CONTROL_RUNS_KEY, JSON.stringify(runs));
    if (samePath(projectPath, state.project)) state.started = new Set(ids);
  } catch {
    // The current window still tracks the run even if preferences are unavailable.
  }
}

function setStatus(text, kind = "") {
  const node = byId("controlStatus");
  node.textContent = text;
  node.className = `control-status${kind ? ` ${kind}` : ""}`;
}

function renderProject() {
  byId("controlProject").textContent = state.project ? projectName(state.project) : "Velg prosjekt i hovedvinduet";
  syncRunButton();
}

function renderAgents() {
  const host = byId("controlAgents");
  host.replaceChildren();
  const writer = writerSetup();
  const agents = availableAgents();
  for (const info of agents) {
    const isWriter = info.id === writer.agent;
    const chip = element("button", `bar-chip control-agent${state.agent === info.id ? " primary" : ""}`);
    chip.type = "button";
    chip.setAttribute("role", "radio");
    chip.setAttribute("aria-checked", String(state.agent === info.id));
    chip.append(element("span", "agent-mark", AGENT_MARKS[info.id] || "•"), ` ${info.label}`);
    chip.disabled = isWriter;
    attachPeek(chip, isWriter ? `${info.label} skriver i prosjektet. Velg en annen agent til validering.` : (info.note || info.label), { head: info.label });
    chip.addEventListener("click", () => {
      state.agent = info.id;
      state.model = "";
      renderAgents();
      renderModels();
      persistValidatorSetup();
      syncRunButton();
    });
    host.append(chip);
  }
  if (!agents.length) host.append(element("span", "control-muted", "Ingen agenter er klare."));
}

function renderModels() {
  const select = byId("controlModel");
  select.replaceChildren();
  const info = agentInfo(state.agent);
  const known = Array.isArray(state.catalog?.models?.[state.agent]) ? state.catalog.models[state.agent] : [];
  select.append(new Option(info?.model ? `Standard (${info.model})` : "Standard (oppdages ved start)", ""));
  for (const model of known) select.append(new Option(model, model));
  select.value = known.includes(state.model) ? state.model : "";
  select.disabled = !state.agent;
}

function renderPresets() {
  const host = byId("controlPresets");
  host.replaceChildren();
  for (const preset of PRESETS) {
    const chip = element("button", "bar-chip control-preset", preset);
    chip.type = "button";
    chip.addEventListener("click", () => {
      byId("controlPrompt").value = preset;
      syncRunButton();
      byId("controlPrompt").focus();
    });
    host.append(chip);
  }
}

function syncRunButton() {
  const ready = Boolean(invoke && state.enabled && state.project && state.agent && validatorDiffersFromWriter() && byId("controlPrompt").value.trim() && !state.starting);
  byId("controlRun").disabled = !ready;
}

async function loadCatalog() {
  const lifecycle = state.lifecycle;
  const request = ++state.catalogRequest;
  if (!invoke) {
    setStatus("Tilkoblingen til appen mangler.", "warn");
    return;
  }
  try {
    if (!state.catalog || Date.now() - state.catalogLoadedAt >= 60000) {
      const catalog = await invoke("get_intent_catalog");
      if (!state.open || lifecycle !== state.lifecycle || request !== state.catalogRequest) return false;
      state.catalog = catalog;
      state.catalogLoadedAt = Date.now();
    }
    const snapshot = window.AgentSyncStatus?.current() || await window.AgentSyncStatus?.refresh();
    if (!state.open || lifecycle !== state.lifecycle || request !== state.catalogRequest) return false;
    const runtime = snapshot?.runtime;
    state.enabled = Boolean(runtime?.enabled);
    state.generation = Number(runtime?.generation) || 0;
    state.enabledSince = Number(runtime?.enabledSinceUnixMs) || state.observedAt;
  } catch (error) {
    if (!state.open || lifecycle !== state.lifecycle || request !== state.catalogRequest) return false;
    setStatus(`Kunne ikke lese katalogen: ${error}`, "error");
    return;
  }
  chooseValidatorSetup();
  state.writerSetupSignature = JSON.stringify(projectSetup() || {});
  renderWriter();
  renderAgents();
  renderModels();
  persistValidatorSetup();
  syncRunButton();
  renderLive();
  return true;
}

// What kind of change this is, read off the diff itself. A model could be
// asked to classify first, but that costs a round trip and, worse, anchors the
// review before it starts - which is the contamination blind mode exists to
// avoid. A diffstat cannot hallucinate.
// The file names live in workspaceAfter.status, in porcelain form ("M  path").
// diffStat is a one-line summary, and in checkpoint mode it is written in
// Norwegian - reading it as a file list handed the validator the sentence
// "6 filer endret: 0 lagt til, 6 endret, 0 slettet" as though it were a path,
// and left it to survey the whole project instead. It read eighteen files,
// filled its context and answered with nothing.
function changedFileNames(source) {
  const status = String(source?.workspaceAfter?.status || "");
  const fromStatus = status
    .split(/\r?\n/)
    .map((line) => line.replace(/^[A-Z?! ]{1,2}\s+/, "").trim())
    .map((name) => name.replace(/^"|"$/g, ""))
    // A rename reads "old -> new"; the new path is the one to look at.
    .map((name) => (name.includes(" -> ") ? name.split(" -> ").pop().trim() : name))
    .filter(Boolean);
  if (fromStatus.length) return fromStatus;
  // Git mode without a status line: fall back to the diff's own headers.
  return [...String(source?.workspaceAfter?.diff || "").matchAll(/^\+\+\+ b\/(.+)$/gm)]
    .map((match) => match[1].trim())
    .filter((name) => name && name !== "/dev/null");
}

function changeShape(source) {
  const files = changedFileNames(source);
  const has = (pattern) => files.some((name) => pattern.test(name));
  const notes = [];
  notes.push(has(/(^|[\\/])(tests?|__tests__|spec)[\\/]|\.(test|spec)\.[a-z]+$|_test\.[a-z]+$|\.Tests\.ps1$/i)
    ? "Testfiler er endret i samme omgang."
    : "Ingen testfiler er endret.");
  if (has(/(package(-lock)?\.json|cargo\.(toml|lock)|composer\.(json|lock)|go\.(mod|sum)|pyproject\.toml|requirements.*\.txt)$/i)) {
    notes.push("Avhengigheter er endret.");
  }
  if (has(/\.(json|toml|ya?ml|ini|conf|cfg|env)$/i)) notes.push("Konfigurasjon er endret.");
  if (has(/\.(md|rst|txt)$/i)) notes.push("Dokumentasjon er endret.");
  return notes.join(" ");
}

// A validation is about a change, not a survey. Told only that "six files
// changed", the validator read eighteen files, filled its context and answered
// with nothing at all. Naming the files keeps it on the change and inside its
// budget - and it is what a reviewer gets in any case: the diff, not the world.
const VALIDATION_FILE_LIMIT = 40;

// Measured here at about 80 seconds per changed file. A single-file change is
// rarely worth that, and the register shows most of them find nothing.
const VALIDATION_FLOOR_FILES = 2;

function belowValidationFloor(source) {
  if (window.AgentSyncSettings?.enabled("validation.floor") === false) return false;
  const files = missionChangedFiles(source);
  const below = files > 0 && files < VALIDATION_FLOOR_FILES;
  if (below) window.AgentSyncSettings?.used("validation.floor");
  return below;
}

function automaticPrompt(source, blind = true) {
  const files = changedFileNames(source);
  const changed = files.length || missionChangedFiles(source);
  const list = files.length
    ? [
        `Disse filene ble endret:${files.slice(0, VALIDATION_FILE_LIMIT).map((name) => `\n  ${name}`).join("")}`,
        files.length > VALIDATION_FILE_LIMIT ? `  … og ${files.length - VALIDATION_FILE_LIMIT} til.` : "",
        "Se på disse filene og det som kaller dem. Ikke gjennomgå resten av prosjektet.",
      ].filter(Boolean).join("\n")
    : "Filnavnene er ikke kjent. Hold deg til det du kan verifisere raskt, og si fra om at du ikke fikk vite hvilke filer som ble endret.";
  return [
    "Gjør en uavhengig hjelpevalidering av en endring i dette prosjektet.",
    `${source.agentLabel || agentLabel(source.agent)} fullførte nettopp et skriveoppdrag som endret ${changed === 1 ? "én fil" : `${changed} filer`}.`,
    changeShape(source),
    list,
    "Ikke les eller gjett skriveagentens konklusjon. Undersøk resultatet selv.",
    // In a blind copy the history is not there to read. Here it is, and the
    // only thing keeping the check independent is this sentence. Say so.
    blind ? "" : "Denne kontrollen kjører i prosjektet selv. Ikke åpne .agent-state, .git eller de andre agentenes notater. Ingenting hindrer deg teknisk; uavhengigheten hviler på at du lar det være.",
    "Prioriter konkrete feil, regresjoner, sikkerhetsrisiko og manglende tester. Oppgi fil og linje når det er mulig.",
    "Finner du ingenting som er verdt å kritisere, er det et fullgodt svar. Si det rett ut, og skriv hva du undersøkte, slik at leseren ser at du faktisk så etter. Ikke finn på et funn for å ha noe å levere.",
    "Svar alltid med en kort skriftlig konklusjon til slutt, selv om den bare er én setning. Et tomt svar kan ikke leses som en frikjennelse.",
    "Ikke endre filer.",
  ].filter(Boolean).join("\n");
}

async function runControl(options = {}) {
  const automatic = options.automatic === true;
  if (automatic && window.AgentSyncSettings?.enabled("validation.auto") === false) return "skipped";
  const source = options.source || null;
  // Blind is the strong arm: independence is a property of the copy. Shared is
  // the cheap arm, where it rests on the prompt. The register records which,
  // so the two can be compared instead of assumed.
  const blindRun = automatic
    ? window.AgentSyncSettings?.enabled("validation.blind") !== false
    : byId("controlBlind").checked;
  const prompt = automatic ? automaticPrompt(source, blindRun) : byId("controlPrompt").value.trim();
  const automaticSetup = automatic ? validatorChoiceForSource(source) : null;
  const target = automaticSetup || {
    project: state.project,
    agent: state.agent,
    model: byId("controlModel").value || "",
    level: byId("controlLevel").value || "",
  };
  if (automatic && !automaticSetup) {
    state.autoError = `Ingen annen agent med en kjent, forskjellig modell kan validere ${projectName(source?.projectPath)}.`;
    state.autoErrorProject = plainPath(source?.projectPath);
    return "error";
  }
  const differentAgent = automatic ? target.agent !== source?.agent : validatorDiffersFromWriter();
  if (!invoke || !state.enabled || window.AgentSyncSettings?.enabled("validation") === false || !target.project || !target.agent || !differentAgent || !prompt || state.starting) return "skipped";
  const blind = blindRun;
  const lifecycle = state.lifecycle;
  const currentView = () => state.open && state.lifecycle === lifecycle && samePath(target.project, state.project);
  const button = byId("controlRun");
  state.starting = true;
  state.startingMode = blind ? "blind" : "shared";
  state.startingProject = target.project;
  button.disabled = true;
  if (currentView()) setStatus(automatic ? `Klargjør validering av ${projectName(target.project)}…` : (blind ? "Lager blind kopi og starter…" : "Starter…"));
  let missionId = "";
  try {
    // A blind run works in its own copy, so it never collides with an agent
    // working in the project; running it alongside is the point.
    const result = await invoke("start_mission", {
      request: {
        projectPath: target.project,
        prompt,
        agent: target.agent,
        model: target.model || null,
        level: target.level || null,
        force: blind,
        mode: blind ? "blind" : "shared",
        purpose: automatic ? "validator" : "manualControl",
        sourceMissionId: automatic ? source?.id || null : null,
        validatorGeneration: state.generation,
      },
    });
    missionId = String(result?.missionId || "");
    if (!missionId) throw new Error("Oppstartsbekreftelsen mangler oppdrags-ID.");
    rememberStartedRun(missionId, target.project);
    state.launchedRuns.add(missionId);
    if (currentView()) state.selectedRun = missionId;
    if (automatic && missionId) {
      rememberValidatorUse(target.project, target.agent);
      window.AgentSyncSettings?.used("validation.auto");
      window.AgentSyncSettings?.used("validation.rotate");
      if (blind) window.AgentSyncSettings?.used("validation.blind");
      state.autoMissionIds.set(missionId, String(source?.id || ""));
      const minutes = estimateMinutes(source);
      if (minutes) (state.autoEstimates ||= new Map()).set(missionId, minutes);
    }
    state.autoError = "";
    state.autoErrorProject = "";
    window.AgentSyncSettings?.used("validation");
    if (currentView()) setStatus(automatic ? "Automatisk validering startet." : (blind ? "Blind kontroll startet." : "Kontroll startet."), "ok");
    return "started";
  } catch (error) {
    const message = String(error);
    if (automatic && message.includes("VALIDATOR_WAIT")) {
      if (currentView()) setStatus("Venter til skriveagenten og filene er klare.");
      return "wait";
    }
    if (automatic && message.includes("VALIDATOR_ALREADY_DONE")) {
      return "done";
    }
    if (automatic) {
      state.autoError = `Automatisk validering kunne ikke starte: ${message}`;
      state.autoErrorProject = plainPath(target.project);
    }
    if (currentView()) setStatus(message.includes("AGENT_BUSY") ? `${message.replace(/^.*AGENT_BUSY:\s*/s, "")} Slå på Blind for å kjøre ved siden av.` : `Kunne ikke starte: ${message}`, "error");
    return "error";
  } finally {
    state.starting = false;
    state.startingMode = "";
    state.startingProject = "";
    syncRunButton();
    if (!automatic) {
      await window.AgentSyncStatus?.refresh();
      if (missionId && currentView()) await showFindings(missionId);
    }
  }
}

// How long an active run has been going, and whether it has passed what was
// estimated for it. Without this the panel says "arbeider" for seven minutes
// and there is no way to tell that apart from a hung process.
function runProgress(run) {
  if (window.AgentSyncSettings?.enabled("validation.progress") === false) return "";
  if (!run.startedUnixMs) return "";
  window.AgentSyncSettings?.used("validation.progress");
  const minutes = Math.floor((Date.now() - run.startedUnixMs) / 60000);
  const elapsed = minutes < 1 ? "under ett minutt" : `${minutes} min`;
  // The estimate kept from when this run was queued, made from the writer's
  // change. A control has no change of its own to estimate from, so a manual
  // one simply has no estimate and says nothing about one.
  const estimate = state.autoEstimates?.get(run.id) || 0;
  const over = estimate && minutes > estimate * 2
    ? ` · over dobbelt av anslaget på ${estimate} min`
    : "";
  return ` · ${elapsed}${over}`;
}

function runStatus(run) {
  if (run.status === "queued") return `${run.phase || "venter"}${runProgress(run)}`;
  if (run.status === "running") return `${run.phase || "arbeider"}${runProgress(run)}`;
  if (run.status === "completed") return "ferdig";
  if (run.status === "failed") return "feilet";
  if (run.status === "canceled") return "avbrutt";
  return run.status || "ukjent";
}

function compactSubject(value, limit = 112) {
  const text = String(value || "")
    .replace(/^[#>*\-\s]+/, "")
    .replace(/\s+/g, " ")
    .trim();
  if (!text) return "Siste endring i prosjektet";
  return text.length > limit ? `${text.slice(0, limit - 1).trimEnd()}…` : text;
}

function runSubject(run) {
  const source = run?.sourceMissionId
    ? state.missionsById.get(String(run.sourceMissionId))
    : null;
  return compactSubject(source?.prompt || run?.prompt);
}

function severityRank(value) {
  return ({ hoy: 3, "høy": 3, high: 3, middels: 2, medium: 2, lav: 1, low: 1 })[String(value || "").toLowerCase()] || 0;
}

function digestFromReport(report) {
  if (!report || !["findings", "clean", "unreadable"].includes(report.outcome)) return null;
  const findings = Array.isArray(report.findings) ? report.findings : [];
  let top = null;
  for (const finding of findings) {
    if (!top || severityRank(finding.severity) > severityRank(top.severity)) top = finding;
  }
  return {
    outcome: report.outcome,
    count: report.outcome === "unreadable" ? null : findings.length,
    topSeverity: top?.severity || null,
    topTitle: top?.title || null,
    topFile: top?.file || null,
  };
}

function runDigest(run) {
  return digestFromReport(state.findings.get(run?.id)) || run?.validationDigest || null;
}

function runPresentation(run) {
  const active = missionActive(run);
  if (active) return { kind: "running", title: "Kontrollen arbeider", badge: runStatus(run) };
  if (run?.status === "failed") return { kind: "failed", title: "Kontrollen feilet", badge: "Feilet" };
  if (run?.status === "canceled") return { kind: "canceled", title: "Kontrollen ble avbrutt", badge: "Avbrutt" };

  const digest = runDigest(run);
  if (digest?.outcome === "findings") {
    const count = digest.count !== null && digest.count !== undefined && Number.isFinite(Number(digest.count))
      ? Number(digest.count)
      : null;
    const severity = String(digest.topSeverity || "").toLowerCase();
    const severityText = ({ hoy: "høy", "høy": "høy", high: "høy", middels: "middels", medium: "middels", lav: "lav", low: "lav" })[severity] || "";
    return {
      kind: severityRank(severity) >= 3 ? "high" : severityRank(severity) === 2 ? "medium" : "low",
      title: digest.topTitle || (count === 1 ? "Ett konkret funn" : "Konkrete funn"),
      badge: count === null ? "Funn" : `${count} ${count === 1 ? "funn" : "funn"}${severityText ? ` · ${severityText}` : ""}`,
      file: digest.topFile || "",
    };
  }
  if (digest?.outcome === "clean") return { kind: "clean", title: "Ingen konkrete funn", badge: "Ingen funn" };
  if (digest?.outcome === "unreadable") return { kind: "unreadable", title: "Resultatet kunne ikke tolkes", badge: "Må leses" };
  if (run?.status === "completed_warning") return { kind: "warning", title: "Ferdig med en teknisk merknad", badge: "Merknad" };
  return { kind: "unread", title: "Resultatet er ikke lest ennå", badge: "Åpne resultat" };
}

function detailMeta(run) {
  return [
    run?.agentLabel || agentLabel(run?.agent),
    missionPurpose(run) === "validator" ? "automatisk" : "manuell",
    run?.mode === "blind" ? "blind" : "delt",
    window.AgentSyncStatus?.modelLabel(run) || run?.model || "modell ikke registrert",
    formatTime(run?.startedUnixMs),
  ].filter(Boolean).join(" · ");
}

function showDetailShell(run, resetScroll = true) {
  if (!run) return;
  const presentation = runPresentation(run);
  const browser = byId("controlBrowser");
  const detail = byId("controlDetail");
  browser.classList.add("has-selection");
  detail.hidden = false;
  detail.dataset.kind = presentation.kind;
  byId("controlDetailTitle").textContent = presentation.title;
  byId("controlDetailMeta").textContent = `${detailMeta(run)} · Kontroll av: ${runSubject(run)}`;
  const raw = byId("controlRawDetails");
  raw.open = missionActive(run);
  byId("controlRawSummary").textContent = missionActive(run) ? "Direkte agenttekst" : "Hele agentrapporten";
  if (resetScroll) byId("controlDetailScroll").scrollTop = 0;
}

function closeRunDetail({ focus = true, render = true } = {}) {
  const missionId = state.selectedRun;
  state.selectedRun = "";
  state.findingsRequest += 1;
  clearFindingButtons();
  const pane = byId("controlFindings");
  pane.hidden = true;
  pane.textContent = "";
  delete pane.dataset.missionId;
  delete pane.dataset.status;
  byId("controlDetail").hidden = true;
  byId("controlBrowser").classList.remove("has-selection");
  if (render) renderRuns(true);
  if (focus && missionId) {
    [...byId("controlList").querySelectorAll("[data-mission]")]
      .find((row) => row.dataset.mission === missionId)
      ?.focus();
  }
}

function renderRuns(force = false) {
  if (!presentationVisible()) { state.presentationDirty = true; return; }
  const host = byId("controlList");
  const signature = JSON.stringify({
    selectedRun: state.selectedRun,
    runs: state.runs.map((run) => ({
      id: run.id,
      status: run.status,
      phase: run.phase,
      agent: run.agent,
      model: run.model,
      resolvedModel: run.resolvedModel,
      modelSource: run.modelSource,
      purpose: missionPurpose(run),
      mode: run.mode,
      startedUnixMs: run.startedUnixMs,
      subject: runSubject(run),
      presentation: runPresentation(run),
      // Coarse enough that the list redraws once a minute while something is
      // running, and never while nothing is.
      minute: run.status === "queued" || run.status === "running"
        ? Math.floor((Date.now() - run.startedUnixMs) / 60000)
        : 0,
    })),
  });
  if (!force && signature === state.runsSignature) return;
  state.runsSignature = signature;
  const focusedMission = host.contains(document.activeElement)
    ? document.activeElement?.dataset?.mission || ""
    : "";
  host.replaceChildren();
  if (!state.runs.length) {
    host.append(element("div", "control-muted", "Ingen kontroller ennå."));
    return;
  }
  for (const run of state.runs) {
    const active = run.status === "queued" || run.status === "running";
    const presentation = runPresentation(run);
    const selected = state.selectedRun === run.id;
    const row = element("button", `control-item ${presentation.kind}${selected ? " selected" : ""}${active ? " running" : ""}`);
    row.type = "button";
    row.dataset.mission = run.id;
    row.setAttribute("aria-controls", "controlDetail");
    row.setAttribute("aria-current", selected ? "true" : "false");
    const head = element("div", "control-item-head");
    const identity = element("span", "control-item-agent");
    identity.append(
      element("span", "agent-mark", AGENT_MARKS[run.agent] || "•"),
      element("b", "", run.agentLabel || agentLabel(run.agent)),
    );
    head.append(identity, element("span", `control-item-badge ${presentation.kind}`, presentation.badge));
    const title = element("div", "control-item-title", presentation.title);
    const subject = element("div", "control-item-subject", `Kontroll av: ${runSubject(run)}`);
    const meta = element("div", "control-item-meta", [run.mode === "blind" ? "Blind" : "Delt", window.AgentSyncStatus?.modelLabel(run) || run.model || "modell ikke registrert", formatTime(run.startedUnixMs)].join(" · "));
    row.append(head, title);
    if (presentation.file) row.append(element("div", "control-item-file", presentation.file));
    row.append(subject, meta);
    row.addEventListener("click", () => showFindings(run.id));
    host.append(row);
  }
  if (focusedMission) {
    [...host.querySelectorAll("[data-mission]")]
      .find((row) => row.dataset.mission === focusedMission)
      ?.focus();
  }
}

function clearFindingButtons() {
  hidePeek({ force: true });
  state.topSend = null;
  byId("controlFindingList").replaceChildren();
  const verdict = byId("controlVerdict");
  verdict.hidden = true;
  verdict.replaceChildren();
  verdict.className = "control-verdict";
}

function showVerdict(kind, node) {
  const verdict = byId("controlVerdict");
  verdict.className = `control-verdict${kind ? ` ${kind}` : ""}`;
  verdict.replaceChildren(node);
  verdict.hidden = false;
}

// Each finding becomes a button carrying the whole critique. Pressing it hands
// that text to the agent running in the canvas, exactly as if the user had
// pasted it and pressed Kjør.
// A hover that explains, in the app's own frame instead of the operating
// system's tooltip: the exact text that would be sent on. "Vis teksten" pins
// it open. The send button never opens it, so reading and sending stay
// separate actions - one of them costs a mission.
const HOVER_PEEK_DELAY_MS = 1100;
const peek = { node: null, timer: 0, pinned: false, anchor: null };

function peekNode() {
  if (peek.node) return peek.node;
  peek.node = element("div", "finding-peek");
  peek.node.hidden = true;
  document.body.append(peek.node);
  return peek.node;
}

function hidePeek({ force = false } = {}) {
  window.clearTimeout(peek.timer);
  if (peek.pinned && !force) return;
  peek.pinned = false;
  peek.anchor = null;
  if (peek.node) peek.node.hidden = true;
}

// getBoundingClientRect reports viewport pixels; a fixed element's left and top
// are read as layout pixels and then scaled. Under the app's zoom control the
// two differ by exactly the zoom factor, and the popup landed 339 px right and
// 195 px low at 140 %. Everything below is computed in layout space, with the
// factor measured on the anchor rather than read from the zoom setting.
function layoutScale(element) {
  const rect = element.getBoundingClientRect();
  return element.offsetWidth > 0 && rect.width > 0 ? rect.width / element.offsetWidth : 1;
}

function showPeek(anchor, text, { pinned = false, head = "Dette sendes til agenten" } = {}) {
  if (anchor.isConnected === false || !String(text || "").trim()) return;
  const node = peekNode();
  node.replaceChildren(...[
    head ? element("div", "finding-peek-head", head) : null,
    element("pre", "finding-peek-body", String(text)),
  ].filter(Boolean));
  node.hidden = false;
  peek.pinned = pinned;
  peek.anchor = anchor;

  const scale = layoutScale(anchor);
  const viewWidth = window.innerWidth / scale;
  const viewHeight = window.innerHeight / scale;
  const width = Math.min(420, Math.max(240, viewWidth - 24));
  node.style.width = `${width}px`;

  const rect = anchor.getBoundingClientRect();
  const anchorLeft = rect.left / scale;
  const anchorTop = rect.top / scale;
  const anchorBottom = rect.bottom / scale;
  const height = node.offsetHeight;

  // Below the finding by preference, above it when there is no room. Sideways
  // it flips rather than slides: aligned to the finding's left edge, or to its
  // right edge when that would overflow, so the box stays visually attached
  // instead of sitting hundreds of pixels away from what it explains.
  const anchorRight = rect.right / scale;
  let left = anchorLeft;
  if (left + width > viewWidth - 12) left = anchorRight - width;
  // The stage can be wider than the window under zoom, so the finding itself
  // may sit partly off-screen. The box that explains it must not follow it out.
  left = Math.min(Math.max(12, left), Math.max(12, viewWidth - width - 12));
  let top = anchorBottom + 8;
  if (top + height > viewHeight - 12) {
    const above = anchorTop - height - 8;
    top = above >= 12 ? above : Math.max(12, viewHeight - height - 12);
  }
  node.style.left = `${left}px`;
  node.style.top = `${top}px`;
}

// A hover explanation on any element, in the app's own frame. The text may be
// a function, so a value that changes between hovers is read at hover time and
// never goes stale on the element.
function attachPeek(node, text, { head = "" } = {}) {
  if (!node) return node;
  const read = () => {
    const value = typeof node.peekText === "function" ? node.peekText() : node.peekText;
    return String(value == null ? "" : value).trim();
  };
  // A native title was also the accessible name of an icon-only control.
  // Replacing it must not leave the control unnamed, and must never overwrite
  // a name the element already has. Only a name this put there is refreshed.
  const name = () => {
    const ours = node.dataset.peekName === "1";
    if (!ours && (node.getAttribute("aria-label") || node.getAttribute("aria-labelledby"))) return;
    if (String(node.textContent || "").trim()) return;
    const value = read();
    if (!value) return;
    node.setAttribute("aria-label", value);
    node.dataset.peekName = "1";
  };
  // A title was reassigned on every render. Wiring the listeners once must not
  // freeze the text along with them, or a button that changes state keeps
  // explaining the state it was in when the panel first drew.
  node.peekText = text;
  node.peekHead = head;
  name();
  if (node.dataset.peek === "1") return node;
  node.dataset.peek = "1";
  const open = () => {
    // A pinned finding stays until it is dismissed. Hovering past something
    // else must not steal the box out from under it.
    if (peek.pinned) return;
    window.clearTimeout(peek.timer);
    peek.timer = 0;
    const value = read();
    if (value) showPeek(node, value, { head: node.peekHead });
    name();
  };
  const scheduleOpen = () => {
    if (peek.pinned) return;
    window.clearTimeout(peek.timer);
    peek.anchor = node;
    peek.timer = window.setTimeout(() => {
      peek.timer = 0;
      if (peek.pinned || peek.anchor !== node) return;
      open();
    }, HOVER_PEEK_DELAY_MS);
  };
  const close = () => {
    window.clearTimeout(peek.timer);
    peek.timer = 0;
    if (peek.anchor === node) hidePeek();
  };
  node.addEventListener("pointerenter", scheduleOpen);
  node.addEventListener("pointerleave", close);
  node.addEventListener("focus", open);
  node.addEventListener("blur", close);
  return node;
}

// One popup for the whole window: the validation panel and the canvas live in
// the same document, so sharing it is also what keeps two from opening at once.
window.AgentSyncPeek = {
  attach: attachPeek,
  show: (anchor, text, options) => showPeek(anchor, text, options),
  hide: (options) => hidePeek(options),
  pinned: () => peek.pinned,
};

function handleFindingShortcut(event) {
  if (event.key === "Escape") hidePeek({ force: true });
  // Once the list is read, the distance to acting on it is pure friction.
  if (event.key !== "Enter" || !(event.ctrlKey || event.metaKey)) return;
  if (event.defaultPrevented || event.repeat || event.isComposing || !presentationVisible()) return;
  if (!byId("controlPanel")?.contains(event.target)) return;
  if (window.AgentSyncSettings?.enabled("flow.shortcut") === false) return;
  // The control prompt has its own Ctrl+Enter, and a typed field is never the
  // place this fires from.
  const inField = ["TEXTAREA", "INPUT", "SELECT"].includes(event.target?.tagName)
    || event.target?.isContentEditable === true;
  if (inField || !state.topSend) return;
  event.preventDefault();
  state.topSend();
}
document.addEventListener("keydown", handleFindingShortcut);
document.addEventListener("pointerdown", (event) => {
  if (!peek.pinned) return;
  const inside = peek.node?.contains(event.target) || event.target.closest?.(".control-finding-peek");
  if (!inside) hidePeek({ force: true });
});

function showLimit(report) {
  const host = byId("controlFindingList");
  if (!report.couldNotCheck) return;
  if (window.AgentSyncSettings?.enabled("findings.limit") === false) return;
  window.AgentSyncSettings?.used("findings.limit");
  const note = element("div", "control-finding-limit");
  note.append(element("b", "", "Kunne ikke sjekkes: "), report.couldNotCheck);
  host.append(note);
}

function renderFindingButtons(report, missionId = state.selectedRun) {
  hidePeek({ force: true });
  state.topSend = null;
  const ownerProject = state.project;
  // When the findings first appeared in front of a person. Only counted while
  // the panel is actually on screen, so a list rendered into a hidden panel
  // does not start a clock nobody is watching. A re-render keeps the first
  // stamp: the question is how long the reader took, not the last redraw.
  state.findingsShownAt ||= new Map();
  if (presentationVisible() && !state.findingsShownAt.has(missionId)) {
    state.findingsShownAt.set(missionId, Date.now());
    while (state.findingsShownAt.size > 200) state.findingsShownAt.delete(state.findingsShownAt.keys().next().value);
  }
  const host = byId("controlFindingList");
  host.replaceChildren();
  const by = [report.validatorAgent, report.validatorModel].filter(Boolean).join(" · ");

  if (report.outcome === "unreadable") {
    // Never the same as clean: a validation that cannot be read is a failure,
    // not an acquittal.
    const node = element("span");
    node.append(element("b", "", "Kunne ikke leses. "), report.warning || "Valideringen ga ikke noe som kunne tolkes som funn.");
    showVerdict("unreadable", node);
    return;
  }

  if (report.outcome === "clean") {
    const node = element("span");
    node.append(element("b", "", "Fant ikke noe som er verdt å kritisere. "));
    if (report.checked) node.append(report.checked, " ");
    if (by) node.append(element("span", "control-muted", `Validert av ${by}.`));
    showVerdict("clean", node);
    // A clean verdict from a validation that could not run the tests is worth
    // less than one that could. The reader has to be told which they have.
    showLimit(report);
    return;
  }

  const node = element("span");
  node.append(
    element("b", "", `${report.findings.length} ${report.findings.length === 1 ? "funn" : "funn"}. `),
    "Send kritikken videre eller registrer om varslet var riktig. Sendt er ikke det samme som rettet."
  );
  if (report.checked) node.append(" ", element("span", "control-muted", report.checked));
  showVerdict("", node);
  showLimit(report);

  // Four findings in one file are one problem, not four. Grouping makes the
  // priority obvious without anyone ranking anything: the file with the most
  // against it rises to the top. Order within a file is left as the validator
  // ranked it, worst first.
  const byFile = new Map();
  for (const [findingIndex, finding] of report.findings.entries()) {
    const key = finding.file || "";
    if (!byFile.has(key)) byFile.set(key, []);
    byFile.get(key).push([findingIndex, finding]);
  }
  const grouping = window.AgentSyncSettings?.enabled("findings.group") !== false;
  const grouped = grouping ? [...byFile.entries()].sort((left, right) => {
    // Files with more against them first; findings without a file last.
    if (!left[0] !== !right[0]) return left[0] ? -1 : 1;
    return right[1].length - left[1].length;
  }) : [["", [...report.findings.entries()]]];

  for (const [groupFile, entries] of grouped) {
    if (groupFile && entries.length > 1) {
      window.AgentSyncSettings?.used("findings.group");
      const heading = element("div", "control-finding-group");
      heading.append(
        element("span", "control-finding-group-file", groupFile),
        element("span", "control-finding-group-count", `${entries.length} funn`),
      );
      host.append(heading);
    }
  for (const [findingIndex, finding] of entries) {
    const card = element("div", "control-finding-card");
    // The finding itself is text: readable, selectable, copyable. Only the
    // line naming the action is a button.
    const body = element("div", `control-finding ${finding.severity}`);
    const head = element("div", "control-finding-head");
    head.append(element("span", "control-finding-title", finding.title));
    // How sure the validator sounded, which is not how bad the fault would be.
    // Only worth the space when it is less than certain.
    if (finding.confidence && finding.confidence !== "sikker" && window.AgentSyncSettings?.enabled("findings.confidence") !== false) {
      window.AgentSyncSettings?.used("findings.confidence");
      head.append(element("span", `control-finding-confidence ${finding.confidence}`, finding.confidence));
    }
    if (finding.file) head.append(element("span", "control-finding-where", finding.file));
    body.append(head, element("div", "control-finding-detail", finding.detail));
    if (finding.test && window.AgentSyncSettings?.enabled("findings.test") !== false) {
      window.AgentSyncSettings?.used("findings.test");
      const test = element("div", "control-finding-test");
      test.append(element("b", "", "Test som ville fanget det: "), finding.test);
      body.append(test);
    }
    if (finding.ownWork && window.AgentSyncSettings?.enabled("findings.ownWork") !== false) {
      window.AgentSyncSettings?.used("findings.ownWork");
      body.append(element("div", "control-finding-echo", "Filendringer er registrert i et tidligere oppdrag fra samme agent. Det kan påvirke uavhengigheten; registreringen beviser ikke hvem som skrev innholdet."));
    }
    if (finding.echoesWriter && window.AgentSyncSettings?.enabled("findings.echo") !== false) {
      window.AgentSyncSettings?.used("findings.echo");
      body.append(element("div", "control-finding-echo", "Sammenfall med skriveagentens konklusjon. Tekstlikhet beviser ikke at kontrollen kopierte konklusjonen eller mangler selvstendig verdi."));
    }
    const button = element("button", "control-finding-send");
    button.type = "button";

    // Delivery is not adjudication. Keep the send action separate from the
    // user's assessment, even when an earlier delivery disables this button.
    const target = window.AgentSyncHost?.selectedAgent?.();
    // Exact links from the register, plus what the mission records say. The
    // register began on 7 September; a critique sent before then lives only
    // in the record of the writing mission that carried it. Without the
    // union, one finding went to the same agent three times in a day.
    const sentTo = [...new Set([
      ...(Array.isArray(finding.exactSentTo) ? finding.exactSentTo : []),
      ...(Array.isArray(finding.actedOnBy) ? finding.actedOnBy : []),
    ])];
    const doneHere = Boolean(target && sentTo.includes(target.id));
    const history = [];
    if (sentTo.length) history.push(`sendt til ${sentTo.map((id) => agentLabel(id)).join(", ")}`);
    if (finding.seenBefore > 0) {
      history.push(finding.seenBefore === 1 ? "meldt én gang før" : `meldt ${finding.seenBefore} ganger før`);
    } else if (finding.fileSeenBefore > 0) {
      // Not the same finding, but the same file. Wording changes between runs;
      // a path does not, so this is the recurrence an exact title match misses.
      history.push(finding.fileSeenBefore === 1
        ? "filen er meldt én gang før"
        : `filen er meldt ${finding.fileSeenBefore} ganger før`);
    }
    if (history.length && window.AgentSyncSettings?.enabled("findings.history") !== false) {
      window.AgentSyncSettings?.used("findings.history");
      body.classList.add("known");
      body.append(element("div", "control-finding-history", history.join(" · ")));
    }

    if (doneHere) {
      body.classList.add("done");
      button.textContent = `Sendt til ${target.label} · ikke automatisk avklart`;
    } else {
      button.textContent = "Henter status for dette funnet…";
    }
    // Pressable only once the register has said what happened to this finding.
    button.disabled = true;
    const peekButton = element("button", "control-finding-peek", "Vis teksten");
    peekButton.type = "button";
    peekButton.setAttribute("aria-label", "Vis hele kritikken som sendes");
    peekButton.addEventListener("click", (event) => {
      event.stopPropagation();
      if (peek.pinned && peek.anchor === body) hidePeek({ force: true });
      else showPeek(body, finding.prompt, { pinned: true });
    });
    const actions = element("div", "control-finding-actions");
    actions.append(button, peekButton);
    // The topmost finding is the one the keyboard reaches. It goes through the
    // button's own guard, so the shortcut can never send what the button
    // refuses.
    if (!state.topSend) {
      state.topSend = () => {
        if (button.disabled || !presentationVisible()) return;
        window.AgentSyncSettings?.used("flow.shortcut");
        return deliver(target?.id);
      };
      attachPeek(button, "Ctrl+Enter sender dette funnet til agenten i lerretet.", { head: "Snarvei" });
    }
    let statusKnown = false;
    let pick = null;
    const deliveryKey = `${missionId}:${findingIndex}`;
    const deliveries = state.findingDeliveries ||= new Set();
    const sentAgents = () => [...new Set([...(finding.exactSentTo || []), ...(finding.actedOnBy || [])])];
    const isCurrent = () => state.selectedRun === missionId && state.project === ownerProject;
    const updateActions = () => {
      const delivered = sentAgents();
      const sentHere = Boolean(target && delivered.includes(target.id));
      button.disabled = !statusKnown || deliveries.has(deliveryKey) || sentHere || !target;
      body.classList.toggle("done", sentHere);
      button.textContent = sentHere ? `Sendt til ${target.label} · ikke automatisk avklart`
        : !statusKnown ? "Henter status for dette funnet…"
        : target ? `Send til ${target.label} →` : "Velg en agent i canvasen først";
      if (pick) {
        pick.disabled = !statusKnown || deliveries.has(deliveryKey);
        for (const option of pick.querySelectorAll("option")) {
          if (option.value && delivered.includes(option.value)) option.remove();
        }
        pick.hidden = pick.querySelectorAll("option").length <= 1;
      }
    };
    const deliver = async (agentId, allowDifferentAgent = false) => {
      if (!statusKnown || !agentId || !isCurrent() || deliveries.has(deliveryKey) || sentAgents().includes(agentId)) return;
      // End the observation at the user's action, not after native startup.
      const shownAt = state.findingsShownAt?.get(missionId);
      const elapsed = Number.isFinite(shownAt) ? Date.now() - shownAt : null;
      const deliberationMs = elapsed !== null && elapsed >= 0 && elapsed <= 86_400_000
        && window.AgentSyncSettings?.enabled("flow.deliberation") !== false ? elapsed : null;
      deliveries.add(deliveryKey);
      updateActions();
      let keepWarning = false;
      try {
        const sent = await window.AgentSyncHost?.sendToAgent(finding.prompt, ownerProject, agentId, { allowDifferentAgent });
        if (!sent?.accepted || !sent.missionId) return;
        // Keep the local delivery marker even if storing its link fails. A
        // retry must write only the link, never start the agent a second time.
        finding.actedOnBy = [...new Set([...sentAgents(), agentId])];
        finding.exactSentTo = [...new Set([...sentAgents(), agentId])];
        finding.actedOn = true;
        const link = async () => {
          const result = await invoke("link_finding_followup", { request: {
            missionId, findingIndex, followupMissionId: sent.missionId, deliberationMs,
          } });
          if (deliberationMs !== null) window.AgentSyncSettings?.used("flow.deliberation");
          window.dispatchEvent(new CustomEvent("agentsync:evaluation-saved", { detail: result }));
        };
        try { await link(); }
        catch (error) {
          if (!isCurrent()) return;
          keepWarning = true;
          const warning = element("span", "", `Oppdraget startet, men koblingen til funnet ble ikke lagret: ${error} `);
          const retry = element("button", "evaluation-button", "Lagre koblingen på nytt");
          retry.type = "button";
          retry.addEventListener("click", async () => {
            retry.disabled = true;
            try {
              await link();
              if (isCurrent()) showVerdict("", element("span", "", "Koblingen er lagret. Funnet må fortsatt avklares."));
            } catch (retryError) { retry.disabled = false; attachPeek(retry, String(retryError), { head: "Feil" }); }
          });
          warning.append(retry);
          showVerdict("unreadable", warning);
        }
      } catch (error) {
        keepWarning = true;
        if (isCurrent()) showVerdict("unreadable", element("span", "", `Kunne ikke sende funnet: ${error}`));
      } finally {
        deliveries.delete(deliveryKey);
        updateActions();
        // Another status/settings event may have replaced the card while the
        // native start/link was pending. Release that replacement's lock too.
        if (!keepWarning && isCurrent() && card.isConnected === false) renderFindingButtons(report, missionId);
      }
    };
    // Sending to someone other than the agent in the canvas, without having to
    // switch the canvas first and switch it back.
    const others = availableAgents().filter((info) => info.id !== target?.id && !sentTo.includes(info.id));
    if (others.length) {
      pick = element("select", "control-finding-to");
      pick.disabled = true;
      pick.setAttribute("aria-label", `Send «${finding.title}» til en annen agent`);
      const placeholder = element("option", "", "Send til en annen…");
      placeholder.value = "";
      pick.append(placeholder);
      for (const info of others) {
        const option = element("option", "", info.label);
        option.value = info.id;
        pick.append(option);
      }
      pick.addEventListener("change", async () => {
        const agentId = pick.value;
        pick.selectedIndex = 0;
        await deliver(agentId, true);
      });
      actions.append(pick);
    }
    body.append(actions);
    body.addEventListener("pointerenter", () => {
      if (peek.pinned || window.AgentSyncSettings?.enabled("findings.peek") === false) return;
      window.clearTimeout(peek.timer);
      peek.timer = window.setTimeout(() => {
        if (!presentationVisible() || window.AgentSyncSettings?.enabled("findings.peek") === false) return;
        showPeek(body, finding.prompt);
        window.AgentSyncSettings?.used("findings.peek");
      }, HOVER_PEEK_DELAY_MS);
    });
    body.addEventListener("pointerleave", () => hidePeek());
    button.addEventListener("click", async () => {
      if (button.disabled) return;
      await deliver(target?.id);
    });
    card.append(body);
    if (groupFile && entries.length > 1) card.classList.add("grouped");
    host.append(card);
    window.AgentSyncEvaluations?.decorate(card, {
      missionId, findingIndex, projectPath: ownerProject,
      onCase(item) {
        finding.exactSentTo = [...new Set([...sentAgents(), ...(item.followups || []).map((entry) => entry.agent).filter(Boolean)])];
        statusKnown = true;
        updateActions();
      },
      onError() {
        statusKnown = false;
        button.disabled = true;
        if (pick) pick.disabled = true;
        button.textContent = "Kunne ikke lese funnets status. Åpne kontrollen på nytt.";
      },
    });
  }
  }
}

async function loadFindings(missionId, mission) {
  if (!invoke || mission?.status !== "completed") return;
  if (!["validator", "manualControl"].includes(missionPurpose(mission))) return;
  const cached = state.findings.get(missionId);
  if (cached) {
    if (presentationVisible() && state.selectedRun === missionId) renderFindingButtons(cached, missionId);
    return;
  }
  if (state.findingsPending.has(missionId)) return;
  state.findingsPending.add(missionId);
  try {
    const report = await invoke("extract_findings", { request: { missionId, resolverModel: null } });
    state.findings.set(missionId, report);
    renderRuns(true);
    while (state.findings.size > 40) {
      const oldest = [...state.findings.keys()].find((id) => id !== state.selectedRun && !state.findingsPending.has(id));
      if (!oldest) break;
      state.findings.delete(oldest);
    }
    if (state.open && presentationVisible() && state.selectedRun === missionId) {
      showDetailShell(state.runs.find((item) => item.id === missionId), false);
      renderFindingButtons(report, missionId);
    }
  } catch (error) {
    const node = element("span");
    node.append(element("b", "", "Kunne ikke leses. "), String(error));
    if (presentationVisible() && state.selectedRun === missionId) showVerdict("unreadable", node);
  } finally {
    state.findingsPending.delete(missionId);
  }
}

async function showFindings(missionId) {
  if (!state.open || !presentationVisible()) { state.presentationDirty = true; return; }
  const run = state.runs.find((item) => item.id === missionId);
  if (!run) return;
  const requestId = ++state.findingsRequest;
  state.selectedRun = missionId;
  showDetailShell(run);
  clearFindingButtons();
  renderRuns(true);
  const pane = byId("controlFindings");
  pane.hidden = false;
  pane.textContent = "Henter…";
  try {
    if (missionActive(run)) {
      updateSelectedText();
      return;
    }
    if (!state.sessionReads.has(missionId)) {
      state.sessionReads.set(missionId, invoke("get_mission_session", { missionId }).finally(() => state.sessionReads.delete(missionId)));
    }
    const mission = await state.sessionReads.get(missionId);
    if (!state.open || !presentationVisible() || requestId !== state.findingsRequest) return;
    const text = String(mission?.finalOutput || "").trim();
    pane.textContent = text || (mission?.status === "running" ? "Agenten arbeider fortsatt." : "Ingen sluttekst fra agenten.");
    pane.dataset.missionId = missionId;
    pane.dataset.status = String(mission?.status || "");
    byId("controlRawDetails").open = false;
    if (mission?.status === "completed") await loadFindings(missionId, mission);
    else clearFindingButtons();
  } catch (error) {
    if (!state.open || !presentationVisible() || requestId !== state.findingsRequest) return;
    pane.textContent = `Kunne ikke hente kontrollen: ${error}`;
    clearFindingButtons();
    delete pane.dataset.missionId;
    delete pane.dataset.status;
  }
}

function presentationVisible() {
  const panel = byId("controlPanel");
  return state.open && !document.hidden && !panel.hidden && !panel.classList.contains("minimized");
}

function updateSelectedText() {
  if (!presentationVisible() || !state.selectedRun) return;
  const run = state.runs.find((item) => item.id === state.selectedRun);
  if (!missionActive(run)) return;
  const buffered = window.AgentSyncHost?.missionText?.(run.id);
  showDetailShell(run, false);
  byId("controlRawDetails").open = true;
  const pane = byId("controlFindings");
  const text = buffered?.finalOutput || "Agenten arbeider fortsatt.";
  if (pane.textContent !== text) {
    const following = pane.scrollHeight - pane.scrollTop - pane.clientHeight <= 6;
    pane.textContent = text;
    if (following) pane.scrollTop = pane.scrollHeight;
  }
  pane.hidden = false;
  pane.dataset.missionId = run.id;
  pane.dataset.status = String(run.status || "");
}

// Consume the shared lightweight stream serially. The latest snapshot replaces
// a queued one, so a slow operation cannot create a backlog of stale renders.
function poll(snapshot = window.AgentSyncStatus?.current()) {
  if (!state.open || !snapshot) return Promise.resolve();
  state.pendingSnapshot = snapshot;
  if (state.pollInFlight) return state.pollInFlight;
  const lifecycle = state.lifecycle;
  state.pollInFlight = (async () => {
    while (state.open && lifecycle === state.lifecycle && state.pendingSnapshot) {
      const next = state.pendingSnapshot;
      state.pendingSnapshot = null;
      await consumeStatus(next);
    }
  })().finally(() => {
    state.pollInFlight = null;
    if (state.open && state.pendingSnapshot) poll(state.pendingSnapshot);
  });
  return state.pollInFlight;
}

async function consumeStatus(snapshot) {
  try {
    if (snapshot.runtimeError || snapshot.summariesError) {
      renderLive(`Kunne ikke lese valideringsstatus: ${snapshot.runtimeError || snapshot.summariesError}`, "error");
      return;
    }
    const runtime = snapshot.runtime;
    state.enabled = Boolean(runtime?.enabled);
    state.generation = Number(runtime?.generation) || 0;
    state.enabledSince = Number(runtime?.enabledSinceUnixMs) || state.observedAt;
    const live = Array.isArray(snapshot.missions) ? snapshot.missions : [];
    const history = Array.isArray(snapshot.history) ? snapshot.history : [];
    const seen = new Set();
    const all = [];
    for (const mission of [...live, ...history]) {
      if (!mission || !mission.id || seen.has(mission.id)) continue;
      seen.add(mission.id);
      all.push(mission);
    }
    state.missionsById = new Map(all.map((mission) => [String(mission.id), mission]));
    state.activeWriter = all
      .filter((mission) => samePath(mission?.projectPath, state.project)
        && missionPurpose(mission) === "writer"
        && missionActive(mission))
      .sort((left, right) => (Number(right.startedUnixMs) || 0) - (Number(left.startedUnixMs) || 0))[0] || null;
    seen.clear();
    const runs = [];
    for (const mission of all) {
      if (!mission || seen.has(mission.id) || !samePath(mission.projectPath, state.project)) continue;
      if (!["manualControl", "validator"].includes(missionPurpose(mission)) && !state.started.has(mission.id)) continue;
      seen.add(mission.id);
      runs.push(mission);
    }
    runs.sort((left, right) => (Number(right.startedUnixMs) || 0) - (Number(left.startedUnixMs) || 0));
    state.runs = runs.slice(0, 20);
    const previousStatuses = state.runStatuses;
    const hadStatuses = state.statusReady;
    state.runStatuses = new Map(state.runs.map((run) => [String(run.id), String(run.status || "")]));
    state.statusReady = true;
    renderRuns();
    const selected = state.runs.find((run) => run.id === state.selectedRun);
    const pane = byId("controlFindings");
    if (state.selectedRun && !selected) closeRunDetail({ focus: false });
    else if (missionActive(selected)) updateSelectedText();
    else if (selected && presentationVisible() && (state.presentationDirty
      || pane.dataset.missionId !== selected.id || pane.dataset.status !== String(selected.status || ""))) showFindings(selected.id);
    // Only a control launched or observed as running by this app may open
    // itself when it finishes. Historical rows never march through the detail
    // pane after startup, and a result never replaces something the user chose.
    const finished = state.runs.find((run) => {
      const before = previousStatuses.get(String(run.id));
      const transitioned = hadStatuses && ["queued", "running"].includes(before) && !missionActive(run);
      return run.status === "completed" && (transitioned || state.launchedRuns.has(String(run.id)));
    });
    if (finished) state.launchedRuns.delete(String(finished.id));
    if (finished && presentationVisible() && (!state.selectedRun || state.selectedRun === finished.id)
      && window.AgentSyncSettings?.enabled("validation.showFindings") !== false) {
      window.AgentSyncSettings?.used("validation.showFindings");
      state.shownFindings.add(finished.id);
      showFindings(finished.id);
    }
    if (presentationVisible()) state.presentationDirty = false;
    // Keep only IDs still represented by the bounded stream or a live queue.
    const retained = new Set(all.map((mission) => mission.id));
    for (const key of state.writerStates.keys()) if (!retained.has(key) && !state.pendingSources.has(key)) state.writerStates.delete(key);
    for (const key of state.shownFindings) if (!retained.has(key)) state.shownFindings.delete(key);
    for (const key of state.autoMissionIds.keys()) if (!retained.has(key)) state.autoMissionIds.delete(key);
    for (const key of state.autoEstimates?.keys() || []) if (!retained.has(key)) state.autoEstimates.delete(key);
    await scheduleAutomaticValidation(all);
    renderLive();
  } catch (error) {
    renderLive(`Kunne ikke lese valideringsstatus: ${error}`, "error");
  }
}

async function scheduleAutomaticValidation(allMissions) {
  if (!state.enabled || window.AgentSyncSettings?.enabled("validation.auto") === false) {
    state.pendingSources.clear();
    // Observe completions while off without replaying them when turned on.
    for (const mission of allMissions) {
      if (missionPurpose(mission) === "writer") state.writerStates.set(mission.id, mission.status || "");
    }
    return;
  }
  const writers = allMissions.filter((mission) => missionPurpose(mission) === "writer");
  const validated = new Set(
    allMissions
      .filter((mission) => missionPurpose(mission) === "validator"
        && mission.sourceMissionId
        && ["queued", "running", "completed"].includes(mission.status))
      .map((mission) => String(mission.sourceMissionId))
  );
  for (const mission of allMissions) {
    if (!state.autoMissionIds.has(mission.id) || !["failed", "canceled"].includes(mission.status)) continue;
    const detail = mission.errorSummary || mission.error || runStatus(mission);
    state.autoError = `Automatisk validering av ${projectName(mission.projectPath)} ${mission.status === "canceled" ? "ble avbrutt" : "feilet"}: ${detail}`;
    state.autoErrorProject = plainPath(mission.projectPath);
    state.autoMissionIds.delete(mission.id);
  }

  for (const sourceId of [...state.pendingSources.keys()]) {
    if (validated.has(sourceId)) state.pendingSources.delete(sourceId);
  }

  for (const writer of writers) {
    const previous = state.writerStates.get(writer.id);
    state.writerStates.set(writer.id, writer.status || "");
    const finishedAt = Number(writer.finishedUnixMs) || 0;
    const newlyCompleted = writer.status === "completed"
      && previous !== "completed"
      && missionChangedFiles(writer) > 0
      && !belowValidationFloor(writer)
      && !validated.has(String(writer.id))
      && finishedAt >= Math.max(state.enabledSince || state.observedAt, state.automaticEnabledSince || 0);
    if (!newlyCompleted) continue;
    state.pendingSources.set(String(writer.id), { source: writer, since: Date.now() });
  }
  if (allMissions.some((mission) => missionActive(mission) && missionPurpose(mission) !== "writer")) return;
  if (state.starting) return;

  const ready = [...state.pendingSources.values()]
    .filter(({ source, since }) => Date.now() - since >= VALIDATOR_QUIET_MS
      && !allMissions.some((mission) => missionActive(mission)
        && mission.mode !== "blind"
        && samePath(mission.projectPath, source.projectPath)))
    .sort((left, right) => left.since - right.since)[0];
  if (!ready) return;

  // Status never carries source buffers/diffs. Read the completed source once,
  // only when it is ready for a legitimate automatic control, not on every tick.
  const lifecycle = state.lifecycle;
  const generation = state.generation;
  const source = await invoke("get_mission_session", { missionId: ready.source.id });
  if (!state.open || lifecycle !== state.lifecycle || generation !== state.generation || !state.enabled
    || window.AgentSyncSettings?.enabled("validation.auto") === false
    || !state.pendingSources.has(String(ready.source.id))) return;
  if (!source || source.id !== ready.source.id || !samePath(source.projectPath, ready.source.projectPath)) {
    throw new Error("Kildeoppdraget kunne ikke bekreftes for validering.");
  }
  const outcome = await runControl({ automatic: true, source });
  if (["started", "done", "error"].includes(outcome)) {
    state.pendingSources.delete(String(source.id));
  }
}

function followMainWindow() {
  if (!state.open) return;
  applyTheme();
  const project = readPreference("agentsync.v4.project");
  if (changeVisibleProject(project)) return;
  const setupSignature = JSON.stringify(projectSetup() || {});
  if (setupSignature !== state.writerSetupSignature) {
    state.writerSetupSignature = setupSignature;
    chooseValidatorSetup();
    renderWriter();
    renderAgents();
    renderModels();
    persistValidatorSetup();
    syncRunButton();
    const report = state.findings.get(state.selectedRun);
    if (report && presentationVisible()) renderFindingButtons(report, state.selectedRun);
  }
}

function changeVisibleProject(projectPath) {
  const nextProject = plainPath(projectPath);
  if (samePath(nextProject, state.project)) return false;
  hidePeek({ force: true });
  if (booted && state.project) {
    state.projectDrafts ||= new Map();
    state.projectDrafts.set(plainPath(state.project).toLowerCase(), byId("controlPrompt").value);
  }
  state.project = nextProject;
  state.selectedRun = "";
  state.runs = [];
  state.runsSignature = "";
  state.activeWriter = null;
  state.agent = "";
  state.model = "";
  state.writerSetupSignature = "";
  state.findingsRequest += 1;
  loadStartedRuns();
  if (!booted) return true;
  byId("controlPrompt").value = state.projectDrafts?.get(nextProject.toLowerCase()) || "";
  closeRunDetail({ focus: false, render: false });
  setStatus("");
  chooseValidatorSetup();
  // Observation maps span projects. Switching the visible project must not
  // erase writer completions that are waiting for background validation.
  renderProject();
  renderWriter();
  renderAgents();
  renderModels();
  renderRuns(true);
  renderLive();
  syncRunButton();
  if (state.open) loadCatalog();
  else state.presentationDirty = true;
  return true;
}

function boot() {
  applyTheme();
  state.project = readPreference("agentsync.v4.project");
  resetWriterObservation();
  loadStartedRuns();
  renderProject();
  renderPresets();
  byId("controlPrompt").addEventListener("input", syncRunButton);
  byId("controlModel").addEventListener("change", () => {
    state.model = byId("controlModel").value;
    persistValidatorSetup();
  });
  byId("controlLevel").addEventListener("change", persistValidatorSetup);
  byId("controlRun").addEventListener("click", runControl);
  byId("controlDetailBack").addEventListener("click", () => closeRunDetail());
  byId("controlPrompt").addEventListener("keydown", (event) => {
    if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
      event.preventDefault();
      runControl();
    }
  });
  window.addEventListener("storage", () => {
    if (!state.open) return;
    followMainWindow();
    poll();
  });
}

let booted = false;

window.AgentSyncControl = {
  async open() {
    if (state.open) return;
    state.open = true;
    const lifecycle = ++state.lifecycle;
    if (!booted) {
      booted = true;
      boot();
    } else followMainWindow();
    await loadCatalog();
    // Closing while a catalog read is pending must never resurrect polling.
    if (!state.open || lifecycle !== state.lifecycle) return;
    state.unsubscribe = window.AgentSyncStatus?.subscribe((snapshot) => {
      if (!state.open || lifecycle !== state.lifecycle) return;
      followMainWindow();
      poll(snapshot);
    }) || null;
  },
  close() {
    hidePeek({ force: true });
    state.open = false;
    state.lifecycle += 1;
    state.findingsRequest += 1;
    state.unsubscribe?.();
    state.unsubscribe = null;
    state.pendingSnapshot = null;
  },
  projectChanged(projectPath) {
    applyTheme();
    changeVisibleProject(projectPath);
  },
};
function refreshPresentation() {
  if (!presentationVisible()) { hidePeek({ force: true }); return; }
  state.presentationDirty = true;
  poll();
}
document.addEventListener("visibilitychange", refreshPresentation);
window.addEventListener("agentsync:control-visibility", refreshPresentation);
window.addEventListener("agentsync:mission-text", (event) => {
  if (event.detail?.missionId === state.selectedRun) updateSelectedText();
});
window.addEventListener("agentsync:evaluation-saved", () => {
  window.AgentSyncEvaluations?.invalidate();
  const report = state.findings.get(state.selectedRun);
  if (report && presentationVisible()) renderFindingButtons(report, state.selectedRun);
  else state.presentationDirty = true;
});
function settingsChanged() {
  hidePeek({ force: true });
  const automatic = window.AgentSyncSettings?.own("validation.auto") !== false;
  if (window.AgentSyncSettings?.enabled("validation.auto") === false) {
    state.pendingSources.clear();
  }
  if (automatic && state.automaticWasEnabled === false) state.automaticEnabledSince = Date.now();
  state.automaticWasEnabled = automatic;
  const report = state.findings.get(state.selectedRun);
  if (report && presentationVisible()) renderFindingButtons(report, state.selectedRun);
  else state.presentationDirty = true;
  renderLive();
}
window.addEventListener("agentsync:settings", settingsChanged);
})();
