// The finding card, executed as production code in a small DOM fixture.
// What it guards: the finding is text, only the line naming the action is a
// button, and reading the critique never costs a mission.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const control = fs.readFileSync(path.join(__dirname, '../src/control.js'), 'utf8');

// Production top-level declarations close at column zero.
function fn(name) {
  const start = control.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.notEqual(start, -1, name);
  const end = control.indexOf('\n}', start);
  assert.notEqual(end, -1, name);
  return control.slice(start, end + 2);
}

function fixture({ agent = { id: 'claude', label: 'Claude Code' } } = {}) {
  let body;
  class Element {
    constructor(tag) {
      this.tagName = tag.toUpperCase();
      this.children = []; this.dataset = {}; this.attributes = {}; this.events = {};
      this.className = ''; this._text = ''; this.disabled = false;
      this.hidden = false; this.parent = null; this.style = {};
      this.offsetHeight = 120; this.offsetWidth = 360;
      this.classList = {
        add: (...names) => { this.className = [...new Set([...this.className.split(' '), ...names])].join(' ').trim(); },
        toggle: (name, on) => { if (on) this.classList.add(name); else this.className = this.className.split(' ').filter(n => n !== name).join(' '); },
        contains: name => this.className.split(' ').includes(name),
      };
    }
    // Real textContent gathers every descendant. A heading built from child
    // spans has to read as its own text, or a test passes on an empty string.
    get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
    set textContent(value) { this._text = String(value); this.children = []; }
    append(...nodes) {
      // Production appends plain strings alongside elements.
      for (const n of nodes) {
        if (typeof n === "string") { this._text += n; continue; }
        n.remove(); n.parent = this; this.children.push(n);
      }
    }
    replaceChildren(...nodes) { for (const n of this.children) n.parent = null; this.children = []; this.append(...nodes); }
    remove() { if (this.parent) this.parent.children = this.parent.children.filter(n => n !== this); this.parent = null; }
    setAttribute(key, value) { this.attributes[key] = value; }
    getAttribute(key) { return Object.hasOwn(this.attributes, key) ? this.attributes[key] : null; }
    addEventListener(key, handler) { (this.events[key] ||= []).push(handler); }
    async fire(key) { for (const handler of this.events[key] || []) await handler({ preventDefault() {}, stopPropagation() {}, target: this }); }
    contains(node) { return node === this || this.children.some(child => child.contains(node)); }
    closest() { return null; }
    getBoundingClientRect() { return { left: 40, top: 60, right: 400, bottom: 180, width: 360, height: 120 }; }
    matches(selector) {
      if (selector.startsWith('.')) return this.className.split(' ').includes(selector.slice(1));
      return this.tagName.toLowerCase() === selector;
    }
    querySelectorAll(selector) {
      const found = [];
      const visit = node => { for (const child of node.children) { if (child.matches(selector)) found.push(child); visit(child); } };
      visit(this); return found;
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  }

  body = new Element('body');
  const registry = {
    controlFindingList: new Element('div'),
    controlVerdict: new Element('div'),
  };
  const sent = [];
  const caseCallbacks = [];
  const hoverDelays = [];
  const context = {
    console,
    HOVER_PEEK_DELAY_MS: 1100,
    peek: { node: null, timer: 0, pinned: false, anchor: null },
    state: { selectedRun: 'mission-1', project: 'P:/test' },
    element(tag, className = '', text) {
      const node = new Element(tag);
      if (className) node.className = className;
      if (text !== undefined) node.textContent = text;
      return node;
    },
    byId: id => registry[id],
    // The card offers to send a finding to an agent other than the selected
    // one, so the fixture has to know which agents exist.
    availableAgents: () => [
      { id: "claude", label: "Claude Code" },
      { id: "codex", label: "Codex" },
      { id: "opencode", label: "OpenCode" },
    ],
    agentLabel: id => ({ claude: 'Claude Code', codex: 'Codex' }[id] || id),
    document: { body, addEventListener() {} },
    window: {
      innerWidth: 1280, innerHeight: 800,
      setTimeout(callback, delay) { hoverDelays.push(delay); callback(); return 1; },
      clearTimeout() {},
      AgentSyncHost: {
        selectedAgent: () => agent,
        async sendToAgent(prompt, project, agentId) { sent.push({ prompt, project, agentId }); return { accepted: true, missionId: 'mission-2' }; },
      },
      AgentSyncEvaluations: { decorate(_card, callbacks) { caseCallbacks.push(callbacks); } },
      dispatchEvent() {},
    },
    CustomEvent: class { constructor(name, init) { this.type = name; Object.assign(this, init); } },
    invoke: async () => ({}),
    // The panel is on screen in every card test, which is what lets the card
    // stamp when a finding was first put in front of a person.
    presentationVisible: () => true,
  };
  context.window.document = context.document;
  vm.createContext(context);
  vm.runInContext([fn('showVerdict'), fn('showLimit'), fn('peekNode'), fn('hidePeek'), fn('layoutScale'), fn('showPeek'), fn('attachPeek'), fn('renderFindingButtons')].join('\n'), context);
  return { context, registry, body, sent, Element, caseCallbacks, hoverDelays };
}

const report = {
  outcome: 'findings',
  checked: 'Leste diffen.',
  validatorAgent: 'Codex',
  validatorModel: 'gpt-5.6-sol',
  findings: [{
    severity: 'hoy',
    title: 'Manglende nullsjekk',
    detail: 'Verdien kan være null før den brukes.',
    file: 'desktop/src/app.js',
    prompt: 'Et funn fra en uavhengig validering.\n\nFunn: Manglende nullsjekk\nVurder funnet selv før du handler.',
    seenBefore: 0,
    actedOn: false,
    actedOnBy: [],
    exactSentTo: [],
  }],
};

test('the finding is text and only the action line is a button', () => {
  const { context, registry } = fixture();
  context.renderFindingButtons(report, 'mission-1');

  const card = registry.controlFindingList.children[0];
  const finding = card.querySelector('.control-finding');
  assert.equal(finding.tagName, 'DIV', 'the finding itself must not be a button');
  assert.equal(finding.attributes.title, undefined, 'no native tooltip; the popup replaces it');

  const send = card.querySelector('.control-finding-send');
  assert.equal(send.tagName, 'BUTTON', 'the action line is the button');

  const buttons = card.querySelectorAll('button');
  assert.equal(buttons.length, 2, 'exactly two buttons: send, and show the text');
  assert.ok(card.querySelector('.control-finding-peek'), 'reading the critique has its own button');
});

test('the send button stays locked until the register reports on the finding', () => {
  const { context, registry } = fixture();
  context.renderFindingButtons(report, 'mission-1');
  const send = registry.controlFindingList.children[0].querySelector('.control-finding-send');
  assert.equal(send.disabled, true, 'nothing is sent before the status is known');
});

test('showing the text opens the popup and sends nothing', async () => {
  const { context, registry, body, sent } = fixture();
  context.renderFindingButtons(report, 'mission-1');
  const card = registry.controlFindingList.children[0];

  await card.querySelector('.control-finding-peek').fire('click');
  const popup = body.querySelector('.finding-peek');
  assert.ok(popup, 'the popup lives outside the panel, so scrolling cannot clip it');
  assert.equal(popup.hidden, false);
  assert.match(popup.querySelector('.finding-peek-body').textContent, /Manglende nullsjekk/);
  assert.equal(sent.length, 0, 'reading is not sending');

  // Pressing it again puts the popup away.
  await card.querySelector('.control-finding-peek').fire('click');
  assert.equal(body.querySelector('.finding-peek').hidden, true);
});

test('hovering the finding shows the text; the send button never does', async () => {
  const { context, registry, body, sent, caseCallbacks, hoverDelays } = fixture();
  context.renderFindingButtons(structuredClone(report), 'mission-1');
  const card = registry.controlFindingList.children[0];
  const finding = card.querySelector('.control-finding');

  await finding.fire('pointerenter');
  assert.equal(hoverDelays.at(-1), 1100, 'finding hover uses the shared 1.1 second delay');
  assert.equal(body.querySelector('.finding-peek').hidden, false, 'hover explains');
  await finding.fire('pointerleave');
  assert.equal(body.querySelector('.finding-peek').hidden, true, 'and stops explaining');

  const send = card.querySelector('.control-finding-send');
  caseCallbacks[0].onCase({ followups: [] });
  await send.fire('click');
  assert.equal(sent.length, 1, 'the send button sends');
  assert.equal(body.querySelector('.finding-peek').hidden, true, 'and never opens the popup');
});

test('a finding already sent to this agent offers no second send', () => {
  const { context, registry } = fixture();
  const already = { ...report, findings: [{ ...report.findings[0], exactSentTo: ['claude'] }] };
  context.renderFindingButtons(already, 'mission-1');
  const card = registry.controlFindingList.children[0];

  assert.equal(card.querySelector('.control-finding-send').disabled, true);
  assert.match(card.querySelector('.control-finding-send').textContent, /Sendt til Claude Code/);
  assert.ok(card.querySelector('.control-finding').classList.contains('done'));
  // Reading it is still allowed.
  assert.equal(card.querySelector('.control-finding-peek').disabled, false);
});

test('what the validation could not verify is shown, and qualifies a clean verdict', () => {
  const { context, registry } = fixture();
  const limit = 'Kunne ikke kjøre testene: PHP mangler på maskinen.';

  context.renderFindingButtons({ ...report, couldNotCheck: limit }, 'mission-1');
  const shown = registry.controlFindingList.querySelector('.control-finding-limit');
  assert.ok(shown, 'the limit is shown alongside the findings');
  assert.match(shown.textContent, /PHP mangler/);

  // A clean verdict returns early; the limit must still reach the reader,
  // because a clean bill from a validation that ran nothing is worth less.
  context.renderFindingButtons({ ...report, outcome: 'clean', findings: [], couldNotCheck: limit }, 'mission-1');
  assert.ok(registry.controlFindingList.querySelector('.control-finding-limit'), 'a clean verdict shows it too');

  // No claimed limit, no note invented.
  context.renderFindingButtons({ ...report, couldNotCheck: null }, 'mission-1');
  assert.equal(registry.controlFindingList.querySelector('.control-finding-limit'), null);
});

test('a file flagged before is named even when the title is new', () => {
  const { context, registry } = fixture();
  const recurring = { ...report, findings: [{ ...report.findings[0], seenBefore: 0, fileSeenBefore: 3 }] };
  context.renderFindingButtons(recurring, 'mission-1');
  const history = registry.controlFindingList.querySelector('.control-finding-history');
  assert.match(history.textContent, /filen er meldt 3 ganger før/);

  // An exact repeat still reports itself as one, not as a file count.
  const exact = { ...report, findings: [{ ...report.findings[0], seenBefore: 2, fileSeenBefore: 3 }] };
  context.renderFindingButtons(exact, 'mission-1');
  assert.match(registry.controlFindingList.querySelector('.control-finding-history').textContent, /meldt 2 ganger før/);
});

test('certainty is shown only when the validator was less than certain', () => {
  const { context, registry } = fixture();
  const sure = { ...report, findings: [{ ...report.findings[0], confidence: 'sikker' }] };
  context.renderFindingButtons(sure, 'mission-1');
  assert.equal(registry.controlFindingList.querySelector('.control-finding-confidence'), null,
    '"sikker" on every card would say nothing');

  const hedged = { ...report, findings: [{ ...report.findings[0], confidence: 'usikker' }] };
  context.renderFindingButtons(hedged, 'mission-1');
  assert.match(registry.controlFindingList.querySelector('.control-finding-confidence').textContent, /usikker/);
});

test('a proposed test is shown, and never invented', () => {
  const { context, registry } = fixture();
  const withTest = { ...report, findings: [{ ...report.findings[0], test: 'En test som kaller endepunktet uten where.' }] };
  context.renderFindingButtons(withTest, 'mission-1');
  assert.match(registry.controlFindingList.querySelector('.control-finding-test').textContent, /uten where/);

  context.renderFindingButtons({ ...report, findings: [{ ...report.findings[0], test: null }] }, 'mission-1');
  assert.equal(registry.controlFindingList.querySelector('.control-finding-test'), null);
});

test('a finding with similar text is marked without judging its independent value', () => {
  const { context, registry } = fixture();
  const echo = { ...report, findings: [{ ...report.findings[0], echoesWriter: true }] };
  context.renderFindingButtons(echo, 'mission-1');
  const note = registry.controlFindingList.querySelector('.control-finding-echo');
  assert.ok(note, 'textual overlap is visible without claiming how it arose');
  assert.match(note.textContent, /Sammenfall med skriveagentens konklusjon/);

  context.renderFindingButtons(report, 'mission-1');
  assert.equal(registry.controlFindingList.querySelector('.control-finding-echo'), null);
});

test('findings in the same file are grouped under it, worst-served file first', () => {
  const { context, registry } = fixture();
  const make = (title, file) => ({ ...report.findings[0], title, file });
  const many = {
    ...report,
    findings: [
      make('Ett funn her', 'src/lonely.js'),
      make('Manglende vakt', 'src/guards.js'),
      make('Ubrukt import', 'src/guards.js'),
      make('Mangler test', null),
    ],
  };
  context.renderFindingButtons(many, 'mission-1');

  const headings = registry.controlFindingList.querySelectorAll('.control-finding-group');
  assert.equal(headings.length, 1, 'only a file with more than one finding earns a heading');
  assert.match(headings[0].textContent, /src\/guards\.js/);
  assert.match(headings[0].textContent, /2 funn/);

  // The grouped file comes before the single one; a finding with no file last.
  const titles = registry.controlFindingList
    .querySelectorAll('.control-finding-title')
    .map(node => node.textContent);
  assert.deepEqual(titles, ['Manglende vakt', 'Ubrukt import', 'Ett funn her', 'Mangler test']);

  // Every finding is still shown, none swallowed by the grouping.
  assert.equal(registry.controlFindingList.querySelectorAll('.control-finding-send').length, 4);
});

test('a finding can go to an agent other than the one in the canvas', async () => {
  const { context, registry, sent, caseCallbacks } = fixture();
  context.renderFindingButtons(structuredClone(report), 'mission-1');
  const card = registry.controlFindingList.children[0];

  const pick = card.querySelector('.control-finding-to');
  assert.ok(pick, 'switching the canvas and back should not be the only route');
  const offered = pick.children.filter(node => node.value).map(node => node.value);
  assert.deepEqual(offered, ['codex', 'opencode'], 'the selected agent is not offered twice');

  pick.value = 'codex';
  caseCallbacks[0].onCase({ followups: [] });
  await pick.fire('change');
  assert.equal(sent.length, 1);
  assert.equal(sent[0].agentId, 'codex', 'it goes where it was sent, not to the canvas agent');
});

test('an agent that already has the finding is not offered it again', () => {
  const { context, registry } = fixture();
  const already = { ...report, findings: [{ ...report.findings[0], exactSentTo: ['codex'] }] };
  context.renderFindingButtons(already, 'mission-1');
  const pick = registry.controlFindingList.querySelector('.control-finding-to');
  const offered = pick.children.filter(node => node.value).map(node => node.value);
  assert.deepEqual(offered, ['opencode']);
});

test('a finding about earlier same-agent records qualifies rather than disproves independence', () => {
  const { context, registry } = fixture();
  const own = { ...report, findings: [{ ...report.findings[0], ownWork: true }] };
  context.renderFindingButtons(own, 'mission-1');
  const notes = registry.controlFindingList.querySelectorAll('.control-finding-echo');
  assert.equal(notes.length, 1, 'blind mode hides other agents history, not the agent own habits');
  assert.match(notes[0].textContent, /registrert i et tidligere oppdrag fra samme agent/);

  context.renderFindingButtons(report, 'mission-1');
  assert.equal(registry.controlFindingList.querySelector('.control-finding-echo'), null);
});
