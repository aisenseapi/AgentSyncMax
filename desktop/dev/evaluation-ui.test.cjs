// A deliberately small DOM fixture executes the actual register module.
// It checks allocation/lifecycle and draft semantics, not browser layout speed.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../src/evaluation.js'), 'utf8');

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

function fixture(count = 1000) {
  let created = 0;
  let body;
  const listeners = new Map();
  const project = 'P:/test';
  class Element {
    constructor(tag) {
      created++;
      this.tagName = tag.toUpperCase(); this.children = []; this.dataset = {};
      this.attributes = {}; this.events = {}; this.className = ''; this.textContent = '';
      this.value = ''; this.disabled = false; this.open = false; this.parent = null;
      this.classList = {
        add: (...names) => { this.className = [...new Set([...this.className.split(' '), ...names])].join(' ').trim(); },
        remove: (...names) => { this.className = this.className.split(' ').filter(name => !names.includes(name)).join(' '); },
        toggle: (name, force) => {
          const on = force === undefined ? !this.classList.contains(name) : Boolean(force);
          if (on) this.classList.add(name); else this.classList.remove(name);
          return on;
        },
        contains: name => this.className.split(' ').includes(name),
      };
    }
    get options() { return this.children.filter(n => n.tagName === 'OPTION'); }
    get isConnected() { return this === body || !!this.parent?.isConnected; }
    append(...nodes) { for (const n of nodes) { n.remove(); n.parent = this; this.children.push(n); } }
    prepend(n) { n.remove(); n.parent = this; this.children.unshift(n); }
    replaceChildren(...nodes) { for (const n of this.children) n.parent = null; this.children = []; this.append(...nodes); }
    remove() { if (this.parent) this.parent.children = this.parent.children.filter(n => n !== this); this.parent = null; }
    setAttribute(key, value) { this.attributes[key] = value; }
    addEventListener(key, fn) { (this.events[key] ||= []).push(fn); }
    async fire(key) { for (const fn of this.events[key] || []) await fn({ preventDefault() {}, stopPropagation() {} }); }
    matches(selector) {
      if (selector.startsWith('.')) return this.className.split(' ').includes(selector.slice(1));
      if (selector === '[data-case-id]') return !!this.dataset.caseId;
      if (selector === '[data-evaluation-save-lock]') return this.dataset.evaluationSaveLock != null;
      if (selector === '[data-later-save-lock]') return this.dataset.laterSaveLock != null;
      if (selector === '[role=status]') return this.attributes.role === 'status';
      if (selector === 'button[type="submit"]') return this.tagName === 'BUTTON' && this.type === 'submit';
      return this.tagName.toLowerCase() === selector;
    }
    querySelectorAll(selectors) {
      const choices = selectors.split(',').map(s => s.trim());
      const result = [];
      const visit = n => { for (const child of n.children) { if (choices.some(s => child.matches(s))) result.push(child); visit(child); } };
      visit(this); return result;
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    focus() {} scrollIntoView() {}
    show() { this.open = true; }
    showModal() { this.open = true; this.showModalCalls = (this.showModalCalls || 0) + 1; }
    close() { this.open = false; return this.fire('close'); }
  }
  body = new Element('body');
  const cases = Array.from({length: count}, (_, i) => ({
    id: `finding-mission-${i}-0`, missionId: `mission-${i}`, findingIndex: 0,
    kind: 'validatorFinding', title: `Finding ${i}`, detail: 'An original claim.',
    projectPath: project, revision: 0, verdict: 'unreviewed', remediation: 'open',
    provenance: { resolvedModel: 'old-model', modelSource: 'unknown' }, history: [], followups: [],
  }));
  const calls = [];
  let save;
  let record;
  let dataset = () => ({cases, summary: {}, groups: []});
  let summaries = () => ({missions: [], history: []});
  let periods = () => ({recorded: false});
  let exported = () => ({path: 'simulert-forhåndsvisning.json', caseCount: count});
  const railEvaluationsButton = new Element('button');
  const controlEvaluationsButton = new Element('button');
  const window = {
    __TAURI__: {core: {invoke: async (command, args) => {
      calls.push(command);
      if (command === 'get_evaluation_dataset') return dataset(args.request);
      if (command === 'get_mission_summaries') return summaries(args.request);
      if (command === 'get_validator_periods') return periods(args);
      if (command === 'export_evaluation_dataset') return exported(args.request);
      if (command === 'save_finding_evaluation') return save(args.request);
      if (command === 'record_later_finding') return record(args.request);
      throw Error(`Unexpected command ${command}`);
    }}},
    AgentSyncHost: { selectedProject: () => project },
    addEventListener: (key, fn) => listeners.set(key, fn),
    dispatchEvent: event => listeners.get(event.type)?.(event),
  };
  const controls = { railEvaluationsButton, controlEvaluationsButton };
  const document = { body, createElement: tag => new Element(tag), getElementById: id => controls[id] || null, activeElement: null };
  vm.runInNewContext(source, { window, document, CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init?.detail; } } });
  return {window, body, cases, project, calls, railEvaluationsButton, created: () => created, setDataset: fn => {dataset = fn;}, setSave: fn => {save = fn;}, setRecord: fn => {record = fn;}, setSummaries: fn => {summaries = fn;}, setPeriods: fn => {periods = fn;}, setExport: fn => {exported = fn;}, dialog: () => body.querySelector('dialog')};
}

