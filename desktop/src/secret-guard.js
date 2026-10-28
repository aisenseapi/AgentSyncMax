// The Rust boundary owns both the setting and one-use exceptions. The UI never
// scans or stores secrets and cannot grant an exception without a user action.
(() => {
  const guarded = new Set(["start_mission", "review_workspace_changes", "resolve_intent", "scope_mission"]);
  const raw = (command, args) => {
    const bridge = window.__TAURI__?.core?.invoke;
    return bridge ? bridge(command, args) : Promise.reject(new Error("Lokal motor er ikke tilgjengelig."));
  };
  const node = (tag, className, text = "") => {
    const element = document.createElement(tag);
    element.className = className;
    element.textContent = text;
    return element;
  };
  const safeText = (value, fallback = "Ukjent", limit = 700) => typeof value === "string" && value.trim()
    ? value.replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, " ").slice(0, limit) : fallback;
  const copy = value => typeof structuredClone === "function" ? structuredClone(value) : value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  let confirmed = null, host = null, indicator = null, busy = false, loading = false, settingsError = "";
  let settingsGeneration = 0, projectGeneration = 0, pending = null;

  function stopped(message) {
    const error = new Error(message);
    error.code = "SECRET_GUARD";
    return error;
  }
  function parseBlock(error) {
    const message = typeof error === "string" ? error : error?.message;
    if (typeof message !== "string" || !message.startsWith("SECRET_GUARD:")) return null;
    try {
      const data = JSON.parse(message.slice("SECRET_GUARD:".length));
      if (data?.code !== "SECRET_GUARD" || (data.canAllowOnce !== false && (typeof data.token !== "string" || !data.token || data.token.length > 2048))
        || !Array.isArray(data.findings) || !data.findings.length) throw new Error("Invalid block");
      return data;
    } catch (_) {
      throw stopped("Hemmelighetsvernet stoppet overføringen. Kontrollinformasjonen kunne ikke leses. Ingen unntak er gitt.");
    }
  }
  function checkedSettings(value) {
    if (!value || typeof value.enabled !== "boolean") throw new Error("Unconfirmed setting");
    return { enabled: value.enabled, warning: typeof value.warning === "string" ? safeText(value.warning, "") : "" };
  }
  function drawIndicator() {
    if (!indicator) return;
    indicator.hidden = confirmed?.enabled === true && !settingsError && !confirmed.warning;
    indicator.textContent = confirmed?.enabled === false ? "Hemmelighetsvern av" : settingsError || confirmed?.warning ? "Hemmelighetsvern: sjekk status" : "Hemmelighetsvern: leser status";
    indicator.title = confirmed?.enabled === false ? "Ekstra kontroll er slått av. Åpne Brytere for å slå den på." : "Åpne Brytere for bekreftet status fra den lokale motoren.";
  }
  function drawSettings() {
    drawIndicator();
    if (!host?.isConnected) return;
    host.replaceChildren(node("h2", "settings-group-name", "Hemmelighetsvern"));
    const row = node("div", "settings-row");
    const toggle = node("button", "settings-toggle", confirmed ? confirmed.enabled ? "på" : "av" : "…");
    toggle.type = "button";
    toggle.setAttribute("role", "switch");
    toggle.setAttribute("aria-label", "Hemmelighetsvern");
    // Unknown does not masquerade as off. Keep the default-on visual, disabled
    // and explicitly unconfirmed until the backend has answered.
    toggle.setAttribute("aria-checked", String(confirmed?.enabled !== false));
    toggle.setAttribute("aria-describedby", "secretGuardHelp secretGuardState");
    toggle.disabled = !confirmed || busy || loading;
    toggle.addEventListener("click", () => { if (confirmed && !busy && !loading) change(!confirmed.enabled); });
    const info = node("div", "settings-text");
    const status = node("div", "settings-label", !confirmed ? loading ? "Leser lagret innstilling …" : "Status er ikke bekreftet" : busy ? "Lagrer …" : loading ? "Kontrollerer lagret innstilling …" : confirmed.enabled ? "På · lokal kontroll før overføring" : "Av · ekstra kontroll er deaktivert");
    status.id = "secretGuardState";
    status.setAttribute("role", "status");
    const help = node("p", "settings-help", "På som standard. Kontrollerer prompt, kontekst og diff som MAX selv klargjør for overføring. Mulige hemmeligheter stoppes før sending. Du kan tillate én konkret overføring uten å slå av vernet.");
    help.id = "secretGuardHelp";
    info.append(status, help, node("p", "settings-help", "Dette endrer ikke Dropbox eller agentenes egne filtilganger. Filer en ekstern agent leser på egen hånd er utenfor denne kontrollen. Native agentlogger, synkhistorikk og checkpoints renses ikke. Kontrollen kan ikke garantere at alle hemmeligheter blir oppdaget."));
    if (confirmed?.warning) info.append(node("p", "settings-blocked", confirmed.warning));
    if (settingsError) info.append(node("p", "settings-blocked", settingsError));
    if (!confirmed && !loading) {
      const retry = node("button", "settings-button", "Les status på nytt");
      retry.type = "button";
      retry.addEventListener("click", refresh);
      info.append(retry);
    }
    row.append(toggle, info);
    host.append(row);
  }
  async function refresh() {
    if (busy) { drawSettings(); return; }
    const generation = ++settingsGeneration;
    loading = true;
    drawSettings();
    try {
      const value = checkedSettings(await raw("get_secret_guard_settings"));
      if (generation !== settingsGeneration) return;
      confirmed = value;
      settingsError = "";
    } catch (_) {
      if (generation !== settingsGeneration) return;
      settingsError = "Kan ikke bekrefte den lagrede innstillingen. Siste bekreftede verdi beholdes; motoren avgjør om en overføring kan skje.";
    } finally {
      if (generation === settingsGeneration) { loading = false; drawSettings(); }
    }
  }
  async function change(enabled) {
    if (!confirmed || busy || loading) return;
    const focusOwner = document.activeElement;
    const ownerHost = host;
    const restoreToggleFocus = focusOwner?.getAttribute?.("role") === "switch" && ownerHost?.contains(focusOwner);
    busy = true;
    ++settingsGeneration;
    settingsError = "";
    drawSettings();
    try {
      confirmed = checkedSettings(await raw("set_secret_guard_settings", { enabled }));
    } catch (_) {
      settingsError = "Ikke lagret. Siste bekreftede verdi vises fortsatt. Prøv igjen.";
    } finally {
      busy = false;
      drawSettings();
      if (restoreToggleFocus && host === ownerHost && host?.isConnected && !host.closest?.("[hidden]")
        && (!document.activeElement || document.activeElement === document.body || document.activeElement === focusOwner)) {
        host.querySelector('[role="switch"]')?.focus();
      }
    }
  }
  function ask(block) {
    if (pending) return Promise.reject(stopped("En annen overføring venter på avklaring i hemmelighetsvernet. Avklar den først."));
    return new Promise((resolve) => {
      const previousFocus = document.activeElement;
      const dialog = node("dialog", "secret-guard-dialog");
      dialog.setAttribute("aria-labelledby", "secretGuardTitle");
      dialog.setAttribute("aria-describedby", "secretGuardDescription");
      const canAllow = block.canAllowOnce !== false;
      const title = node("h2", "", canAllow ? "Mulig hemmelighet før overføring" : "Overføringen kunne ikke kontrolleres");
      title.id = "secretGuardTitle";
      const description = node("p", "", canAllow ? "Overføringen er stoppet. Kontroller kilden før du eventuelt tillater denne ene sendingen. Ingen hemmelighetsverdier vises her." : "Overføringen er stoppet fordi innholdet ikke kunne kontrolleres fullstendig. Rett årsaken før du prøver igjen. Denne kontrollfeilen kan ikke omgås med et engangsunntak.");
      description.id = "secretGuardDescription";
      const recipient = node("p", "secret-guard-recipient", `Mottaker: ${safeText(block.recipient)}`);
      const operation = node("p", "secret-guard-operation", `Handling: ${safeText(block.operation)}`);
      const list = node("ul", "secret-guard-findings");
      for (const finding of block.findings.slice(0, 100)) {
        const item = node("li", "");
        item.append(node("strong", "", safeText(finding?.source, "Ukjent kilde")));
        const line = Number.isSafeInteger(finding?.line) && finding.line > 0 ? ` · linje ${finding.line}` : "";
        item.append(node("span", "", safeText(finding?.kind, "Mulig hemmelighet") + line));
        list.append(item);
      }
      if (block.findings.length > 100) list.append(node("li", "", `Viser 100 av ${block.findings.length} funn.`));
      const actions = node("div", "secret-guard-actions");
      const cancel = node("button", "", "Avbryt");
      const allow = node("button", "secret-guard-allow", "Tillat denne overføringen én gang");
      cancel.type = allow.type = "button";
      const finish = (approved) => {
        if (pending?.dialog !== dialog) return;
        pending = null;
        if (dialog.open) dialog.close();
        dialog.remove();
        if (previousFocus?.isConnected) previousFocus.focus();
        resolve(approved);
      };
      cancel.addEventListener("click", () => finish(false));
      allow.addEventListener("click", () => finish(true));
      dialog.addEventListener("keydown", (event) => {
        // Canvas shortcuts must not submit another task behind this dialog.
        event.stopPropagation();
        if (event.key !== "Tab") return;
        const last = canAllow ? allow : cancel;
        if (event.shiftKey && document.activeElement === cancel) {
          event.preventDefault(); last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault(); cancel.focus();
        }
      });
      dialog.addEventListener("cancel", (event) => { event.preventDefault(); finish(false); });
      dialog.addEventListener("close", () => finish(false));
      actions.append(cancel);
      if (canAllow) actions.append(allow);
      dialog.append(title, description, recipient, operation, list);
      if (canAllow) dialog.append(node("p", "secret-guard-footnote", "Unntaket gjelder bare denne handlingen og dette innholdet. Hemmelighetsvernet forblir på for neste overføring."));
      dialog.append(actions);
      pending = { dialog, cancel: () => finish(false) };
      document.body.append(dialog);
      if (typeof dialog.showModal !== "function") { finish(false); return; }
      try { dialog.showModal(); cancel.focus(); } catch (_) { finish(false); }
    });
  }
  async function invoke(command, args) {
    if (!guarded.has(command)) return raw(command, args);
    const snapshot = copy(args);
    const generation = projectGeneration;
    let block;
    try { return await raw(command, copy(snapshot)); }
    catch (error) {
      block = parseBlock(error);
      if (!block) throw error;
    }
    if (snapshot?.request?.purpose === "validator") {
      throw stopped(`Hemmelighetsvernet stoppet automatisk validering: ${block.findings.length} mulige hemmelighetsfunn før overføring til ${safeText(block.recipient)}. Ingen data ble sendt. Kontroller kildene og start en manuell kontroll ved behov.`);
    }
    if (generation !== projectGeneration) throw stopped("Overføringen ble avbrutt fordi prosjektet ble endret. Utkastet er beholdt.");
    if (!await ask(block)) throw stopped("Overføringen ble avbrutt. Ingen unntak er gitt, og utkastet er beholdt.");
    if (generation !== projectGeneration) throw stopped("Overføringen ble avbrutt fordi prosjektet ble endret.");
    try { await raw("allow_secret_guard_once", { token: block.token }); }
    catch (_) { throw stopped("Unntaket kunne ikke bekreftes. Ingen ny overføring er forsøkt. Prøv handlingen på nytt."); }
    if (generation !== projectGeneration) throw stopped("Overføringen ble avbrutt fordi prosjektet ble endret.");
    try { return await raw(command, copy(snapshot)); }
    catch (error) {
      if (parseBlock(error)) throw stopped("Overføringen er fortsatt stoppet. Innholdet kan ha endret seg, eller unntaket kan ha utløpt. Kontroller kildene og start handlingen på nytt.");
      throw error;
    }
  }
  window.AgentSyncSecretGuard = {
    invoke,
    isBlocked: error => error?.code === "SECRET_GUARD",
    projectChanged() { ++projectGeneration; pending?.cancel(); },
    mountSettings(parent) {
      host = node("section", "settings-group secret-guard-settings");
      parent.append(host);
      refresh();
    },
    init({ indicatorParent } = {}) {
      if (indicator) return;
      indicator = node("button", `bar-chip secret-guard-indicator${indicatorParent ? "" : " secret-guard-indicator-fixed"}`, "Hemmelighetsvern: leser status");
      indicator.type = "button";
      indicator.addEventListener("click", () => {
        const settings = document.getElementById("railSettingsButton");
        if (settings) {
          if (document.getElementById("settingsPanel")?.hidden) settings.click();
          host?.scrollIntoView({ block: "nearest" });
          return;
        }
        // The classic surface has no Brytere panel but must show the same
        // persisted setting, never a separate preference.
        const dialog = node("dialog", "secret-guard-dialog");
        const close = node("button", "", "Lukk");
        close.type = "button";
        close.addEventListener("click", () => dialog.close());
        dialog.addEventListener("close", () => dialog.remove());
        document.body.append(dialog);
        this.mountSettings(dialog);
        dialog.append(close);
        dialog.showModal();
      });
      (indicatorParent || document.body).append(indicator);
      refresh();
    }
  };
})();
