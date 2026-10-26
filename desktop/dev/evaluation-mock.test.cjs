const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "mock-tauri.js"), "utf8");
const projectPath = "C:\\Projects\\AgentSyncToolkit";
const missionId = "mission-preview-evaluation-1";
const storageKey = "agentsync.preview.finding-evaluations.v1";

function preview(storage = new Map(), setItem) {
  const window = { localStorage: {
    getItem: (key) => storage.get(key) ?? null,
    setItem: setItem || ((key, value) => storage.set(key, value))
  } };
  vm.runInNewContext(source, { window, setTimeout: (fn) => { fn(); return 1; } });
  return { window, storage, invoke: window.__TAURI__.core.invoke };
}

async function cases(api) {
  return (await api.invoke("get_finding_evaluations", { request: { missionId } })).cases;
}

async function save(api, patch = {}) {
  return api.invoke("save_finding_evaluation", { request: {
    missionId, findingIndex: 0, expectedRevision: 0, verdict: "confirmed", remediation: "open",
    evidence: "Reproduksjon: null-innput gir samme TypeError i isolert test.", notes: "Kontrollert manuelt.", ...patch
  } });
}

test("fixture has three stable unreviewed cases and explicit source metadata", async () => {
  const api = preview();
  const first = await cases(api);
  assert.equal(first.length, 3);
  assert.equal(first[0].verdict, "unreviewed");
  assert.equal(first[0].revision, 0);
  assert.equal(first[0].provenance.validatorAgent, "claude");
  assert.equal(first[0].provenance.resolvedModel, "claude-opus-5");
  assert.equal(first[0].provenance.sourceAgent, "codex");
  assert.equal(first[0].provenance.contextMode, "blind");
  assert.equal(first[0].provenance.durationMs, 60000);
  const report = await api.invoke("extract_findings", { request: { missionId } });
  assert.equal(report.findings.length, 3);
  assert.equal((await cases(api))[0].id, first[0].id);
});

test("adjudication persists through reload and keeps correction history", async () => {
  const api = preview();
  const initial = await cases(api);
  await save(api);
  const reloaded = preview(api.storage);
  let restored = (await cases(reloaded))[0];
  assert.equal(restored.verdict, "confirmed");
  assert.equal(restored.revision, 1);
  assert.equal(restored.history.length, 1);
  assert.equal(initial[0].revision, 0);
  restored = await save(reloaded, { expectedRevision: 1, verdict: "falsePositive", remediation: "open", evidence: "Reproduksjonen gjaldt gammel kode; eksisterende vakt avviser null." });
  assert.equal(restored.revision, 2);
  assert.equal(restored.history[0].verdict, "confirmed");
  assert.equal(restored.history[1].verdict, "falsePositive");
  assert.equal(restored.history[1].kind, "assessment");
  assert.equal(restored.kind, "validatorFinding");
  assert.equal(restored.origin, "user");
});

test("stale revisions across preview tabs cannot overwrite an adjudication", async () => {
  const first = preview();
  const second = preview(first.storage);
  await cases(second);
  await save(first);
  await assert.rejects(save(second), /endret siden/);
  assert.equal((await cases(second))[0].revision, 1);
});

test("determinate verdicts and verified remediation need evidence", async () => {
  const api = preview();
  for (const verdict of ["confirmed", "partial", "falsePositive"]) {
    await assert.rejects(save(api, { verdict, evidence: "  " }), /bevis/);
  }
  await assert.rejects(save(api, { verdict: "unresolved", remediation: "verified", evidence: "" }), /bevis/);
  assert.equal((await cases(api))[0].revision, 0);
});

test("invalid verdict and remediation states are rejected", async () => {
  const api = preview();
  await assert.rejects(save(api, { verdict: "accepted" }), /Ukjent avklaring/);
  await assert.rejects(save(api, { remediation: "sent" }), /Ukjent rettestatus/);
  await assert.rejects(save(api, { verdict: "unreviewed", remediation: "fixed" }), /ikke vurdert/);
  await assert.rejects(save(api, { verdict: "falsePositive", remediation: "verified" }), /falskt varsel/);
  await assert.rejects(save(api, { verdict: "unresolved", remediation: "verified" }), /uavklart/);
  await assert.rejects(save(api, { verdict: "unresolved", remediation: "fixed" }), /uavklart/);
  assert.equal((await cases(api))[0].revision, 0);
});

