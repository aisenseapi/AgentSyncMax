// Mocked Tauri bridge: enough of the backend contract to drive the v4 UI in
// an ordinary browser (see preview-server.js). Projects, agents, intent
// resolution, streaming missions, mission history, quotas and the engine
// status are all faked here.
(function () {
  const TOOLKIT = "C:\\Projects\\AgentSyncToolkit";
  const DEMOAPP = "C:\\Projects\\demo.example";
  const SAMPLEAPP = "C:\\Projects\\SampleApp\\code";
  const CLIENTPORTAL = "C:\\Projects\\Sample client portal 2026";
  // Windows canonicalisation adds this prefix to every mission path.
  const CANONICAL_PREFIX = String.fromCharCode(92, 92, 63, 92);
  const CANONICAL = (path) => CANONICAL_PREFIX + path;
  // The preview's control page opens in a separate browser window. Keep the
  // mocked backend state on the opener so both pages see the same runtime and
  // missions, just as two Tauri windows talk to the same Rust process.
  let sharedState = null;
  try {
    sharedState = window.opener?.__agentSyncMockState || window.__agentSyncMockState || null;
  } catch {
    sharedState = window.__agentSyncMockState || null;
  }
  if (!sharedState) {
    sharedState = {
      missions: [],
      counter: 0,
      controlWindow: null,
      validatorRuntime: { enabled: false, generation: 0, enabledSinceUnixMs: 0 }
    };
  }
  window.__agentSyncMockState = sharedState;
  const missions = sharedState.missions;
  const validatorRuntime = sharedState.validatorRuntime;

  const catalog = {
    recentMissionsTruncated: false,
    projects: [
      { name: "AgentSyncToolkit", label: "Projects / AgentSyncToolkit", path: TOOLKIT, latestIso: "2026-09-02T10:30:00+02:00" },
      { name: "demo.example", label: "Projects / demo.example", path: DEMOAPP, latestIso: "2026-09-01T09:00:00+02:00" },
      { name: "Sample client portal 2026", label: "Projects / Sample client portal 2026", path: CLIENTPORTAL, latestIso: "2026-08-31T15:00:00+02:00" },
      { name: "code", label: "Projects / SampleApp / code", path: SAMPLEAPP, latestIso: "2026-08-30T09:00:00+02:00" }
    ],
    agentRecords: [
      { agent: "claude", runs: 20, completedPercent: 90, changedFiles: 32, lastRunUnixMs: Date.now() - 3_600_000 },
      { agent: "codex", runs: 11, completedPercent: 73, changedFiles: 92, lastRunUnixMs: Date.now() - 3 * 86_400_000 },
      { agent: "cline", runs: 11, completedPercent: 27, changedFiles: 0, lastRunUnixMs: Date.now() - 20 * 86_400_000 }
    ],
    agents: [
      // The real backend fills `model` from the agent's own default when no
      // model is configured, so the bar names one instead of "agentens standard".
      { id: "claude", label: "Claude", available: true, model: "claude-opus-5", note: "Klar for kontrollert headless-kjøring i valgt prosjektmappe." },
      { id: "codex", label: "Codex", available: true, model: "gpt-5.6-sol", note: "Klar for kontrollert headless-kjøring i valgt prosjektmappe." },
      { id: "opencode", label: "OpenCode", available: true, model: null, note: "" },
      { id: "antigravity", label: "Antigravity", available: true, model: null, note: "" },
      { id: "cline", label: "Cline", available: false, model: null, note: "Cline-utvidelsen er ikke nok. Mission Control trenger Cline CLI i PATH." },
      { id: "aider", label: "Aider", available: true, model: "ollama_chat/qwen3-coder-next:q8_0", note: "Lokal modell på NVIDIA DGX Spark via SSH tunnel." }
    ],
    models: {
      claude: ["claude-fable-5-1", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5-20251001"],
      codex: ["gpt-5.6-sol"],
      opencode: ["kimi-k3", "deepseek-v4-pro", "qwen3.5:397b"],
      antigravity: ["gemini-3.7-flash-high"],
      aider: ["ollama_chat/qwen3-coder-next:q8_0", "ollama_chat/qwen3.5:27b"]
    },
    levels: ["normal", "max", "ultra"],
    resolverModel: "gemini-3-flash-preview:cloud",
    resolverCandidates: ["deepseek-v4-flash:cloud", "gemini-3-flash-preview:cloud", "gpt-oss:120b", "kimi-k3:cloud"],
    resolverEndpoint: "http://127.0.0.1:11435",
    resolverTimeoutSeconds: 25
  };

  const knowledgeReviews = sharedState.knowledgeReviews ||= [
    {
      reviewId: "rev1-agent-sync-activity",
      viewId: "view1-agent-sync-activity",
      proposalId: "eb1-mock-agent-sync-activity",
      projectPath: TOOLKIT,
      pageId: "projects/agentsynctoolkit-49bb9b9257/activity",
      generatedUtc: new Date(Date.now() - 42 * 60_000).toISOString(),
      modelTag: "gemma4:31b",
      modelDigest: "6316b263de0d4f09b22486d8dc4f411ef20a1512ed7281e61645132f5c8eeb2f",
      resultMarkdown: "## Prosjektaktivitet\n\nAgentSync har registrert aktivitet fra flere kodeagenter.\n\n- 69 indekserte sesjoner\n- 43 indekserte stier\n- metadata er ikke publisert",
      rationale: "Metadata er samlet konservativt. Påstander som ikke kunne underbygges ble forkastet.",
      preservedSources: [
        { ref: "project/summary", why: "Gir aggregert prosjektaktivitet." },
        { ref: "session/0001", why: "Dokumenterer en nyere Codex-økt." },
      ],
      discardedSources: [
        { ref: "session/0002", reasonCode: "redundant", why: "Samme informasjon finnes i prosjektoversikten." },
        { ref: "session/0003", reasonCode: "unverified", why: "Påstanden var ikke bekreftet av metadata." },
      ],
      humanReviewRequired: true,
      semanticCorrectnessVerified: false,
      decision: { revision: 0, status: "pending", editedMarkdown: null, note: "", atUnixMs: null, conflict: false },
    },
    {
      reviewId: "rev1-agent-sync-method",
      viewId: "view1-agent-sync-method",
      proposalId: "eb1-mock-agent-sync-method",
      projectPath: TOOLKIT,
      pageId: "projects/agentsynctoolkit-49bb9b9257/method",
      generatedUtc: new Date(Date.now() - 26 * 60 * 60_000).toISOString(),
      modelTag: "gemma4:31b",
      modelDigest: "6316b263de0d4f09b22486d8dc4f411ef20a1512ed7281e61645132f5c8eeb2f",
      resultMarkdown: "## Metode\n\nKunnskapsutkast skal alltid gjennomgås av et menneske før publisering.",
      rationale: "Kort metodebeskrivelse basert på den verifiserte labkontrakten.",
      preservedSources: [{ ref: "project/summary", why: "Prosjektets avgrensede metadata." }],
      discardedSources: [],
      humanReviewRequired: true,
      semanticCorrectnessVerified: false,
      decision: { revision: 1, status: "draft", editedMarkdown: "## Metode\n\nAlle utkast krever menneskelig gjennomgang.", note: "Strammet inn teksten.", atUnixMs: Date.now() - 3_600_000, conflict: false },
    },
  ];

  // Byte cursors as the real backend uses them; JS string lengths stand in for bytes.
  function missionDelta(mission, cursor) {
    const known = cursor && cursor.generation === (mission.generation || 0)
      && cursor.outputBytes <= mission.output.length && cursor.finalOutputBytes <= mission.finalOutput.length && cursor.errorOutputBytes <= mission.errorOutput.length;
    return {
      id: mission.id,
      projectPath: mission.projectPath,
      agent: mission.agent,
      agentLabel: mission.agentLabel,
      model: mission.model,
      resolvedModel: mission.resolvedModel || null,
      modelSource: mission.modelSource || "unknown",
      modelSource: mission.modelSource || "unknown",
      mode: mission.mode || "shared",
      purpose: mission.purpose || (mission.mode === "blind" ? "manualControl" : "writer"),
      sourceMissionId: mission.sourceMissionId || null,
      level: mission.level,
      prompt: cursor ? null : mission.prompt,
      status: mission.status,
      phase: mission.phase,
      startedUnixMs: mission.startedUnixMs,
      finishedUnixMs: mission.finishedUnixMs,
      exitCode: mission.exitCode,
      error: mission.error,
      changedFiles: mission.workspaceAfter?.changedFiles ?? null,
      generation: mission.generation || 0,
      reset: !known,
      outputDelta: known ? mission.output.slice(cursor.outputBytes) : mission.output,
      outputBytes: mission.output.length,
      finalOutputDelta: known ? mission.finalOutput.slice(cursor.finalOutputBytes) : mission.finalOutput,
      finalOutputBytes: mission.finalOutput.length,
      errorOutputDelta: known ? mission.errorOutput.slice(cursor.errorOutputBytes) : mission.errorOutput,
      errorOutputBytes: mission.errorOutput.length
    };
  }

  const dayMs = 86_400_000;
  const archived = [
    {
      id: "mission-1788350000000",
      projectPath: CANONICAL(TOOLKIT),
      prompt: "Skriv changelog for 4.0.0.",
      agent: "codex",
      agentLabel: "Codex",
      model: "gpt-5.6-sol",
      mode: "shared",
      purpose: "writer",
      sourceMissionId: null,
      level: "max",
      status: "completed",
      phase: "Ferdig, Git-diff er klar",
      startedUnixMs: Date.now() - dayMs - 3_600_000,
      finishedUnixMs: Date.now() - dayMs - 3_400_000,
      exitCode: 0,
      output: "[+  2s] Verktøy: read · CHANGELOG.md\n[+  9s] Verktøy: edit · CHANGELOG.md\n",
      finalOutput: "## Changelog oppdatert\n\nJeg la til en **4.0.0**-seksjon med tre punkter:\n\n- lerretet\n- ønskefeltet\n- prosjektvinduet\n\n| Fil | Endring |\n| --- | --- |\n| CHANGELOG.md | +18 linjer |\n\n```bash\ngit diff --stat\n```\n\n> [!NOTE]\n> Ingen tester ble berørt.\n\n" + "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ".repeat(40),
      errorOutput: "",
      workspaceAfter: { changedFiles: 1 },
      error: null
    },
    {
      id: "mission-1788420000000",
      projectPath: CANONICAL(TOOLKIT),
      prompt: "Kjør testene og rapporter.",
      agent: "claude",
      agentLabel: "Claude",
      model: null,
      mode: "shared",
      purpose: "writer",
      sourceMissionId: null,
      level: null,
      status: "failed",
      phase: "Agenten avsluttet med feil",
      startedUnixMs: Date.now() - 7_200_000,
      finishedUnixMs: Date.now() - 7_100_000,
      exitCode: 1,
      output: "[+  1s] Kommando: cargo test\n",
      finalOutput: "Testene feilet: `intent_tests::heuristic_intent_reads_agent_level_and_project_from_a_norwegian_wish`.",
      errorOutput: "error: test failed, to rerun pass `--bin agentsync-desktop`\n",
      workspaceAfter: { changedFiles: 0 },
      error: "Agenten avsluttet med exitkode 1."
    }
  ];

  // A completed, explicitly synthetic control makes the evaluation workflow
  // available immediately. Opening this record never starts a real model.
  const evaluationFixture = {
    id: "mission-preview-evaluation-1",
    projectPath: CANONICAL(TOOLKIT),
    prompt: "Forhåndsvisning: kontroller endringen uavhengig og begrunn mulige feil.",
    agent: "claude", agentLabel: "Claude", model: "claude-opus-5", resolvedModel: "claude-opus-5", modelSource: "observed",
    mode: "blind", purpose: "manualControl", sourceMissionId: "mission-1788350000000", level: "max",
    status: "completed", phase: "Forhåndsvisning: kontroll fullført", exitCode: 0,
    startedUnixMs: 1788753600000, finishedUnixMs: 1788753660000,
    output: "[+  1s] Forhåndsvisning: leser syntetisk diff\n",
    finalOutput: "## Eksempelrapport\n\nTre syntetiske funn for å prøve avklaring. Dette er ikke en kontroll av den virkelige koden.",
    errorOutput: "", error: null,
    workspaceBefore: { projectPath: CANONICAL(TOOLKIT), isGit: true, clean: true, controlMode: "git", branch: "main", headCommit: "preview-baseline", changedFiles: 0 },
    workspaceAfter: { projectPath: CANONICAL(TOOLKIT), isGit: true, clean: true, controlMode: "git", branch: "main", headCommit: "preview-baseline", changedFiles: 0 }
  };
  evaluationFixture.findings = buildMockFindings(evaluationFixture, 0);
  archived.push(evaluationFixture);

  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  function labelFor(agent) {
    return catalog.agents.find((item) => item.id === agent)?.label || agent;
  }

  function projectKey(path) {
    let value = String(path || "").replace(/\\/g, "/");
    if (/^\/\/\?\/unc\//i.test(value)) value = "//" + value.slice(8);
    else if (value.startsWith("//?/")) value = value.slice(4);
    return value.replace(/\/+$/, "").toLowerCase();
  }

  function isActive(mission) {
    return mission.status === "queued" || mission.status === "running";
  }

  function purposeFor(mission) {
    if (["writer", "manualControl", "validator"].includes(mission?.purpose)) return mission.purpose;
    return mission?.mode === "blind" ? "manualControl" : "writer";
  }

  function normalizePurpose(value, mode) {
    const purpose = String(value || "").trim();
    if (!purpose) return mode === "blind" ? "manualControl" : "writer";
    if (purpose === "writer" && mode === "blind") throw "Et skriveoppdrag kan ikke kjøres i blind modus.";
    // The ordinary case, missing until now: a writer in shared mode fell
    // through to the final throw, so no writer mission could start in the rig.
    if (purpose === "writer") return purpose;
    if (purpose === "manualControl" && (mode === "shared" || mode === "blind")) return purpose;
    if (purpose === "validator" && mode === "blind") return purpose;
    if (purpose === "validator") throw "Automatisk validering kan bare kjøres i blind modus.";
    throw "Ukjent oppdragstype for valideringsagenten.";
  }

  function resolvedModelFor(agent, requested) {
    if (String(requested || "").trim()) return String(requested).trim();
    return ({ claude: "claude-opus-5", codex: "gpt-5.6-sol", aider: "ollama_chat/qwen3-coder-next:q8_0" })[agent] || null;
  }

  function validatorStatus() {
    return {
      enabled: validatorRuntime.enabled,
      generation: validatorRuntime.generation,
      enabledSinceUnixMs: validatorRuntime.enabledSinceUnixMs || 0,
      activeControls: missions.filter((mission) => isActive(mission) && purposeFor(mission) !== "writer").length
    };
  }

  function cancelValidatorMissions() {
    const finishedUnixMs = Date.now();
    missions.forEach((mission) => {
      if (!isActive(mission) || purposeFor(mission) === "writer") return;
      mission.status = "canceled";
      mission.phase = "Valideringsagenten er slått av";
      mission.finishedUnixMs = finishedUnixMs;
      mission.exitCode = null;
    });
  }

  function findMission(missionId) {
    return archived.find((item) => item.id === missionId) || missions.find((item) => item.id === missionId);
  }

  function buildMockFindings(mission, forcedOutcome) {
    const by = mission.agentLabel || mission.agent;
    const model = mission.resolvedModel || mission.model || null;
    const shape = { validatorAgent: by, validatorModel: model, resolverModel: "deepseek-v4-pro:cloud", elapsedMs: 1500, warning: null };
    // The outcome depends on the record, never on which report was opened
    // first. Reloading cannot silently change a model's apparent performance.
    const outcome = forcedOutcome ?? Array.from(mission.id).reduce((sum, char) => sum + char.charCodeAt(0), 0) % 3;
    if (outcome === 1) return { ...shape, outcome: "clean", couldNotCheck: null, checked: "Forhåndsvisning: gjennomgikk endringer og teststatus.", findings: [] };
    if (outcome === 2) return { ...shape, outcome: "unreadable", checked: "", findings: [], warning: "Valideringen ga ingen tekst å lese. Dette er ikke en frikjennelse." };
    const critique = (title, detail, file) => [
      "Et funn fra en uavhengig validering av dette prosjektet.", "", `Funn: ${title}`, detail,
      file ? `Sted: ${file}` : "", "",
      `Om kilden: valideringen ble gjort av ${by}${model ? ` på ${model}` : ""}, i en kopi av prosjektet uten tilgang til de andre agentenes historikk. Den kjenner altså ikke resonnementet bak endringen, og kan ta feil. Brukeren har lest funnet og sendt det videre.`,
      "", "Vurder funnet selv før du handler. Er det riktig, rett det. Er det feil eller allerede håndtert, si det og la koden være."
    ].filter(Boolean).join("\n");
    // confidence, test, echoesWriter and fileSeenBefore mirror the real
    // extraction, so the panel can be exercised on all of them here.
    const finding = (severity, title, detail, file, seenBefore, actedOn, actedOnBy, extra = {}) => ({
      severity, title, detail, file, seenBefore, actedOn, actedOnBy,
      confidence: "sikker", test: null, echoesWriter: false, fileSeenBefore: 0,
      ...extra, prompt: critique(title, detail, file)
    });
    return { ...shape, outcome: "findings", checked: "Forhåndsvisning: leste syntetisk diff og testresultat.", findings: [
      finding("hoy", "Manglende nullsjekk", "Verdien kan være null før den brukes, og et kall vil da kaste.", "desktop/src/app.js", 0, false, []),
      finding("middels", "Mangler test", "Den nye grenen er ikke dekket av noen test.", null, 2, false, ["codex"], { confidence: "trolig", test: "En test som kaller endepunktet uten where og forventer avvisning." }),
      finding("lav", "Ubrukt import", "En import brukes ikke lenger etter endringen.", "desktop/src/control.js", 1, true, ["claude"], { confidence: "usikker", echoesWriter: true, fileSeenBefore: 3 })
    ] };
  }

  const EVALUATION_STORAGE_KEY = "agentsync.preview.finding-evaluations.v1";
  const EVALUATION_SCORES = { usefulness: "Nytteverdien", actionability: "Handlingsklarheten", novelty: "Ny informasjon" };
  const copy = (value) => JSON.parse(JSON.stringify(value));

  function knowledgeDataset(projectPath) {
    return {
      items: copy(knowledgeReviews.filter((item) => projectKey(item.projectPath) === projectKey(projectPath))),
      warning: "Forhåndsvisning: lokale testdata. Ingen Wiki-side er lest eller skrevet.",
    };
  }

  function saveKnowledgeDecision(request) {
    const item = knowledgeReviews.find((candidate) => candidate.reviewId === request.reviewId
      && candidate.viewId === request.viewId
      && projectKey(candidate.projectPath) === projectKey(request.projectPath));
    if (!item) throw new Error("Kunnskapsutkastet finnes ikke i dette prosjektet.");
    if (!Number.isInteger(request.expectedRevision) || request.expectedRevision !== item.decision.revision) {
      throw new Error("Utkastet er endret siden du åpnet det. Hent siste versjon før du lagrer.");
    }
    if (!["draft", "approved", "rejected"].includes(request.status)) throw new Error("Ukjent gjennomgangsstatus.");
    const editedMarkdown = String(request.editedMarkdown || "");
    const note = String(request.note || "");
    if (request.status !== "rejected" && !editedMarkdown.trim()) throw new Error("Utkastet kan ikke være tomt.");
    item.decision = {
      revision: item.decision.revision + 1,
      status: request.status,
      editedMarkdown,
      note,
      atUnixMs: Date.now(),
      conflict: false,
    };
    return copy(item);
  }

  function evaluationScores(value) {
    return Object.fromEntries(Object.keys(EVALUATION_SCORES).map((key) => [key, value[key] ?? null]));
  }

  function evaluationStore() {
    try {
      // Re-read for a second preview tab as well as reload. The native backend
      // owns this centrally, whereas preview tabs only share localStorage.
      const stored = window.localStorage?.getItem(EVALUATION_STORAGE_KEY);
      const value = stored ? JSON.parse(stored) : { schemaVersion: 1, cases: [] };
      if (value.schemaVersion !== 1 || !Array.isArray(value.cases)) throw new Error("Ukjent lagringsformat");
      sharedState.evaluations = value;
      return value;
    } catch (error) {
      throw new Error(`Kan ikke lese avklaringene i forhåndsvisningen: ${error.message}`);
    }
  }

  function persistEvaluation(item) {
    const store = evaluationStore();
    const next = { schemaVersion: 1, cases: [...store.cases.filter((existing) => existing.id !== item.id), item] };
    if (!window.localStorage) throw new Error("Forhåndsvisningen trenger lokal nettleserlagring for å huske avklaringer.");
    // Commit to memory only after persistence succeeds. A failed write must
    // not look like a durable adjudication to the user.
    window.localStorage.setItem(EVALUATION_STORAGE_KEY, JSON.stringify(next));
    sharedState.evaluations = next;
    return copy(item);
  }

  function workspaceMetadata(workspace) {
    if (!workspace) return null;
    const metadata = {};
    for (const key of ["projectPath", "isGit", "clean", "controlMode", "branch", "headCommit", "changedFiles", "diffTruncated"]) {
      if (workspace[key] !== undefined) metadata[key] = workspace[key];
    }
    return metadata;
  }

  function checkpointMetadata(checkpoint) {
    if (!checkpoint) return null;
    const metadata = {};
    for (const key of ["directory", "mode", "complete", "fileCount", "totalBytes", "skippedFiles", "changedFiles", "warning"]) {
      if (checkpoint[key] !== undefined) metadata[key] = checkpoint[key];
    }
    return metadata;
  }

  function evaluationProvenance(mission, report) {
    const source = findMission(mission?.sourceMissionId);
    return {
      validatorAgent: mission?.agent || null,
      requestedModel: mission?.model || null, resolvedModel: mission?.resolvedModel || null,
      modelSource: mission?.modelSource || "unknown",
      resolverModel: report?.resolverModel || null, contextMode: mission?.mode || null,
      sourceMissionId: mission?.sourceMissionId || null, sourceAgent: source?.agent || null,
      sourceRequestedModel: source?.model || null, sourceResolvedModel: source?.resolvedModel || null,
      startedUnixMs: mission?.startedUnixMs || null, finishedUnixMs: mission?.finishedUnixMs || null,
      durationMs: mission?.finishedUnixMs && mission?.startedUnixMs ? Math.max(0, mission.finishedUnixMs - mission.startedUnixMs) : null,
      workspaceBefore: workspaceMetadata(mission?.workspaceBefore), workspaceAfter: workspaceMetadata(mission?.workspaceAfter),
      checkpoint: checkpointMetadata(mission?.checkpoint), sourceCheckpoint: checkpointMetadata(source?.checkpoint)
    };
  }

  function casesForMission(mission) {
    if (!mission || mission.status !== "completed" || purposeFor(mission) === "writer" || mission.findings?.outcome !== "findings") return [];
    const saved = evaluationStore().cases;
    return mission.findings.findings.map((finding, findingIndex) => {
      const id = `finding-${mission.id}-${findingIndex}`;
      const existing = saved.find((item) => item.id === id);
      return existing ? refreshEvaluationFollowups(existing) : {
        id, kind: "validatorFinding", missionId: mission.id, findingIndex,
        projectPath: mission.projectPath, title: finding.title, detail: finding.detail,
        file: finding.file || null, severity: finding.severity || null,
        provenance: evaluationProvenance(mission, mission.findings),
        revision: 0, verdict: "unreviewed", remediation: "open", ...evaluationScores({}), evidence: "", notes: "",
        origin: "unreviewed", updatedUnixMs: null, history: [], followups: []
      };
    });
  }

  function allEvaluationCases(projectPath) {
    const combined = new Map();
    [...archived, ...missions].forEach((mission) => casesForMission(mission).forEach((item) => combined.set(item.id, item)));
    evaluationStore().cases.forEach((item) => combined.set(item.id, refreshEvaluationFollowups(item)));
    return [...combined.values()].filter((item) => !projectPath || projectKey(item.projectPath) === projectKey(projectPath));
  }

  function evaluationCounts(cases) {
    const result = { total: cases.length, unreviewed: 0, unresolved: 0, confirmed: 0, partial: 0, falsePositive: 0,
      laterDiscovered: 0, remediationFixed: 0, remediationVerified: 0, adjudicated: 0, confirmedRate: null,
      usefulnessRated: 0, usefulnessAverage: null, actionabilityRated: 0, actionabilityAverage: null,
      noveltyRated: 0, noveltyAverage: null };
    const sums = { usefulness: 0, actionability: 0, novelty: 0 };
    for (const item of cases) {
      if (item.kind === "laterDiscovered") { result.laterDiscovered += 1; continue; }
      result[item.verdict] += 1;
      if (item.remediation === "fixed") result.remediationFixed += 1;
      if (item.remediation === "verified") result.remediationVerified += 1;
      if (["confirmed", "falsePositive"].includes(item.verdict)) result.adjudicated += 1;
      for (const key of Object.keys(EVALUATION_SCORES)) {
        if (Number.isInteger(item[key]) && item[key] >= 1 && item[key] <= 10) {
          result[`${key}Rated`] += 1;
          sums[key] += item[key];
        }
      }
    }
    const denominator = result.confirmed + result.falsePositive;
    if (denominator) result.confirmedRate = result.confirmed / denominator;
    for (const key of Object.keys(EVALUATION_SCORES)) {
      if (result[`${key}Rated`]) result[`${key}Average`] = sums[key] / result[`${key}Rated`];
    }
    return result;
  }

  function evaluationDataset(projectPath) {
    const cases = allEvaluationCases(projectPath);
    const grouped = new Map();
    for (const item of cases.filter((candidate) => candidate.kind === "validatorFinding")) {
      const provenance = item.provenance;
      const identity = { validatorAgent: provenance.validatorAgent || "unknown",
        model: provenance.resolvedModel || provenance.requestedModel || "unknown",
        modelSource: provenance.resolvedModel ? (["observed", "requested", "configured"].includes(provenance.modelSource) ? provenance.modelSource : "legacyUnverified") : provenance.requestedModel ? "requestedOnly" : "unknown",
        contextMode: provenance.contextMode || "unknown" };
      const key = JSON.stringify(identity);
      if (!grouped.has(key)) grouped.set(key, { identity, cases: [] });
      grouped.get(key).cases.push(item);
    }
    return copy({ schemaVersion: 1, generatedUnixMs: Date.now(), projectPath: projectPath || null, cases,
      summary: evaluationCounts(cases), groups: [...grouped.values()].map((group) => ({ ...group.identity, ...evaluationCounts(group.cases) })), truncated: false });
  }

  function saveEvaluation(request) {
    if (request.caseId && (request.missionId != null || request.findingIndex != null)) {
      throw new Error("Oppgi enten funnets ID eller oppdrag og funnnummer, ikke begge.");
    }
    // caseId addresses saved records (including later discoveries). Native
    // findings use their mission/index for the first assessment as in Rust.
    const candidates = request.caseId ? evaluationStore().cases : casesForMission(findMission(request.missionId));
    const current = candidates.find((item) => request.caseId ? item.id === request.caseId : item.findingIndex === request.findingIndex);
    if (!current) throw new Error("Fant ikke funnet som skal avklares.");
    if (current.kind === "validatorFinding" && ((request.missionId && current.missionId !== request.missionId)
      || (request.findingIndex != null && current.findingIndex !== request.findingIndex))) {
      throw new Error("Funnets identitet stemmer ikke med oppdraget.");
    }
    if (request.expectedRevision !== current.revision) throw new Error("Avklaringen er endret siden du åpnet den. Last inn på nytt før du lagrer.");
    const verdict = request.verdict;
    const remediation = request.remediation;
    const scores = evaluationScores(request);
    const evidence = String(request.evidence || "").trim();
    const notes = String(request.notes || "").trim();
    if (!["unreviewed", "unresolved", "confirmed", "partial", "falsePositive"].includes(verdict)) throw new Error("Ukjent avklaring.");
    if (!["open", "fixed", "verified"].includes(remediation)) throw new Error("Ukjent rettestatus.");
    for (const [key, label] of Object.entries(EVALUATION_SCORES)) {
      if (scores[key] !== null && (!Number.isInteger(scores[key]) || scores[key] < 1 || scores[key] > 10)) {
        throw new Error(`${label} må være et heltall fra 1 til 10 eller ikke vurdert.`);
      }
    }
    if ((["confirmed", "partial", "falsePositive"].includes(verdict) || remediation === "verified") && !evidence) {
      throw new Error("Oppgi bevis eller en konkret begrunnelse for avklaringen.");
    }
    if (verdict === "unreviewed" && remediation !== "open") throw new Error("Et ikke vurdert funn kan ikke markeres som rettet.");
    if (verdict === "falsePositive" && remediation !== "open") throw new Error("Et falskt varsel kan ikke markeres som rettet.");
    if (remediation !== "open" && !["confirmed", "partial"].includes(verdict)) throw new Error("Et uavklart funn kan ikke markeres som rettet.");
    const event = { revision: current.revision + 1, verdict, remediation, ...scores, evidence, notes, origin: "user", atUnixMs: Date.now(), kind: "assessment", followup: null };
    return persistEvaluation({ ...current, revision: event.revision, verdict, remediation, ...scores, evidence, notes,
      origin: "user", updatedUnixMs: event.atUnixMs, history: [...current.history, event] });
  }

  function recordLaterFinding(request) {
    const project = catalog.projects.find((item) => projectKey(item.path) === projectKey(request.projectPath));
    if (!project) throw new Error("Velg et gyldig prosjekt først.");
    const title = String(request.title || "").trim();
    const detail = String(request.detail || "").trim();
    const evidence = String(request.evidence || "").trim();
    if (!title || !detail || !evidence) throw new Error("Oppgi tittel, beskrivelse og bevis for feilen som ble oppdaget senere.");
    const source = request.sourceMissionId ? findMission(request.sourceMissionId) : null;
    if (request.sourceMissionId && (!source || projectKey(source.projectPath) !== projectKey(project.path))) {
      throw new Error("Kildeoppdraget må tilhøre samme prosjekt.");
    }
    const atUnixMs = Date.now();
    const event = { revision: 1, verdict: "unresolved", remediation: "open", ...evaluationScores({}), evidence, notes: "", origin: "user", atUnixMs, kind: "assessment", followup: null };
    const provenance = evaluationProvenance(null, null);
    if (source) Object.assign(provenance, { sourceMissionId: source.id, sourceAgent: source.agent,
      sourceRequestedModel: source.model || null, sourceResolvedModel: source.resolvedModel || null,
      workspaceBefore: workspaceMetadata(source.workspaceBefore), workspaceAfter: workspaceMetadata(source.workspaceAfter) });
    return persistEvaluation({ id: `later-${atUnixMs}-preview-${evaluationStore().cases.length}`, kind: "laterDiscovered",
      missionId: null, findingIndex: null, projectPath: project.path, title, detail, file: String(request.file || "").trim() || null,
      severity: null, provenance, revision: 1, verdict: "unresolved", remediation: "open", ...evaluationScores({}), evidence, notes: "",
      origin: "user", updatedUnixMs: atUnixMs, history: [event], followups: [] });
  }

  function followupSnapshot(mission) {
    return { missionId: mission.id, projectPath: mission.projectPath, agent: mission.agent, requestedModel: mission.model || null,
      resolvedModel: mission.resolvedModel || null, status: mission.status, startedUnixMs: mission.startedUnixMs || null,
      finishedUnixMs: mission.finishedUnixMs || null, recordAvailable: true,
      durationMs: mission.finishedUnixMs && mission.startedUnixMs ? Math.max(0, mission.finishedUnixMs - mission.startedUnixMs) : null };
  }

  function refreshEvaluationFollowups(item) {
    return { ...item, ...evaluationScores(item),
      history: (item.history || []).map((entry) => ({ ...entry, ...evaluationScores(entry) })),
      followups: (item.followups || []).map((snapshot) => {
      const mission = findMission(snapshot.missionId);
      return mission ? followupSnapshot(mission) : { ...snapshot, recordAvailable: false };
    }) };
  }

  function linkFindingFollowup(request) {
    const current = casesForMission(findMission(request.missionId)).find((item) => item.findingIndex === request.findingIndex);
    if (!current) throw new Error("Fant ikke funnet som skal følges opp.");
    const followup = findMission(request.followupMissionId);
    if (!followup || purposeFor(followup) !== "writer" || projectKey(followup.projectPath) !== projectKey(current.projectPath)) {
      throw new Error("Oppfølgingsoppdraget må være et skriveoppdrag i samme prosjekt.");
    }
    const followups = current.followups || [];
    if (followups.some((item) => item.missionId === followup.id)) return copy(current);
    const linked = followupSnapshot(followup);
    const event = { revision: current.revision + 1, kind: "followupLinked", followup: linked,
      verdict: current.verdict, remediation: current.remediation, ...evaluationScores(current), evidence: current.evidence, notes: current.notes,
      origin: "user", atUnixMs: Date.now() };
    // A dispatch is evidence of dispatch, never evidence that the warning
    // was true, fixed, or independently verified.
    return persistEvaluation({ ...current, revision: event.revision, updatedUnixMs: event.atUnixMs,
      origin: "user", followups: [...followups, linked], history: [...current.history, event] });
  }

  function validateControlGeneration(expected) {
    if (expected === undefined || expected === null) {
      throw "Valideringsvinduet må åpnes på nytt før kontrollen kan starte.";
    }
    if (!validatorRuntime.enabled || Number(expected) !== validatorRuntime.generation) {
      throw "Valideringsagenten er slått av. Slå den på i venstreskinnen.";
    }
  }

  function validateValidatorSource(request, model) {
    const sourceMissionId = String(request.sourceMissionId || "").trim();
    // Only a writer mission from this process can authorize an automatic
    // validation. Archived/synced records are history, not authority.
    const source = missions.find((mission) => mission.id === sourceMissionId);
    const sourcePurpose = purposeFor(source);
    if (!source || (source.mode || "shared") !== "shared" || sourcePurpose !== "writer"
      || source.status !== "completed" || (source.workspaceAfter?.changedFiles || 0) === 0
      || projectKey(source.projectPath) !== projectKey(request.projectPath)) {
      throw "Kildeoppdraget kan ikke valideres. Det må være et fullført delt skriveoppdrag med filendringer i samme prosjekt.";
    }
    if (String(source.agent || "").toLowerCase() === String(request.agent || "").toLowerCase()) {
      throw "Velg en annen agent enn skriveagenten til valideringen.";
    }
    const sourceModel = String(source.resolvedModel || source.model || "").trim();
    if (!sourceModel || !String(model || "").trim()) {
      throw "Skriveoppdraget og valideringsoppdraget må ha registrert modell.";
    }
    if (sourceModel.toLowerCase() === String(model).trim().toLowerCase()) {
      throw "Velg en annen modell enn modellen som skrev endringen.";
    }
    const alreadyUsed = [...archived, ...missions].some((mission) => purposeFor(mission) === "validator"
      && mission.sourceMissionId === sourceMissionId
      && ["queued", "running", "completed"].includes(mission.status));
    if (alreadyUsed) throw "VALIDATOR_ALREADY_DONE: Endringen er allerede sendt til validering.";
    const writerIsActive = missions.some((mission) => isActive(mission) && (mission.mode || "shared") === "shared"
      && purposeFor(mission) === "writer" && projectKey(mission.projectPath) === projectKey(request.projectPath));
    if (writerIsActive) {
      throw "VALIDATOR_WAIT: Skriveagenten arbeider fortsatt. Valideringen venter til filene er stabile.";
    }
  }

  function historyItem(mission) {
    return {
      id: mission.id,
      prompt: mission.prompt,
      projectPath: mission.projectPath,
      agent: mission.agent,
      agentLabel: mission.agentLabel,
      model: mission.model,
      resolvedModel: mission.resolvedModel || null,
      mode: mission.mode || "shared",
      purpose: purposeFor(mission),
      sourceMissionId: mission.sourceMissionId || null,
      status: mission.status,
      startedUnixMs: mission.startedUnixMs,
      finishedUnixMs: mission.finishedUnixMs,
      changedFiles: mission.workspaceAfter?.changedFiles || 0,
      errorSummary: mission.error
    };
  }

  function advance(mission) {
    if (mission.status !== "running") return;
    mission.tick += 1;
    const elapsed = Math.round((Date.now() - mission.startedUnixMs) / 1000);
    const steps = [
      "Verktøy: read · desktop/src/app.js",
      "Verktøy: grep · resolve_intent",
      "Verktøy: edit · desktop/src/app.js",
      "Kommando: node --check desktop/src/app.js",
      "Verktøy: read · CHANGELOG.md"
    ];
    if (mission.tick <= steps.length) mission.output += `[+${String(elapsed).padStart(3, " ")}s] ${steps[mission.tick - 1]}\n`;
    if (mission.tick >= 2) {
      const text = [
        "## Hva jeg gjorde\n\nJeg har sett på filen. ",
        "Endringen er liten: **ønskefeltet** mister ikke fokus lenger når tolkingen feiler.\n\n",
        "- `resolveIntent` beholder fokus i `finally`\n- ingen andre kall berørt\n\n",
        "```js\nfinally {\n  intentInput.disabled = false;\n  intentInput.focus();\n}\n```\n\n",
        "| Test | Resultat |\n| --- | --- |\n| node --check | grønn |\n| cargo test | 39 ok |\n\n",
        "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. ",
        "Endrede filer: desktop/src/app.js."
      ];
      const index = mission.tick - 2;
      if (index < text.length) mission.finalOutput += text[index];
    }
    if (mission.tick === 4 && mission.agent === "codex") mission.errorOutput += "warning: reasoning effort xhigh is slow on this model\n";
    if (mission.tick >= 9) {
      mission.status = "completed";
      mission.phase = "Ferdig, Git-diff er klar";
      mission.finishedUnixMs = Date.now();
      mission.exitCode = 0;
      mission.workspaceAfter = { changedFiles: 2 };
    } else {
      mission.phase = `${mission.agentLabel} arbeider`;
    }
  }

  async function invoke(command, args = {}) {
    switch (command) {
      case "get_secret_guard_settings":
        return { enabled: sharedState.secretGuardEnabled !== false, warning: "Forhåndsvisning: ingen filer kontrolleres og ingen data sendes." };
      case "set_secret_guard_settings":
        if (typeof args.enabled !== "boolean") throw new Error("Ugyldig innstilling.");
        sharedState.secretGuardEnabled = args.enabled;
        return { enabled: args.enabled, warning: "Forhåndsvisning: ingen filer kontrolleres og ingen data sendes." };
      case "allow_secret_guard_once":
        throw new Error("Forhåndsvisningen har ingen ekte kontrolltoken.");
      case "get_active_memory_settings":
        return { ...(sharedState.activeMemorySettings || { enabled: true, ramBudgetMib: 16 }) };
      case "set_active_memory_settings":
        if (typeof args.enabled !== "boolean" || !Number.isInteger(args.ramBudgetMib) || args.ramBudgetMib < 0 || args.ramBudgetMib > 128) throw new Error("Ugyldige minneinnstillinger.");
        sharedState.activeMemorySettings = { enabled: args.enabled, ramBudgetMib: args.ramBudgetMib };
        return { ...sharedState.activeMemorySettings };
      case "get_active_memory": {
        const project = catalog.projects.find(item => projectKey(item.path) === projectKey(args.projectPath));
        if (!project) throw new Error("Prosjektet finnes ikke i forhåndsvisningen.");
        const settings = sharedState.activeMemorySettings || { enabled: true, ramBudgetMib: 16 };
        return { projectPath: project.path, generatedUnixMs: Date.now(), entryPath: null,
          markdown: settings.enabled ? `# ${project.name}\n\n## Start her\nDette er et simulert prosjektminne. Ingen virkelig historikk er lest.\n\n## Uavklart\n- Kontroller de opprinnelige kildene før du viderefører en beslutning.\n\n## Nylig arbeid\n- Forhåndsvisning av lokal kontekst og en avgrenset RAM-cache.\n\n## Kilder\n- AGENTS.md (eksempel, ikke lest i denne visningen)` : "",
          warnings: ["Simulering. Ingen filer skrives og ingen agenter eller eksterne tjenester startes."], sourceCount: settings.enabled ? 1 : 0,
          cacheSource: !settings.enabled ? "disabled" : args.force ? "rebuilt" : "disk", cachedBytes: 0, cachedProjects: 0, settings: { ...settings } };
      }
      case "get_external_watch":
        return { enabled: window.__mockExternalWatchEnabled !== false, state: window.__mockExternalWatchEnabled === false ? "disabled" : "offline", note: "Simulert nettbrudd i forhåndsvisningen. Ingen ekstern vakt er opprettet, og lokale oppdrag virker fortsatt.", expiresAt: 0, lastConfirmed: 0, readUrl: null, statusUrl: null };
      case "set_external_watch":
        window.__mockExternalWatchEnabled = Boolean(args.enabled);
        return { enabled: window.__mockExternalWatchEnabled, state: window.__mockExternalWatchEnabled ? "offline" : "disabled", note: "Simulering. Ingen nettaktivitet.", expiresAt: 0, lastConfirmed: 0, readUrl: null, statusUrl: null };
      case "get_intent_catalog":
        await wait(150);
        return JSON.parse(JSON.stringify(catalog));
      case "resolve_intent": {
        await wait(800);
        const text = String(args.request?.text || "").toLowerCase();
        const project = catalog.projects.find((item) => item.path.toLowerCase() === String(args.request?.currentProject || "").toLowerCase());
        if (!project) throw new Error("Velg et gyldig prosjekt først.");
        if (text.includes("feil")) throw new Error("Ollama-kallet feilet: connection refused");
        const force = text.includes("tving") || text.includes("parallel");
        const level = text.includes("ultra") ? "ultra" : text.includes("normal") || text.includes("rask") ? "normal" : "max";
        const make = (agent, model, rationale, candidateLevel = level) => ({ project: project.path, agent, model, level: candidateLevel, force, rationale });
        let choices;
        if (text.includes("lokal") || text.includes("spark") || text.includes("ollama")) {
          choices = [
            make("aider", "ollama_chat/qwen3-coder-next:q8_0", "Lokal og stor kodekandidat på Spark. Faglige konklusjoner må kontrolleres."),
            make("aider", "ollama_chat/qwen3.5:27b", "Lettere lokalt alternativ. Fart og fagkvalitet er ikke målt i AgentSync.", "normal")
          ];
        } else if (text.includes("claude") || text.includes("sonnet")) {
          choices = [
            make("claude", text.includes("sonnet") ? "claude-sonnet-5" : "claude-opus-5", "Sterk generell kandidat fra ønsket ditt."),
            make("codex", "gpt-5.6-sol", "Alternativ leverandør for en uavhengig vurdering."),
            make("opencode", "kimi-k3", "Et tredje perspektiv med en registrert OpenCode-modell.", "normal")
          ];
        } else {
          choices = [
            make("codex", "gpt-5.6-sol", "Sterk generell kandidat. Ingen regnskapsspesifikk vurdering er registrert."),
            make("claude", "claude-opus-5", "Grundig alternativ. Ingen regnskapsspesifikk vurdering er registrert."),
            make("aider", "ollama_chat/qwen3-coder-next:q8_0", "Lokal Spark-kandidat uten betalte API-token. Faglige konklusjoner må kontrolleres.", "normal")
          ];
        }
        if (text.includes("opencode") || text.includes("kimi")) {
          choices.unshift(make("opencode", "kimi-k3", "Eksplisitt nevnt i ønsket ditt."));
          choices = choices.filter((choice, index, all) => all.findIndex((candidate) => candidate.agent === choice.agent && candidate.model === choice.model && candidate.level === choice.level) === index).slice(0, 4);
        }
        return { fields: choices[0], choices, source: "ollama", resolverModel: args.request?.resolverModel || "gemini-3-flash-preview:cloud", elapsedMs: 812, warning: null };
      }
      case "start_mission": {
        await wait(200);
        const request = args.request || {};
        const mode = request.mode === "blind" ? "blind" : "shared";
        const purpose = normalizePurpose(request.purpose, mode);
        const sourceMissionId = String(request.sourceMissionId || "").trim() || null;
        const resolvedModel = resolvedModelFor(request.agent, request.model);
        if (purpose !== "validator" && sourceMissionId) {
          throw "En kilde-ID kan bare brukes av automatisk validering.";
        }
        if (purpose === "validator" && (mode !== "blind" || !sourceMissionId)) {
          throw "Automatisk validering krever blind modus og et fullført kildeoppdrag.";
        }
        if (purpose !== "writer") validateControlGeneration(request.validatorGeneration);
        if (purpose === "validator") validateValidatorSource({ ...request, sourceMissionId }, resolvedModel);
        const busy = missions.find((mission) => isActive(mission) && (mission.mode || "shared") !== "blind"
          && projectKey(mission.projectPath) === projectKey(request.projectPath));
        // A blind mission works in its own copy, so it never blocks a writer
        // and is never blocked by an active shared writer.
        if (busy && !request.force && mode !== "blind") {
          throw `AGENT_BUSY: ${busy.agentLabel} kjører allerede i dette prosjektet. Bruk tving for å kjøre ${labelFor(request.agent)} parallelt.`;
        }
        sharedState.counter += 1;
        const missionId = `mission-${Date.now()}${String(sharedState.counter).padStart(6, "0")}`;
        missions.push({
          id: missionId,
          // Windows canonicalisation adds this prefix; the catalog has none.
          projectPath: CANONICAL(request.projectPath),
          prompt: request.prompt,
          agent: request.agent,
          agentLabel: labelFor(request.agent),
          model: request.model || null,
          // What the real backend resolves from config or the agent's stream.
          resolvedModel,
          mode,
          purpose,
          sourceMissionId,
          level: request.level || null,
          status: "running",
          phase: "Starter " + labelFor(request.agent),
          startedUnixMs: Date.now(),
          finishedUnixMs: null,
          exitCode: null,
          output: "",
          finalOutput: "",
          errorOutput: "",
          workspaceAfter: null,
          error: null,
          tick: 0
        });
        return { accepted: true, message: "Oppdraget er sendt.", missionId };
      }
      case "get_mission_summaries": {
        await wait(30);
        const request = args.request || {};
        const key = value => String(value || "").replaceAll("\\", "/").replace(/\/+$/, "").toLowerCase();
        const seen = new Set();
        const history = [...missions, ...archived].filter(mission => {
          if (seen.has(mission.id)) return false;
          seen.add(mission.id);
          return !request.projectPath || key(mission.projectPath) === key(request.projectPath);
        }).sort((left, right) => right.startedUnixMs - left.startedUnixMs);
        const offset = request.offset || 0;
        const limit = request.limit || 500;
        return {
          missions: missions.map(historyItem),
          history: history.slice(offset, offset + limit).map(historyItem),
          total: history.length,
          hasMore: offset + limit < history.length,
          warning: null
        };
      }
      case "get_mission_control":
        await wait(60);
        missions.forEach(advance);
        return {
          agents: catalog.agents,
          missions: JSON.parse(JSON.stringify(missions)),
          history: [...archived, ...missions.filter((mission) => mission.status !== "running")].map(historyItem)
        };
      case "extract_findings": {
        await wait(500);
        const mission = findMission(args.request?.missionId);
        if (!mission) throw "Kan ikke åpne oppdraget.";
        if (mission.status !== "completed" || purposeFor(mission) === "writer") throw "Velg en fullført kontroll for å lese funn.";
        mission.findings = mission.findings || buildMockFindings(mission);
        return copy(mission.findings);
      }
      case "get_finding_evaluations": {
        const mission = findMission(args.request?.missionId);
        if (!mission) throw new Error("Kan ikke åpne oppdraget.");
        return { cases: copy(casesForMission(mission)) };
      }
      case "save_finding_evaluation":
        return saveEvaluation(args.request || {});
      case "get_evaluation_dataset":
        return evaluationDataset(args.request?.projectPath);
      case "get_knowledge_reviews":
        return knowledgeDataset(args.request?.projectPath);
      case "save_knowledge_review_decision":
        return saveKnowledgeDecision(args.request || {});
      case "export_evaluation_dataset": {
        const dataset = evaluationDataset(args.request?.projectPath);
        return { path: "Forhåndsvisning: simulert eksport, ingen fil skrevet", caseCount: dataset.cases.length };
      }
      case "record_later_finding":
        return recordLaterFinding(args.request || {});
      case "link_finding_followup":
        return linkFindingFollowup(args.request || {});
      case "get_mission_session": {
        await wait(40);
        const mission = findMission(args.missionId);
        if (!mission) throw "Kan ikke åpne oppdraget.";
        return JSON.parse(JSON.stringify(mission));
      }
      case "cancel_mission": {
        const mission = missions.find((item) => item.id === args.missionId);
        if (!mission) throw "Denne missionen kjører ikke lenger.";
        mission.status = "canceled";
        mission.phase = "Avbrutt av brukeren";
        mission.finishedUnixMs = Date.now();
        return { accepted: true, message: "Avbryt-signal er sendt til agenten." };
      }
      case "get_project_file_authors":
        await wait(30);
        // Recorded changes, not proof of authorship when work overlaps.
        return { files: [
          { file: "code/php/js/app-discover.js", agent: "claude", atUnixMs: Date.now() - 86_400_000, missionId: "mission-1", also: ["aider", "claude"] },
          { file: "code/php/strings.blk", agent: "claude", atUnixMs: Date.now() - 90_000_000, missionId: "mission-2", also: ["antigravity", "claude"] },
          { file: "desktop/src/app.js", agent: "codex", atUnixMs: Date.now() - 3_600_000, missionId: "mission-3", also: ["codex"] }
        ].map(file => ({ ...file, evidence: "observedInMission", finishedTimeKnown: true })), warning: null, totalRecords: 3 };
      case "get_agent_quotas":
        await wait(80);
        return [
          {
            agent: "codex",
            label: "Codex",
            windows: [
              { name: "uke", usedPercent: 9, windowMinutes: 10080, resetsAtUnix: Math.floor(Date.now() / 1000) + 4 * 86400 },
              { name: "5 t", usedPercent: 74.5, windowMinutes: 300, resetsAtUnix: Math.floor(Date.now() / 1000) + 5400 }
            ],
            observedUnixMs: Date.now() - 120_000,
            source: "codex-sessions",
            status: "measured",
            note: null
          },
          {
            agent: "ollama",
            label: "Ollama Cloud",
            windows: [
              { name: "økt", usedPercent: 2.2, windowMinutes: null, resetsAtUnix: null },
              { name: "uke", usedPercent: 42.7, windowMinutes: null, resetsAtUnix: null }
            ],
            observedUnixMs: Date.now() - 60_000,
            source: "ollama-cloud-api",
            status: "measured",
            note: "Best-effort: Ollamas kvoterute er foreløpig ikke dokumentert."
          },
          { agent: "aider", label: "Aider (Spark)", windows: [], observedUnixMs: Date.now(), source: "local", status: "unlimited", note: "Lokal modell på Spark, ingen kvote" }
        ];
      case "poll_missions": {
        await wait(30);
        missions.forEach(advance);
        const known = Array.isArray(args.known) ? args.known : [];
        return missions.map((mission) => missionDelta(mission, known.find((cursor) => cursor.id === mission.id)));
      }
      case "get_engine_health":
        await wait(30);
        return { isRunning: true, detection: "mutex", diagnostics: { daemonStartedUtc: new Date(Date.now() - 3 * 3_600_000).toISOString(), cycles: 102, incrementalCycles: 93, errorsSinceStart: 0, lastCycle: { mode: "incremental", agents: ["antigravity", "claude", "codex", "opencode"], trigger: "max-wait", durationMs: 53746, workingSetMB: 516.6, errors: 0, silentFailures: {}, completedUtc: new Date(Date.now() - 120_000).toISOString() }, errorJournalBytes: 0 } };
      case "get_dashboard":
        await wait(40);
        return {
          agentSyncHome: TOOLKIT,
          engine: { isRunning: true, detection: "mutex", event: null },
          status: { path: TOOLKIT + "\\AgentSync-Status.json", exists: true, modifiedUnixMs: 1, unchanged: false, data: { diagnostics: { daemonStartedUtc: new Date(Date.now() - 3 * 3_600_000).toISOString(), cycles: 102, incrementalCycles: 93, errorsSinceStart: 0, lastCycle: { mode: "incremental", agents: ["antigravity", "claude", "codex", "opencode"], trigger: "max-wait", durationMs: 53746, workingSetMB: 516.6, errors: 0, silentFailures: {}, completedUtc: new Date(Date.now() - 120_000).toISOString() }, errorJournalBytes: 0 } }, error: null },
          recovery: { path: TOOLKIT + "\\AgentSync-Recovery.json", exists: true, modifiedUnixMs: 1, unchanged: true, data: null, error: null },
          intelligence: { path: TOOLKIT + "\\AgentSync-Intelligence.json", exists: true, modifiedUnixMs: 1, unchanged: true, data: null, error: null }
        };
      case "get_validator_periods":
        return { recorded: false, offMs: 0, windowMs: args?.windowMs || 7 * 24 * 60 * 60 * 1000, periods: [] };
      case "get_validator_control":
        await wait(20);
        return validatorStatus();
      case "set_validator_control": {
        const enabled = Boolean(args.enabled);
        if (enabled && !validatorRuntime.enabled) {
          validatorRuntime.enabled = true;
          validatorRuntime.generation += 1;
          validatorRuntime.enabledSinceUnixMs = Date.now();
        } else if (!enabled && validatorRuntime.enabled) {
          validatorRuntime.enabled = false;
          validatorRuntime.generation += 1;
          validatorRuntime.enabledSinceUnixMs = 0;
        }
        // The panel lives inside the main window now; the switch only carries
        // runtime state, and the frontend shows or hides the panel itself.
        if (!enabled) cancelValidatorMissions();
        return validatorStatus();
      }
      case "scope_mission": {
        // Mirrors heuristic_scope in main.rs so the scope strip can be
        // exercised here: a short prompt without a verb is wide, anything
        // else narrow. The option texts are what the real kimi returned for
        // "ok?" on 2026-09-05.
        await wait(400);
        const prompt = String(args.request?.prompt || "").trim();
        const tokens = prompt.split(/\s+/).filter(Boolean);
        const wide = tokens.length <= 3 || (prompt.endsWith("?") && tokens.length <= 6);
        const reading = (text) => `Brukeren skrev: «${prompt}»\nTolket som: ${text}`;
        if (!wide) {
          return { summary: `Agenten vil ${prompt.charAt(0).toLowerCase()}${prompt.slice(1)}.`, spread: "narrow", options: [], source: "ollama", resolverModel: "deepseek-v4-pro:cloud", elapsedMs: 1100 };
        }
        return {
          summary: `Brukeren ber om en bekreftelse eller status med et svært åpent «${prompt}».`,
          spread: "wide",
          options: [
            { label: "Kort status", description: "Gi en rask bekreftelse på at alt ser greit ut.", prompt: reading("Gi en kort status: bekreft at alt ser greit ut, eller oppsummer eventuelle åpenbare problemer.") },
            { label: "Sjekk og rapporter", description: "Gjør en rask gjennomgang av koden og rapporter funn.", prompt: reading("Gjennomgå den relevante koden raskt, sjekk for åpenbare feil, og rapporter funnene uten å gjøre endringer.") },
            { label: "Full revisjon med tester", description: "Utfør en grundig revisjon og verifiser med kjørende tester.", prompt: reading("Utfør en grundig revisjon av koden, identifiser potensielle problemer, kjør relevante tester, og rapporter resultatene.") }
          ],
          source: "ollama",
          resolverModel: "deepseek-v4-pro:cloud",
          elapsedMs: 2800
        };
      }
      default:
        throw `Ukjent kommando i mock: ${command}`;
    }
  }

  window.__TAURI__ = { core: { invoke }, event: { listen: async () => () => {} } };
  window.__mockMissions = missions;
})();
