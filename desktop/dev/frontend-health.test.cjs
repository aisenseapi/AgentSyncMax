// Executes the production functions in isolated fixtures; no CLI, model or
// native provider state is touched. Run with node --test.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = name => fs.readFileSync(path.join(__dirname, '..', 'src', name), 'utf8');
const app = source('app.js');
const control = source('control.js');
function fn(text, name) {
  const start = text.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.notEqual(start, -1, name);
  // Production top-level declarations close at column zero.
  const end = text.indexOf('\n}', start);
  assert.notEqual(end, -1, name);
  return text.slice(start, end + 2);
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function timers() {
  let id = 0;
  const pending = new Map();
  return {
    pending,
    setTimeout(callback, delay) { pending.set(++id, { callback, delay }); return id; },
    clearTimeout(timer) { pending.delete(timer); },
    requestAnimationFrame(callback) { pending.set(++id, { callback, delay: 0 }); return id; },
    flush() { const entries = [...pending]; pending.clear(); for (const [, item] of entries) item.callback(); },
  };
}
function streamFixture(invoke) {
  const clock = timers();
  const handlers = {};
  const document = { hidden: false, addEventListener(name, handler) { handlers[name] = handler; } };
  const window = { ...clock, __TAURI__: { core: { invoke } } };
  vm.runInNewContext(source('mission-status.js'), { window, document, console });
  return { api: window.AgentSyncStatus, clock, document, handlers };
}

test('one shared in-flight read serves multiple subscribers and refreshes', async () => {
  const gate = deferred();
  const calls = [];
  const f = streamFixture((command) => {
    calls.push(command);
    return command === 'get_mission_summaries' ? gate.promise : Promise.resolve({ enabled: false });
  });
  let first = 0, second = 0;
  const stop1 = f.api.subscribe(() => first++);
  const stop2 = f.api.subscribe(() => second++);
  const p1 = f.api.refresh(), p2 = f.api.refresh();
  assert.equal(p1, p2);
  assert.deepEqual(calls, ['get_mission_summaries', 'get_validator_control']);
  gate.resolve({ missions: [], history: [] });
  await p1;
  assert.equal(first, 1); assert.equal(second, 1);
  assert.equal(f.clock.pending.size, 1);
  stop1(); stop2();
  assert.equal(f.clock.pending.size, 0);
});

test('unsubscribe during pending status read cannot resurrect a timer', async () => {
  const gate = deferred();
  const f = streamFixture(() => gate.promise);
  const stop = f.api.subscribe(() => assert.fail('closed subscriber called'));
  const pending = f.api.refresh();
  stop();
  gate.resolve({ missions: [], history: [], enabled: false });
  await pending;
  assert.equal(f.clock.pending.size, 0);
});

test('hidden presentation slows idle reads but keeps V observation active', async () => {
  let enabled = false;
  const f = streamFixture(async command => command === 'get_validator_control' ? { enabled } : { missions: [], history: [] });
  f.document.hidden = true;
  const stop = f.api.subscribe(() => {});
  await f.api.refresh();
  assert.equal([...f.clock.pending.values()][0].delay, 10000);
  enabled = true;
  await f.api.refresh();
  assert.equal([...f.clock.pending.values()][0].delay, 2000);
  stop();
});

test('failed status reads preserve last snapshot but flag stale data', async () => {
  let fail = false;
  const f = streamFixture(async command => {
    if (fail && command === 'get_mission_summaries') throw new Error('offline fixture');
    return command === 'get_validator_control' ? { enabled: true } : { missions: [{ id: 'writer' }], history: [] };
  });
  await f.api.refresh(); fail = true;
  const latest = await f.api.refresh();
  assert.equal(latest.missions[0].id, 'writer');
  assert.match(latest.summariesError, /offline fixture/);
  assert.equal(f.clock.pending.size, 0);
});

test('model labels do not call requested or legacy identity observed', () => {
  const f = streamFixture(async () => ({}));
  assert.equal(f.api.modelLabel({ resolvedModel: 'model', modelSource: 'observed' }), 'model (observert)');
  assert.equal(f.api.modelLabel({ resolvedModel: 'model', modelSource: 'configured' }), 'model (konfigurert)');
  assert.equal(f.api.modelLabel({ model: 'model' }), 'model (ønsket)');
  assert.equal(f.api.modelLabel({ resolvedModel: 'legacy' }), 'legacy (ikke bekreftet)');
});

function controlLifecycleFixture() {
  const state = { open: false, lifecycle: 0, findingsRequest: 0, pendingSnapshot: null, unsubscribe: null };
  const reads = [], callbacks = [];
  let subscribed = 0, stopped = 0, boots = 0;
  const window = { AgentSyncStatus: { subscribe(callback) { subscribed++; callbacks.push(callback); return () => stopped++; } } };
  const context = vm.createContext({ state, window, hidePeek() {}, boot() { boots++; }, followMainWindow() {}, poll() {}, loadCatalog() {
    const d = deferred(); reads.push(d); return d.promise;
  } });
  const start = control.indexOf('let booted = false;');
  const end = control.indexOf('\nfunction refreshPresentation', start);
  vm.runInContext(control.slice(start, end), context);
  return { state, api: window.AgentSyncControl, reads, callbacks, counts: () => ({ subscribed, stopped, boots }) };
}
test('panel open/close during catalog read leaves no observer or timer', async () => {
  const f = controlLifecycleFixture();
  const pending = f.api.open();
  f.api.close();
  f.reads[0].resolve(); await pending;
  assert.deepEqual(f.counts(), { subscribed: 0, stopped: 0, boots: 1 });
  assert.equal(f.state.open, false);
});
test('older open completion cannot attach to reopened panel', async () => {
  const f = controlLifecycleFixture();
  const old = f.api.open(); f.api.close();
  const current = f.api.open();
  f.reads[1].resolve(); await current;
  f.reads[0].resolve(); await old;
  assert.equal(f.counts().subscribed, 1);
  f.api.close(); assert.equal(f.counts().stopped, 1);
});

test('control consumer serializes work and drops superseded snapshots', async () => {
  const state = { open: true, lifecycle: 1, pendingSnapshot: null, pollInFlight: null };
  const gate = deferred(), seen = [];
  const context = vm.createContext({ state, window: {}, consumeStatus: async snapshot => {
    seen.push(snapshot.sequence); if (snapshot.sequence === 1) await gate.promise;
  } });
  vm.runInContext(fn(control, 'poll'), context);
  const first = context.poll({ sequence: 1 });
  const second = context.poll({ sequence: 2 });
  context.poll({ sequence: 3 });
  assert.equal(first, second);
  gate.resolve(); await first;
  assert.deepEqual(seen, [1, 3]);
});

test('selected active control uses canvas delta buffer, not full session calls', async () => {
  const pane = { hidden: true, textContent: '', dataset: {}, scrollHeight: 100, scrollTop: 80, clientHeight: 20 };
  const state = { open: true, selectedRun: '', findingsRequest: 0, runs: [{ id: 'active', status: 'running' }] };
  const context = vm.createContext({ state, presentationVisible: () => true, clearFindingButtons() {}, renderRuns() {}, showDetailShell() {},
    byId: () => pane, invoke: () => assert.fail('active full session read'),
    window: { AgentSyncHost: { missionText: () => ({ finalOutput: 'Streamed answer' }) } } });
  vm.runInContext([fn(control, 'missionActive'), fn(control, 'updateSelectedText'), fn(control, 'showFindings')].join('\n'), context);
  await context.showFindings('active');
  assert.equal(pane.textContent, 'Streamed answer');
  assert.equal(pane.dataset.status, 'running');
  assert.equal(pane.scrollTop, 100);
});

test('stale summaries never authorize automatic validation', async () => {
  let controls = 0;
  const context = vm.createContext({ renderLive() {}, scheduleAutomaticValidation: async () => controls++ });
  vm.runInContext(fn(control, 'consumeStatus'), context);
  await context.consumeStatus({ summariesError: 'offline', runtime: { enabled: true } });
  assert.equal(controls, 0);
});

test('status chip refresh has one request pair and one timer', async () => {
  const clock = timers(), gate = deferred();
  const calls = [];
  const state = { statusInFlight: null, statusTimer: null };
  let renders = 0;
  const context = vm.createContext({ state, window: clock, document: { hidden: false }, STATUS_POLL_MS: 60000,
    invoke: command => { calls.push(command); return gate.promise; }, renderRail: () => renders++ });
  vm.runInContext(fn(app, 'loadStatusChips'), context);
  const first = context.loadStatusChips(), second = context.loadStatusChips();
  assert.equal(first, second);
  gate.resolve({ isRunning: true }); await first;
  assert.deepEqual(calls, ['get_agent_quotas', 'get_engine_health']);
  assert.equal(renders, 1); assert.equal(clock.pending.size, 1);
  await context.loadStatusChips();
  assert.equal(clock.pending.size, 1);
});

test('unchanged rail geometry does not restart long-name animation', () => {
  const clock = timers();
  let removed = 0, added = 0, clipHeight = 100;
  const label = { textContent: 'Long project name', getBoundingClientRect: () => ({ height: 180 }),
    classList: { remove() { removed++; }, add() { added++; } }, style: { removeProperty() {}, setProperty() {} } };
  const clip = { getBoundingClientRect: () => ({ height: clipHeight }) };
  const context = vm.createContext({ window: clock, document: { hidden: false }, byId: id => id === 'railLabelClip' ? clip : label });
  vm.runInContext('let railScrollFrame = null; let railScrollSignature = "";\n' + fn(app, 'updateRailScroll'), context);
  context.updateRailScroll(); clock.flush();
  context.updateRailScroll(); clock.flush();
  assert.equal(removed, 1); assert.equal(added, 1);
  clipHeight = 120; context.updateRailScroll(); clock.flush();
  assert.equal(removed, 2);
});

test('hidden Markdown waits and newest content renders once on return', () => {
  const clock = timers();
  let visible = false, renders = 0;
  const record = { finalRenderTimer: null, finalRenderedAt: 0, finalOutput: 'old' };
  const context = vm.createContext({ window: clock, MARKDOWN_RENDER_MS: 900, missionContentVisible: () => visible,
    patchMarkdownContent: item => { renders++; assert.equal(item.finalOutput, 'newest'); }, isAtBottom: () => false, afterCanvasChange() {} });
  vm.runInContext(fn(app, 'scheduleMarkdownRender'), context);
  context.scheduleMarkdownRender(record); record.finalOutput = 'newest'; context.scheduleMarkdownRender(record);
  assert.equal(renders, 0); assert.equal(clock.pending.size, 0); assert.equal(record.markdownDirty, true);
  visible = true; context.scheduleMarkdownRender(record, true);
  assert.equal(renders, 1); assert.equal(record.markdownDirty, false);
});

test('project switches retain unsaved and active records while releasing saved DOM', () => {
  let removed = 0;
  const node = () => ({ dataset: { projectPath: 'project' }, remove() { removed++; } });
  const records = [
    { id: 'saved', projectPath: 'project', finished: true, user: node(), agent: node() },
    { id: 'unsaved', projectPath: 'project', finished: true, persistenceError: 'disk full', user: node(), agent: node() },
    { id: 'active', projectPath: 'project', finished: false, user: node(), agent: node() },
  ];
  const state = { missions: new Map(records.map(r => [r.id, r])), historyLoaded: new Set(['project']) };
  const context = vm.createContext({ state, stream: { children: [] }, samePath: (a, b) => a === b, window: timers(), projectSetupKey: p => p });
  vm.runInContext(fn(app, 'releaseFinishedProjectView'), context);
  context.releaseFinishedProjectView('project');
  assert.deepEqual([...state.missions.keys()], ['unsaved', 'active']); assert.equal(removed, 2);
});

test('an actual project switch resets every project-bound surface once', () => {
  const calls = [];
  const state = { selection: { project: 'P:/old', agent: 'codex', model: 'old-model', level: 'max' }, setupMode: 'chosen', forceNext: true };
  const intentInput = { value: 'old wish', focus() { calls.push('focus'); } };
  const window = {
    AgentSyncPeek: { hide: options => calls.push(['peek', options]) },
    AgentSyncEvaluations: { close: () => calls.push('register') },
    AgentSyncKnowledgeReviews: { close: () => calls.push('knowledge') },
    AgentSyncControl: { projectChanged: project => calls.push(['validator', project]) },
  };
  const context = vm.createContext({
    state, window, intentInput,
    projectByPath: path => ({ path, name: 'New project' }),
    samePath: (left, right) => left.toLowerCase() === right.toLowerCase(),
    cancelResolving() { calls.push('cancel'); }, closeScopeStrip() {}, resetCanvasFocus() {},
    releaseFinishedProjectView() {}, restoreProjectSetup() {}, persistSelection() {}, closeBarInfo() {},
    refreshCanvasProjectVisibility() {}, updateProjectLabels() {}, renderProjectList() {}, renderTopBar() {},
    setDrawerOpen() {}, showProjectHistory() {},
  });
  vm.runInContext([fn(app, 'resetProjectBoundSurfaces'), fn(app, 'selectProject')].join('\n'), context);

  context.selectProject('P:/new');
  assert.deepEqual(JSON.parse(JSON.stringify(calls.filter(item => Array.isArray(item) || ['register', 'knowledge'].includes(item)))), [
    ['peek', { force: true }], 'register', 'knowledge', ['validator', 'P:/new'],
  ]);
  assert.equal(state.selection.project, 'P:/new');
  assert.equal(state.selection.agent, '');
  assert.equal(intentInput.value, '');

  calls.length = 0;
  context.selectProject('p:/NEW');
  assert.equal(calls.some(item => Array.isArray(item) || ['register', 'knowledge'].includes(item)), false,
    'choosing the current project again must not dismiss the surfaces');
});

test('losing a project from the catalog crosses the same popup boundary', () => {
  const calls = [];
  const state = { selection: { project: 'P:/gone', agent: 'codex', model: 'model', level: 'max' }, setupMode: 'chosen', forceNext: true };
  const context = vm.createContext({
    state, intentInput: { value: 'old wish' },
    cancelResolving() { calls.push('cancel'); }, closeScopeStrip() {}, resetCanvasFocus() {}, releaseFinishedProjectView() {},
    persistSelection() { calls.push('persist'); }, resetProjectBoundSurfaces: project => calls.push(['reset', project]),
    closeBarInfo() {}, refreshCanvasProjectVisibility() {},
  });
  vm.runInContext(fn(app, 'clearSelectedProject'), context);
  context.clearSelectedProject();
  assert.deepEqual(JSON.parse(JSON.stringify(state.selection)), { project: '', agent: '', model: '', level: '' });
  assert.equal(state.setupMode, 'idle');
  assert.equal(state.forceNext, false);
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), ['cancel', 'persist', ['reset', '']]);
  assert.match(fn(app, 'renderAll'), /clearSelectedProject\(\)/);
  assert.match(fn(app, 'startMission'), /clearSelectedProject\(\)/);
});