test("rates exclude partial, unresolved and later-discovered reports", async () => {
  const api = preview();
  await save(api, { remediation: "verified" });
  await save(api, { findingIndex: 1, verdict: "falsePositive", evidence: "Testen dekker allerede grenen." });
  await save(api, { findingIndex: 2, verdict: "partial", evidence: "Importen er overflødig bare i ett bygg." });
  const later = await api.invoke("record_later_finding", { request: {
    projectPath, title: "Feil oppdaget i senere bruk", detail: "En tidligere ukontrollert null-verdi.", file: "desktop/src/app.js",
    sourceMissionId: "mission-1788350000000", evidence: "Reprodusert manuelt med tomt prosjekt."
  } });
  assert.equal(later.kind, "laterDiscovered");
  assert.equal(later.verdict, "unresolved");
  assert.equal(later.history.length, 1);
  await save(api, { caseId: later.id, missionId: null, findingIndex: null, expectedRevision: 1, verdict: "confirmed" });
  const dataset = await api.invoke("get_evaluation_dataset", { request: { projectPath } });
  assert.equal(dataset.cases.length, 4);
  assert.equal(dataset.summary.total, 4);
  assert.equal(dataset.summary.laterDiscovered, 1);
  assert.equal(dataset.summary.confirmedRate, 0.5);
  assert.equal(dataset.summary.adjudicated, 2);
  assert.equal(dataset.summary.remediationVerified, 1);
  assert.equal(dataset.groups.length, 1);
  assert.equal(dataset.groups[0].total, 3);
  assert.equal(dataset.groups[0].modelSource, "observed");
  assert.equal(dataset.groups[0].confirmedRate, 0.5);
});

test("empty denominator is unknown, not zero percent", async () => {
  const api = preview();
  await save(api, { verdict: "partial" });
  const dataset = await api.invoke("get_evaluation_dataset", { request: { projectPath } });
  assert.equal(dataset.summary.confirmedRate, null);
  assert.equal(dataset.groups[0].confirmedRate, null);
  assert.equal((await api.invoke("get_evaluation_dataset", { request: { projectPath: "P:\\elsewhere" } })).cases.length, 0);
});

test("dataset contains workspace metadata but no prompts, output or raw diff", async () => {
  const api = preview();
  const dataset = await api.invoke("get_evaluation_dataset", { request: { projectPath } });
  for (const item of dataset.cases) {
    assert.equal(Object.hasOwn(item, "prompt"), false);
    assert.equal(Object.hasOwn(item, "output"), false);
    assert.equal(Object.hasOwn(item.provenance.workspaceBefore, "diff"), false);
    assert.equal(Object.hasOwn(item.provenance.workspaceAfter, "status"), false);
  }
});

test("storage failure does not pretend a revision was persisted", async () => {
  const api = preview(new Map(), () => { throw new Error("Storage quota reached"); });
  await assert.rejects(save(api), /Storage quota/);
  assert.equal((await cases(api))[0].revision, 0);
});

test("corrupt preview storage is surfaced and not overwritten", async () => {
  const storage = new Map([[storageKey, "broken"]]);
  const api = preview(storage);
  await assert.rejects(cases(api), /Kan ikke lese/);
  await assert.rejects(save(api), /Kan ikke lese/);
  assert.equal(storage.get(storageKey), "broken");
});

test("later reports require evidence and matching source project", async () => {
  const api = preview();
  const request = { projectPath, title: "Ny feil", detail: "Beskrivelse", evidence: "" };
  await assert.rejects(api.invoke("record_later_finding", { request }), /bevis/);
  await assert.rejects(api.invoke("record_later_finding", { request: { ...request, evidence: "Test", sourceMissionId: "does-not-exist" } }), /samme prosjekt/);
});

test("preview export is explicitly simulated, never a fake real file path", async () => {
  const api = preview();
  const exported = await api.invoke("export_evaluation_dataset", { request: { projectPath } });
  assert.equal(exported.caseCount, 3);
  assert.match(exported.path, /simulert.*ingen fil skrevet/);
});

test("ordinary writer startup still works and is not interpreted as validation", async () => {
  const api = preview();
  const started = await api.invoke("start_mission", { request: { projectPath, agent: "codex", model: "gpt-5.6-sol", purpose: "writer", mode: "shared", prompt: "Oppsummer prosjektet." } });
  assert.equal(started.accepted, true);
  await assert.rejects(api.invoke("extract_findings", { request: { missionId: started.missionId } }), (error) => String(error).includes("fullført kontroll"));
});

