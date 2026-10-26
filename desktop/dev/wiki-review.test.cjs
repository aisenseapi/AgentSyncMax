const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../src/wiki-review.js'), 'utf8');
const PROJECT = 'P:/Dropbox/Projects/AgentSyncToolkit';

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function review(overrides = {}) {
  return {
    reviewId: 'review-1', viewId: 'view-1', proposalId: 'proposal-1', projectPath: PROJECT,
    pageId: 'projects/agentsync/activity', generatedUtc: '2026-09-14T12:00:00Z',
    modelTag: 'gemma4:31b', modelDigest: 'a'.repeat(64),
    resultMarkdown: '## Activity\n\nOriginal text.', rationale: 'Conservative summary.',
    preservedSources: [{ref: 'project/summary', why: 'Project metadata.'}],
    discardedSources: [{ref: 'session/0001', reasonCode: 'redundant', why: 'Duplicate.'}],
    humanReviewRequired: true, semanticCorrectnessVerified: false,
    decision: {revision: 0, status: 'pending', editedMarkdown: null, note: '', atUnixMs: null, conflict: false},
    ...overrides,
  };
}

function fixture(invokeImpl = async command => {
  if (command === 'get_knowledge_reviews') return {items: [review()]};
  throw new Error(command);
}, preferenceStore = new Map()) {
  let document;
  let activeElement = null;
  class Element {
    constructor(tag) {
      this.tagName = tag.toUpperCase(); this.children = []; this.parent = null;
      this.dataset = {}; this.attributes = {}; this.events = {}; this.className = '';
      this.style = {}; this.id = ''; this._offsetWidth = 0; this._offsetHeight = 0;
      this.clientWidth = 0; this.clientHeight = 0; this.capturedPointer = null;
      this.textContent = ''; this.value = ''; this.disabled = false; this.open = false;
      this.hidden = false; this.tabIndex = 0; this.maxLength = 0; this.rows = 0;
      this.classList = {
        add: (...names) => { this.className = [...new Set([...this.className.split(' ').filter(Boolean), ...names])].join(' '); },
        remove: (...names) => { this.className = this.className.split(' ').filter(name => !names.includes(name)).join(' '); },
        contains: name => this.className.split(' ').includes(name),
      };
    }
    get isConnected() { return this === document.body || Boolean(this.parent?.isConnected); }
    get options() { return this.children.filter(child => child.tagName === 'OPTION'); }
    get lastChild() { return this.children.at(-1) || null; }
    append(...nodes) { for (const item of nodes) { if (typeof item === 'string') this.textContent += item; else { item.remove(); item.parent = this; this.children.push(item); } } }
    prepend(item) { item.remove(); item.parent = this; this.children.unshift(item); }
    replaceChildren(...nodes) { for (const child of this.children) child.parent = null; this.children = []; this.textContent = ''; this.append(...nodes); }
    remove() { if (!this.parent) return; this.parent.children = this.parent.children.filter(child => child !== this); this.parent = null; }
    setAttribute(key, value) { this.attributes[key] = String(value); }
    addEventListener(key, handler) { (this.events[key] ||= []).push(handler); }
    removeEventListener(key, handler) { this.events[key] = (this.events[key] || []).filter(candidate => candidate !== handler); }
    async fire(key, extra = {}) {
      const event = {target: this, currentTarget: this, preventDefault() {}, stopPropagation() {}, ...extra};
      for (const handler of this.events[key] || []) await handler(event);
    }
    get offsetWidth() {
      const styled = Number.parseFloat(this.style.width);
      if (Number.isFinite(styled)) return styled;
      if (this.classList.contains('minimized')) return 330;
      return this._offsetWidth || (this.tagName === 'DIALOG' ? 1100 : 0);
    }
    set offsetWidth(value) { this._offsetWidth = value; }
    get offsetHeight() {
      const styled = Number.parseFloat(this.style.height);
      if (Number.isFinite(styled)) return styled;
      if (this.classList.contains('minimized')) return 48;
      return this._offsetHeight || (this.tagName === 'DIALOG' ? 720 : 0);
    }
    set offsetHeight(value) { this._offsetHeight = value; }
    getBoundingClientRect() { return {width: this.offsetWidth, height: this.offsetHeight}; }
    setPointerCapture(pointerId) { this.capturedPointer = pointerId; }
    hasPointerCapture(pointerId) { return this.capturedPointer === pointerId; }
    releasePointerCapture(pointerId) { if (this.capturedPointer === pointerId) this.capturedPointer = null; }
    matches(selector) {
      if (selector.startsWith('#')) return this.id === selector.slice(1);
      if (selector.startsWith('.')) return this.classList.contains(selector.slice(1));
      if (selector === '[data-review-id]') return Boolean(this.dataset.reviewId);
      if (selector === '[role=status]') return this.attributes.role === 'status';
      return this.tagName.toLowerCase() === selector.toLowerCase();
    }
    closest(selector) {
      let candidate = this;
      while (candidate) {
        if (candidate.matches(selector)) return candidate;
        candidate = candidate.parent;
      }
      return null;
    }
    querySelectorAll(selectors) {
      const wanted = selectors.split(',').map(item => item.trim());
      const result = [];
      const visit = host => { for (const child of host.children) { if (wanted.some(selector => child.matches(selector))) result.push(child); visit(child); } };
      visit(this);
      return result;
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    focus() { activeElement = this; }
    scrollIntoView() {}
    show() { this.open = true; this.nonModal = true; }
    showModal() { throw new Error('knowledge review must not block the validator rail'); }
    close() { this.open = false; return this.fire('close'); }
  }

  const body = new Element('body');
  const rail = new Element('button');
  rail.id = 'railKnowledgeButton';
  const stage = new Element('main');
  stage.id = 'stage'; stage.clientWidth = 1200; stage.clientHeight = 800;
  body.append(rail, stage);
  document = {
    body,
    createElement: tag => new Element(tag),
    createElementNS: (_namespace, tag) => new Element(tag),
    getElementById: id => id === 'railKnowledgeButton' ? rail : id === 'stage' ? stage : null,
    get activeElement() { return activeElement; },
  };
  activeElement = rail;
  const calls = [];
  const listeners = new Map();
  const timers = [];
  const window = {
    __TAURI__: {core: {invoke: async (command, args) => {
      calls.push({command, request: args?.request});
      return invokeImpl(command, args?.request || {});
    }}},
    AgentSyncHost: {selectedProject: () => PROJECT},
    innerWidth: 1200,
    innerHeight: 800,
    localStorage: {
      getItem: key => preferenceStore.has(key) ? preferenceStore.get(key) : null,
      setItem: (key, value) => preferenceStore.set(key, String(value)),
      removeItem: key => preferenceStore.delete(key),
    },
    setTimeout: callback => { timers.push(callback); return timers.length; },
    dispatchEvent: event => listeners.get(event.type)?.forEach(handler => handler(event)),
    addEventListener: (type, handler) => (listeners.get(type) || listeners.set(type, []).get(type)).push(handler),
  };
  const context = vm.createContext({window, document, console, CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init?.detail; } }});
  vm.runInContext(source, context);
  return {window, document, body, stage, rail, calls, timers, preferenceStore, dialog: () => body.querySelector('dialog')};
}