test('the validator clears the old project immediately and keeps drafts per project', () => {
  const prompt = { value: 'draft for old' };
  const calls = [];
  const state = {
    project: 'P:/old', selectedRun: 'old-run', runs: [{id: 'old-run'}], runsSignature: 'old',
    activeWriter: {id: 'writer'}, agent: 'old-agent', model: 'old-model', writerSetupSignature: 'old',
    findingsRequest: 0, open: true,
  };
  const context = vm.createContext({
    state, booted: true,
    plainPath: value => String(value || ''),
    samePath: (left, right) => left.toLowerCase() === right.toLowerCase(),
    hidePeek: () => calls.push('peek'),
    byId: id => id === 'controlPrompt' ? prompt : {},
    loadStartedRuns: () => calls.push('started'),
    closeRunDetail: () => calls.push('detail'), setStatus: () => calls.push('status'),
    chooseValidatorSetup: () => { state.agent = 'new-agent'; state.model = 'new-model'; calls.push('setup'); },
    renderProject: () => calls.push('project'), renderWriter: () => {}, renderAgents: () => {}, renderModels: () => {},
    renderRuns: () => calls.push('runs'), renderLive: () => {}, syncRunButton: () => {}, loadCatalog: () => calls.push('catalog'),
  });
  vm.runInContext(fn(control, 'changeVisibleProject'), context);

  assert.equal(context.changeVisibleProject('P:/new'), true);
  assert.equal(state.project, 'P:/new');
  assert.equal(state.selectedRun, '');
  assert.equal(state.runs.length, 0);
  assert.equal(prompt.value, '');
  assert.deepEqual(calls, ['peek', 'started', 'detail', 'status', 'setup', 'project', 'runs', 'catalog']);

  prompt.value = 'draft for new';
  calls.length = 0;
  assert.equal(context.changeVisibleProject('P:/old'), true);
  assert.equal(prompt.value, 'draft for old');
  assert.equal(context.changeVisibleProject('p:/OLD'), false);
});

