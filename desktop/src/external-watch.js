// Isolated from missions and their polling. This panel reads local watch state;
// only the Rust worker talks to AI Sense, with its own bounded deadlines.
(() => {
  let host, timer, busy = false, generation = 0;
  const invoke = (...args) => window.__TAURI__?.core?.invoke(...args);
  const labels = { ready: "Klargjøres", creating: "Opprettelse ikke ferdig bekreftet", active: "Ekstern vakt aktiv", offline: "Lokal drift · ekstern kontakt mangler", uncertain: "Lokal drift · opprettelse uviss", attention: "Ekstern vakt trenger ettersyn", expired: "Vaktens tidsvindu er utløpt", disabled: "Av" };
  const node = (tag, cls, text) => { const n = document.createElement(tag); n.className = cls; n.textContent = text; return n; };
  function safeLink(url, kind) {
    const pattern = kind === "heartbeat" ? /^[a-f0-9]{64}$/i : /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
    const prefix = `https://aisenseapi.com/services/v1/${kind}/`;
    return typeof url === "string" && url.startsWith(prefix) && pattern.test(url.slice(prefix.length));
  }
  function draw(status) {
    if (!host?.isConnected) return;
    host.replaceChildren(node("h2", "settings-group-name", "AI Sense · ekstern driftsvakt"));
    const row = node("div", "settings-row", "");
    const toggle = node("button", "settings-toggle", status.enabled ? "på" : "av");
    toggle.type = "button"; toggle.setAttribute("role", "switch");
    toggle.setAttribute("aria-label", "AI Sense ekstern driftsvakt");
    toggle.setAttribute("aria-checked", String(status.enabled)); toggle.disabled = busy;
    toggle.addEventListener("click", () => change(!status.enabled, false));
    const info = node("div", "settings-text", "");
    info.append(node("div", "settings-label", labels[status.state] || "Ukjent status"), node("p", "settings-help", status.note));
    info.append(node("p", "settings-help", "Gevinst: les prosessens siste livstegn fra en annen enhet, også når denne maskinen er borte. Dette tester ikke appvinduet, synkemotoren eller Spark. Kildekode, stier og samtaler sendes aldri. AI Sense mottar vanlig nettmetadata som IP-adressen."));
    info.append(node("p", "settings-help", "Dette er en midlertidig vakt, ikke e-post eller pushvarsling. Fravær kan skyldes vanlig lukking, nettbrudd eller feil. Delbare lenker er bearer-hemmeligheter og utløper innen 24 timer. Av stopper alle nye kall, men sletter ikke en ekstern vakt."));
    if (status.lastConfirmed) info.append(node("p", "settings-help", `Sist bekreftet: ${new Date(status.lastConfirmed * 1000).toLocaleString("nb-NO")}`));
    if (status.expiresAt) info.append(node("p", "settings-help", `Vindu frem til: ${new Date(status.expiresAt * 1000).toLocaleString("nb-NO")}`));
    for (const [url, kind, title] of [[status.statusUrl, "heartbeat", "Statuslenke"], [status.readUrl, "webhook_capture", "Hendelseslenke"]]) {
      if (!safeLink(url, kind)) continue;
      const label = node("label", "external-watch-link", title);
      const field = node("input", "", ""); field.type = "text"; field.readOnly = true; field.value = url;
      field.setAttribute("aria-label", `${title} · privat, kan kopieres til en annen enhet`);
      field.addEventListener("click", () => field.select()); label.append(field); info.append(label);
    }
    if (status.enabled && ["uncertain", "creating", "expired", "attention"].includes(status.state)) {
      const retry = node("button", "settings-button", "Opprett nytt 24-timersvindu"); retry.type = "button"; retry.disabled = busy;
      retry.addEventListener("click", () => {
        if (window.confirm("Dette oppretter nye private lenker. En tidligere vakt kan fortsatt eksistere til den utløper. Fortsette?")) change(true, true);
      }); info.append(retry);
    }
    row.append(toggle, info); host.append(row);
  }
  async function refresh() {
    if (!host?.isConnected || busy) return;
    if (host.contains(document.activeElement) && document.activeElement?.tagName === "INPUT") return;
    const token = ++generation;
    try {
      const status = await invoke("get_external_watch");
      if (!status || typeof status.enabled !== "boolean" || typeof status.state !== "string") throw new Error("Ukjent status");
      if (token === generation) draw(status);
    } catch (_) {
      if (token === generation && host?.isConnected) {
        host.replaceChildren(node("h2", "settings-group-name", "AI Sense · ekstern driftsvakt"), node("p", "settings-help", "Kan ikke lese driftsvaktstatus. Lokal bruk av MAX fortsetter. Status er ikke bekreftet."));
      }
    }
  }
  async function change(enabled, newWindow) {
    if (busy) return;
    busy = true; ++generation;
    host?.querySelectorAll("button").forEach(b => { b.disabled = true; });
    try { draw(await invoke("set_external_watch", { enabled, newWindow })); }
    catch (error) { if (host?.isConnected) host.append(node("p", "settings-blocked", String(error))); }
    finally { busy = false; host?.querySelectorAll("button").forEach(b => { b.disabled = false; }); }
  }
  window.AgentSyncExternalWatch = {
    mount(parent) {
      ++generation; clearInterval(timer);
      host = node("section", "settings-group external-watch", "Leser lokal driftsvaktstatus …");
      parent.append(host); refresh();
      timer = setInterval(() => {
        if (!host?.isConnected) { clearInterval(timer); return; }
        if (!document.hidden && !document.getElementById("settingsPanel")?.hidden) refresh();
      }, 15000);
    }
  };
})();
