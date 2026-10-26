// Execute the actual frontend. No native calls, models, missions or user data.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const app = fs.readFileSync(path.join(__dirname, '../src/app.js'), 'utf8');
const control = fs.readFileSync(path.join(__dirname, '../src/control.js'), 'utf8');
function fn(source, name) {
  const start = source.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.notEqual(start, -1, name);
  return source.slice(start, source.indexOf('\n}', start) + 2);
}
function cards() {
  const box = { console, __dirname, require: id => id === 'node:test' ? () => {} : require(id) };
  vm.createContext(box);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'finding-card.test.cjs'), 'utf8')
    + '\nglobalThis.make=fixture; globalThis.sample=report;', box);
  return { ...box.make(), report: structuredClone(box.sample) };
}

test('the entire app registers handlers without a stray top-level runtime identifier', () => {
  const f = cards(), nodes = new Map();
  f.context.document.getElementById = id => {
    if (!nodes.has(id)) nodes.set(id, new f.Element('div'));
    return nodes.get(id);
  };
  f.context.document.createElement = tag => new f.Element(tag);
  f.context.window.addEventListener = () => {};
  f.context.window.localStorage = { getItem: () => null, setItem() {} };
  // Suppress only boot's invocation, not the production declarations or any
  // top-level statements. Function-only fixtures missed the stray `async`.
  const source = app.replace(/\nboot\(\);\s*$/, '\nglobalThis.bootRegistered = typeof boot;');
  const isolated = { window: f.context.window, document: f.context.document, console };
  vm.createContext(isolated);
  vm.runInContext(source, isolated);
  assert.equal(isolated.bootRegistered, 'function');
});

for (const configured of [false, true]) test(`production script chain boots with ${configured ? 'a remembered project and agent' : 'no selected project'}, using only simulated reads`, async () => {
  const f = cards(), nodes = new Map(), calls = [], timers = new Map(); let nextTimer = 0;
  const element = tag => {
    const node = new f.Element(tag);
    node.value = ''; node.toggleAttribute = () => {}; node.removeAttribute = () => {};
    node.classList.remove = (...names) => names.forEach(name => node.classList.toggle(name, false));
    node.style.setProperty = () => {}; node.style.removeProperty = () => {};
    node.focus = () => { f.context.document.activeElement = node; };
    return node;
  };
  Object.assign(f.context.document, {
    getElementById: id => {if (!nodes.has(id)) nodes.set(id, element('div')); return nodes.get(id);},
    createElement: element, createDocumentFragment: () => element('fragment'),
    querySelector: () => null, querySelectorAll: () => [], documentElement: element('html'), hidden: false,
  });
  Object.assign(f.context.window, {
    addEventListener() {}, localStorage: {getItem: key => configured ? ({
      'agentsync.v4.project': 'P:/project',
      'agentsync.v4.projectSetups': JSON.stringify({'p:/project': {agent: 'claude', model: 'claude-model', level: ''}}),
    }[key] || null) : null, setItem() {}, removeItem() {}},
    requestAnimationFrame: () => 1, cancelAnimationFrame() {},
    setTimeout: callback => {timers.set(++nextTimer, callback); return nextTimer;}, clearTimeout: id => timers.delete(id),
    __TAURI__: {core: {invoke: async command => {
      calls.push(command);
      if (command === 'get_intent_catalog') return configured
        ? {projects: [{path: 'P:/project', name: 'Fixture project'}], agents: [{id: 'claude', label: 'Claude', available: true, model: 'claude-model'}], models: {claude: ['claude-model']}}
        : {projects: [], agents: [], models: {}};
      if (command === 'poll_missions') return [];
      if (command === 'get_validator_control') return {enabled: false};
      if (command === 'get_agent_quotas') return [];
      if (command === 'get_engine_health') return {isRunning: false};
      if (command === 'get_mission_summaries') return {missions: [], history: [], total: 0, hasMore: false};
      throw Error(`Unapproved test command: ${command}`);
    }}},
  });
  const context = {window: f.context.window, document: f.context.document, console,
    Option: function(text, value) {const option = element('option'); option.textContent = text; option.value = value; return option;},
    CustomEvent: class {constructor(type, init) {this.type = type; this.detail = init?.detail;}}};
  vm.createContext(context);
  // Load the real script chain in index.html order, with actual closures and
  // shared globals. No production function is stubbed or replaced.
  for (const name of ['settings.js', 'mission-status.js', 'control.js', 'evaluation.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../src', name), 'utf8'), context);
  }
  vm.runInContext(app.replace(/\nboot\(\);\s*$/, '\nglobalThis.bootDone = boot();'), context);
  await context.bootDone;
  await context.window.AgentSyncStatus.refresh();
  await vm.runInContext('loadStatusChips()', context);
  assert.equal(nodes.get('projectContextName').textContent, configured ? 'Fixture project' : 'Velg prosjekt');
  assert.equal(nodes.get('instructionInput').disabled, !configured);
  assert.ok(calls.includes('poll_missions'));
  assert.ok(!f.body.textContent.includes('Kunne ikke'), f.body.textContent);
  assert.ok(!nodes.get('canvasStream').textContent.includes('Kunne ikke'), nodes.get('canvasStream').textContent);
  assert.equal(calls.some(command => /start|save|export|set_/.test(command)), false);
  assert.equal(nodes.get('settingsBody').querySelectorAll('button').every(node => node.attributes['aria-label']), true);
});