test('the rail register button toggles a non-modal surface and its state', async () => {
  const f = fixture(1);
  assert.equal(f.railEvaluationsButton.attributes['aria-expanded'], undefined);
  await f.railEvaluationsButton.fire('click');
  assert.equal(f.dialog().open, true);
  assert.equal(f.dialog().showModalCalls || 0, 0, 'the rail must remain clickable');
  assert.equal(f.railEvaluationsButton.attributes['aria-expanded'], 'true');
  assert.ok(f.railEvaluationsButton.classList.contains('active'));

  await f.railEvaluationsButton.fire('click');
  assert.equal(f.dialog().open, false);
  assert.equal(f.railEvaluationsButton.attributes['aria-expanded'], 'false');
  assert.equal(f.railEvaluationsButton.classList.contains('active'), false);
});

test('the host can close the register when its project is left', async () => {
  const f = fixture(1);
  await f.window.AgentSyncEvaluations.open(f.project);
  f.window.AgentSyncEvaluations.close();
  assert.equal(f.dialog().open, false);
  assert.equal(f.railEvaluationsButton.attributes['aria-expanded'], 'false');
  assert.equal(f.body.querySelectorAll('.evaluation-case').length, 0);
});

test('closing during the first register read rejects its late result', async () => {
  const gate = deferred();
  const f = fixture(1);
  f.setDataset(() => gate.promise);
  const pending = f.window.AgentSyncEvaluations.open(f.project);
  f.window.AgentSyncEvaluations.close();
  gate.resolve({cases: f.cases, summary: {}, groups: []});
  await pending;
  assert.equal(f.dialog().open, false);
  assert.equal(f.body.querySelector('.evaluation-case'), null);
});

test('a late register read from the previous project cannot replace the current project', async () => {
  const oldGate = deferred();
  const newGate = deferred();
  const oldProject = 'P:/old';
  const newProject = 'P:/new';
  const f = fixture(1);
  const oldCase = {...f.cases[0], id: 'old-case', title: 'Old project finding', projectPath: oldProject};
  const newCase = {...f.cases[0], id: 'new-case', title: 'New project finding', projectPath: newProject};
  f.setDataset(request => request.projectPath === oldProject ? oldGate.promise : newGate.promise);
  const oldOpen = f.window.AgentSyncEvaluations.open(oldProject);
  const newOpen = f.window.AgentSyncEvaluations.open(newProject);
  newGate.resolve({cases: [newCase], summary: {}, groups: []});
  await newOpen;
  oldGate.resolve({cases: [oldCase], summary: {}, groups: []});
  await oldOpen;
  assert.equal(f.body.querySelector('.evaluation-case').dataset.caseId, 'new-case');
  assert.equal(f.body.querySelectorAll('.evaluation-case').some(item => item.dataset.caseId === 'old-case'), false);
});