test('quota buttons keep identity and focus on unchanged status', () => {
  const nodes = new Map();
  const document = { activeElement: null };
  function node() {
    return { children: [], dataset: {}, style: {}, classList: { toggle() {} },
      setAttribute() {}, append(...items) { this.children.push(...items); }, replaceChildren() { this.children = []; },
      contains(item) { return this.children.includes(item); }, focus() { document.activeElement = this; } };
  }
  const byId = id => { if (!nodes.has(id)) nodes.set(id, node()); return nodes.get(id); };
  const state = { selection: { agent: 'codex', project: 'fixture' }, quotas: [{ agent: 'codex', label: 'Codex', windows: [{ usedPercent: 20, name: 'hour' }] }],
    railQuotaSignature: '', validator: { enabled: false, activeControls: 0, changing: false } };
  const context = vm.createContext({ state, window: {}, document, byId, element: () => node(), activeMissionsForProject: () => [],
    agentMark: () => 'C', agentLabel: () => 'Codex', quotaTone: () => 'green', updateRailScroll() {},
    tip: (node) => node, projectByPath: () => null, formatDuration: () => '1 min' });
  vm.runInContext(fn(app, 'renderRail'), context);
  context.renderRail();
  const original = byId('railQuotas').children[0]; original.focus();
  context.renderRail();
  assert.equal(byId('railQuotas').children[0], original);
  assert.equal(document.activeElement, original);
  state.quotas[0].windows[0].usedPercent = 21;
  context.renderRail();
  assert.notEqual(byId('railQuotas').children[0], original);
  assert.equal(document.activeElement, byId('railQuotas').children[0]);
});

