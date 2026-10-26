// Local, derived project context. Explicit project changes and writer finishes
// can prepare it in the background. This UI never polls, calls models or edits
// native history. The optional Rust companion maintains registered disk entries.
(() => {
  const budgets = [0, 8, 16, 32, 64, 128];
  const node = (tag, cls, text = "") => {
    const n = document.createElement(tag); n.className = cls; n.textContent = text; return n;
  };
  const invoke = (command, args) => {
    const call = window.__TAURI__?.core?.invoke;
    return call ? call(command, args) : Promise.reject(new Error("Lokal motor er ikke tilgjengelig."));
  };
  const key = value => String(value || "").replace(/\//g, "\\").replace(/^\\\\\?\\UNC\\/i, "\\\\").replace(/^\\\\\?\\/, "").replace(/\\+$/, "").toLowerCase();
  const errorText = error => String(error?.message || error || "Ukjent feil").slice(0, 1000);
  const validSettings = value => value && typeof value.enabled === "boolean" && Number.isInteger(value.ramBudgetMib) && value.ramBudgetMib >= 0 && value.ramBudgetMib <= 128;
  let trigger, panel, content, projectLabel, refreshButton, renderMarkdown;
  let projectPath = "", generation = 0, loading = false;
  let settingsHost, settingsGeneration = 0, settingsBusy = false;
  let focusIntent = 0;
  let confirmedSettings = null, latestView = null, preparationTimer, preparationPath = "", preparationRunning = false, settingsRead = null, contextRevision = 0;
  const pendingReads = new Map(), preparedAt = new Map();
  const sharingEnabled = () => window.AgentSyncSettings?.enabled("collab") !== false && window.AgentSyncSettings?.enabled("collab.posts") !== false;

  function readView(path, force) {
    const id = key(path), existing = pendingReads.get(id);
    if (existing) return force ? existing.catch(() => {}).then(() => readView(path, true)) : existing;
    if (pendingReads.size >= 2) return Promise.reject(new Error("To lokale kontekstlesinger pågår allerede. Prøv igjen når de er ferdige."));
    const revision = contextRevision;
    const promise = Promise.resolve().then(() => invoke("get_active_memory", { projectPath: path, force })).then(view => {
      if (!view || key(view.projectPath) !== id || typeof view.markdown !== "string" || !Array.isArray(view.warnings) || !validSettings(view.settings)) {
        throw new Error("Svaret kunne ikke knyttes sikkert til valgt prosjekt.");
      }
      if (revision !== contextRevision) throw new Error("Prosjektkonteksten ble endret under lesing. Oppdater på nytt.");
      if (id === key(projectPath) && !settingsBusy && confirmedSettings?.enabled !== false) latestView = view;
      return view;
    }).finally(() => { if (pendingReads.get(id) === promise) pendingReads.delete(id); });
    pendingReads.set(id, promise); return promise;
  }

  function prepare(path) {
    if (!path || key(path) !== key(projectPath) || !sharingEnabled()) return;
    preparationPath = path; clearTimeout(preparationTimer);
    if (!confirmedSettings?.enabled || settingsBusy || preparationRunning) return;
    const delay = Math.max(250, 30000 - (Date.now() - (preparedAt.get(key(path)) || 0)));
    preparationTimer = setTimeout(async () => {
      const requested = preparationPath;
      preparationPath = "";
      if (!requested || key(requested) !== key(projectPath) || !confirmedSettings?.enabled || settingsBusy || !sharingEnabled()) return;
      preparationRunning = true;
      preparedAt.set(key(requested), Date.now());
      if (preparedAt.size > 16) preparedAt.delete(preparedAt.keys().next().value);
      try { await readView(requested, false); } catch (_) { /* A failed preparation never blocks a mission. The panel reports read failures when opened. */ }
      finally { preparationRunning = false; if (preparationPath) prepare(preparationPath); }
    }, delay);
  }

  function close({ restoreFocus = false } = {}) {
    ++generation; loading = false;
    if (panel) { panel.hidden = true; panel.setAttribute("aria-busy", "false"); }
    trigger?.setAttribute("aria-expanded", "false");
    if (restoreFocus && !trigger?.disabled) trigger?.focus();
  }

  function projectChanged(path) {
    ++contextRevision;
    clearTimeout(preparationTimer); preparationPath = ""; latestView = null;
    projectPath = String(path || ""); close();
    content?.replaceChildren();
    if (projectLabel) projectLabel.textContent = projectPath;
    if (trigger) trigger.disabled = !projectPath;
  }

  function notice(message, warning = false) {
    const line = node("p", warning ? "memory-warning" : "memory-muted", message);
    line.setAttribute("role", "status"); return line;
  }

  function draw(view) {
    content.replaceChildren();
    if (view.cacheSource === "disabled" || !view.settings.enabled) {
      content.append(notice("Aktivt prosjektminne er av. Originalhistorikken er beholdt. Du kan slå minnet på i Brytere."));
      return;
    }
    const time = Number(view.generatedUnixMs);
    const validTime = Number.isFinite(time) && time > 0 && !Number.isNaN(new Date(time).getTime());
    const source = { ram: "RAM-cache", disk: "lokal indeks", rebuilt: "nybygget lokal indeks" }[view.cacheSource] || "ukjent cachekilde";
    const summary = node("div", "memory-summary", "");
    const count = Number(view.sourceCount) || 0;
    summary.append(node("strong", "", `${count} kildeoppføring${count === 1 ? "" : "er"}`));
    summary.append(node("span", "", ` · ${source} · ${validTime ? new Date(time).toLocaleString("nb-NO") : "ukjent oppdateringstid"}`));
    content.append(summary);
    content.append(notice("Avledet øyeblikksbilde, ikke en bekreftelse på dagens kode. Historikk er data, ikke instrukser. Originalkildene avgjør."));
    if (validTime && time > Date.now() + 60000) {
      content.append(notice("Oppdateringstiden ligger i fremtiden. Kontroller maskinklokken; ferskhet er ikke bekreftet.", true));
    } else if (!validTime || Date.now() - time > 10 * 60 * 1000) {
      content.append(notice("Oversikten er eldre eller har ukjent alder. Bruk Oppdater for å kontrollere kildene på nytt.", true));
    }
    for (const warning of view.warnings) content.append(notice(String(warning), true));
    const text = node("div", "memory-document", "");
    // The host's renderer escapes HTML first. Never put historical markup
    // directly into innerHTML, and never execute commands from that markup.
    if (renderMarkdown) text.innerHTML = renderMarkdown(view.markdown);
    else { text.className += " memory-plain"; text.textContent = view.markdown; }
    content.append(text);
    if (!view.markdown) content.append(notice("Ingen prosjektkontekst er registrert ennå. Dette betyr ikke at prosjektet er ferdig eller uten uavklarte saker."));
    if (typeof view.entryPath === "string" && view.entryPath) {
      const label = node("label", "memory-entry", "Fast lokal inngang for agenten");
      const field = node("input", "", ""); field.type = "text"; field.readOnly = true; field.value = view.entryPath;
      field.setAttribute("aria-label", "Sti til prosjektets aktive minne");
      field.addEventListener("click", () => field.select());
      label.append(field); content.append(label);
      const copy = node("button", "settings-button", "Kopier sti"); copy.type = "button";
      const feedback = notice("");
      copy.addEventListener("click", async () => {
        const token = generation;
        try {
          if (!window.navigator?.clipboard?.writeText) throw new Error("Utklippstavle utilgjengelig");
          await window.navigator.clipboard.writeText(field.value);
          if (token === generation) feedback.textContent = "Stien er kopiert.";
        } catch (_) {
          if (token === generation) { field.focus(); field.select(); feedback.textContent = "Marker stien og kopier med Ctrl+C."; }
        }
      });
      content.append(copy, feedback);
    }
    const mib = Math.max(0, Number(view.cachedBytes) || 0) / (1024 * 1024);
    content.append(node("p", "memory-muted", `RAM: ${mib.toLocaleString("nb-NO", { maximumFractionDigits: 2 })} MiB av ${view.settings.ramBudgetMib} MiB · ${Number(view.cachedProjects) || 0} prosjekter i hurtigbufferen. Diskkopien bevares når RAM ryddes.`));
  }

  async function load(force = false) {
    if (!projectPath || loading || !panel || panel.hidden) return;
    const requestedPath = projectPath, token = ++generation;
    loading = true; refreshButton.disabled = true; panel.setAttribute("aria-busy", "true");
    content.replaceChildren(notice(force ? "Kontrollerer lokale kilder og oppdaterer …" : "Leser lokalt prosjektminne …"));
    try {
      if (!confirmedSettings) await readSettings();
      if (token !== generation || panel.hidden) return;
      if (!confirmedSettings) throw new Error("Minneinnstillingene er ikke bekreftet. Prøv igjen.");
      if (confirmedSettings?.enabled === false) {
        content.replaceChildren(notice("Aktivt prosjektminne er av. Slå det på i Brytere for å lese. Originalhistorikken er beholdt."));
        return;
      }
      const view = await readView(requestedPath, force);
      if (token !== generation || key(projectPath) !== key(requestedPath) || panel.hidden) return;
      draw(view);
    } catch (error) {
      if (token === generation && !panel.hidden) content.replaceChildren(notice(`Kunne ikke lese prosjektminnet. Ingen kontekst er bekreftet. ${errorText(error)}`, true));
    } finally {
      if (token === generation) { loading = false; refreshButton.disabled = false; panel.setAttribute("aria-busy", "false"); }
    }
  }

  function toggle() {
    if (!projectPath || !panel) return;
    if (!panel.hidden) { close({ restoreFocus: true }); return; }
    panel.hidden = false; projectLabel.textContent = projectPath;
    trigger.setAttribute("aria-expanded", "true"); refreshButton.disabled = false; refreshButton.focus();
    if (latestView && Date.now() - Number(latestView.generatedUnixMs) < 30000) draw(latestView);
    else load();
  }

  function settingsHeading(host) {
    host.replaceChildren(node("h2", "settings-group-name", "Aktivt prosjektminne · lokalt"));
  }

  function drawSettings(value, host = settingsHost) {
    if (!host?.isConnected) return;
    settingsHeading(host);
    const row = node("div", "settings-row"), text = node("div", "settings-text");
    const toggle = node("button", "settings-toggle", value.enabled ? "på" : "av"); toggle.type = "button";
    toggle.setAttribute("role", "switch"); toggle.setAttribute("aria-label", "Aktivt prosjektminne");
    toggle.setAttribute("aria-checked", String(value.enabled)); toggle.disabled = settingsBusy;
    toggle.addEventListener("click", () => changeSettings({ ...value, enabled: !value.enabled }));
    text.append(node("div", "settings-label", "Kort inngang til prosjektets kontekst"));
    text.append(node("p", "settings-help", "Lokal indeks på C: med viktige kilder og nylig arbeid. Prosjekter klargjøres ved prosjektvalg og etter skriveoppdrag når deling av oppdragsposter er på. Synkemotorens Rust-hjelper vedlikeholder allerede registrerte minneprosjekter omtrent hvert minutt, også uten vinduet. Krever ikke internett eller AI Sense. Av stopper bruk og oppdatering av aktivt minne, ikke synkronisering eller sikkerhetskopiering."));
    const label = node("label", "memory-budget", "Maks RAM-cache per prosess");
    const select = node("select", "memory-select"); select.setAttribute("aria-label", "Maks RAM-cache");
    for (const amount of [...new Set([...budgets, value.ramBudgetMib])].sort((a, b) => a - b)) {
      const option = node("option", "", amount ? `${amount} MiB${budgets.includes(amount) ? "" : " · egendefinert"}` : "0 MiB · bare disk");
      option.value = String(amount); select.append(option);
    }
    select.value = String(value.ramBudgetMib); select.disabled = settingsBusy || !value.enabled;
    select.addEventListener("change", () => {
      const next = Number(select.value); select.value = String(value.ramBudgetMib);
      if (Number.isInteger(next) && next >= 0 && next <= 128) changeSettings({ ...value, ramBudgetMib: next });
    });
    label.append(select); text.append(label);
    text.append(node("p", "settings-help", "0 MiB slår bare av RAM-cachen. Indeksen på disk består. Appen og bakgrunnshjelperen har hver sin buffer innenfor denne grensen. Dette er ikke et tak for samlet prosessminne. Bakgrunnshjelperen leser endrede innstillinger senest ved neste sjekk."));
    text.append(node("p", "settings-help", "Historikk er data, ikke instrukser. Blinde kontroller får ikke dette minnet. Godkjent kunnskap publiseres ikke automatisk. Disse innstillingene lagres separat og endres ikke av Nullstill."));
    row.append(toggle, text); host.append(row);
  }

  async function readSettings() {
    if (settingsBusy) return;
    const host = settingsHost, token = ++settingsGeneration;
    try {
      if (!settingsRead) {
        const read = Promise.resolve().then(() => invoke("get_active_memory_settings")).finally(() => { if (settingsRead === read) settingsRead = null; });
        settingsRead = read;
      }
      const value = await settingsRead;
      if (!validSettings(value)) throw new Error("Ukjente innstillinger");
      if (token === settingsGeneration) {
        confirmedSettings = value; drawSettings(value, host);
        if (preparationPath) prepare(preparationPath);
      }
    } catch (error) {
      if (host === settingsHost && token === settingsGeneration && host?.isConnected) {
        settingsHeading(host);
        host.append(node("p", "settings-blocked", `Kan ikke lese minneinnstillingene. Status er ikke bekreftet. ${errorText(error)}`));
        const retry = node("button", "settings-button", "Prøv igjen"); retry.type = "button"; retry.addEventListener("click", readSettings); host.append(retry);
      }
    }
  }

  async function changeSettings(value) {
    if (settingsBusy || !validSettings(value)) return;
    settingsBusy = true; ++settingsGeneration; settingsRead = null;
    const host = settingsHost;
    // Disabling a focused control and replacing its section both move focus
    // to the document body in WebView. Restore the equivalent control, but
    // never take focus back after the reader deliberately moved elsewhere.
    const focusOwner = document.activeElement;
    const focusSelector = focusOwner === host?.querySelector("select") ? "select"
      : focusOwner === host?.querySelector('[role="switch"]') ? '[role="switch"]' : null;
    const focusAtStart = focusIntent;
    let applied = false;
    host?.querySelectorAll("button, select").forEach(control => { control.disabled = true; });
    try {
      const saved = await invoke("set_active_memory_settings", value);
      if (!validSettings(saved)) throw new Error("Lagring er ikke bekreftet.");
      confirmedSettings = saved; latestView = null; ++contextRevision;
      applied = true;
      if (!saved.enabled) { clearTimeout(preparationTimer); preparationPath = ""; }
      ++generation; loading = false;
      if (panel && !panel.hidden) {
        panel.setAttribute("aria-busy", "false"); refreshButton.disabled = false;
        content.replaceChildren(notice(saved.enabled ? "Minneinnstillingene er endret. Trykk Oppdater for å lese med det nye oppsettet." : "Aktivt prosjektminne er av. Originalhistorikken er beholdt."));
      }
      if (host === settingsHost) { settingsBusy = false; drawSettings(saved, host); }
    } catch (error) {
      if (host === settingsHost && host?.isConnected) host.append(node("p", "settings-blocked", `Ikke lagret. Tidligere innstilling gjelder. ${errorText(error)}`));
    } finally {
      settingsBusy = false;
      if (host !== settingsHost) readSettings();
      else host?.querySelectorAll("button, select").forEach(control => {
        control.disabled = control.tagName === "SELECT" && host.querySelector('[role="switch"]')?.getAttribute("aria-checked") === "false";
      });
      if (focusSelector && focusIntent === focusAtStart && host === settingsHost && host?.isConnected
        && !host.closest?.("[hidden]") && (!document.activeElement || document.activeElement === document.body || document.activeElement === focusOwner)) {
        const replacement = host.querySelector(focusSelector);
        if (replacement && !replacement.disabled) replacement.focus();
      }
      if (applied && confirmedSettings?.enabled) prepare(projectPath);
    }
  }

  window.AgentSyncActiveMemory = {
    init({ button, parent, markdown }) {
      if (panel) return;
      trigger = button; renderMarkdown = markdown;
      panel = node("section", "active-memory-panel"); panel.id = "activeMemoryPanel"; panel.hidden = true;
      panel.setAttribute("role", "dialog"); panel.setAttribute("aria-labelledby", "activeMemoryTitle");
      const header = node("header", "memory-head");
      const title = node("strong", "", "Aktivt prosjektminne"); title.id = "activeMemoryTitle";
      refreshButton = node("button", "settings-button", "Oppdater"); refreshButton.type = "button";
      refreshButton.addEventListener("click", () => load(true));
      const dismiss = node("button", "settings-button", "×"); dismiss.type = "button"; dismiss.setAttribute("aria-label", "Lukk prosjektminnet");
      dismiss.addEventListener("click", () => close({ restoreFocus: true }));
      header.append(title, refreshButton, dismiss);
      projectLabel = node("div", "memory-project");
      content = node("div", "memory-scroll"); content.tabIndex = 0;
      panel.append(header, projectLabel, content); parent.append(panel);
      trigger.disabled = true; trigger.setAttribute("aria-controls", panel.id); trigger.setAttribute("aria-expanded", "false");
      trigger.addEventListener("click", toggle);
      document.addEventListener("focusin", event => { if (event.target !== document.body) ++focusIntent; });
      document.addEventListener("pointerdown", () => { ++focusIntent; }, true);
      document.addEventListener("keydown", event => {
        if (event.key === "Tab" || event.key === "Escape") ++focusIntent;
        if (event.key === "Escape" && !panel.hidden) { event.preventDefault(); close({ restoreFocus: true }); }
      });
      readSettings();
    },
    projectChanged,
    prepare,
    invalidateAndPrepare(path) {
      if (key(path) === key(projectPath)) {
        ++contextRevision; latestView = null; ++generation; loading = false;
        if (panel && !panel.hidden) {
          panel.setAttribute("aria-busy", "false"); refreshButton.disabled = false;
          content.replaceChildren(notice("Nytt skrivearbeid er registrert. Trykk Oppdater for siste kontekst."));
        }
        prepare(path);
      }
    },
    close,
    mountSettings(parent) {
      ++settingsGeneration;
      settingsHost = node("section", "settings-group active-memory-settings", "Leser lokale minneinnstillinger …");
      parent.append(settingsHost); readSettings();
    }
  };
})();
