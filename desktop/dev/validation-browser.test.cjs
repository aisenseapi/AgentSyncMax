// The validation browser is exercised as a reader, not as disconnected style
// fragments: informative rows, an in-place detail pane and no historical
// resolver storm when the panel opens.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = name => fs.readFileSync(path.join(__dirname, '..', 'src', name), 'utf8');
const control = source('control.js');
const app = source('app.js');

function sourceFn(code, name) {
  const start = code.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.notEqual(start, -1, name);
  const end = code.indexOf('\n}', start);
  assert.notEqual(end, -1, name);
  return code.slice(start, end + 2);
}

const fn = name => sourceFn(control, name);
const appFn = name => sourceFn(app, name);

class Element {
  constructor(tag = 'div') {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.dataset = {};
    this.attributes = {};
    this.events = {};
    this.className = '';
    this.hidden = false;
    this.open = false;
    this.scrollTop = 0;
    this._text = '';
    this.classList = {
      add: (...names) => { this.className = [...new Set([...this.className.split(' ').filter(Boolean), ...names])].join(' '); },
      remove: (...names) => { this.className = this.className.split(' ').filter(name => !names.includes(name)).join(' '); },
      contains: name => this.className.split(' ').includes(name),
    };
  }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
  set textContent(value) { this._text = String(value); this.children = []; }
  append(...nodes) { for (const node of nodes) { if (typeof node === 'string') this._text += node; else this.children.push(node); } }
  replaceChildren(...nodes) { this.children = []; this._text = ''; this.append(...nodes); }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  addEventListener(key, handler) { this.events[key] = handler; }
  contains(node) { return node === this || this.children.some(child => child.contains(node)); }
  matches(selector) {
    if (selector === '[data-mission]') return Boolean(this.dataset.mission);
    if (selector.startsWith('.')) return this.classList.contains(selector.slice(1));
    return this.tagName.toLowerCase() === selector;
  }
  querySelectorAll(selector) {
    const found = [];
    const visit = node => { for (const child of node.children) { if (child.matches(selector)) found.push(child); visit(child); } };
    visit(this);
    return found;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  focus() { this.focused = true; }
}

function element(tag, className = '', text) {
  const node = new Element(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

test('list and selected validation share one responsive browser', () => {
  const html = source('index.html');
  const css = source('styles.css');
  assert.match(html, /id="controlBrowser"[\s\S]*id="controlList"[\s\S]*id="controlDetail"[\s\S]*id="controlVerdict"[\s\S]*id="controlFindingList"/);
  assert.match(html, /id="controlRawDetails"[\s\S]*id="controlFindings"/);
  assert.match(css, /\.control-browser\.has-selection \.control-run-pane \{ display: none; \}/);
  assert.match(css, /@container validator \(min-width: 680px\)/);
  assert.match(css, /grid-template-columns: minmax\(230px, 36%\) minmax\(340px, 64%\)/);
});

test('folded validation panel keeps intrinsic width outside size containment', () => {
  const css = source('styles.css');
  const panelRule = css.match(/\.control-panel\s*\{([^}]*)\}/)?.[1] || '';
  const foldedRule = css.match(/\.control-panel\.minimized\s*\{([^}]*)\}/)?.[1] || '';
  const bodyRule = css.match(/(?:^|\n)\.control-panel-body\s*\{([^}]*)\}/)?.[1] || '';
  assert.match(foldedRule, /width:\s*max-content/);
  assert.doesNotMatch(panelRule, /container-type:\s*inline-size/,
    'inline-size containment collapses the folded panel max-content width to its border');
  assert.match(bodyRule, /container-type:\s*inline-size/,
    'the body remains the responsive query container while the title bar sizes normally');
});

test('folded validation panel has a four-way move handle with separate open semantics', () => {
  const html = source('index.html');
  const css = source('styles.css');
  assert.match(html, /id="controlPanelMove"[\s\S]*class="control-panel-move-icon"[\s\S]*M12 2v20M2 12h20/);
  assert.match(html, /id="controlPanelMinimize"[\s\S]*aria-controls="controlPanel"/);
  assert.match(css, /\.control-panel\.minimized \.control-panel-move \{ display: flex; \}/);
  assert.match(css, /\.control-panel-move \{[^}]*cursor: move/);
  assert.doesNotMatch(app, /controlPanelBar"\)\.addEventListener\("dblclick"/,
    'double click must not reopen and immediately fold the panel again');
});