test('Ollama Cloud quota details keep the measured window and best-effort source explicit', () => {
  let message = '';
  const state = { quotas: [{
    agent: 'ollama', label: 'Ollama Cloud',
    windows: [{ name: 'uke', usedPercent: 42.7, windowMinutes: null, resetsAtUnix: null }],
    observedUnixMs: 1234, source: 'ollama-cloud-api',
    status: 'measured',
    note: 'Best-effort: Ollamas kvoterute er foreløpig ikke dokumentert.'
  }] };
  const context = vm.createContext({
    state,
    agentMark: agent => agent === 'ollama' ? 'OL' : '?',
    describeWindow: () => '',
    formatCompactDate: value => value,
    formatDuration: () => '',
    clock: () => 'nå',
    showBarInfo: value => { message = value; },
    Date,
  });
  vm.runInContext(fn(app, 'showQuotaInfo'), context);
  context.showQuotaInfo(0, 0);
  assert.match(message, /OL Ollama Cloud: 43 % brukt av uke-kvoten/);
  assert.match(message, /ikke dokumentert/);
  assert.match(message, /Ollama Cloud-konto via OpenCode-nøkkelen/);
  assert.match(app, /ollama: "OL"/);
});

test('Ollama Cloud monthly usage is shown as money rather than a guessed percent', () => {
  let message = '';
  const state = { quotas: [{
    agent: 'ollama', label: 'Ollama Cloud',
    windows: [{ name: 'måned', usedPercent: null, usedAmount: 12.5, amountUnit: 'USD', windowMinutes: null, resetsAtUnix: null }],
    observedUnixMs: 1234, source: 'ollama-cloud-api', status: 'measured',
    note: 'Best-effort: kontoruten kan endres.'
  }] };
  const context = vm.createContext({
    state, agentMark: () => 'OL', describeWindow: () => '', formatCompactDate: value => value,
    formatDuration: () => '', clock: () => 'nå', showBarInfo: value => { message = value; }, Date,
  });
  vm.runInContext(fn(app, 'showQuotaInfo'), context);
  context.showQuotaInfo(0, 0);
  assert.match(message, /12,50 USD brukt i måned/);
  assert.match(message, /grensen er ikke oppgitt av Ollama/);
  assert.doesNotMatch(message, /12 %/);
});