function buttonByText(host, text) {
  return host.querySelectorAll('button').find(button => button.textContent === text);
}

test('module is inert until opened and renders a compact master-detail reader', async () => {
  const f = fixture();
  assert.equal(f.calls.length, 0);
  assert.ok(f.rail.events.click?.length, 'rail trigger is wired');
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  assert.equal(f.dialog().nonModal, true, 'the knowledge reader must leave the app rail usable');
  assert.equal(f.dialog().classList.contains('surface-front'), true, 'K must be visible above the validator when opened');
  assert.equal(f.rail.attributes['aria-expanded'], 'true');
  assert.equal(f.calls[0].command, 'get_knowledge_reviews');
  assert.equal(f.calls[0].request.projectPath, PROJECT);
  const row = f.dialog().querySelector('.knowledge-item');
  assert.match(row.textContent + row.children.map(child => child.textContent).join(' '), /activity|AgentSync/i);
  await row.fire('click');
  assert.equal(f.dialog().querySelector('.knowledge-browser').classList.contains('has-selection'), true);
  assert.equal(f.dialog().querySelector('textarea').value, '## Activity\n\nOriginal text.');
  assert.match(f.dialog().querySelector('.knowledge-detail').children[0].children[0].children.at(-1).textContent, /Ikke vurdert/);
});