test('moving the folded validation panel never opens it, while the rest of the bar does', () => {
  const panel = new Element('section');
  panel.classList.add('minimized');
  panel.style = { left: '40px', top: '50px' };
  const handlers = {};
  const bar = {
    captured: false,
    setPointerCapture() { this.captured = true; },
    hasPointerCapture() { return this.captured; },
    releasePointerCapture() { this.captured = false; },
    addEventListener(name, handler) { handlers[name] = handler; },
    removeEventListener(name) { delete handlers[name]; },
  };
  const target = kind => ({
    closest(selector) {
      if (selector === '#controlPanelMove') return kind === 'move' ? this : null;
      if (selector === '#controlPanelClose') return kind === 'close' ? this : null;
      if (selector === 'button') return ['move', 'close'].includes(kind) ? this : null;
      return null;
    }
  });
  let minimizedCalls = 0;
  let timer = null;
  const context = vm.createContext({
    controlPanelSuppressOpenClick: false,
    byId: id => id === 'controlPanel' ? panel : null,
    controlPanelBounds: () => ({ stage: { width: 1000, height: 700 }, width: 180, height: 32 }),
    viewportPerLayoutPixel: () => 1,
    placeControlPanel: (left, top) => { panel.style.left = `${left}px`; panel.style.top = `${top}px`; },
    writePreference() {}, controlPanelPositionKey: () => 'position',
    setControlPanelMinimized: () => { minimizedCalls += 1; },
    window: { setTimeout(callback) { timer = callback; } },
    Math, JSON, parseFloat,
  });
  vm.runInContext(`${appFn('beginControlPanelDrag')}\n${appFn('handleControlPanelBarClick')}`, context);

  context.beginControlPanelDrag({ button: 0, target: target('move'), currentTarget: bar, pointerId: 7, clientX: 100, clientY: 100 });
  handlers.pointermove({ clientX: 125, clientY: 112 });
  handlers.pointerup();
  assert.equal(panel.style.left, '65px');
  assert.equal(panel.style.top, '62px');
  assert.equal(context.controlPanelSuppressOpenClick, true);

  let prevented = 0;
  context.handleControlPanelBarClick({
    target: target('title'), preventDefault() { prevented += 1; }, stopPropagation() {},
  });
  assert.equal(prevented, 1, 'the synthetic post-drag click is consumed');
  assert.equal(minimizedCalls, 0, 'dragging never unfolds the panel');

  timer?.();
  context.handleControlPanelBarClick({ target: target('move'), preventDefault() {}, stopPropagation() {} });
  context.handleControlPanelBarClick({ target: target('close'), preventDefault() {}, stopPropagation() {} });
  assert.equal(minimizedCalls, 0, 'move and close remain explicit exceptions');

  context.handleControlPanelBarClick({ target: target('title'), preventDefault() {}, stopPropagation() {} });
  assert.equal(minimizedCalls, 1, 'a deliberate click on the rest of the folded bar opens it');

  const before = { ...panel.style };
  context.beginControlPanelDrag({ button: 0, target: target('move'), currentTarget: bar, pointerId: 8, clientX: 200, clientY: 200 });
  handlers.pointermove({ clientX: 202, clientY: 201 });
  handlers.pointerup();
  assert.deepEqual(panel.style, before, 'sub-threshold movement is still a click, not a move');
  const callsBeforeRetarget = minimizedCalls;
  context.handleControlPanelBarClick({ target: target('title'), preventDefault() {}, stopPropagation() {} });
  assert.equal(minimizedCalls, callsBeforeRetarget, 'even a captured handle click cannot retarget into open');
});

