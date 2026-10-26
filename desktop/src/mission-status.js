// One lightweight status stream shared by the canvas and validation panel.
// Text/diffs are deliberately absent; the canvas owns byte-delta polling.
(() => {
  const listeners = new Set();
  let snapshot = null;
  let timer = null;
  let inFlight = null;
  let sequence = 0;
  const visibleInterval = 2000;
  const hiddenInterval = 10000;

  function stopTimer() {
    if (timer !== null) window.clearTimeout(timer);
    timer = null;
  }
  function schedule() {
    stopTimer();
    if (!listeners.size) return;
    // V remains an active observer when the presentation is hidden.
    const delay = document.hidden && !snapshot?.runtime?.enabled ? hiddenInterval : visibleInterval;
    timer = window.setTimeout(refresh, delay);
  }
  function publish(next) {
    snapshot = next;
    for (const listener of [...listeners]) {
      try { listener(next); } catch (error) { console.error("Status listener failed", error); }
    }
  }
  function refresh() {
    if (inFlight) return inFlight;
    stopTimer();
    const invoke = window.__TAURI__?.core?.invoke;
    if (!invoke) return Promise.resolve(snapshot);
    inFlight = (async () => {
      const [summaries, runtime] = await Promise.allSettled([
        invoke("get_mission_summaries", { request: { limit: 200 } }),
        invoke("get_validator_control"),
      ]);
      const next = {
        sequence: ++sequence,
        missions: summaries.status === "fulfilled" ? summaries.value?.missions || [] : snapshot?.missions || [],
        history: summaries.status === "fulfilled" ? summaries.value?.history || [] : snapshot?.history || [],
        runtime: runtime.status === "fulfilled" ? runtime.value : snapshot?.runtime || null,
        summariesError: summaries.status === "rejected" ? String(summaries.reason) : "",
        summariesWarning: summaries.status === "fulfilled" ? summaries.value?.warning || "" : snapshot?.summariesWarning || "",
        runtimeError: runtime.status === "rejected" ? String(runtime.reason) : "",
        observedAt: Date.now(),
      };
      publish(next);
      return next;
    })().finally(() => {
      inFlight = null;
      schedule();
    });
    return inFlight;
  }
  function subscribe(listener) {
    listeners.add(listener);
    if (snapshot) listener(snapshot);
    if (!inFlight && timer === null) refresh();
    return () => {
      listeners.delete(listener);
      if (!listeners.size) stopTimer();
    };
  }
  function modelLabel(mission) {
    if (mission?.resolvedModel) {
      const origin = { observed: "observert", requested: "ønsket", configured: "konfigurert" }[mission.modelSource] || "ikke bekreftet";
      return `${mission.resolvedModel} (${origin})`;
    }
    return mission?.model ? `${mission.model} (ønsket)` : "modell ikke registrert";
  }
  document.addEventListener("visibilitychange", () => {
    if (!listeners.size) return;
    if (!document.hidden) refresh();
    else if (!inFlight) schedule();
  });
  window.AgentSyncStatus = { refresh, subscribe, current: () => snapshot, modelLabel };
})();
