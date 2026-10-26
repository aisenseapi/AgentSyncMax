// Human review of local WikiKiki metadata proposals. This surface can record
// drafts and decisions, but it cannot publish, touch Git or start a model.
(() => {
  const PAGE_SIZE = 50;
  const MAX_MARKDOWN_BYTES = 128 * 1024;
  const MAX_NOTE_CHARACTERS = 4000;
  const KNOWLEDGE_POSITION_KEY = "agentsync.v4.knowledgePosition";
  const KNOWLEDGE_FOLDED_POSITION_KEY = "agentsync.v4.knowledgePositionFolded";
  const KNOWLEDGE_SIZE_KEY = "agentsync.v4.knowledgeSize";
  const KNOWLEDGE_MARGIN = 8;
  const KNOWLEDGE_MIN_WIDTH = 420;
  const KNOWLEDGE_MIN_HEIGHT = 260;
  const STATUS_LABELS = {
    pending: "Ikke vurdert",
    draft: "Utkast lagret",
    approved: "Godkjent utkast",
    rejected: "Avvist",
    conflict: "Konflikt",
  };
  const drafts = new Map();
  const saving = new Set();
  const state = {
    project: "",
    items: [],
    selectedReviewId: "",
    requestGeneration: 0,
    filter: "all",
    visibleCount: PAGE_SIZE,
    flash: new Map(),
    warning: "",
    sourceAvailable: true,
  };

  let dialog;
  let header;
  let headingProject;
  let body;
  let moveButton;
  let minimizeButton;
  let returnFocus;
  let resizeObserver;
  let suppressHeaderOpenClick = false;

  function readPreference(key) {
    try {
      return window.localStorage?.getItem(key) || "";
    } catch {
      return "";
    }
  }

  function writePreference(key, value) {
    try {
      if (value) window.localStorage?.setItem(key, value);
      else window.localStorage?.removeItem(key);
    } catch {
      // Geometry is a convenience. Storage failure must never block review.
    }
  }

  function readStoredObject(key) {
    try {
      const value = JSON.parse(readPreference(key) || "null");
      return value && typeof value === "object" ? value : null;
    } catch {
      return null;
    }
  }

  function railButton() {
    return document.getElementById("railKnowledgeButton");
  }

  function bringToFront() {
    if (!dialog?.open) return;
    dialog.classList.add("surface-front");
    railButton()?.classList.add("active");
    railButton()?.setAttribute("aria-expanded", "true");
  }

  function sendToBack() {
    dialog?.classList.remove("surface-front");
    railButton()?.classList.remove("active");
  }

  function isFront() {
    return Boolean(dialog?.open && dialog.classList.contains("surface-front"));
  }

  function knowledgeStage() {
    return document.getElementById("stage");
  }

  function knowledgeBounds() {
    const stage = knowledgeStage();
    return {
      stage: {
        width: Number(stage?.clientWidth) || Number(window.innerWidth) || 0,
        height: Number(stage?.clientHeight) || Number(window.innerHeight) || 0,
      },
      width: Number(dialog?.offsetWidth) || 0,
      height: Number(dialog?.offsetHeight) || 0,
    };
  }

  function positionKey() {
    return dialog?.classList.contains("minimized")
      ? KNOWLEDGE_FOLDED_POSITION_KEY
      : KNOWLEDGE_POSITION_KEY;
  }

  function clampPosition(left, top, size = null) {
    const bounds = size || knowledgeBounds();
    const maximumLeft = Math.max(KNOWLEDGE_MARGIN, bounds.stage.width - bounds.width - KNOWLEDGE_MARGIN);
    const maximumTop = Math.max(KNOWLEDGE_MARGIN, bounds.stage.height - bounds.height - KNOWLEDGE_MARGIN);
    return {
      left: Math.round(Math.min(Math.max(Number(left) || 0, KNOWLEDGE_MARGIN), maximumLeft)),
      top: Math.round(Math.min(Math.max(Number(top) || 0, KNOWLEDGE_MARGIN), maximumTop)),
    };
  }

  function placeDialog(left, top, { remember = true, size = null } = {}) {
    const position = clampPosition(left, top, size);
    dialog.style.left = `${position.left}px`;
    dialog.style.top = `${position.top}px`;
    if (remember) writePreference(positionKey(), JSON.stringify(position));
    return position;
  }

  function restoreSize() {
    const stored = readStoredObject(KNOWLEDGE_SIZE_KEY);
    if (!stored) return;
    const bounds = knowledgeBounds().stage;
    const maximumWidth = Math.max(0, bounds.width - 2 * KNOWLEDGE_MARGIN);
    const maximumHeight = Math.max(0, bounds.height - 2 * KNOWLEDGE_MARGIN);
    const minimumWidth = Math.min(KNOWLEDGE_MIN_WIDTH, maximumWidth);
    const minimumHeight = Math.min(KNOWLEDGE_MIN_HEIGHT, maximumHeight);
    if (Number.isFinite(stored.width) && maximumWidth > 0) {
      dialog.style.width = `${Math.round(Math.min(Math.max(stored.width, minimumWidth), maximumWidth))}px`;
    }
    if (Number.isFinite(stored.height) && maximumHeight > 0) {
      dialog.style.height = `${Math.round(Math.min(Math.max(stored.height, minimumHeight), maximumHeight))}px`;
    }
  }

  function rememberSize() {
    if (!dialog?.open || dialog.classList.contains("minimized")) return;
    writePreference(KNOWLEDGE_SIZE_KEY, JSON.stringify({
      width: dialog.offsetWidth,
      height: dialog.offsetHeight,
    }));
  }

  function restorePosition({ fallback = "default" } = {}) {
    const bounds = knowledgeBounds();
    const stored = readStoredObject(positionKey());
    let left;
    let top;
    if (Number.isFinite(stored?.left) && Number.isFinite(stored?.top)) {
      ({ left, top } = stored);
    } else if (fallback === "current" && dialog.style.left) {
      left = parseFloat(dialog.style.left) || 0;
      top = parseFloat(dialog.style.top) || 0;
    } else {
      left = Math.round((bounds.stage.width - bounds.width) / 2);
      top = Math.round(bounds.stage.height * 0.04);
    }
    placeDialog(left, top, { remember: false, size: bounds });
  }

  function setMinimized(minimized) {
    if (!dialog) return;
    if (minimized) {
      if (!dialog.classList.contains("minimized")) {
        rememberSize();
        dialog.dataset.restoreWidth = dialog.style.width || `${dialog.offsetWidth}px`;
        dialog.dataset.restoreHeight = dialog.style.height || `${dialog.offsetHeight}px`;
        dialog.style.width = "";
        dialog.style.height = "";
        dialog.classList.add("minimized");
      }
    } else if (dialog.classList.contains("minimized")) {
      dialog.classList.remove("minimized");
      if (dialog.dataset.restoreWidth) dialog.style.width = dialog.dataset.restoreWidth;
      if (dialog.dataset.restoreHeight) dialog.style.height = dialog.dataset.restoreHeight;
      delete dialog.dataset.restoreWidth;
      delete dialog.dataset.restoreHeight;
    }
    const label = minimized ? "Åpne kunnskapsutkastene" : "Minimer til tittellinjen";
    minimizeButton?.setAttribute("aria-label", label);
    minimizeButton?.setAttribute("aria-expanded", String(!minimized));
    if (dialog.open) restorePosition({ fallback: "current" });
  }

  function closeDialog() {
    if (!dialog?.open) return;
    rememberSize();
    dialog.close();
  }

  function moveIcon() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "knowledge-move-icon");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("focusable", "false");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", "M12 2v20M2 12h20M12 2 9 5m3-3 3 3m-3 17-3-3m3 3 3-3M2 12l3-3m-3 3 3 3m17-3-3-3m3 3-3 3");
    svg.append(path);
    return svg;
  }

  function viewportPerLayoutPixel(element) {
    const layout = Number(element?.offsetWidth) || 0;
    const viewport = Number(element?.getBoundingClientRect?.().width) || 0;
    return layout > 0 && viewport > 0 ? viewport / layout : 1;
  }

  function handleMoveKeydown(event) {
    const directions = {
      ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1],
    };
    const direction = directions[event.key];
    if (!direction || !dialog.classList.contains("minimized")) return;
    event.preventDefault();
    event.stopPropagation();
    const step = event.shiftKey ? 32 : 8;
    placeDialog(
      (parseFloat(dialog.style.left) || 0) + direction[0] * step,
      (parseFloat(dialog.style.top) || 0) + direction[1] * step
    );
  }

  function handleHeaderClick(event) {
    if (suppressHeaderOpenClick) {
      suppressHeaderOpenClick = false;
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    const move = event.target.closest?.(".knowledge-move");
    const close = event.target.closest?.(".knowledge-close");
    if (dialog.classList.contains("minimized") && !move && !close) setMinimized(false);
  }

  function beginDrag(event) {
    if (event.button !== 0) return;
    const folded = dialog.classList.contains("minimized");
    const move = event.target.closest?.(".knowledge-move");
    if (folded ? !move : event.target.closest?.("button")) return;
    bringToFront();
    const start = {
      bounds: knowledgeBounds(),
      left: parseFloat(dialog.style.left) || 0,
      top: parseFloat(dialog.style.top) || 0,
      pointerX: event.clientX,
      pointerY: event.clientY,
      scale: viewportPerLayoutPixel(dialog),
      moved: false,
    };
    const target = event.currentTarget;
    target.setPointerCapture?.(event.pointerId);
    const movePointer = (moveEvent) => {
      const deltaX = moveEvent.clientX - start.pointerX;
      const deltaY = moveEvent.clientY - start.pointerY;
      if (!start.moved) {
        if (Math.hypot(deltaX, deltaY) < 3) return;
        start.moved = true;
        dialog.classList.add("dragging");
      }
      placeDialog(
        start.left + deltaX / start.scale,
        start.top + deltaY / start.scale,
        { remember: false, size: start.bounds }
      );
    };
    const release = () => {
      if (start.moved || (folded && move)) {
        suppressHeaderOpenClick = true;
        window.setTimeout(() => { suppressHeaderOpenClick = false; }, 0);
      }
      dialog.classList.remove("dragging");
      if (target.hasPointerCapture?.(event.pointerId)) target.releasePointerCapture(event.pointerId);
      target.removeEventListener("pointermove", movePointer);
      target.removeEventListener("pointerup", release);
      target.removeEventListener("pointercancel", release);
      if (start.moved) {
        writePreference(positionKey(), JSON.stringify({
          left: parseFloat(dialog.style.left) || 0,
          top: parseFloat(dialog.style.top) || 0,
        }));
      }
    };
    target.addEventListener("pointermove", movePointer);
    target.addEventListener("pointerup", release);
    target.addEventListener("pointercancel", release);
  }

  function node(tag, className = "", text) {
    const result = document.createElement(tag);
    if (className) result.className = className;
    if (text !== undefined) result.textContent = text;
    return result;
  }

  function button(label, action, className = "knowledge-button") {
    const result = node("button", className, label);
    result.type = "button";
    result.addEventListener("click", action);
    return result;
  }

  function invoke(command, request) {
    const bridge = window.__TAURI__?.core?.invoke;
    return bridge
      ? bridge(command, { request })
      : Promise.reject(new Error("Kunnskapsgjennomgangen krever AgentSync-forbindelsen."));
  }

  function pathKey(value) {
    return String(value || "").replace(/^\\\\\?\\/, "").replaceAll("\\", "/").replace(/\/+$/, "").toLowerCase();
  }

  function formatDate(value) {
    const date = new Date(value || 0);
    return Number.isNaN(date.getTime()) ? "Tid ikke registrert" : date.toLocaleString("nb-NO");
  }

  function compactHash(value) {
    const text = String(value || "");
    return text.length > 16 ? `${text.slice(0, 8)}…${text.slice(-8)}` : text || "ikke registrert";
  }

  function utf8Bytes(value) {
    let bytes = 0;
    for (let index = 0; index < value.length; index += 1) {
      const codePoint = value.codePointAt(index);
      if (codePoint <= 0x7f) bytes += 1;
      else if (codePoint <= 0x7ff) bytes += 2;
      else if (codePoint <= 0xffff) bytes += 3;
      else {
        bytes += 4;
        index += 1;
      }
    }
    return bytes;
  }

  function decisionFor(item) {
    const decision = item?.decision && typeof item.decision === "object" ? item.decision : {};
    const status = decision.conflict ? "conflict" : String(decision.status || "pending");
    return {
      revision: Number(decision.revision) || 0,
      status: STATUS_LABELS[status] ? status : "pending",
      editedMarkdown: typeof decision.editedMarkdown === "string" ? decision.editedMarkdown : null,
      note: typeof decision.note === "string" ? decision.note : "",
      atUnixMs: Number(decision.atUnixMs) || null,
      conflict: Boolean(decision.conflict),
    };
  }

  function titleFor(item) {
    const page = String(item?.pageId || "Kunnskapsutkast");
    return page.split("/").filter(Boolean).at(-1) || page;
  }

  function sourceCount(item, key) {
    return Array.isArray(item?.[key]) ? item[key].length : 0;
  }

  function ensureDialog() {
    if (dialog) return;
    dialog = node("dialog", "knowledge-dialog");
    dialog.id = "knowledgeDialog";
    dialog.setAttribute("aria-labelledby", "knowledgeHeading");
    header = node("header", "knowledge-header");
    const heading = node("div", "knowledge-heading");
    const title = node("h2", "", "Kunnskapsutkast");
    title.id = "knowledgeHeading";
    headingProject = node("div", "knowledge-project", "Ingen prosjekt valgt");
    heading.append(title, headingProject);
    moveButton = button("", (event) => event.stopPropagation(), "knowledge-window-button knowledge-move");
    moveButton.setAttribute("aria-label", "Flytt kunnskapsvinduet");
    moveButton.append(moveIcon());
    moveButton.addEventListener("keydown", handleMoveKeydown);
    minimizeButton = button("", (event) => {
      event.stopPropagation();
      setMinimized(!dialog.classList.contains("minimized"));
    }, "knowledge-window-button knowledge-minimize");
    minimizeButton.setAttribute("aria-label", "Minimer til tittellinjen");
    minimizeButton.setAttribute("aria-controls", "knowledgeBody");
    minimizeButton.setAttribute("aria-expanded", "true");
    minimizeButton.append(
      node("span", "knowledge-minimize-icon", "−"),
      node("span", "knowledge-expand-icon", "+")
    );
    const close = button("×", (event) => {
      event.stopPropagation();
      closeDialog();
    }, "knowledge-window-button knowledge-close");
    close.setAttribute("aria-label", "Lukk kunnskapsgjennomgangen");
    window.AgentSyncPeek?.attach(moveButton, "Dra for å flytte. Piltaster flytter kontrollert.", { head: "Kunnskapsutkast" });
    window.AgentSyncPeek?.attach(minimizeButton,
      () => dialog.classList.contains("minimized") ? "Åpne kunnskapsutkastene" : "Minimer til tittellinjen",
      { head: "Kunnskapsutkast" });
    window.AgentSyncPeek?.attach(close, "Lukk kunnskapsgjennomgangen", { head: "Kunnskapsutkast" });
    header.append(heading, moveButton, minimizeButton, close);
    header.addEventListener("click", handleHeaderClick);
    header.addEventListener("pointerdown", beginDrag);
    body = node("div", "knowledge-body");
    body.id = "knowledgeBody";
    dialog.append(header, body);
    dialog.addEventListener("keydown", (event) => {
      event.stopPropagation();
      if (event.key === "Escape") {
        event.preventDefault();
        closeDialog();
      }
    });
    dialog.addEventListener("close", () => {
      sendToBack();
      railButton()?.setAttribute("aria-expanded", "false");
      state.requestGeneration += 1;
      body.replaceChildren();
      state.items = [];
      state.selectedReviewId = "";
      state.warning = "";
      state.sourceAvailable = true;
      if (returnFocus?.isConnected) returnFocus.focus();
    });
    dialog.addEventListener("pointerdown", bringToFront);
    dialog.addEventListener("pointerup", (event) => {
      if (event.target === dialog && !dialog.classList.contains("dragging")) rememberSize();
    });
    (knowledgeStage() || document.body).append(dialog);
    if (!resizeObserver && typeof window.ResizeObserver === "function") {
      resizeObserver = new window.ResizeObserver(() => {
        if (!dialog.open || dialog.classList.contains("dragging")) return;
        restorePosition({ fallback: "current" });
      });
      resizeObserver.observe(dialog);
    }
    window.addEventListener("resize", () => {
      if (!dialog?.open) return;
      restorePosition({ fallback: "current" });
    });
  }

  function setBodyMessage(text, kind = "loading", retry = null) {
    const message = node("div", `knowledge-${kind}`, text);
    message.setAttribute("role", kind === "error" ? "alert" : "status");
    if (retry) message.append(button("Prøv igjen", retry, "knowledge-button knowledge-retry"));
    body.replaceChildren(message);
  }

  function normalizeDataset(result) {
    const items = Array.isArray(result?.items) ? result.items : [];
    return {
      items: items.filter((item) => item && typeof item.reviewId === "string" && item.reviewId),
      warning: typeof result?.warning === "string" ? result.warning : "",
      sourceAvailable: result?.sourceAvailable !== false,
    };
  }

  async function refresh() {
    const generation = ++state.requestGeneration;
    const ownerProject = state.project;
    state.flash.clear();
    headingProject.textContent = ownerProject || "Ingen prosjekt valgt";
    if (!ownerProject) {
      setBodyMessage("Velg et prosjekt i hovedvinduet først.", "empty");
      return;
    }
    setBodyMessage("Henter lokale kunnskapsutkast…");
    try {
      const result = normalizeDataset(await invoke("get_knowledge_reviews", { projectPath: ownerProject }));
      if (generation !== state.requestGeneration || !dialog.open || pathKey(ownerProject) !== pathKey(state.project)) return;
      state.items = result.items;
      state.warning = result.warning;
      state.sourceAvailable = result.sourceAvailable;
      if (state.selectedReviewId && !state.items.some((item) => item.reviewId === state.selectedReviewId)) {
        state.selectedReviewId = "";
      }
      renderDataset();
    } catch (error) {
      if (generation !== state.requestGeneration || !dialog.open || pathKey(ownerProject) !== pathKey(state.project)) return;
      setBodyMessage(`Kunne ikke lese kunnskapsutkastene: ${error}`, "error", refresh);
    }
  }

  function renderItem(item) {
    const decision = decisionFor(item);
    const selected = item.reviewId === state.selectedReviewId;
    const result = node("button", `knowledge-item${selected ? " selected" : ""}`);
    result.type = "button";
    result.dataset.reviewId = item.reviewId;
    result.setAttribute("role", "option");
    result.setAttribute("aria-selected", selected ? "true" : "false");
    result.setAttribute("aria-controls", "knowledgeDetail");
    const head = node("div", "knowledge-item-head");
    head.append(node("span", "knowledge-item-title", titleFor(item)),
      node("span", `knowledge-badge ${decision.status}`, STATUS_LABELS[decision.status]));
    result.append(head,
      node("div", "knowledge-item-page", item.pageId || "Side ikke registrert"),
      node("div", "knowledge-item-sources", `${sourceCount(item, "preservedSources")} bevart · ${sourceCount(item, "discardedSources")} forkastet`),
      node("div", "knowledge-item-meta", `${item.modelTag || "Modell ikke registrert"} · ${formatDate(item.generatedUtc)}`));
    result.addEventListener("click", () => {
      state.selectedReviewId = item.reviewId;
      renderDataset();
      body.querySelector(".knowledge-detail")?.focus?.();
    });
    return result;
  }

  function renderSourceList(items, discarded = false) {
    const list = node("ul", "knowledge-source-list");
    for (const source of Array.isArray(items) ? items : []) {
      const row = node("li", "knowledge-source");
      row.append(node("code", "", source.ref || "ukjent kilde"));
      const reason = discarded
        ? [source.reasonCode || source.reason_code, source.why].filter(Boolean).join(" · ")
        : source.why;
      if (reason) row.append(node("span", "knowledge-source-reason", reason));
      list.append(row);
    }
    if (!list.children.length) list.append(node("li", "knowledge-source", "Ingen kilder i denne gruppen."));
    return list;
  }

  function details(summary, content, open = false) {
    const host = node("details", "knowledge-section");
    host.open = open;
    host.append(node("summary", "", summary), content);
    return host;
  }

  function rememberDraft(item, markdown, note) {
    const decision = decisionFor(item);
    const previous = drafts.get(item.reviewId);
    drafts.set(item.reviewId, {
      editedMarkdown: markdown.value,
      note: note.value,
      // Never adopt a newer revision merely because a stale local draft was
      // remounted after refresh. The backend must see and reject that conflict.
      expectedRevision: previous?.expectedRevision ?? decision.revision,
      viewId: previous?.viewId ?? item.viewId,
    });
  }

  function currentDraft(item) {
    const decision = decisionFor(item);
    return drafts.get(item.reviewId) || {
      editedMarkdown: decision.editedMarkdown ?? String(item.resultMarkdown || ""),
      note: decision.note,
      expectedRevision: decision.revision,
      viewId: item.viewId,
    };
  }

  function savedItem(item, response, status, draft) {
    const candidate = response?.item || response;
    if (candidate?.reviewId === item.reviewId) return candidate;
    const returnedDecision = candidate?.decision && typeof candidate.decision === "object"
      ? candidate.decision
      : candidate && typeof candidate === "object" && Number.isFinite(Number(candidate.revision)) ? candidate : null;
    return returnedDecision ? { ...item, decision: returnedDecision } : null;
  }

  async function saveDecision(item, status, markdown, note, statusNode, controls) {
    if (saving.has(item.reviewId)) return;
    rememberDraft(item, markdown, note);
    const draft = drafts.get(item.reviewId);
    const currentDecision = decisionFor(item);
    const ownerProject = state.project;
    const selectedProject = window.AgentSyncHost?.selectedProject?.() || ownerProject;
    if (pathKey(selectedProject) !== pathKey(ownerProject)) {
      statusNode.textContent = "Prosjektet er byttet. Åpne utkastet på nytt før du lagrer.";
      statusNode.className = "knowledge-save-status error";
      return;
    }
    if (draft.expectedRevision !== currentDecision.revision || draft.viewId !== item.viewId) {
      statusNode.textContent = "En nyere lagret revisjon finnes. Velg «Forkast lokal tekst og last inn» før du lagrer på nytt.";
      statusNode.className = "knowledge-save-status error";
      return;
    }
    if (status !== "rejected" && !draft.editedMarkdown.trim()) {
      statusNode.textContent = "Utkastet kan ikke være tomt.";
      statusNode.className = "knowledge-save-status error";
      markdown.focus();
      return;
    }
    if (utf8Bytes(draft.editedMarkdown) > MAX_MARKDOWN_BYTES) {
      statusNode.textContent = "Utkastet er større enn den sikre lagringsgrensen på 128 KiB.";
      statusNode.className = "knowledge-save-status error";
      markdown.focus();
      return;
    }
    saving.add(item.reviewId);
    for (const control of controls) control.disabled = true;
    statusNode.textContent = status === "approved" ? "Godkjenner utkastet lokalt…" : status === "rejected" ? "Avviser utkastet…" : "Lagrer utkastet…";
    statusNode.className = "knowledge-save-status";
    try {
      const response = await invoke("save_knowledge_review_decision", {
        projectPath: ownerProject,
        reviewId: item.reviewId,
        viewId: item.viewId,
        expectedRevision: draft.expectedRevision,
        status,
        editedMarkdown: draft.editedMarkdown,
        note: draft.note,
      });
      const updated = savedItem(item, response, status, draft);
      const confirmed = decisionFor(updated);
      if (!updated || confirmed.conflict || confirmed.status !== status || confirmed.revision <= draft.expectedRevision) {
        throw new Error("Lagringsbekreftelsen hadde ikke forventet status eller revisjon");
      }
      drafts.delete(item.reviewId);
      state.flash.set(item.reviewId, status === "approved"
        ? "Utkastet er godkjent lokalt. Ingenting er publisert."
        : status === "rejected" ? "Utkastet er avvist. Ingenting er publisert." : "Utkastet er lagret lokalt.");
      window.dispatchEvent(new CustomEvent("agentsync:knowledge-review-saved", { detail: updated }));
      if (pathKey(ownerProject) === pathKey(state.project)) {
        state.items = state.items.map((candidate) => candidate.reviewId === item.reviewId ? updated : candidate);
        if (dialog.open && state.selectedReviewId === item.reviewId) renderDataset();
      }
    } catch (error) {
      statusNode.textContent = `Ikke lagret: ${error}. Teksten din er beholdt.`;
      statusNode.className = "knowledge-save-status error";
    } finally {
      saving.delete(item.reviewId);
      for (const control of controls) control.disabled = false;
    }
  }

  function renderDetail(item) {
    const detail = node("section", "knowledge-detail");
    detail.id = "knowledgeDetail";
    detail.tabIndex = -1;
    if (!item) {
      detail.append(node("div", "knowledge-empty", "Velg et utkast i listen."));
      return detail;
    }
    const decision = decisionFor(item);
    const head = node("header", "knowledge-detail-head");
    const top = node("div", "knowledge-detail-top");
    const back = button("← Alle utkast", () => {
      state.selectedReviewId = "";
      renderDataset();
      body.querySelector(".knowledge-item")?.focus?.();
    }, "knowledge-back");
    top.append(back, node("div", "knowledge-detail-title", item.pageId || "Side ikke registrert"),
      node("span", `knowledge-badge ${decision.status}`, STATUS_LABELS[decision.status]));
    head.append(top, node("div", "knowledge-detail-meta", `${item.modelTag || "Modell ikke registrert"} · ${formatDate(item.generatedUtc)} · ${compactHash(item.modelDigest)}`));

    const scroll = node("div", "knowledge-detail-scroll");
    const safety = node("p", `knowledge-safety${decision.conflict ? " conflict" : ""}`,
      decision.conflict
        ? "Denne gjennomgangen har en revisjonskonflikt. Last inn siste versjon før du tar en ny beslutning. Ingen Wiki-side er endret."
        : "Dette er modellgenerert tekst som ikke er semantisk verifisert. Du vurderer bare et lokalt utkast. Ingen Wiki-side, Git-historikk eller publisering endres her.");
    const draft = currentDraft(item);
    const staleDraft = draft.expectedRevision !== decision.revision || draft.viewId !== item.viewId;
    const markdown = node("textarea", "knowledge-input");
    markdown.rows = 16;
    markdown.maxLength = 120000;
    markdown.value = draft.editedMarkdown;
    markdown.placeholder = "Modellen forkastet forslaget eller leverte ingen tekst.";
    const note = node("textarea", "knowledge-input knowledge-note");
    note.rows = 3;
    note.maxLength = MAX_NOTE_CHARACTERS;
    note.value = draft.note;
    note.placeholder = "Hvorfor godkjenner, endrer eller avviser du dette? (valgfritt)";
    markdown.addEventListener("input", () => rememberDraft(item, markdown, note));
    note.addEventListener("input", () => rememberDraft(item, markdown, note));
    const rationale = node("p", "knowledge-rationale", item.rationale || "Ingen modellbegrunnelse registrert.");
    const preserved = details(`Bevarte kilder (${sourceCount(item, "preservedSources")})`, renderSourceList(item.preservedSources), true);
    const discarded = details(`Forkastede kilder (${sourceCount(item, "discardedSources")})`, renderSourceList(item.discardedSources, true));
    const technical = node("pre", "knowledge-technical",
      `Review: ${item.reviewId}\nForslag: ${item.proposalId || "ikke registrert"}\nVisning: ${item.viewId || "ikke registrert"}\nModellhash: ${item.modelDigest || "ikke registrert"}\nMenneskelig gjennomgang kreves: ${item.humanReviewRequired === false ? "nei" : "ja"}\nSemantisk korrekthet verifisert: ${item.semanticCorrectnessVerified === true ? "ja" : "nei"}\nEksisterende Wiki-side lest: nei\nDiff tilgjengelig: nei`);
    const statusNode = node("span", "knowledge-save-status", state.flash.get(item.reviewId) || "");
    statusNode.setAttribute("role", "status");
    const reload = button("Forkast lokal tekst og last inn", () => {
      drafts.delete(item.reviewId);
      state.flash.set(item.reviewId, "Den lokale teksten er forkastet. Sist lagrede revisjon vises.");
      renderDataset();
    });
    const save = button("Lagre utkast", () => saveDecision(item, "draft", markdown, note, statusNode, controls));
    const reject = button("Avvis", () => saveDecision(item, "rejected", markdown, note, statusNode, controls), "knowledge-button reject");
    const approve = button("Godkjenn utkast (publiserer ikke)", () => saveDecision(item, "approved", markdown, note, statusNode, controls), "knowledge-button primary");
    const controls = [markdown, note, save, reject, approve, reload];
    if (saving.has(item.reviewId) || decision.conflict) for (const control of controls) control.disabled = true;
    if (decision.conflict) statusNode.textContent = "Konflikten må oppdateres før en ny beslutning kan lagres.";
    if (staleDraft && !decision.conflict) {
      for (const control of [save, reject, approve]) control.disabled = true;
      statusNode.textContent = `Den lokale teksten bygger på revisjon ${draft.expectedRevision}, mens lagret revisjon er ${decision.revision}. Teksten er beholdt.`;
      statusNode.className = "knowledge-save-status error";
    }
    const actions = node("div", "knowledge-actions");
    actions.append(save, reject);
    if (staleDraft) actions.append(reload);
    actions.append(statusNode, approve);
    scroll.append(safety,
      node("p", "knowledge-rationale", "Eksisterende Wiki-side er ikke lest. Diff blir tilgjengelig først i en separat, sikker publiseringsfase."),
      node("label", "knowledge-field", "Redigerbart Markdown"));
    scroll.lastChild.append(markdown);
    scroll.append(node("label", "knowledge-field", "Merknad"));
    scroll.lastChild.append(note);
    scroll.append(details("Modellens begrunnelse", rationale), preserved, discarded, details("Teknisk spor og sikkerhetsgrenser", technical));
    detail.append(head, scroll, actions);
    return detail;
  }

  function renderDataset() {
    const warning = state.warning;
    const sourceAvailable = state.sourceAvailable;
    const selected = state.items.find((item) => item.reviewId === state.selectedReviewId) || null;
    const filtered = state.items.filter((item) => state.filter === "all" || decisionFor(item).status === state.filter);
    const toolbar = node("div", "knowledge-toolbar");
    toolbar.append(node("span", "knowledge-toolbar-note", warning || `${state.items.length} lokale utkast. Åpning starter ingen modell.`));
    const filter = node("select", "knowledge-input knowledge-filter");
    filter.setAttribute("aria-label", "Filtrer kunnskapsutkast");
    for (const [value, label] of [["all", "Alle"], ...Object.entries(STATUS_LABELS)]) {
      const option = node("option", "", label);
      option.value = value;
      filter.append(option);
    }
    filter.value = state.filter;
    filter.addEventListener("change", () => {
      state.filter = filter.value;
      state.visibleCount = PAGE_SIZE;
      if (state.selectedReviewId && !state.items.some((item) => item.reviewId === state.selectedReviewId && (state.filter === "all" || decisionFor(item).status === state.filter))) {
        state.selectedReviewId = "";
      }
      renderDataset();
    });
    const refreshButton = button("Oppdater", refresh);
    toolbar.append(filter, refreshButton);

    const browser = node("div", `knowledge-browser${selected ? " has-selection" : ""}`);
    const listPane = node("div", "knowledge-list-pane");
    const list = node("div", "knowledge-list");
    list.setAttribute("role", "listbox");
    list.setAttribute("aria-label", "Lokale kunnskapsutkast");
    const visible = filtered.slice(0, state.visibleCount);
    if (!visible.length) list.append(node("div", "knowledge-list-empty", state.items.length
      ? "Ingen utkast passer filteret."
      : sourceAvailable
        ? "Ingen kunnskapsutkast er registrert for dette prosjektet."
        : "Ingen sikre, lokale kunnskapsutkast er gjort klare for gjennomgang ennå."));
    else for (const item of visible) list.append(renderItem(item));
    listPane.append(list);
    if (filtered.length > visible.length) {
      listPane.append(button(`Vis flere (${visible.length} av ${filtered.length})`, () => {
        state.visibleCount += PAGE_SIZE;
        renderDataset();
      }, "knowledge-button knowledge-more"));
    }
    browser.append(listPane, renderDetail(selected));
    body.replaceChildren(toolbar, browser);
  }

  async function open(projectPath = "") {
    ensureDialog();
    const nextProject = projectPath || "";
    if (pathKey(nextProject) !== pathKey(state.project)) {
      state.project = nextProject;
      state.items = [];
      state.selectedReviewId = "";
      state.filter = "all";
      state.visibleCount = PAGE_SIZE;
      state.warning = "";
      state.sourceAvailable = true;
    }
    if (!dialog.open) {
      returnFocus = document.activeElement;
      setMinimized(false);
      // This is a large in-app work surface, not a blocking confirmation. Keep
      // the project rail and the higher validator panel usable while it is open.
      if (typeof dialog.show === "function") dialog.show();
      else dialog.setAttribute("open", "");
      restoreSize();
      restorePosition();
    }
    bringToFront();
    await refresh();
  }

  async function toggle(projectPath = "") {
    ensureDialog();
    if (dialog.open && pathKey(projectPath) !== pathKey(state.project)) {
      await open(projectPath);
      return;
    }
    if (dialog.open && isFront()) {
      closeDialog();
      return;
    }
    if (dialog.open) {
      bringToFront();
      return;
    }
    await open(projectPath);
  }

  window.AgentSyncKnowledgeReviews = { open, toggle, close: closeDialog, refresh, bringToFront, sendToBack, isFront };
  railButton()?.addEventListener("click", async (event) => {
    event.stopPropagation();
    await toggle(window.AgentSyncHost?.selectedProject?.() || "");
  });
})();