test('the folded move handle supports precise keyboard movement without opening the panel', () => {
  const panel = new Element('section');
  panel.classList.add('minimized');
  panel.style = { left: '40px', top: '50px' };
  const placements = [];
  const context = vm.createContext({
    byId: id => id === 'controlPanel' ? panel : null,
    placeControlPanel(left, top) {
      placements.push([left, top]);
      panel.style.left = `${left}px`;
      panel.style.top = `${top}px`;
    },
    parseFloat,
  });
  vm.runInContext(appFn('handleControlPanelMoveKeydown'), context);

  let prevented = 0;
  let stopped = 0;
  context.handleControlPanelMoveKeydown({
    key: 'ArrowRight', shiftKey: false,
    preventDefault() { prevented += 1; },
    stopPropagation() { stopped += 1; },
  });
  context.handleControlPanelMoveKeydown({
    key: 'ArrowDown', shiftKey: true,
    preventDefault() { prevented += 1; },
    stopPropagation() { stopped += 1; },
  });
  assert.deepEqual(placements, [[48, 50], [48, 82]]);
  assert.equal(prevented, 2);
  assert.equal(stopped, 2);

  context.handleControlPanelMoveKeydown({ key: 'Enter', shiftKey: false });
  panel.classList.remove('minimized');
  context.handleControlPanelMoveKeydown({ key: 'ArrowLeft', shiftKey: false });
  assert.equal(placements.length, 2, 'unrelated keys and an expanded panel do not move it');
});

test('validation rows say what differs without opening every report', () => {
  const host = new Element('div');
  const state = {
    selectedRun: 'check-1',
    runsSignature: '',
    findings: new Map(),
    missionsById: new Map([['writer-1', { prompt: 'Kontroller betalingsrutingen før produksjon' }]]),
    runs: [
      { id: 'check-1', agent: 'opencode', agentLabel: 'OpenCode', status: 'completed', mode: 'blind', purpose: 'validator', sourceMissionId: 'writer-1', startedUnixMs: 1,
        validationDigest: { outcome: 'findings', count: 4, topSeverity: 'hoy', topTitle: 'DDL-guard mangler', topFile: 'functions.blk' } },
      { id: 'check-2', agent: 'codex', agentLabel: 'Codex', status: 'completed', mode: 'shared', purpose: 'manualControl', prompt: 'Les testdekningen', startedUnixMs: 2,
        validationDigest: { outcome: 'clean', count: 0 } },
    ],
  };
  const context = vm.createContext({
    state, element, byId: id => id === 'controlList' ? host : null,
    AGENT_MARKS: { opencode: 'OC', codex: 'CX' },
    presentationVisible: () => true,
    missionActive: run => ['queued', 'running'].includes(run?.status),
    missionPurpose: run => run?.purpose || 'writer',
    runStatus: run => run.status,
    agentLabel: value => value,
    formatTime: value => `tid-${value}`,
    showFindings() {},
    document: { activeElement: null },
    window: { AgentSyncStatus: { modelLabel: () => 'modell-x' } },
  });
  vm.runInContext([
    fn('compactSubject'), fn('runSubject'), fn('severityRank'), fn('digestFromReport'),
    fn('runDigest'), fn('runPresentation'), fn('renderRuns'),
  ].join('\n'), context);
  context.renderRuns(true);

  assert.equal(host.children.length, 2);
  assert.match(host.children[0].textContent, /DDL-guard mangler/);
  assert.match(host.children[0].textContent, /4 funn · høy/);
  assert.match(host.children[0].textContent, /Kontroller betalingsrutingen/);
  assert.match(host.children[0].textContent, /functions\.blk/);
  assert.match(host.children[1].textContent, /Ingen konkrete funn/);
  assert.equal(host.children[0].attributes['aria-current'], 'true');
});