test('K opens, brings an existing background reader forward, then closes it', async () => {
  const f = fixture();
  await f.rail.fire('click');
  assert.equal(f.dialog().open, true);
  assert.equal(f.calls.length, 1);
  f.window.AgentSyncKnowledgeReviews.sendToBack();
  assert.equal(f.dialog().open, true, 'changing layers must not discard the open review');
  assert.equal(f.window.AgentSyncKnowledgeReviews.isFront(), false);
  assert.equal(f.rail.classList.contains('active'), false);
  await f.rail.fire('click');
  assert.equal(f.window.AgentSyncKnowledgeReviews.isFront(), true);
  assert.equal(f.rail.classList.contains('active'), true);
  assert.equal(f.calls.length, 1, 'bringing the existing window forward must not reread the dataset');
  await f.rail.fire('click');
  assert.equal(f.dialog().open, false, 'K closes the knowledge window when it is already in front');
  assert.equal(f.rail.attributes['aria-expanded'], 'false');
  assert.equal(f.rail.classList.contains('active'), false);
  assert.equal(f.calls.length, 1, 'closing must not reread the dataset');
});

test('K closes immediately while its first dataset read is still pending', async () => {
  const wait = deferred();
  const f = fixture(async command => {
    if (command === 'get_knowledge_reviews') return wait.promise;
    throw new Error(command);
  });
  const opening = f.rail.fire('click');
  assert.equal(f.dialog().open, true);
  await f.rail.fire('click');
  assert.equal(f.dialog().open, false);
  wait.resolve({items: [review()]});
  await opening;
  assert.equal(f.dialog().open, false, 'a late read must not reopen the window');
  assert.equal(f.dialog().querySelector('.knowledge-item'), null, 'a late read must not repopulate the closed window');
});

test('K refreshes a background reader when the selected project has changed', async () => {
  const first = deferred();
  const second = deferred();
  const firstProject = 'P:/one';
  const secondProject = 'P:/two';
  const f = fixture((_command, request) => request.projectPath === firstProject ? first.promise : second.promise);
  const firstOpen = f.window.AgentSyncKnowledgeReviews.open(firstProject);
  f.window.AgentSyncKnowledgeReviews.sendToBack();
  f.window.AgentSyncHost.selectedProject = () => secondProject;
  const switching = f.rail.fire('click');
  second.resolve({items: [review({reviewId: 'review-new', viewId: 'view-new', projectPath: secondProject, pageId: 'projects/new'})]});
  await switching;
  assert.equal(f.dialog().open, true);
  assert.equal(f.window.AgentSyncKnowledgeReviews.isFront(), true);
  assert.match(f.dialog().querySelector('.knowledge-project').textContent, /two/);
  assert.equal(f.dialog().querySelector('.knowledge-item').dataset.reviewId, 'review-new');
  assert.deepEqual(f.calls.map(call => call.request.projectPath), [firstProject, secondProject]);

  first.resolve({items: [review({reviewId: 'review-old', viewId: 'view-old', projectPath: firstProject, pageId: 'projects/old'})]});
  await firstOpen;
  assert.equal(f.dialog().querySelector('.knowledge-item').dataset.reviewId, 'review-new', 'the late old-project read cannot replace the new project');
});

test('knowledge window folds, moves and reopens without a captured click opening it', async () => {
  const f = fixture();
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  const dialog = f.dialog();
  const header = dialog.querySelector('.knowledge-header');
  const heading = dialog.querySelector('.knowledge-heading');
  const move = dialog.querySelector('.knowledge-move');
  const minimize = dialog.querySelector('.knowledge-minimize');
  const initialWidth = dialog.offsetWidth;
  const initialHeight = dialog.offsetHeight;

  await minimize.fire('click');
  assert.equal(dialog.classList.contains('minimized'), true);
  assert.equal(minimize.attributes['aria-expanded'], 'false');
  assert.match(minimize.attributes['aria-label'], /Åpne/);

  const left = Number.parseFloat(dialog.style.left);
  const top = Number.parseFloat(dialog.style.top);
  await header.fire('pointerdown', {button: 0, target: move, pointerId: 7, clientX: 100, clientY: 100});
  await header.fire('pointermove', {pointerId: 7, clientX: 125, clientY: 112});
  await header.fire('pointerup', {pointerId: 7, clientX: 125, clientY: 112});
  assert.equal(dialog.style.left, `${left + 25}px`);
  assert.equal(dialog.style.top, `${top + 12}px`);
  assert.equal(dialog.classList.contains('minimized'), true);

  await header.fire('click', {target: heading});
  assert.equal(dialog.classList.contains('minimized'), true, 'the synthetic post-drag click is consumed');
  await header.fire('click', {target: heading});
  assert.equal(dialog.classList.contains('minimized'), false, 'a deliberate title click opens the folded window');
  assert.equal(dialog.offsetWidth, initialWidth);
  assert.equal(dialog.offsetHeight, initialHeight);
  assert.equal(minimize.attributes['aria-expanded'], 'true');
});