test("forwarding a finding records a writer link, not a verdict or repair", async () => {
  const api = preview();
  const started = await api.invoke("start_mission", { request: { projectPath, agent: "codex", model: "gpt-5.6-sol", purpose: "writer", mode: "shared", prompt: "Undersøk null-sjekken." } });
  const request = { missionId, findingIndex: 0, followupMissionId: started.missionId };
  const linked = await api.invoke("link_finding_followup", { request });
  assert.equal(linked.revision, 1);
  assert.equal(linked.verdict, "unreviewed");
  assert.equal(linked.remediation, "open");
  assert.equal(linked.followups.length, 1);
  assert.equal(linked.followups[0].status, "running");
  assert.equal(linked.followups[0].agent, "codex");
  assert.equal(linked.history[0].kind, "followupLinked");
  assert.equal(linked.history[0].followup.missionId, started.missionId);
  const liveMission = api.window.__mockMissions.find((item) => item.id === started.missionId);
  liveMission.status = "completed";
  liveMission.finishedUnixMs = liveMission.startedUnixMs + 12500;
  const refreshed = (await cases(api))[0];
  assert.equal(refreshed.followups[0].status, "completed");
  assert.equal(refreshed.followups[0].durationMs, 12500);
  assert.equal(refreshed.history[0].followup.status, "running");
  const repeated = await api.invoke("link_finding_followup", { request });
  assert.equal(repeated.revision, 1);
  assert.equal(repeated.history.length, 1);
  const reloaded = (await cases(preview(api.storage)))[0];
  assert.equal(reloaded.followups[0].missionId, started.missionId);
  assert.equal(reloaded.followups[0].recordAvailable, false);
  await assert.rejects(save(api), /endret siden/);
});

test("followup links reject wrong projects, controls and unknown writers", async () => {
  const api = preview();
  const started = await api.invoke("start_mission", { request: { projectPath: "C:\\Projects\\demo.example", agent: "codex", purpose: "writer", mode: "shared", prompt: "Oppsummer." } });
  for (const followupMissionId of [started.missionId, missionId, "missing"]) {
    await assert.rejects(api.invoke("link_finding_followup", { request: { missionId, findingIndex: 0, followupMissionId } }), /skriveoppdrag i samme prosjekt/);
  }
  assert.equal((await cases(api))[0].revision, 0);
});

test("case IDs cannot redirect edits to a different native mission or finding", async () => {
  const api = preview();
  const caseId = (await cases(api))[0].id;
  await assert.rejects(save(api, { caseId, findingIndex: 2 }), /ikke begge/);
  await assert.rejects(save(api, { caseId, missionId: "different-mission" }), /ikke begge/);
  await assert.rejects(save(api, { caseId, missionId: null, findingIndex: null }), /Fant ikke/);
  await assert.rejects(save(api, { findingIndex: 99 }), /Fant ikke/);
  await assert.rejects(save(api, { missionId: "missing" }), /Fant ikke/);
  await save(api);
  const savedById = await save(api, { caseId, missionId: null, findingIndex: null, expectedRevision: 1 });
  assert.equal(savedById.revision, 2);
});

test("missing records fail distinctly from a valid control with no stored findings", async () => {
  const api = preview();
  await assert.rejects(api.invoke("get_finding_evaluations", { request: { missionId: "missing" } }), /Kan ikke åpne/);
  const response = await api.invoke("get_finding_evaluations", { request: { missionId: "mission-1788350000000" } });
  assert.equal(response.cases.length, 0);
  await assert.rejects(save(api, { missionId: "mission-1788350000000", findingIndex: 0 }), /Fant ikke/);
});

test("requested-only model groups are not mislabeled as observed use", async () => {
  const api = preview();
  api.window.__mockMissions.push({
    id: "mission-123", projectPath, status: "completed", purpose: "manualControl", mode: "shared",
    agent: "aider", model: "requested-test-model", resolvedModel: null,
    findings: { outcome: "findings", findings: [{ title: "Påstand", detail: "Forklaring", severity: "lav", file: null }] }
  });
  const dataset = await api.invoke("get_evaluation_dataset", { request: { projectPath } });
  const group = dataset.groups.find((item) => item.validatorAgent === "aider");
  assert.equal(group.modelSource, "requestedOnly");
  assert.equal(group.contextMode, "shared");
  assert.equal(group.confirmedRate, null);
});