test('a hidden or closed finding list cannot send through a retained shortcut', async () => {
  const f = cards();
  f.context.renderFindingButtons(f.report, 'mission-1');
  f.caseCallbacks[0].onCase({ followups: [] });
  f.context.presentationVisible = () => false;
  await f.context.state.topSend();
  assert.equal(f.sent.length, 0);
});

test('deliberation ends at the human action, before waiting for native startup', async () => {
  const f = cards(); let now = 10_000; const links = [];
  f.context.Date = { now: () => now };
  f.context.renderFindingButtons(f.report, 'mission-1');
  f.caseCallbacks[0].onCase({ followups: [] });
  now = 12_000;
  f.context.window.AgentSyncHost.sendToAgent = async () => {
    now = 32_000;
    return { accepted: true, missionId: 'writer-2' };
  };
  f.context.invoke = async (_command, args) => { links.push(args.request); return {}; };
  await f.registry.controlFindingList.querySelector('.control-finding-send').fire('click');
  assert.equal(links[0].deliberationMs, 2_000);
});

test('metadata overlap never claims proven authorship or disproves an independent discovery', () => {
  const f = cards();
  Object.assign(f.report.findings[0], { ownWork: true, echoesWriter: true });
  f.context.renderFindingButtons(f.report, 'mission-1');
  const text = f.registry.controlFindingList.textContent;
  assert.doesNotMatch(text, /har skrevet|ikke uavhengig|fant ikke dette selv/);
  assert.match(text, /registrert/);
  assert.match(text, /[Ss]ammenfall/);
});

test('registered handovers retain exact file context without asserting overwrites', () => {
  const context = { window: {}, agentLabel: id => id, formatDuration: () => '1m' };
  vm.createContext(context); vm.runInContext(fn(app, 'handoverSummary'), context);
  const text = context.handoverSummary([{file: 'a/index.js', fromAgent: 'claude', toAgent: 'codex'}]);
  assert.match(text, /a\/index.js/);
  assert.doesNotMatch(text, /skrev|overskrev/);
});