test('the folded knowledge move handle supports small and large keyboard steps', async () => {
  const f = fixture();
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  const dialog = f.dialog();
  const move = dialog.querySelector('.knowledge-move');
  await dialog.querySelector('.knowledge-minimize').fire('click');
  const left = Number.parseFloat(dialog.style.left);
  const top = Number.parseFloat(dialog.style.top);
  let prevented = 0;
  await move.fire('keydown', {key: 'ArrowRight', shiftKey: false, preventDefault() { prevented += 1; }});
  await move.fire('keydown', {key: 'ArrowDown', shiftKey: true, preventDefault() { prevented += 1; }});
  assert.equal(dialog.style.left, `${left + 8}px`);
  assert.equal(dialog.style.top, `${top + 32}px`);
  assert.equal(prevented, 2);
});

test('knowledge size and open position persist and clamp into a smaller stage', async () => {
  const preferences = new Map();
  const first = fixture(undefined, preferences);
  await first.window.AgentSyncKnowledgeReviews.open(PROJECT);
  const firstDialog = first.dialog();
  firstDialog.style.width = '880px';
  firstDialog.style.height = '620px';
  firstDialog.style.left = '260px';
  firstDialog.style.top = '140px';
  await firstDialog.fire('pointerup', {target: firstDialog});
  await first.dialog().querySelector('.knowledge-header').fire('pointerdown', {
    button: 0, target: first.dialog().querySelector('.knowledge-heading'), pointerId: 8, clientX: 100, clientY: 100,
  });
  await first.dialog().querySelector('.knowledge-header').fire('pointermove', {pointerId: 8, clientX: 110, clientY: 110});
  await first.dialog().querySelector('.knowledge-header').fire('pointerup', {pointerId: 8, clientX: 110, clientY: 110});
  await first.dialog().close();

  preferences.set('agentsync.v4.knowledgePosition', JSON.stringify({left: 9999, top: 9999}));
  const second = fixture(undefined, preferences);
  second.stage.clientWidth = 760;
  second.stage.clientHeight = 540;
  await second.window.AgentSyncKnowledgeReviews.open(PROJECT);
  assert.equal(second.dialog().style.width, '744px');
  assert.equal(second.dialog().style.height, '524px');
  assert.equal(second.dialog().style.left, '8px');
  assert.equal(second.dialog().style.top, '8px');
});

test('save sends the exact revision and approval explicitly remains non-publishing', async () => {
  let savedRequest;
  const f = fixture(async (command, request) => {
    if (command === 'get_knowledge_reviews') return {items: [review()]};
    if (command === 'save_knowledge_review_decision') {
      savedRequest = request;
      return review({decision: {revision: 1, status: 'approved', editedMarkdown: request.editedMarkdown, note: request.note, atUnixMs: 10, conflict: false}});
    }
    throw new Error(command);
  });
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  await f.dialog().querySelector('.knowledge-item').fire('click');
  const fields = f.dialog().querySelectorAll('textarea');
  fields[0].value = '## Reviewed\n\nKept.'; await fields[0].fire('input');
  fields[1].value = 'Checked manually.'; await fields[1].fire('input');
  const approve = buttonByText(f.dialog(), 'Godkjenn utkast (publiserer ikke)');
  assert.ok(approve);
  await approve.fire('click');
  assert.equal(savedRequest.projectPath, PROJECT);
  assert.equal(savedRequest.reviewId, 'review-1');
  assert.equal(savedRequest.viewId, 'view-1');
  assert.equal(savedRequest.expectedRevision, 0);
  assert.equal(savedRequest.status, 'approved');
  assert.equal(savedRequest.editedMarkdown, '## Reviewed\n\nKept.');
  assert.equal(savedRequest.note, 'Checked manually.');
  assert.match(f.dialog().querySelector('.knowledge-save-status').textContent, /Ingenting er publisert/);
  assert.match(f.dialog().querySelector('.knowledge-badge').textContent, /Godkjent/);
});