test('a click exposes the detail shell before the session read completes', async () => {
  let resolveSession;
  const session = new Promise(resolve => { resolveSession = resolve; });
  const registry = Object.fromEntries([
    'controlBrowser', 'controlDetail', 'controlDetailTitle', 'controlDetailMeta',
    'controlRawDetails', 'controlRawSummary', 'controlDetailScroll', 'controlFindings',
  ].map(id => [id, new Element(id === 'controlRawDetails' ? 'details' : 'div')]));
  const run = { id: 'check-1', agent: 'codex', agentLabel: 'Codex', status: 'completed', mode: 'blind', purpose: 'validator', prompt: 'Finn regresjonen', startedUnixMs: 1 };
  const state = { open: true, selectedRun: '', findingsRequest: 0, runs: [run], sessionReads: new Map(), findings: new Map(), missionsById: new Map() };
  const context = vm.createContext({
    state, byId: id => registry[id], element,
    presentationVisible: () => true,
    missionActive: () => false,
    missionPurpose: item => item?.purpose,
    runPresentation: () => ({ kind: 'unread', title: 'Resultatet er ikke lest ennå', badge: 'Åpne resultat' }),
    detailMeta: () => 'Codex · blind', runSubject: () => 'Finn regresjonen',
    clearFindingButtons() {}, renderRuns() {}, loadFindings() {},
    invoke: command => command === 'get_mission_session' ? session : Promise.reject(new Error(command)),
  });
  vm.runInContext([fn('showDetailShell'), fn('showFindings')].join('\n'), context);
  const pending = context.showFindings('check-1');
  assert.equal(registry.controlDetail.hidden, false);
  assert.equal(registry.controlBrowser.classList.contains('has-selection'), true);
  assert.equal(registry.controlFindings.textContent, 'Henter…');
  resolveSession({ id: 'check-1', status: 'completed', finalOutput: 'Ferdig rapport' });
  await pending;
  assert.equal(registry.controlFindings.textContent, 'Ferdig rapport');
});

test('historical completions stay still; only running to completed may surface', async () => {
  const shown = [];
  const pane = { dataset: {} };
  const state = {
    project: 'P:/project', open: true, enabled: true, selectedRun: '', runs: [], started: new Set(),
    missionsById: new Map(), runStatuses: new Map(), launchedRuns: new Set(), statusReady: false,
    writerStates: new Map(), pendingSources: new Map(), autoMissionIds: new Map(), shownFindings: new Set(),
    observedAt: 1, presentationDirty: false,
  };
  const context = vm.createContext({
    state, samePath: (a, b) => a === b, missionPurpose: run => run?.purpose,
    missionActive: run => ['queued', 'running'].includes(run?.status),
    renderRuns() {}, byId: () => pane, updateSelectedText() {}, closeRunDetail() {},
    showFindings: id => shown.push(id), presentationVisible: () => true,
    scheduleAutomaticValidation: async () => {}, renderLive() {},
    window: { AgentSyncSettings: { enabled: () => true, used() {} } },
  });
  vm.runInContext(fn('consumeStatus'), context);
  const row = status => ({ id: 'check', projectPath: 'P:/project', purpose: 'validator', status, startedUnixMs: 10 });
  await context.consumeStatus({ runtime: { enabled: true }, missions: [], history: [row('completed')] });
  assert.deepEqual(shown, [], 'old history must not open or resolve itself');
  await context.consumeStatus({ runtime: { enabled: true }, missions: [row('running')], history: [] });
  await context.consumeStatus({ runtime: { enabled: true }, missions: [], history: [row('completed')] });
  assert.deepEqual(shown, ['check']);
});

test('unchanged validator runtime repairs a missing panel presentation', () => {
  const panel = new Element('section');
  panel.hidden = true;
  const state = {
    validator: { enabled: true, generation: 7, activeControls: 0, changing: false },
  };
  let syncs = 0;
  let settingsRenders = 0;
  let railRenders = 0;
  const context = vm.createContext({
    state,
    invoke() {},
    byId: id => id === 'controlPanel' ? panel : null,
    syncControlPanel: () => { syncs += 1; },
    renderSettings: () => { settingsRenders += 1; },
    renderRail: () => { railRenders += 1; },
    document: { hidden: false },
  });
  vm.runInContext(appFn('readValidatorControl'), context);

  context.readValidatorControl({ runtime: { enabled: true, generation: 7, activeControls: 0 } });
  assert.equal(syncs, 1, 'enabled runtime must repair a hidden panel');
  assert.equal(settingsRenders, 0, 'presentation repair does not redraw unchanged settings');
  assert.equal(railRenders, 0, 'presentation repair does not redraw unchanged rail state');

  panel.hidden = false;
  context.readValidatorControl({ runtime: { enabled: true, generation: 7, activeControls: 0 } });
  assert.equal(syncs, 1, 'an already consistent presentation stays still');
});