test('shared automatic validation is never labeled as a blind copy', () => {
  const context = { window: {}, state: { catalog: {} }, LEVEL_LABELS: {},
    missionPurpose: mission => mission.purpose, projectDisplayName: p => p };
  vm.createContext(context); vm.runInContext(fn(app, 'missionUserMeta'), context);
  const text = context.missionUserMeta({purpose: 'validator', mode: 'shared', projectPath: 'P:/test'});
  assert.match(text, /delt/);
  assert.doesNotMatch(text, /blind/);
  const aliases = context.missionUserMeta({observedModels: [{model: 'qwen3.5:397b'}, {model: 'ollama-cloud/qwen3.5:397b'}]});
  assert.doesNotMatch(aliases, /modellskifter/);
  assert.match(aliases, /modellnavn/);
});

test('finding shortcut ignores other panels, editable controls and repeated or handled keys', () => {
  const f = cards(); let sent = 0;
  f.context.state.topSend = () => sent++;
  f.registry.controlPanel = new f.Element('section');
  const card = new f.Element('div'); f.registry.controlPanel.append(card);
  vm.runInContext(fn(control, 'handleFindingShortcut'), f.context);
  const event = {key: 'Enter', ctrlKey: true, target: card, preventDefault() {}};
  for (const change of [{repeat: true}, {isComposing: true}, {defaultPrevented: true}, {target: new f.Element('div')}]) {
    f.context.handleFindingShortcut({...event, ...change});
  }
  for (const tag of ['select', 'input', 'textarea']) {
    const field = new f.Element(tag); f.registry.controlPanel.append(field);
    f.context.handleFindingShortcut({...event, target: field});
  }
  assert.equal(sent, 0);
  f.context.handleFindingShortcut(event);
  assert.equal(sent, 1);
});

function controlStartFixture() {
  const remembered = [], shown = [], rotated = [], statuses = [];
  let finish, fail;
  const values = {controlPrompt: {value: 'Inspect without editing'}, controlBlind: {checked: true}, controlRun: {}, controlModel: {value: 'other-model'}, controlLevel: {value: ''}};
  const context = {console, window: {}, state: {open: true, project: 'P:/first', agent: 'claude', enabled: true, lifecycle: 1, generation: 1, started: new Set(), autoMissionIds: new Map()},
    byId: id => values[id], samePath: (a,b) => a === b, validatorDiffersFromWriter: () => true,
    automaticPrompt: () => 'Check changed files', projectName: p => p, estimateMinutes: () => 1,
    validatorChoiceForSource: source => ({project: source.projectPath, agent: 'claude', model: 'other-model'}),
    rememberValidatorUse: (...args) => rotated.push(args), rememberStartedRun: (...args) => remembered.push(args),
    setStatus: text => statuses.push(text), syncRunButton() {}, showFindings: id => shown.push(id),
    invoke: () => new Promise((resolve, reject) => { finish = resolve; fail = reject; }),
  };
  vm.createContext(context); vm.runInContext(fn(control, 'runControl'), context);
  return {context, remembered, shown, rotated, statuses, finish: result => finish(result), fail: error => fail(error)};
}

test('a manual control starting during a project switch cannot select its run in the new project', async () => {
  const f = controlStartFixture();
  const pending = f.context.runControl();
  f.context.state.project = 'P:/second';
  f.context.state.selectedRun = 'second-existing';
  f.finish({missionId: 'first-new'}); await pending;
  assert.equal(f.context.state.selectedRun, 'second-existing');
  assert.equal(f.shown.length, 0);
  assert.equal(f.remembered[0][1], 'P:/first');
});

test('a late control failure cannot write its old status into the new project', async () => {
  const f = controlStartFixture();
  const pending = f.context.runControl();
  assert.equal(f.statuses.length, 1);
  f.context.state.project = 'P:/second';
  f.fail(Error('old project failed'));
  await pending;
  assert.equal(f.statuses.length, 1, 'only the pre-switch start status belongs to the old view');
});