test('failed save keeps the draft through close and reopen', async () => {
  const f = fixture(async command => {
    if (command === 'get_knowledge_reviews') return {items: [review()]};
    if (command === 'save_knowledge_review_decision') throw new Error('revision conflict');
    throw new Error(command);
  });
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  await f.dialog().querySelector('.knowledge-item').fire('click');
  const markdown = f.dialog().querySelector('textarea');
  markdown.value = 'Unsaved exact text\n  with indentation'; await markdown.fire('input');
  await buttonByText(f.dialog(), 'Lagre utkast').fire('click');
  assert.match(f.dialog().querySelector('.knowledge-save-status').textContent, /Teksten din er beholdt/);
  assert.equal(markdown.value, 'Unsaved exact text\n  with indentation');
  await f.dialog().close();
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  await f.dialog().querySelector('.knowledge-item').fire('click');
  assert.equal(f.dialog().querySelector('textarea').value, 'Unsaved exact text\n  with indentation');
});

test('frontend enforces the backend text bounds before invoking storage', async () => {
  const f = fixture(async command => {
    if (command === 'get_knowledge_reviews') return {items: [review()]};
    throw new Error(`unexpected storage call: ${command}`);
  });
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  await f.dialog().querySelector('.knowledge-item').fire('click');
  const fields = f.dialog().querySelectorAll('textarea');
  assert.equal(fields[1].maxLength, 4000);
  fields[0].value = 'ø'.repeat(70000); await fields[0].fire('input');
  await buttonByText(f.dialog(), 'Lagre utkast').fire('click');
  assert.match(f.dialog().querySelector('.knowledge-save-status').textContent, /128 KiB/);
  assert.equal(f.calls.filter(call => call.command === 'save_knowledge_review_decision').length, 0);
});

test('a remounted stale draft never adopts a newer backend revision', async () => {
  let remoteRevision = 0;
  let savedRequest;
  const f = fixture(async (command, request) => {
    if (command === 'get_knowledge_reviews') return {items: [review({decision: {revision: remoteRevision, status: remoteRevision ? 'draft' : 'pending', editedMarkdown: remoteRevision ? 'Remote text' : null, note: '', atUnixMs: 2, conflict: false}})]};
    if (command === 'save_knowledge_review_decision') { savedRequest = request; throw new Error('revision conflict'); }
    throw new Error(command);
  });
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  await f.dialog().querySelector('.knowledge-item').fire('click');
  let markdown = f.dialog().querySelector('textarea');
  markdown.value = 'My local draft'; await markdown.fire('input');
  await f.dialog().close();
  remoteRevision = 3;
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  await f.dialog().querySelector('.knowledge-item').fire('click');
  markdown = f.dialog().querySelector('textarea');
  assert.equal(markdown.value, 'My local draft');
  assert.equal(buttonByText(f.dialog(), 'Lagre utkast').disabled, true);
  assert.match(f.dialog().querySelector('.knowledge-save-status').textContent, /beholdt/);
  await buttonByText(f.dialog(), 'Forkast lokal tekst og last inn').fire('click');
  assert.equal(f.dialog().querySelector('textarea').value, 'Remote text');
  assert.equal(savedRequest, undefined);
});

test('a successful save clears its local draft even when the dialog closes during storage', async () => {
  const wait = deferred();
  let remote = review();
  const f = fixture(async (command, request) => {
    if (command === 'get_knowledge_reviews') return {items: [remote]};
    if (command === 'save_knowledge_review_decision') {
      await wait.promise;
      remote = review({decision: {revision: 1, status: 'draft', editedMarkdown: request.editedMarkdown, note: request.note, atUnixMs: 10, conflict: false}});
      return remote.decision;
    }
    throw new Error(command);
  });
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  await f.dialog().querySelector('.knowledge-item').fire('click');
  const markdown = f.dialog().querySelector('textarea');
  markdown.value = 'Saved while closing'; await markdown.fire('input');
  const pending = buttonByText(f.dialog(), 'Lagre utkast').fire('click');
  await f.dialog().close();
  wait.resolve(); await pending;
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  await f.dialog().querySelector('.knowledge-item').fire('click');
  assert.equal(f.dialog().querySelector('textarea').value, 'Saved while closing');
  assert.equal(buttonByText(f.dialog(), 'Lagre utkast').disabled, false);
});

test('a late response from the previous project cannot replace the current project', async () => {
  const first = deferred();
  const second = deferred();
  const firstProject = 'P:/one';
  const secondProject = 'P:/two';
  const f = fixture((_command, request) => request.projectPath === firstProject ? first.promise : second.promise);
  const oldOpen = f.window.AgentSyncKnowledgeReviews.open(firstProject);
  const newOpen = f.window.AgentSyncKnowledgeReviews.open(secondProject);
  second.resolve({items: [review({reviewId: 'review-new', viewId: 'view-new', projectPath: secondProject, pageId: 'projects/new'})]});
  await newOpen;
  first.resolve({items: [review({reviewId: 'review-old', viewId: 'view-old', projectPath: firstProject, pageId: 'projects/old'})]});
  await oldOpen;
  assert.equal(f.dialog().querySelector('.knowledge-item').dataset.reviewId, 'review-new');
  assert.match(f.dialog().querySelector('.knowledge-project').textContent, /two/);
});