test('1000 findings allocate only 50 summary rows and no hidden forms', async () => {
  const f = fixture();
  await f.window.AgentSyncEvaluations.open(f.project);
  assert.equal(f.body.querySelectorAll('.evaluation-case').length, 50);
  assert.equal(f.body.querySelectorAll('textarea').length, 0);
  assert.ok(f.created() < 400, `Created ${f.created()} elements`);
  // The downtime line is read on open too: a rate over a week the validator
  // was partly off means something different, and the reader has to be told.
  assert.deepEqual(f.calls, ['get_evaluation_dataset', 'get_mission_summaries', 'get_validator_periods']);
  const more = f.body.querySelectorAll('button').find(n => n.textContent.startsWith('Vis flere'));
  await more.fire('click');
  assert.equal(f.body.querySelectorAll('.evaluation-case').length, 100);
});

test('form and history are lazy; closing releases DOM while preserving unsaved draft', async () => {
  const f = fixture(2);
  await f.window.AgentSyncEvaluations.open(f.project);
  const item = f.body.querySelector('.evaluation-case');
  item.open = true; await item.fire('toggle');
  const evidence = item.querySelector('textarea');
  evidence.value = 'Preserve this exact draft\n  indentation'; await evidence.fire('input');
  assert.ok(item.querySelector('form'));
  assert.equal(item.querySelectorAll('.evaluation-history-entry').length, 0);
  await f.dialog().close();
  assert.equal(f.body.querySelectorAll('.evaluation-case').length, 0);
  assert.equal(f.body.querySelectorAll('textarea').length, 0);
  await f.window.AgentSyncEvaluations.open(f.project);
  assert.equal(f.body.querySelector('.evaluation-case').querySelector('textarea').value, 'Preserve this exact draft\n  indentation');
});

test('exact linked finding beyond first page is reachable without allocating other forms', async () => {
  const f = fixture(110);
  await f.window.AgentSyncEvaluations.open(f.project, f.cases[105].id);
  assert.equal(f.body.querySelectorAll('.evaluation-case').length, 110);
  assert.equal(f.body.querySelectorAll('.evaluation-form').length, 1);
  assert.equal(f.body.querySelectorAll('.evaluation-case').filter(n => n.open).length, 1);
});

test('failed save retains draft and leaves form usable', async () => {
  const f = fixture(1);
  f.setSave(async () => { throw Error('disk unavailable'); });
  await f.window.AgentSyncEvaluations.open(f.project, f.cases[0].id);
  const form = f.body.querySelector('form');
  const evidence = form.querySelector('textarea');
  evidence.value = 'Do not lose me'; await evidence.fire('input');
  await form.fire('submit');
  assert.match(form.querySelector('.evaluation-status').textContent, /Ikke lagret/);
  assert.equal(evidence.disabled, false);
  await f.dialog().close();
  await f.window.AgentSyncEvaluations.open(f.project);
  assert.equal(f.body.querySelector('textarea').value, 'Do not lose me');
});

test('older writing missions are requested within this project and can be loaded without losing draft', async () => {
  const f = fixture(1);
  f.setSummaries(request => {
    assert.equal(request.projectPath, f.project);
    return {history: [{id: `writer-${request.offset}`, projectPath: f.project, purpose: 'writer'}], hasMore: request.offset === 0, warning: request.offset === 0 ? 'One unreadable record was preserved.' : null};
  });
  await f.window.AgentSyncEvaluations.open(f.project);
  const later = f.body.querySelector('.evaluation-later');
  later.open = true; await later.fire('toggle');
  const form = later.querySelector('form');
  const title = form.querySelector('input');
  title.value = 'Keep this title'; await title.fire('input');
  const select = form.querySelector('select');
  select.value = 'writer-0'; await select.fire('change');
  const older = form.querySelectorAll('button').find(n => n.textContent === 'Hent eldre skriveoppdrag');
  assert.equal(older.hidden, false);
  await older.fire('click');
  assert.equal(older.hidden, true);
  assert.deepEqual(select.options.map(n => n.value), ['', 'writer-0', 'writer-1']);
  assert.equal(select.value, 'writer-0');
  assert.equal(title.value, 'Keep this title');
});