test('rotation advances only after a real accepted start, not a waiting attempt', async () => {
  const f = controlStartFixture();
  f.context.invoke = async () => { throw Error('VALIDATOR_WAIT: active writer'); };
  assert.equal(await f.context.runControl({automatic: true, source: {id: 'source', projectPath: 'P:/first', agent: 'codex'}}), 'wait');
  assert.equal(f.rotated.length, 0);
});

function writerFixture() {
  const box = {console, __dirname, require: id => id === 'node:test' ? () => {} : require(id)};
  vm.createContext(box);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'health-integration.test.cjs'), 'utf8')
    + '\nglobalThis.make = hostFixture;', box);
  const f = box.make();
  Object.assign(f.context, {preferredResolverModel: () => '', persistSelection() {}, updateProjectLabels() {}, setDrawerOpen() {},
    enterChoosing() {}, agentChoices: () => [], showScopeStrip() {}, scopeChoiceNote() {}});
  vm.runInContext(fn(app, 'startMission'), f.context);
  return f;
}

test('changing project while scope is pending cannot launch the old project', async () => {
  const f = writerFixture(); let done;
  f.context.invoke = async command => {
    f.calls.push({command});
    if (command === 'scope_mission') return new Promise(resolve => {done = resolve;});
    return {missionId: 'unexpected'};
  };
  const pending = f.context.startMission();
  f.context.state.selection.project = 'P:/another';
  done({spread: 'narrow'}); await pending;
  assert.equal(f.calls.some(call => call.command === 'start_mission'), false);
});

test('a previously offered scope action cannot send after the draft was changed', async () => {
  const f = writerFixture(); let actions;
  f.context.invoke = async command => {
    f.calls.push({command});
    return {spread: 'wide', options: [{label: 'A', prompt: 'Option A'}, {label: 'B', prompt: 'Option B'}]};
  };
  f.context.showScopeStrip = (_summary, choices) => {actions = choices;};
  await f.context.startMission();
  f.context.instructionInput.value = 'A different, unsent instruction';
  await actions[0].run();
  assert.equal(f.calls.some(call => call.command === 'start_mission'), false);
});

test('a late busy result cannot arm force in another project', async () => {
  const f = writerFixture(); let fail;
  f.context.invoke = () => new Promise((_resolve, reject) => {fail = reject;});
  f.context.state.forceNext = false;
  const pending = f.context.launchMission({...f.context.state.selection, force: false, prompt: 'original', composerDraft: f.context.instructionInput.value});
  f.context.state.selection.project = 'P:/another';
  fail(Error('AGENT_BUSY: old project busy')); await pending;
  assert.equal(f.context.state.forceNext, false);
  assert.match(f.context.instructionInput.value, /Separate unsent draft/);
});

test('catalog coverage uses request start, ignores stale responses and does not advance on failure', async () => {
  let now = 1_000; const pending = [];
  const context = {console, window: {}, Date: {now: () => now}, state: {catalog: null, catalogLoadedAt: 0}, CATALOG_MAX_AGE_MS: 60_000,
    invoke: () => new Promise((resolve, reject) => pending.push({resolve, reject})), renderAll() {}, canvasNote() {}};
  vm.createContext(context); vm.runInContext(fn(app, 'loadCatalog'), context);
  const older = context.loadCatalog(true);
  now = 2_000; const newer = context.loadCatalog(true);
  now = 3_000; pending[1].resolve({projects: [{path: 'new'}], recentMissionsTruncated: true}); await newer;
  assert.equal(context.state.catalogObservedAt, 2_000);
  assert.equal(context.state.catalog.recentMissionsTruncated, true);
  pending[0].resolve({projects: [{path: 'old'}]}); await older;
  assert.equal(context.state.catalog.projects[0].path, 'new');
  assert.equal(context.state.catalogObservedAt, 2_000);
  now = 4_000; const failed = context.loadCatalog(true);
  pending[2].reject(Error('unreadable')); await failed;
  assert.equal(context.state.catalogObservedAt, 2_000);
});