test("usefulness is optional and independent of truth adjudication", async () => {
  const api = preview();
  const scored = await save(api, { verdict: "unreviewed", usefulness: 10, evidence: "" });
  assert.equal(scored.usefulness, 10);
  assert.equal(scored.verdict, "unreviewed");
  assert.equal(scored.remediation, "open");
  assert.equal(scored.history[0].usefulness, 10);
  assert.equal((await cases(preview(api.storage)))[0].usefulness, 10);
  const dataset = await api.invoke("get_evaluation_dataset", { request: { projectPath } });
  assert.equal(dataset.summary.usefulnessRated, 1);
  assert.equal(dataset.summary.usefulnessAverage, 10);
  assert.equal(dataset.summary.confirmedRate, null);
});

test("invalid usefulness values cannot be stored", async () => {
  const api = preview();
  for (const usefulness of [0, 11, -1, 1.5, "5", true, {}, []]) {
    await assert.rejects(save(api, { usefulness }), /heltall fra 1 til 10/);
  }
  assert.equal((await cases(api))[0].revision, 0);
});

test("usefulness averages exclude unrated and later-discovered entries", async () => {
  const api = preview();
  await save(api, { usefulness: 10 });
  await save(api, { findingIndex: 1, usefulness: 2, verdict: "falsePositive" });
  const later = await api.invoke("record_later_finding", { request: { projectPath, title: "Senere feil", detail: "Feil i tom verdi.", evidence: "Test reproduserer." } });
  await save(api, { missionId: null, findingIndex: null, caseId: later.id, expectedRevision: 1, usefulness: 1 });
  let dataset = await api.invoke("get_evaluation_dataset", { request: { projectPath } });
  assert.equal(dataset.summary.usefulnessRated, 2);
  assert.equal(dataset.summary.usefulnessAverage, 6);
  assert.equal(dataset.groups[0].usefulnessRated, 2);
  assert.equal(dataset.groups[0].usefulnessAverage, 6);
  await save(api, { expectedRevision: 1, usefulness: null });
  dataset = await api.invoke("get_evaluation_dataset", { request: { projectPath } });
  assert.equal(dataset.summary.usefulnessRated, 1);
  assert.equal(dataset.summary.usefulnessAverage, 2);
});

test("legacy records missing score dimensions remain unrated, never zero", async () => {
  const api = preview();
  await save(api);
  const legacy = JSON.parse(api.storage.get(storageKey));
  for (const key of ["usefulness", "actionability", "novelty"]) {
    delete legacy.cases[0][key];
    delete legacy.cases[0].history[0][key];
  }
  api.storage.set(storageKey, JSON.stringify(legacy));
  const reloaded = preview(api.storage);
  const restored = (await cases(reloaded))[0];
  const dataset = await reloaded.invoke("get_evaluation_dataset", { request: { projectPath } });
  for (const key of ["usefulness", "actionability", "novelty"]) {
    assert.equal(restored[key], null);
    assert.equal(restored.history[0][key], null);
    assert.equal(dataset.summary[`${key}Rated`], 0);
    assert.equal(dataset.summary[`${key}Average`], null);
  }
});

test("project matching accepts canonical Windows prefix but preserves nested identity", async () => {
  const api = preview();
  const canonical = String.fromCharCode(92, 92, 63, 92) + projectPath;
  const normal = await api.invoke("get_evaluation_dataset", { request: { projectPath } });
  const prefixed = await api.invoke("get_evaluation_dataset", { request: { projectPath: canonical } });
  const nested = await api.invoke("get_evaluation_dataset", { request: { projectPath: projectPath + "\\desktop" } });
  assert.equal(normal.cases.length, 3);
  assert.equal(prefixed.cases.length, 3);
  const slashes = await api.invoke("get_evaluation_dataset", { request: { projectPath: canonical.replaceAll("\\", "/") } });
  assert.equal(slashes.cases.length, 3);
  assert.equal(nested.cases.length, 0);
});

test("linking preserves all three scores without inventing a new rating", async () => {
  const api = preview();
  await save(api, { usefulness: 7, actionability: 9, novelty: 3, verdict: "unreviewed", evidence: "" });
  const linked = await api.invoke("link_finding_followup", { request: { missionId, findingIndex: 0, followupMissionId: "mission-1788350000000" } });
  assert.equal(linked.revision, 2);
  assert.equal(linked.usefulness, 7);
  assert.equal(linked.history[1].usefulness, 7);
  assert.equal(linked.actionability, 9);
  assert.equal(linked.history[1].actionability, 9);
  assert.equal(linked.novelty, 3);
  assert.equal(linked.history[1].novelty, 3);
  assert.equal(linked.history[1].kind, "followupLinked");
  assert.equal(linked.verdict, "unreviewed");
});