test('unchanged disabled validator hides a stray visible panel', () => {
  const panel = new Element('section');
  panel.hidden = false;
  const state = {
    validator: { enabled: false, generation: 3, activeControls: 0, changing: false },
  };
  let syncs = 0;
  const context = vm.createContext({
    state,
    invoke() {},
    byId: id => id === 'controlPanel' ? panel : null,
    syncControlPanel: () => { syncs += 1; },
    renderSettings() {},
    renderRail() {},
    document: { hidden: false },
  });
  vm.runInContext(appFn('readValidatorControl'), context);

  context.readValidatorControl({ runtime: { enabled: false, generation: 3, activeControls: 0 } });
  assert.equal(syncs, 1, 'disabled runtime must hide a stray visible panel');
});

test('an explicit V-on requests a fully expanded panel presentation', async () => {
  const presentations = [];
  const state = {
    selection: { project: 'P:/project' },
    validator: { enabled: false, generation: 0, activeControls: 0, changing: false },
  };
  const context = vm.createContext({
    state,
    invoke: async (_command, { enabled }) => ({ enabled, generation: 1, activeControls: 0 }),
    projectByPath: () => ({}),
    renderRail() {},
    renderSettings() {},
    syncControlPanel: options => presentations.push(options),
    showBarInfo() {},
    ensurePolling() {},
    canvasNote() {},
    window: { AgentSyncSettings: { own: () => true }, AgentSyncStatus: { refresh() {} } },
  });
  vm.runInContext(appFn('setValidatorEnabled'), context);

  await context.setValidatorEnabled(true);

  assert.equal(presentations.length, 1);
  assert.equal(presentations[0].forceExpanded, true,
    'turning V on must not restore an old minimized preference');
});

test('V brings an already enabled panel in front of K before offering to switch off', async () => {
  const panel = new Element('section');
  panel.hidden = false;
  const state = { validator: { enabled: true } };
  let knowledgeFront = true;
  let minimized = null;
  let restored = 0;
  let switched = 0;
  const context = vm.createContext({
    state,
    byId: id => id === 'controlPanel' ? panel : null,
    window: { AgentSyncKnowledgeReviews: {
      isFront: () => knowledgeFront,
      sendToBack: () => { knowledgeFront = false; },
    } },
    setControlPanelMinimized: value => { minimized = value; },
    restoreControlPanelPosition: () => { restored += 1; },
    setValidatorEnabled: async () => { switched += 1; },
  });
  vm.runInContext(appFn('handleValidatorRailClick'), context);

  await context.handleValidatorRailClick();
  assert.equal(knowledgeFront, false);
  assert.equal(minimized, false);
  assert.equal(restored, 1);
  assert.equal(switched, 0, 'the reveal click must not disable a running validator');

  await context.handleValidatorRailClick();
  assert.equal(switched, 1, 'the next V click keeps its established on/off meaning');
});

test('an explicit validator presentation lowers an open K surface', async () => {
  const panel = new Element('section');
  panel.hidden = false;
  let sentBack = 0;
  let minimized = null;
  const context = vm.createContext({
    byId: id => id === 'controlPanel' ? panel : null,
    window: { AgentSyncKnowledgeReviews: { sendToBack: () => { sentBack += 1; } } },
    setControlPanelMinimized: value => { minimized = value; },
    restoreControlPanelPosition() {},
  });
  vm.runInContext(appFn('showControlPanel'), context);

  await context.showControlPanel({ forceExpanded: true });
  assert.equal(sentBack, 1);
  assert.equal(minimized, false);
});

test('saved control-panel positions are clamped into the current stage', () => {
  const context = vm.createContext({
    CONTROL_PANEL_MARGIN: 8,
    controlPanelBounds: () => ({ stage: { width: 1000, height: 700 }, width: 560, height: 500 }),
  });
  vm.runInContext(appFn('clampPanelPosition'), context);

  const before = context.clampPanelPosition(-9000, -4000);
  const after = context.clampPanelPosition(9000, 4000);
  assert.equal(before.left, 8);
  assert.equal(before.top, 8);
  assert.equal(after.left, 432);
  assert.equal(after.top, 192);
});
