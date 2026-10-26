// A finding is a claim, not a verdict. These controls record the user's
// evidence-based assessment separately from sending a critique to an agent.
// Opening this register never starts a model or changes validator settings.
(() => {
  const VERDICTS = {
    unreviewed: "Ikke vurdert",
    unresolved: "Uavklart",
    confirmed: "Bekreftet feil",
    partial: "Delvis riktig",
    falsePositive: "Falskt varsel",
  };
  const REMEDIATIONS = {
    open: "Åpen / ikke rettet",
    fixed: "Rettet, ikke etterkontrollert",
    verified: "Rettet og kontrollert",
  };
  const SCORE_DIMENSIONS = [
    { key: "usefulness", label: "Nytte", low: "verdiløst", high: "utrolig nyttig" },
    { key: "actionability", label: "Handlingsklarhet", low: "vanskelig å følge opp", high: "helt konkret hva som må undersøkes" },
    { key: "novelty", label: "Ny informasjon", low: "dette visste vi allerede", high: "viktig og tidligere oversett" },
  ];
  const AGENT_LABELS = { codex: "Codex", claude: "Claude Code", antigravity: "Antigravity", opencode: "OpenCode", cline: "Cline", aider: "Aider" };
  const MISSION_STATUSES = { completed: "ferdig", failed: "feilet", cancelled: "avbrutt", canceled: "avbrutt", running: "arbeider", queued: "venter" };
  const missionCache = new Map();
  const drafts = new Map();
  const laterDrafts = new Map();
  const saving = new Set();
  const savingLater = new Set();
  let dialog;
  let body;
  let project = "";
  let dataset = null;
  let filter = "all";
  let requestGeneration = 0;
  let focusCase = "";
  let returnFocus = null;
  let projectMissions = [];
  let missionWarning = "";
  let missionOffset = 0;
  let missionsHaveMore = false;
  const PAGE_SIZE = 50;
  let visibleCount = PAGE_SIZE;
  const expandedCases = new Set();

  function invoke(command, request) {
    const bridge = window.__TAURI__?.core?.invoke;
    return bridge ? bridge(command, { request }) : Promise.reject(new Error("Registeret krever AgentSync-forbindelsen."));
  }
  function node(tag, className = "", text) {
    const result = document.createElement(tag);
    if (className) result.className = className;
    if (text !== undefined) result.textContent = text;
    return result;
  }
  function button(label, action, className = "evaluation-button") {
    const result = node("button", className, label);
    result.type = "button";
    result.addEventListener("click", action);
    return result;
  }
  function date(value) {
    return Number(value) ? new Date(Number(value)).toLocaleString("nb-NO") : "Tid ikke registrert";
  }
  function optionSelect(values, selected, label) {
    const select = node("select", "evaluation-input");
    select.setAttribute("aria-label", label);
    for (const [value, text] of Object.entries(values)) {
      const option = node("option", "", text);
      option.value = value;
      select.append(option);
    }
    select.value = selected;
    return select;
  }
  function field(label, input) {
    const host = node("label", "evaluation-field");
    host.append(node("span", "", label), input);
    return host;
  }
  function note(text, className = "evaluation-note") {
    return node("p", className, text);
  }
  function caseStatus(item) {
    const verdict = VERDICTS[item.verdict] || "Ukjent vurdering";
    const status = item.remediation && item.remediation !== "open"
      ? `${verdict} · ${REMEDIATIONS[item.remediation] || item.remediation}` : verdict;
    const scores = SCORE_DIMENSIONS.filter(({ key }) => item[key] != null)
      .map(({ key, label }) => `${label.toLowerCase()} ${item[key]}/10`);
    return scores.length ? `${status} · ${scores.join(" · ")}` : status;
  }
  function modelText(provenance) {
    if (provenance.resolvedModel && provenance.modelSource === "observed") return `${provenance.resolvedModel} (bekreftet av agenten)`;
    if (provenance.resolvedModel) return `${provenance.resolvedModel} (${provenance.modelSource === "configured" ? "konfigurert" : "ikke bekreftet brukt"})`;
    if (provenance.requestedModel) return `${provenance.requestedModel} (ønsket, brukt modell ukjent)`;
    return "Brukt modell ikke registrert";
  }
  function setStatus(host, text, error = false) {
    host.textContent = text;
    host.className = `evaluation-status${error ? " error" : ""}`;
  }

  function railButton() {
    return document.getElementById("railEvaluationsButton");
  }

  function setRailOpen(open) {
    railButton()?.classList.toggle("active", open);
    railButton()?.setAttribute("aria-expanded", String(open));
  }

  function ensureDialog() {
    if (dialog) return;
    dialog = node("dialog", "evaluation-dialog");
    dialog.id = "evaluationDialog";
    dialog.setAttribute("aria-labelledby", "evaluationHeading");
    const header = node("header", "evaluation-header");
    const heading = node("h2", "", "Funn og avklaringer");
    heading.id = "evaluationHeading";
    const close = button("×", () => dialog.close());
    close.setAttribute("aria-label", "Lukk funn og avklaringer");
    header.append(heading, close);
    body = node("div", "evaluation-body");
    dialog.append(header, body);
    // This is a non-modal work surface so the rail stays usable. Stop canvas
    // shortcuts here, and provide the Escape handling a modal dialog used to
    // supply natively.
    dialog.addEventListener("keydown", (event) => {
      event.stopPropagation();
      if (event.key !== "Escape") return;
      event.preventDefault();
      dialog.close();
    });
    dialog.addEventListener("close", () => {
      setRailOpen(false);
      requestGeneration += 1;
      // Drafts are plain values, so large forms and result text need not stay
      // attached while the register is closed. In-flight saves keep their own
      // references and still complete without altering a different project.
      body.replaceChildren();
      dataset = null;
      projectMissions = [];
      if (returnFocus?.isConnected) returnFocus.focus();
    });
    document.body.append(dialog);
  }

  async function refresh() {
    const generation = ++requestGeneration;
    const wantedProject = project;
    body.replaceChildren(note("Henter lokale funn og avklaringer…"));
    if (!wantedProject) {
      body.replaceChildren(note("Velg et prosjekt i hovedvinduet først."));
      return;
    }
    try {
      const [result, missions] = await Promise.all([
        invoke("get_evaluation_dataset", { projectPath: wantedProject }),
        invoke("get_mission_summaries", { projectPath: wantedProject, offset: 0, limit: 100 }).catch(() => null),
      ]);
      if (generation !== requestGeneration || !dialog.open) return;
      dataset = result;
      projectMissions = [];
      mergeMissions(missions, wantedProject);
      missionOffset = missions?.history?.length || 0;
      missionsHaveMore = Boolean(missions?.hasMore);
      missionWarning = missions ? missions.warning || "" : "Oppdragslisten kunne ikke leses. Du kan fortsatt registrere en senere feil uten oppdragskobling.";
      renderDataset();
    } catch (error) {
      if (generation !== requestGeneration || !dialog.open) return;
      body.replaceChildren(note(`Kunne ikke lese registeret: ${error}`, "evaluation-status error"),
        button("Prøv igjen", refresh));
    }
  }

  function mergeMissions(result, wantedProject) {
    const key = (path) => String(path || "").replace(/^\\\\\?\\/, "").replaceAll("\\", "/").replace(/\/+$/, "").toLowerCase();
    const seen = new Set(projectMissions.map(mission => mission.id));
    for (const mission of [...(result?.missions || []), ...(result?.history || [])]) {
      if (seen.has(mission.id) || key(mission.projectPath) !== key(wantedProject)) continue;
      seen.add(mission.id);
      if (mission.purpose === "writer" || (!mission.purpose && mission.mode !== "blind")) projectMissions.push(mission);
    }
  }

  function evidenceHistory(item) {
    const history = node("details", "evaluation-history");
    const eventCount = item.history?.length || 0;
    history.append(node("summary", "", `Historikk og opphav (${eventCount} ${eventCount === 1 ? "hendelse" : "hendelser"})`));
    let loaded = false;
    history.addEventListener("toggle", () => {
      if (!history.open || loaded) return;
      loaded = true;
      fillEvidenceHistory(history, item);
    });
    return history;
  }

  function fillEvidenceHistory(history, item) {
    const p = item.provenance || {};
    history.append(note(item.kind === "laterDiscovered"
      ? "Registrert av brukeren som en feil oppdaget senere. Ikke et varsel fra validatoren."
      : `Validator: ${p.validatorAgent || "ikke registrert"} · ${modelText(p)} · kontekst: ${p.contextMode || "ukjent"}.`));
    if (p.requestedModel && p.resolvedModel && p.requestedModel !== p.resolvedModel) {
      history.append(note(`Ønsket modell: ${p.requestedModel}.`));
    }
    if (item.missionId) history.append(note(`Kontroll: ${item.missionId}`));
    if (p.sourceMissionId) history.append(note(`Skriveoppdrag: ${p.sourceMissionId}`));
    if (p.durationMs != null) history.append(note(`Kontrollens varighet: ${Math.round(p.durationMs / 1000)} sekunder.`));
    history.append(note("Bevisene og avklaringen er registrert av brukeren. Agentens svar, en videresending eller en endret fil er ikke automatisk fasit."));
    for (const entry of [...(item.history || [])].reverse()) {
      const record = node("div", "evaluation-history-entry");
      if (entry.kind === "followupLinked") {
        record.append(node("b", "", `${date(entry.atUnixMs)} · Sendt til ${entry.followup?.agent || "agent"}`),
          note(`Oppdrag: ${entry.followup?.missionId || "ikke registrert"}. Videresendingen avklarer ikke funnet.`));
        history.append(record);
        continue;
      }
      record.append(node("b", "", `${date(entry.atUnixMs)} · ${VERDICTS[entry.verdict] || entry.verdict} · ${REMEDIATIONS[entry.remediation] || entry.remediation}`));
      const ratings = SCORE_DIMENSIONS.filter(({ key }) => entry[key] != null)
        .map(({ key, label }) => `${label}: ${entry[key]}/10`);
      if (ratings.length) record.append(note(`${ratings.join(" · ")} (brukerens vurderinger).`));
      if (entry.evidence) record.append(node("p", "evaluation-verbatim", entry.evidence));
      if (entry.notes) record.append(node("p", "evaluation-verbatim", entry.notes));
      history.append(record);
    }
  }

  function renderCase(item) {
    const wrapper = node("details", "evaluation-case");
    wrapper.dataset.caseId = item.id;
    const summary = node("summary", "evaluation-case-summary");
    const title = node("span", "evaluation-case-title", item.title);
    const statusBadge = node("span", "evaluation-badge", caseStatus(item));
    summary.append(title, statusBadge);
    wrapper.append(summary);
    let loaded = false;
    const expand = () => {
      if (wrapper.open) {
        expandedCases.add(item.id);
        if (!loaded) {
          loaded = true;
          renderCaseForm(wrapper, item);
        }
      } else {
        expandedCases.delete(item.id);
        wrapper.querySelector("form")?.remove();
        loaded = false;
      }
    };
    wrapper.addEventListener("toggle", expand);
    if (focusCase === item.id || expandedCases.has(item.id)) {
      wrapper.open = true;
      expand();
    }
    return wrapper;
  }

  function renderCaseForm(wrapper, item) {
    const form = node("form", "evaluation-form");
    form.append(note(item.detail, "evaluation-verbatim"));
    if (item.file) form.append(note(item.file, "evaluation-path"));
    const previous = drafts.get(item.id);
    const values = previous || {
      verdict: item.verdict, remediation: item.remediation, evidence: item.evidence || "",
      notes: item.notes || "", usefulness: item.usefulness ?? null,
      actionability: item.actionability ?? null, novelty: item.novelty ?? null, expectedRevision: item.revision,
    };
    const verdictLabel = item.kind === "laterDiscovered" ? "Hva vet vi om feilen?" : "Var varslet riktig?";
    const verdict = optionSelect(VERDICTS, values.verdict, verdictLabel);
    const remediation = optionSelect(REMEDIATIONS, values.remediation, "Er feilen rettet?");
    const selectors = node("div", "evaluation-fields");
    selectors.append(field(verdictLabel, verdict), field("Er feilen rettet?", remediation));
    const scoreFields = node("div", "evaluation-fields");
    const scoreInputs = new Map();
    for (const dimension of SCORE_DIMENSIONS) {
      const scores = { "": "Ikke vurdert ennå" };
      for (let score = 1; score <= 10; score += 1) {
        scores[score] = `${score}${score === 1 ? ` · ${dimension.low}` : score === 10 ? ` · ${dimension.high}` : ""}`;
      }
      const select = optionSelect(scores, values[dimension.key] == null ? "" : String(values[dimension.key]), dimension.label);
      select.prepend([...select.options].find((option) => option.value === ""));
      scoreInputs.set(dimension.key, select);
      scoreFields.append(field(`${dimension.label} (1–10)`, select));
    }
    const evidence = node("textarea", "evaluation-input");
    evidence.rows = 4;
    evidence.maxLength = 12000;
    evidence.value = values.evidence;
    evidence.placeholder = "Hva viser det? Test og resultat, reproduksjon, eller fil/linje og begrunnelse. Ved etterkontroll: skriv hva du kontrollerte.";
    const notes = node("textarea", "evaluation-input");
    notes.rows = 2;
    notes.maxLength = 4000;
    notes.value = values.notes;
    notes.placeholder = "Forbehold eller hva som gjenstår (valgfritt).";
    const status = node("p", "evaluation-status");
    status.setAttribute("role", "status");
    const save = node("button", "evaluation-button primary", "Lagre avklaring");
    save.type = "submit";
    save.disabled = saving.has(item.id);
    const rememberDraft = () => drafts.set(item.id, {
      verdict: verdict.value, remediation: remediation.value,
      evidence: evidence.value, notes: notes.value, expectedRevision: values.expectedRevision,
      ...Object.fromEntries([...scoreInputs].map(([key, select]) => [key, select.value ? Number(select.value) : null])),
    });
    const syncFields = () => {
      const cannotFix = !["confirmed", "partial"].includes(verdict.value);
      for (const option of remediation.options) option.disabled = cannotFix && option.value !== "open";
      if (cannotFix) remediation.value = "open";
      evidence.required = ["confirmed", "partial", "falsePositive"].includes(verdict.value) || remediation.value === "verified";
    };
    verdict.addEventListener("change", () => { syncFields(); rememberDraft(); });
    remediation.addEventListener("change", () => { syncFields(); rememberDraft(); });
    evidence.addEventListener("input", rememberDraft);
    notes.addEventListener("input", rememberDraft);
    for (const select of scoreInputs.values()) select.addEventListener("change", rememberDraft);
    syncFields();
    const actions = node("div", "evaluation-actions");
    actions.append(save, button("Hent lagret på nytt", () => {
      drafts.delete(item.id);
      focusCase = item.id;
      refresh();
    }));
    if (item.followups?.length) {
      const followups = node("div", "evaluation-followups");
      followups.append(note("Sendt videre for vurdering. Agentens svar er en påstand som fortsatt må kontrolleres."));
      for (const followup of item.followups) {
        const reply = node("pre", "evaluation-reply");
        reply.hidden = true;
        const read = button(`Les svar fra ${AGENT_LABELS[followup.agent] || followup.agent || "agent"} · ${MISSION_STATUSES[followup.status] || "ukjent status"}`, async () => {
          read.disabled = true;
          reply.hidden = false;
          reply.textContent = "Henter oppdragets svar…";
          try {
            const session = await window.__TAURI__.core.invoke("get_mission_session", { missionId: followup.missionId });
            reply.textContent = session.finalOutput || (session.status === "running" || session.status === "queued"
              ? "Agenten arbeider fortsatt. Trykk igjen for å hente det siste svaret."
              : "Oppdraget ga ikke noe sluttresultat. Det avklarer ikke funnet.");
          } catch (error) { reply.textContent = `Kunne ikke hente svar: ${error}`; }
          finally { read.disabled = false; }
        });
        followups.append(read, reply);
      }
      form.append(followups);
    }
    form.append(selectors, scoreFields, field("Bevis / begrunnelse", evidence), field("Merknad", notes),
      note("Tre valgfrie scorer, uavhengig av om varslet var riktig. 1 er lavest, 10 er høyest; ytterpunktene står i valgene. Hvert gjennomsnitt teller bare sine besvarte scorer. Ingen samlet totalscore."),
      note("Rettet og kontrollert er din bekreftelse, ikke en test AgentSync har kjørt. Ikke legg inn passord eller nøkler. Registeret kan følge mappens filsynk."), actions, status, evidenceHistory(item));
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (saving.has(item.id)) return;
      rememberDraft();
      if (evidence.required && !evidence.value.trim()) {
        setStatus(status, "Skriv bevis eller begrunnelse før du avklarer funnet.", true);
        evidence.focus();
        return;
      }
      saving.add(item.id);
      const lockedInputs = [...form.querySelectorAll("input, select, textarea, button")].map((input) => [input, input.disabled]);
      for (const [input] of lockedInputs) input.disabled = true;
      const ownerProject = project;
      setStatus(status, "Lagrer avklaringen…");
      try {
        const saved = await invoke("save_finding_evaluation", {
          ...(item.revision > 0 || item.kind === "laterDiscovered" ? { caseId: item.id } : { missionId: item.missionId, findingIndex: item.findingIndex }),
          ...drafts.get(item.id),
        });
        drafts.delete(item.id);
        if (item.missionId) missionCache.delete(item.missionId);
        window.dispatchEvent(new CustomEvent("agentsync:evaluation-saved", { detail: saved }));
        if (ownerProject === project && dialog.open) {
          focusCase = item.id;
          await refresh();
        }
      } catch (error) {
        setStatus(status, `Ikke lagret: ${error}. Teksten din er beholdt.`, true);
        if (ownerProject === project && dialog.open && !form.isConnected) {
          const current = [...body.querySelectorAll("[data-case-id]")].find(candidate => candidate.dataset.caseId === item.id);
          const currentStatus = current?.querySelector("[role=status]");
          if (currentStatus) setStatus(currentStatus, `Ikke lagret: ${error}. Teksten din er beholdt.`, true);
        }
      } finally {
        saving.delete(item.id);
        for (const [input, wasDisabled] of lockedInputs) input.disabled = wasDisabled;
        // A successful refresh may have rendered a new button while saving.
        for (const current of body.querySelectorAll("[data-case-id]")) {
          const submit = current.querySelector('button[type="submit"]');
          if (current.dataset.caseId !== item.id) continue;
          for (const input of current.querySelectorAll("[data-evaluation-save-lock]")) {
            input.disabled = input.dataset.evaluationSaveLock === "1";
            delete input.dataset.evaluationSaveLock;
          }
          if (submit) submit.disabled = false;
        }
      }
    });
    wrapper.append(form);
    if (saving.has(item.id)) {
      for (const input of form.querySelectorAll("input, select, textarea, button")) {
        input.dataset.evaluationSaveLock = input.disabled ? "1" : "0";
        input.disabled = true;
      }
      setStatus(status, "Lagrer avklaringen…");
    }
  }

  function renderGroups(groups) {
    const details = node("details", "evaluation-history");
    details.append(node("summary", "", "Måling per agent, modell og kontekst"));
    details.append(note("Bekreftet-andel = bekreftede feil / (bekreftede feil + falske varsler). Delvis riktige, uavklarte og ikke vurderte vises separat. Dette måler ikke feil ingen oppdaget, og er ingen rangering av modellene."));
    if (!groups?.length) details.append(note("Ingen strukturerte validatorfunn å måle ennå."));
    for (const group of groups || []) {
      const counts = group.summary || group;
      const row = node("div", "evaluation-group");
      const modelBasis = { observed: "bekreftet av agenten", configured: "konfigurert, ikke bekreftet brukt", requested: "ønsket, ikke bekreftet brukt", legacyUnverified: "eldre registrering, ikke bekreftet brukt", requestedOnly: "ønsket, faktisk modell ukjent", unknown: "ukjent" }[group.modelSource] || "ukjent";
      const rate = counts.confirmedRate == null ? "ikke målt" : `${Math.round(counts.confirmedRate * 100)} %`;
      row.append(node("b", "", `${group.validatorAgent || "Ukjent agent"} · ${group.model || "Ukjent modell"}`),
        note(`${group.contextMode || "Ukjent kontekst"} · modellgrunnlag: ${modelBasis}`),
        note(`${counts.confirmed || 0} bekreftet · ${counts.falsePositive || 0} falske · ${counts.partial || 0} delvis · ${counts.unresolved || 0} uavklart · ${counts.unreviewed || 0} ikke vurdert`),
        note(`Bekreftet-andel: ${rate} (${(counts.confirmed || 0) + (counts.falsePositive || 0)} entydig avklarte varsler).`));
      for (const dimension of SCORE_DIMENSIONS) row.append(note(scoreAverage(counts, dimension)));
      details.append(row);
    }
    return details;
  }

  function scoreAverage(counts, { key, label }) {
    const average = counts[`${key}Average`];
    const rated = counts[`${key}Rated`] || 0;
    return `${label}: ${average == null ? "ikke vurdert" : `${Number(average).toLocaleString("nb-NO", { maximumFractionDigits: 1 })}/10 i snitt`} · ${rated} ${rated === 1 ? "score" : "scorer"}.`;
  }

  function laterFindingForm() {
    const ownerProject = project;
    const draft = laterDrafts.get(ownerProject) || {};
    const details = node("details", "evaluation-later");
    details.append(node("summary", "", "+ Registrer feil oppdaget senere"));
    let loaded = false;
    const expand = () => {
      if (!details.open || loaded) return;
      loaded = true;
      fillLaterFindingForm(details, ownerProject, draft);
    };
    details.addEventListener("toggle", expand);
    if (Object.keys(draft).length) { details.open = true; expand(); }
    return details;
  }

  function fillLaterFindingForm(details, ownerProject, draft) {
    const form = node("form", "evaluation-form evaluation-later-form");
    const title = node("input", "evaluation-input");
    title.required = true;
    title.maxLength = 200;
    title.value = draft.title || "";
    const description = node("textarea", "evaluation-input");
    description.required = true;
    description.rows = 3;
    description.maxLength = 4000;
    description.value = draft.detail || "";
    const file = node("input", "evaluation-input");
    file.maxLength = 1000;
    file.value = draft.file || "";
    const evidence = node("textarea", "evaluation-input");
    evidence.required = true;
    evidence.rows = 3;
    evidence.maxLength = 12000;
    evidence.value = draft.evidence || "";
    const sources = { "": "Ukjent / ingen oppdragskobling" };
    for (const mission of projectMissions) {
      sources[mission.id] = `${mission.agentLabel || mission.agent || "Skriveoppdrag"} · ${date(mission.startedUnixMs)} · ${String(mission.prompt || "").slice(0, 60)}`;
    }
    for (const item of dataset?.cases || []) {
      const p = item.provenance || {};
      if (p.sourceMissionId && !sources[p.sourceMissionId]) sources[p.sourceMissionId] = `${p.sourceAgent || "Skriveoppdrag"} · ${p.sourceMissionId}`;
    }
    if (draft.sourceMissionId && !sources[draft.sourceMissionId]) sources[draft.sourceMissionId] = draft.sourceMissionId;
    const source = optionSelect(sources, draft.sourceMissionId || "", "Tilknyttet skriveoppdrag");
    const olderStatus = node("p", "evaluation-status");
    const older = button("Hent eldre skriveoppdrag", async () => {
      if (older.disabled || savingLater.has(ownerProject)) return;
      older.disabled = true;
      const generation = requestGeneration;
      try {
        const result = await invoke("get_mission_summaries", { projectPath: ownerProject, offset: missionOffset, limit: 100 });
        if (generation !== requestGeneration || !dialog.open) return;
        mergeMissions(result, ownerProject);
        missionOffset += result.history?.length || 0;
        missionsHaveMore = Boolean(result.hasMore);
        const known = new Set([...source.options].map(option => option.value));
        for (const mission of projectMissions) {
          if (known.has(mission.id)) continue;
          const option = node("option", "", `${mission.agentLabel || mission.agent || "Skriveoppdrag"} · ${date(mission.startedUnixMs)} · ${String(mission.prompt || "").slice(0, 60)}`);
          option.value = mission.id;
          source.append(option);
        }
        older.hidden = !missionsHaveMore;
        setStatus(olderStatus, result.warning || `${projectMissions.length} skriveoppdrag tilgjengelige.`, Boolean(result.warning));
      } catch (error) {
        if (generation === requestGeneration && dialog.open) setStatus(olderStatus, `Kunne ikke hente eldre oppdrag: ${error}`, true);
      } finally {
        older.disabled = savingLater.has(ownerProject);
      }
    });
    older.hidden = !missionsHaveMore;
    const rememberDraft = () => laterDrafts.set(ownerProject, {
      title: title.value, detail: description.value, file: file.value,
      evidence: evidence.value, sourceMissionId: source.value,
    });
    for (const input of [title, description, file, evidence, source]) input.addEventListener("input", rememberDraft);
    source.addEventListener("change", rememberDraft);
    const save = node("button", "evaluation-button", "Registrer senere oppdaget feil");
    save.type = "submit";
    const status = node("p", "evaluation-status");
    status.setAttribute("role", "status");
    form.append(note("Registrer en feil du har dokumentert utenfor disse varslene. Den holdes utenfor validatorens treffsikkerhet. En kobling til et oppdrag beviser ikke hvem som innførte feilen."),
      field("Kort tittel", title), field("Hva var feilen?", description), field("Fil (valgfritt)", file),
      field("Bevis / reproduksjon", evidence), field("Tilknyttet skriveoppdrag (valgfritt)", source), older, olderStatus, save, status);
    if (missionWarning) form.append(note(missionWarning));
    if (savingLater.has(ownerProject)) {
      for (const input of form.querySelectorAll("input, select, textarea, button")) {
        input.dataset.laterSaveLock = String(input.disabled);
        input.disabled = true;
      }
      setStatus(status, "Lagrer…");
    }
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (save.disabled || savingLater.has(ownerProject)) return;
      savingLater.add(ownerProject);
      const lockedInputs = [...form.querySelectorAll("input, select, textarea, button")].map((input) => [input, input.disabled]);
      for (const [input] of lockedInputs) input.disabled = true;
      try {
        const saved = await invoke("record_later_finding", {
          projectPath: ownerProject, title: title.value.trim(), detail: description.value.trim(),
          file: file.value.trim() || null, evidence: evidence.value.trim(), sourceMissionId: source.value || null,
        });
        laterDrafts.delete(ownerProject);
        if (project === ownerProject && dialog.open) {
          focusCase = saved.id;
          filter = "all";
          await refresh();
        }
      } catch (error) {
        setStatus(status, `Ikke lagret: ${error}`, true);
        if (project === ownerProject && dialog.open && !form.isConnected) {
          const current = body.querySelector(".evaluation-later-form");
          if (current) setStatus(current.querySelector("[role=status]") || current.querySelector(".evaluation-status"), `Ikke lagret: ${error}`, true);
        }
      } finally {
        savingLater.delete(ownerProject);
        for (const [input, wasDisabled] of lockedInputs) input.disabled = wasDisabled;
        if (project === ownerProject && dialog.open) {
          const current = body.querySelector(".evaluation-later-form");
          if (current) for (const input of current.querySelectorAll("[data-later-save-lock]")) {
            input.disabled = input.dataset.laterSaveLock === "true";
            delete input.dataset.laterSaveLock;
          }
        }
      }
    });
    details.append(form);
  }

  // A stretch worked without the validator is a control group, and it is free.
  // But the numbers above it only mean something if the reader is told the check
  // was off for part of the window they cover.
  function validatorDowntimeNote() {
    const host = node("p", "evaluation-status");
    host.setAttribute("role", "status");
    host.hidden = true;
    const bridge = window.__TAURI__?.core?.invoke;
    if (!bridge) return host;
    bridge("get_validator_periods", { windowMs: 7 * 24 * 60 * 60 * 1000 }).then((periods) => {
      if (!host.isConnected) return;
      if (!periods?.recorded || !periods.offMs) return;
      const hours = periods.offMs / 3_600_000;
      const said = hours < 1
        ? `${Math.round(periods.offMs / 60_000)} minutter`
        : `${hours < 10 ? hours.toFixed(1) : Math.round(hours)} timer`;
      const open = periods.periods?.some((item) => item.toUnixMs === null || item.toUnixMs === undefined);
      host.textContent = `Registrerte av-perioder dekker ${said} den siste uken${open ? "; siste periode har ingen registrert slutt" : ""}. Dette er loggede bryterendringer, ikke bevis på kontinuerlig appdrift eller dagens tilstand. Appavbrudd, manuelle og eksterne kontroller kan ikke utledes fra tallet.`;
      host.hidden = false;
    }).catch(() => {
      if (!host.isConnected) return;
      host.textContent = "Av/på-historikken kunne ikke leses. Perioder uten funn kan ikke tolkes som kontinuerlig kontroll.";
      host.hidden = false;
    });
    return host;
  }

  function renderDataset() {
    body.replaceChildren();
    body.append(note(project.replace(/^\\\\\?\\/, ""), "evaluation-path"),
      note("Lokalt register over påstander og avklaringer. Ingen agent startes her, og data brukes ikke automatisk til modelltrening."));
    const summary = dataset.summary || {};
    const totals = node("div", "evaluation-totals");
    for (const [label, value] of [
      ["Bekreftet", summary.confirmed], ["Falske varsler", summary.falsePositive],
      ["Delvis riktig", summary.partial], ["Uavklart", summary.unresolved],
      ["Ikke vurdert", summary.unreviewed], ["Oppdaget senere", summary.laterDiscovered],
    ]) totals.append(node("span", "evaluation-total", `${value || 0} ${label}`));
    body.append(note("Validatorvarsler. Senere oppdagede feil telles separat."), totals);
    for (const dimension of SCORE_DIMENSIONS) body.append(note(scoreAverage(summary, dimension)));
    body.append(note("Scorene vises hver for seg. Ubesvarte er utelatt, og det beregnes ingen totalscore."));
    if (dataset.warnings?.length) body.append(note(dataset.warnings.join(" · "), "evaluation-status error"));
    body.append(note("Utvalget er strukturerte funn som finnes i oppdragspostene, ikke alle kontroller eller alle feil i prosjektet. Hver forekomst vurderes for seg."));
    const actions = node("div", "evaluation-actions");
    const filterSelect = optionSelect({ all: "Alle funn", ...VERDICTS, later: "Oppdaget senere" }, filter, "Filtrer funn");
    filterSelect.addEventListener("change", () => { filter = filterSelect.value; focusCase = ""; visibleCount = PAGE_SIZE; renderDataset(); });
    const exportStatus = node("p", "evaluation-status");
    exportStatus.setAttribute("role", "status");
    const exportTo = async (control, shareable) => {
      control.disabled = true;
      const ownerProject = project;
      try {
        const result = await invoke("export_evaluation_dataset", { projectPath: ownerProject, shareable });
        setStatus(exportStatus, `${result.caseCount} funn eksportert til ${result.path}`);
      } catch (error) {
        setStatus(exportStatus, `Eksport feilet: ${error}`, true);
      } finally {
        control.disabled = false;
      }
    };
    const exportButton = button("Eksporter datasett (JSON)", () => exportTo(exportButton, false));
    const shareButton = button("Eksporter redigert datasett", () => exportTo(shareButton, true));
    window.AgentSyncPeek?.attach(shareButton, "Reduserer sensitive felt. Kontroller filen før eventuell deling.", { head: "Delbar eksport" });
    actions.append(filterSelect, button("Oppdater", refresh), exportButton, shareButton);
    body.append(actions, note("Eksporten gjelder hele prosjektets register, uavhengig av filter. Bevis og filstier følger med, ikke rå samtaler. Filen lagres i AgentSync-mappen og kan følge filsynken."),
      note("Den redigerte eksporten fjerner utvalgte sensitive felt, blant annet funntekst, bevis og notater. Prosjekt og filer får løpende navn. Dette garanterer ikke anonymitet: modellnavn, tidspunkter og kombinasjoner av metadata kan fortsatt gjenkjennes. Les filen før deling. Ingen eksport deles automatisk."),
      exportStatus, validatorDowntimeNote(),
      renderGroups(dataset.groups), laterFindingForm());
    const list = node("section", "evaluation-case-list");
    list.setAttribute("aria-label", "Registrerte funn");
    const cases = (dataset.cases || []).filter((item) => filter === "all"
      || (filter === "later" ? item.kind === "laterDiscovered" : item.verdict === filter));
    if (!cases.length) list.append(note("Ingen funn i dette utvalget."));
    const focusedIndex = cases.findIndex((item) => item.id === focusCase);
    if (focusedIndex >= visibleCount) visibleCount = (Math.floor(focusedIndex / PAGE_SIZE) + 1) * PAGE_SIZE;
    for (const item of cases.slice(0, visibleCount)) list.append(renderCase(item));
    if (cases.length > visibleCount) list.append(button(`Vis flere (${Math.min(visibleCount, cases.length)} av ${cases.length})`, () => {
      const previousCount = visibleCount;
      visibleCount += PAGE_SIZE;
      renderDataset();
      const next = body.querySelectorAll(".evaluation-case")[previousCount];
      next?.querySelector("summary")?.focus();
      next?.scrollIntoView({ block: "nearest" });
    }));
    body.append(list);
    if (focusCase) {
      const chosen = [...list.children].find((item) => item.dataset.caseId === focusCase);
      chosen?.querySelector("summary")?.focus();
      chosen?.scrollIntoView({ block: "nearest" });
      focusCase = "";
    }
  }

  async function open(projectPath, caseId = "") {
    ensureDialog();
    if (project !== projectPath) {
      dataset = null;
      filter = "all";
      visibleCount = PAGE_SIZE;
      expandedCases.clear();
    }
    project = projectPath || "";
    focusCase = caseId;
    if (caseId) filter = "all";
    if (!dialog.open) {
      returnFocus = document.activeElement;
      if (typeof dialog.show === "function") dialog.show();
      else dialog.setAttribute("open", "");
    }
    setRailOpen(true);
    await refresh();
  }

  async function toggle(projectPath = "") {
    ensureDialog();
    if (dialog.open) {
      dialog.close();
      return;
    }
    await open(projectPath);
  }

  function close() {
    if (dialog?.open) dialog.close();
  }

  async function decorate(host, { missionId, findingIndex, projectPath, onCase, onError }) {
    let caseId = "";
    const badge = button("Avklar funnet", () => open(projectPath, caseId));
    badge.classList.add("evaluation-compact");
    host.append(badge);
    try {
      if (!missionCache.has(missionId)) {
        if (missionCache.size >= 100) missionCache.delete(missionCache.keys().next().value);
        missionCache.set(missionId, invoke("get_finding_evaluations", { missionId }).catch((error) => {
          missionCache.delete(missionId);
          throw error;
        }));
      }
      const report = await missionCache.get(missionId);
      if (!badge.isConnected) return;
      const item = report.cases.find((entry) => entry.findingIndex === findingIndex);
      if (!item) throw new Error("Funnet er ikke lagret i oppdragsposten ennå.");
      caseId = item.id;
      badge.textContent = `${caseStatus(item)} · Avklar`;
      onCase?.(item);
    } catch (error) {
      badge.textContent = "Avklaring utilgjengelig";
      window.AgentSyncPeek?.attach(badge, String(error), { head: "Feil" });
      onError?.(error);
    }
  }

  window.addEventListener("agentsync:evaluation-saved", () => missionCache.clear());
  window.AgentSyncEvaluations = { open, toggle, close, decorate, invalidate: () => missionCache.clear() };
  railButton()?.addEventListener("click", async (event) => {
    event.stopPropagation();
    await toggle(window.AgentSyncHost?.selectedProject?.() || "");
  });
  document.getElementById("controlEvaluationsButton")?.addEventListener("click", () => {
    open(window.AgentSyncHost?.selectedProject?.() || "");
  });
})();