test('Ollama Cloud unavailable and stale states remain visible and explicit', () => {
  let message = '';
  const state = { quotas: [{
    agent: 'ollama', label: 'Ollama Cloud', windows: [], observedUnixMs: 1234,
    source: 'ollama-cloud-api', status: 'unavailable', note: 'Kvoten er utilgjengelig.'
  }] };
  const context = vm.createContext({
    state, agentMark: () => 'OL', describeWindow: () => '', formatCompactDate: value => value,
    formatDuration: () => '', clock: () => 'nå', showBarInfo: value => { message = value; }, Date,
  });
  vm.runInContext(fn(app, 'showQuotaInfo'), context);
  context.showQuotaInfo(0, -1);
  assert.match(message, /OL Ollama Cloud: Kvoten er utilgjengelig/);

  state.quotas[0] = {
    ...state.quotas[0], status: 'stale',
    windows: [{ name: 'uke', usedPercent: 42.7, usedAmount: null, amountUnit: null }],
    note: 'Oppdateringen feilet. Viser siste måling.'
  };
  context.showQuotaInfo(0, 0);
  assert.match(message, /eldre måling, siste oppdatering feilet/);
  assert.match(message, /Viser siste måling/);
});

test('quota rail distinguishes Cloud unavailable, low monthly spend, and local unlimited', () => {
  const nodes = new Map();
  const document = { activeElement: null };
  function node() {
    return { children: [], dataset: {}, style: {}, classList: { toggle() {} },
      setAttribute() {}, append(...items) { this.children.push(...items); }, replaceChildren() { this.children = []; },
      contains(item) { return this.children.includes(item); }, focus() { document.activeElement = this; } };
  }
  const byId = id => { if (!nodes.has(id)) nodes.set(id, node()); return nodes.get(id); };
  const element = (_tag, className = '', textContent = '') => Object.assign(node(), { className, textContent });
  const state = {
    selection: { agent: '', project: '' }, railQuotaSignature: '',
    validator: { enabled: false, activeControls: 0, changing: false },
    quotas: [
      { agent: 'ollama', label: 'Ollama Cloud', windows: [], status: 'unavailable', source: 'ollama-cloud-api', note: 'Kvoten er utilgjengelig.' },
      { agent: 'ollama', label: 'Ollama Cloud', windows: [{ name: 'måned', usedPercent: null, usedAmount: 0.42, amountUnit: 'USD' }], status: 'measured', source: 'ollama-cloud-api' },
      { agent: 'aider', label: 'Aider (Spark)', windows: [], status: 'unlimited', source: 'local', note: 'ingen kvote' },
    ]
  };
  const context = vm.createContext({
    state, window: {}, document, byId, element, activeMissionsForProject: () => [],
    agentMark: agent => agent === 'ollama' ? 'OL' : 'ai', agentLabel: value => value,
    quotaTone: () => 'green', updateRailScroll() {}, tip: value => value,
  });
  vm.runInContext(fn(app, 'renderRail'), context);
  context.renderRail();
  const rows = byId('railQuotas').children;
  assert.equal(rows[0].children[0].textContent, 'OL ?');
  assert.equal(rows[1].children[0].textContent, 'OL $0.42');
  assert.equal(rows[2].children[0].textContent, 'ai ∞');
});