test("UNC canonical prefix normalization retains exact project identity", async () => {
  const api = preview();
  api.window.__mockMissions.push({
    id: "mission-124", projectPath: "\\\\?\\UNC\\server\\share\\project", status: "completed", purpose: "manualControl", mode: "shared",
    agent: "aider", model: null, resolvedModel: null,
    findings: { outcome: "findings", findings: [{ title: "Påstand", detail: "Forklaring", severity: "lav", file: null }] }
  });
  const dataset = await api.invoke("get_evaluation_dataset", { request: { projectPath: "\\\\server\\share\\project" } });
  assert.equal(dataset.cases.length, 1);
  assert.equal(dataset.groups[0].modelSource, "unknown");
});

test("actionability and novelty are optional independent dimensions", async () => {
  const api = preview();
  const saved = await save(api, { verdict: "unreviewed", evidence: "", usefulness: null, actionability: 8, novelty: 2 });
  assert.equal(saved.verdict, "unreviewed");
  assert.equal(saved.remediation, "open");
  assert.equal(saved.usefulness, null);
  assert.equal(saved.actionability, 8);
  assert.equal(saved.novelty, 2);
  const reloaded = (await cases(preview(api.storage)))[0];
  assert.equal(reloaded.actionability, 8);
  assert.equal(reloaded.novelty, 2);
  assert.equal(reloaded.history[0].actionability, 8);
  assert.equal(reloaded.history[0].novelty, 2);
  const dataset = await api.invoke("get_evaluation_dataset", { request: { projectPath } });
  assert.equal(dataset.summary.usefulnessRated, 0);
  assert.equal(dataset.summary.actionabilityAverage, 8);
  assert.equal(dataset.summary.noveltyAverage, 2);
  assert.equal(dataset.summary.confirmedRate, null);
});

test("actionability and novelty reject values outside integer1 to10", async () => {
  const api = preview();
  for (const key of ["actionability", "novelty"]) {
    for (const value of [0, 11, -1, 1.5, "5", true, {}, []]) {
      await assert.rejects(save(api, { [key]: value }), /heltall fra 1 til 10/);
    }
  }
  assert.equal((await cases(api))[0].revision, 0);
});

test("each score average has its own denominator, excluding later discoveries", async () => {
  const api = preview();
  await save(api, { usefulness: 10, actionability: 8, novelty: null });
  await save(api, { findingIndex: 1, usefulness: null, actionability: null, novelty: 2 });
  await save(api, { findingIndex: 2, usefulness: 2, actionability: 4, novelty: 8 });
  const later = await api.invoke("record_later_finding", { request: { projectPath, title: "Senere feil", detail: "Feil i tom verdi.", evidence: "Test reproduserer." } });
  await save(api, { missionId: null, findingIndex: null, caseId: later.id, expectedRevision: 1, usefulness: 1, actionability: 1, novelty: 1 });
  let dataset = await api.invoke("get_evaluation_dataset", { request: { projectPath } });
  assert.equal(dataset.summary.usefulnessRated, 2);
  assert.equal(dataset.summary.usefulnessAverage, 6);
  assert.equal(dataset.summary.actionabilityRated, 2);
  assert.equal(dataset.summary.actionabilityAverage, 6);
  assert.equal(dataset.summary.noveltyRated, 2);
  assert.equal(dataset.summary.noveltyAverage, 5);
  assert.equal(dataset.groups[0].actionabilityAverage, 6);
  assert.equal(dataset.groups[0].noveltyAverage, 5);
  // Removing one dimension must not count it as zero or remove other scores.
  await save(api, { findingIndex: 2, expectedRevision: 1, usefulness: 2, actionability: 4, novelty: null });
  dataset = await api.invoke("get_evaluation_dataset", { request: { projectPath } });
  assert.equal(dataset.summary.actionabilityAverage, 6);
  assert.equal(dataset.summary.noveltyRated, 1);
  assert.equal(dataset.summary.noveltyAverage, 2);
  assert.equal((await cases(api))[2].history[0].novelty, 8);
  assert.equal((await cases(api))[2].history[1].novelty, null);
  assert.equal(Object.hasOwn(dataset.summary, "compositeScore"), false);
});