test('the host can close knowledge review when its project is left', async () => {
  const f = fixture(async () => ({items: [review()]}));
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  f.window.AgentSyncKnowledgeReviews.close();
  assert.equal(f.dialog().open, false);
  assert.equal(f.window.AgentSyncKnowledgeReviews.isFront(), false);
  assert.equal(f.dialog().querySelector('.knowledge-item'), null);
});

test('empty and failed reads are explicit, and retry remains local', async () => {
  let fail = false;
  const f = fixture(async () => {
    if (fail) throw new Error('database unavailable');
    return {items: []};
  });
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  assert.match(f.dialog().querySelector('.knowledge-list-empty').textContent, /Ingen kunnskapsutkast/);
  fail = true;
  await f.window.AgentSyncKnowledgeReviews.refresh();
  assert.match(f.dialog().querySelector('.knowledge-error').textContent, /database unavailable/);
  assert.ok(buttonByText(f.dialog(), 'Prøv igjen'));
});

test('missing projection source is distinct from a project with no proposals', async () => {
  const f = fixture(async () => ({sourceAvailable: false, items: []}));
  await f.window.AgentSyncKnowledgeReviews.open(PROJECT);
  assert.match(f.dialog().querySelector('.knowledge-list-empty').textContent, /Ingen.*gjort klare/i);
});

test('index and CSS keep the review separate, flexible and responsive to its own width', () => {
  const html = fs.readFileSync(path.join(__dirname, '../src/index.html'), 'utf8');
  const css = fs.readFileSync(path.join(__dirname, '../src/wiki-review.css'), 'utf8');
  const appCss = fs.readFileSync(path.join(__dirname, '../src/styles.css'), 'utf8');
  assert.match(html, /id="railKnowledgeButton"/);
  assert.match(html, /wiki-review\.css/);
  assert.match(html, /wiki-review\.js/);
  assert.match(css, /grid-template-columns: minmax\(245px, 31%\) minmax\(0, 69%\)/);
  assert.match(css, /@container knowledge \(max-width: 759px\)/);
  assert.match(css, /\.knowledge-dialog \{[\s\S]*position: absolute;[\s\S]*z-index: 35;/);
  assert.match(css, /\.knowledge-dialog \{[\s\S]*transform: none;[\s\S]*resize: both;/,
    'the non-modal dialog must move and resize inside the stage without centered-transform drift');
  assert.match(css, /\.knowledge-dialog\.minimized \{[^}]*resize: none/);
  assert.match(css, /\.knowledge-body \{[^}]*container-type: inline-size;[^}]*container-name: knowledge/);
  assert.match(css, /\.knowledge-move-icon \{[^}]*stroke: currentColor/);
  assert.match(css, /\.knowledge-dialog\.surface-front \{ z-index: 50; \}/);
  assert.match(appCss, /\.project-drawer \{ position: relative; z-index: 60;/,
    'the rail must stay usable above either floating work surface');
  const validator = html.indexOf('id="railValidatorButton"');
  const knowledge = html.indexOf('id="railKnowledgeButton"');
  const register = html.indexOf('id="railEvaluationsButton"');
  assert.ok(validator < knowledge && knowledge < register, 'rail order must be V, K, Register');
  assert.match(css, /\.knowledge-browser\.has-selection \.knowledge-list-pane \{ display: none; \}/);
  assert.doesNotMatch(css, /\.knowledge-actions \{[^}]*position: sticky/s);
  assert.match(source, /detail\.append\(head, scroll, actions\)/);
  assert.match(source, /dialog\.show\(\)/);
  assert.match(source, /bringToFront\(\);[\s\S]*await refresh\(\)/);
  assert.match(source, /async function toggle\([\s\S]*dialog\.open && isFront\(\)[\s\S]*closeDialog\(\)/);
  assert.match(source, /header\.addEventListener\("pointerdown", beginDrag\)/);
  assert.doesNotMatch(source, /dialog\.showModal\(\)/);
  assert.doesNotMatch(source, /invoke\("start_mission"|invoke\("publish|invoke\("wiki_write|invoke\("run_git/);
});