test('streaming Markdown preserves unchanged leading DOM blocks', () => {
  const children = [];
  let parses = 0;
  const block = value => ({ value, isEqualNode(other) { return this.value === other.value; }, remove() { children.splice(children.indexOf(this), 1); } });
  const text = { childNodes: children, append(...nodes) { children.push(...nodes); } };
  const document = { createElement() { return { content: { childNodes: [] }, set innerHTML(html) { this.content.childNodes = html.split('|').map(block); } }; } };
  const context = vm.createContext({ document, markdownToHtml: value => { parses++; return value; } });
  vm.runInContext(fn(app, 'patchMarkdownContent'), context);
  const record = { finalOutput: 'first|unfinished', text };
  context.patchMarkdownContent(record);
  const leading = children[0], oldTail = children[1];
  record.finalOutput = 'first|finished|next'; context.patchMarkdownContent(record);
  assert.equal(children[0], leading); assert.notEqual(children[1], oldTail);
  assert.deepEqual(children.map(n => n.value), ['first', 'finished', 'next']);
  const stable = [...children]; context.patchMarkdownContent(record);
  assert.deepEqual(children, stable); assert.equal(parses, 3);
});

test('older project history pages only summaries and keeps exact project boundary', async () => {
  const calls = [], nodes = [];
  let click, offset = 12;
  const button = { dataset: {}, isConnected: true, addEventListener(name, callback) { click = callback; }, remove() { this.removed = true; } };
  const context = vm.createContext({
    state: { selection: { project: 'fixture' } }, element: () => button, tagProjectNode: node => node,
    samePath: (a, b) => a === b, canvasNote() {}, refreshCanvasProjectVisibility() {},
    missionReopenLink: summary => ({ id: summary.id }),
    document: { createDocumentFragment: () => ({ items: [], append(item) { this.items.push(item); } }) },
    stream: { children: [], insertBefore(fragment) { nodes.push(...fragment.items); } },
    invoke: async (command, args) => {
      calls.push(command); assert.equal(args.request.projectPath, 'fixture'); assert.equal(args.request.offset, offset);
      offset += 2;
      return { history: [{ id: `old-${offset}`, projectPath: 'fixture', status: 'completed' }, { id: 'foreign', projectPath: 'different' }], hasMore: calls.length === 1 };
    },
  });
  vm.runInContext(fn(app, 'olderHistoryButton'), context);
  context.olderHistoryButton('fixture', 12);
  await click(); await click();
  assert.deepEqual(calls, ['get_mission_summaries', 'get_mission_summaries']);
  assert.equal(nodes.length, 2); assert.equal(button.removed, true);
});