test('later finding stays locked after close/reopen during a save; failure restores the draft', async () => {
  const f = fixture(1);
  let fail;
  f.setRecord(() => new Promise((resolve, reject) => { fail = reject; }));
  await f.window.AgentSyncEvaluations.open(f.project);
  const later = f.body.querySelector('.evaluation-later');
  later.open = true; await later.fire('toggle');
  const form = later.querySelector('form');
  const title = form.querySelector('input');
  title.value = 'Pending draft'; await title.fire('input');
  const pending = form.fire('submit');
  await f.dialog().close();
  await f.window.AgentSyncEvaluations.open(f.project);
  const remounted = f.body.querySelector('.evaluation-later-form');
  assert.equal(remounted.querySelector('input').value, 'Pending draft');
  assert.ok(remounted.querySelectorAll('input, select, textarea, button').every(n => n.disabled));
  fail(Error('storage disconnected'));
  await pending;
  assert.ok(remounted.querySelectorAll('input, select, textarea, button').every(n => !n.disabled));
  assert.match(remounted.querySelector('[role=status]').textContent, /Ikke lagret/);
  assert.equal(remounted.querySelector('input').value, 'Pending draft');
});

test('case save failure remains visible after its pending form is closed and remounted', async () => {
  const f = fixture(1);
  let fail;
  f.setSave(() => new Promise((resolve, reject) => { fail = reject; }));
  await f.window.AgentSyncEvaluations.open(f.project, f.cases[0].id);
  const form = f.body.querySelector('.evaluation-case').querySelector('form');
  const evidence = form.querySelector('textarea');
  evidence.value = 'Keep the evidence'; await evidence.fire('input');
  const pending = form.fire('submit');
  await f.dialog().close();
  await f.window.AgentSyncEvaluations.open(f.project);
  const remounted = f.body.querySelector('.evaluation-case').querySelector('form');
  assert.equal(remounted.querySelector('textarea').disabled, true);
  fail(Error('record locked'));
  await pending;
  assert.equal(remounted.querySelector('textarea').disabled, false);
  assert.equal(remounted.querySelector('textarea').value, 'Keep the evidence');
  assert.match(remounted.querySelector('[role=status]').textContent, /Ikke lagret: Error: record locked/);
});

test('downtime uses the native top-level argument and cannot imply no manual checks happened', async () => {
  const f = fixture(1);
  f.setPeriods(args => {
    assert.deepEqual(Object.keys(args), ['windowMs']);
    assert.equal(args.windowMs, 7 * 24 * 60 * 60 * 1000);
    return {recorded: true, offMs: 60_000, periods: [{toUnixMs: null}]};
  });
  await f.window.AgentSyncEvaluations.open(f.project);
  const text = f.body.querySelectorAll('p').map(n => n.textContent).join('\n');
  assert.match(text, /Registrerte av-perioder/);
  assert.match(text, /ikke bevis på kontinuerlig appdrift eller dagens tilstand/);
  assert.doesNotMatch(text, /Skriveoppdrag i den perioden ble ikke kontrollert|og er av nå/);
});

test('an unreadable period register is visible instead of a clean zero', async () => {
  const f = fixture(1);
  f.setPeriods(() => {throw Error('invalid period log');});
  await f.window.AgentSyncEvaluations.open(f.project);
  const text = f.body.querySelectorAll('p').map(n => n.textContent).join('\n');
  assert.match(text, /Av\/på-historikken kunne ikke leses/);
  assert.doesNotMatch(text, /Registrerte av-perioder dekker 0/);
});

test('redacted export remains a local explicit action, with an anonymity caveat', async () => {
  const f = fixture(1); const exports = [];
  f.setExport(request => {exports.push(request); return {path: 'simulert.json', caseCount: 1};});
  await f.window.AgentSyncEvaluations.open(f.project);
  assert.equal(exports.length, 0);
  const control = f.body.querySelectorAll('button').find(n => n.textContent === 'Eksporter redigert datasett');
  await control.fire('click');
  assert.equal(exports[0].shareable, true);
  assert.equal(exports[0].projectPath, f.project);
  assert.match(f.body.querySelectorAll('p').map(n => n.textContent).join('\n'), /garanterer ikke anonymitet/);
});