test('revealing a completed hidden activity burst lays out once, not per line', () => {
  let lines = 0, layouts = 0;
  const record = { pendingActivity: Array.from({ length: 1000 }, (_, i) => ({ line: String(i), startedUnixMs: 1 })) };
  const context = vm.createContext({ state: { missions: new Map([['run', record]]) }, missionContentVisible: () => true,
    appendActivity(item) { lines++; if (!item.deferActivityLayout) layouts++; }, layoutActivity: () => layouts++,
    renderErrors() {}, scheduleMarkdownRender() {},
  });
  vm.runInContext(fn(app, 'flushVisibleMissionContent'), context);
  context.flushVisibleMissionContent();
  assert.equal(lines, 1000); assert.equal(layouts, 1); assert.equal(record.pendingActivity.length, 0);
});

test('focus keeps validator association after source DOM is compacted', () => {
  const source = { agentId: 'codex' };
  const validator = { agentId: 'claude', purpose: 'validator', sourceMissionId: 'writer' };
  const state = { missions: new Map([['writer', source], ['check', validator]]), activeMissions: [] };
  const context = vm.createContext({ state });
  vm.runInContext(fn(app, 'nodeBelongsToFocusedAgent'), context);
  const node = { dataset: { mission: 'check' } };
  assert.equal(context.nodeBelongsToFocusedAgent(node, 'codex'), true);
  state.missions.delete('writer');
  assert.equal(context.nodeBelongsToFocusedAgent(node, 'codex'), true);
  assert.equal(context.nodeBelongsToFocusedAgent(node, 'claude'), false);
  state.missions.delete('check');
  node.dataset.purpose = 'validator'; node.dataset.sourceAgent = 'codex';
  assert.equal(context.nodeBelongsToFocusedAgent(node, 'codex'), true);
});
