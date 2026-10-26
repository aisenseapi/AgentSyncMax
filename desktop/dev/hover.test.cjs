// The app explains itself in its own frame. The browser's tooltip is slow,
// unstyled and cannot be read against the canvas, so nothing in AgentSync Max
// uses it. Executed as production code, so the wiring is guarded too.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const src = (name) => fs.readFileSync(path.join(__dirname, '../src', name), 'utf8');
function fn(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, name);
  const end = source.indexOf('\n}', start);
  assert.notEqual(end, -1, name);
  return source.slice(start, end + 2);
}

const control = src('control.js');
const app = src('app.js');

function fixture() {
  let nextTimer = 0;
  const timers = new Map();
  class Node {
    constructor(tag = 'div', className = '') {
      this.tag = tag; this.className = className; this.dataset = {}; this.style = {};
      this.attributes = {}; this.events = {}; this.children = []; this._text = '';
      this.hidden = false; this.isConnected = true; this.offsetWidth = 100; this.offsetHeight = 40;
    }
    append(...nodes) { for (const n of nodes) this.children.push(n); }
    replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
    setAttribute(key, value) { this.attributes[key] = value; }
    getAttribute(key) { return Object.hasOwn(this.attributes, key) ? this.attributes[key] : null; }
    addEventListener(key, handler) { (this.events[key] ||= []).push(handler); }
    fire(key) { for (const handler of this.events[key] || []) handler({ target: this }); }
    getBoundingClientRect() { return { left: 10, top: 10, right: 110, bottom: 50, width: 100, height: 40 }; }
    get textContent() { return this._text + this.children.map((c) => (typeof c === 'string' ? c : c.textContent)).join(''); }
    set textContent(value) { this.children = []; this._text = String(value); }
  }
  const context = {
    console,
    HOVER_PEEK_DELAY_MS: 1100,
    peek: { node: null, anchor: null, pinned: false, timer: 0 },
    element: (tag, className = '', text) => { const n = new Node(tag, className); if (text !== undefined) n.textContent = text; return n; },
    document: { body: new Node('body') },
    window: {
      innerWidth: 1280,
      innerHeight: 800,
      setTimeout(callback, delay) { timers.set(++nextTimer, { callback, delay }); return nextTimer; },
      clearTimeout(timer) { timers.delete(timer); },
    },
  };
  context.window.document = context.document;
  vm.createContext(context);
  vm.runInContext([
    fn(control, 'peekNode'), fn(control, 'hidePeek'), fn(control, 'layoutScale'),
    fn(control, 'showPeek'), fn(control, 'attachPeek'),
  ].join('\n'), context);
  context.window.AgentSyncPeek = {
    attach: context.attachPeek,
    show: context.showPeek,
    hide: context.hidePeek,
    pinned: () => context.peek.pinned,
  };
  vm.runInContext(fn(app, 'tip') + '\n' + fn(app, 'actorStripe'), context);
  return {
    context,
    Node,
    timers,
    flushTimers() {
      const pending = [...timers.values()];
      timers.clear();
      for (const { callback } of pending) callback();
    },
  };
}

test('hovering waits 1.1 seconds before opening and leaving closes it', () => {
  const { context, timers, flushTimers } = fixture();
  const button = context.element('button', 'rail-item');
  context.attachPeek(button, 'Motoren kjører', { head: 'Motor' });
  assert.equal(context.peek.node, null, 'nothing is built before anyone hovers');

  button.fire('pointerenter');
  assert.equal(context.peek.node, null, 'the hover must not open immediately');
  assert.deepEqual([...timers.values()].map(item => item.delay), [1100]);
  flushTimers();
  assert.equal(context.peek.node.hidden, false);
  assert.match(context.peek.node.textContent, /Motor/);
  assert.match(context.peek.node.textContent, /Motoren kjører/);

  button.fire('pointerleave');
  assert.equal(context.peek.node.hidden, true);
});

test('leaving before 1.1 seconds cancels the pending explanation', () => {
  const { context, timers, flushTimers } = fixture();
  const button = context.element('button');
  context.attachPeek(button, 'Skal aldri vises');
  button.fire('pointerenter');
  assert.equal(timers.size, 1);
  button.fire('pointerleave');
  assert.equal(timers.size, 0);
  flushTimers();
  assert.equal(context.peek.node, null);
});

test('the public force-hide resets a pending or pinned popup at a project boundary', () => {
  const { context, timers, flushTimers } = fixture();
  const button = context.element('button');
  context.attachPeek(button, 'Old project');
  button.fire('pointerenter');
  assert.equal(timers.size, 1);
  context.window.AgentSyncPeek.hide({ force: true });
  assert.equal(timers.size, 0);
  assert.equal(context.peek.anchor, null);
  flushTimers();
  assert.equal(context.peek.node, null);

  context.showPeek(button, 'Pinned old project', { pinned: true });
  context.window.AgentSyncPeek.hide({ force: true });
  assert.equal(context.peek.pinned, false);
  assert.equal(context.peek.anchor, null);
  assert.equal(context.peek.node.hidden, true);
});

test('keyboard focus explains immediately without waiting for hover delay', () => {
  const { context, timers } = fixture();
  const button = context.element('button');
  context.attachPeek(button, 'Tilgjengelig forklaring');
  button.fire('focus');
  assert.equal(timers.size, 0);
  assert.match(context.peek.node.textContent, /Tilgjengelig forklaring/);
  button.fire('blur');
  assert.equal(context.peek.node.hidden, true);
});

test('a value that moves is read when delayed hover opens, not when it was wired up', () => {
  const { context, flushTimers } = fixture();
  let minutes = 1;
  const button = context.element('button');
  context.attachPeek(button, () => `${minutes} min`);
  button.fire('pointerenter');
  flushTimers();
  assert.match(context.peek.node.textContent, /1 min/);
  button.fire('pointerleave');
  minutes = 7;
  button.fire('pointerenter');
  flushTimers();
  assert.match(context.peek.node.textContent, /7 min/, 'the text is not frozen on the element');
});

test('an icon-only control keeps a name; one that already reads aloud is left alone', () => {
  const { context } = fixture();
  const icon = context.element('button');
  context.attachPeek(icon, 'Ingen agent kjører i prosjektet');
  assert.equal(icon.getAttribute('aria-label'), 'Ingen agent kjører i prosjektet',
    'removing the native title must not leave the control unnamed');

  const labelled = context.element('button');
  labelled.textContent = 'Stopp alle';
  context.attachPeek(labelled, 'Send avbryt-signal');
  assert.equal(labelled.getAttribute('aria-label'), null, 'a visible label is never overwritten');

  const named = context.element('button');
  named.setAttribute('aria-label', 'Eget navn');
  context.attachPeek(named, 'Noe annet');
  assert.equal(named.getAttribute('aria-label'), 'Eget navn');
});

test('a pinned finding keeps the box; hovering past something else cannot steal it', () => {
  const { context } = fixture();
  const finding = context.element('div');
  context.showPeek(finding, 'Hele kritikken', { pinned: true });
  const other = context.element('button');
  context.attachPeek(other, 'Noe helt annet');
  other.fire('pointerenter');
  assert.match(context.peek.node.textContent, /Hele kritikken/);
  assert.equal(context.peek.anchor, finding);
});

test('an empty explanation opens nothing at all', () => {
  const { context, flushTimers } = fixture();
  const button = context.element('button');
  context.attachPeek(button, () => '');
  button.fire('pointerenter');
  flushTimers();
  assert.equal(context.peek.node, null);
  assert.equal(button.getAttribute('aria-label'), null);
});

test('the actor stripe is its own layer, reachable and named', () => {
  const { context, flushTimers } = fixture();
  const stripe = context.actorStripe('Claude Code · fable-5-1 · skriveoppdrag');
  assert.equal(stripe.className, 'entry-actor');
  // A three pixel stripe has to be reachable by keyboard as well as by mouse.
  assert.equal(stripe.tabIndex, 0);
  assert.equal(stripe.getAttribute('role'), 'img');
  stripe.fire('pointerenter');
  flushTimers();
  assert.match(context.peek.node.textContent, /Hvem/);
  assert.match(context.peek.node.textContent, /Claude Code · fable-5-1 · skriveoppdrag/,
    'the colour alone is not enough until you have been told what it means');
});

test('a redraw refreshes what the box says without stacking a second listener', () => {
  const { context, flushTimers } = fixture();
  const button = context.element('button');
  // The panel redraws and wires the same persistent element again. A native
  // title was reassigned every time; this has to behave the same way, or a
  // control that changed state keeps explaining the state it was drawn in.
  context.attachPeek(button, 'Valideringsagent av', { head: 'Første' });
  context.attachPeek(button, 'Valideringsagenten arbeider', { head: 'Andre' });
  assert.equal(button.events.pointerenter.length, 1, 'listeners are wired once');
  button.fire('pointerenter');
  flushTimers();
  assert.match(context.peek.node.textContent, /Valideringsagenten arbeider/);
  assert.match(context.peek.node.textContent, /Andre/);
});

test('a name this put on a control is refreshed too, and a foreign one is not', () => {
  const { context } = fixture();
  const icon = context.element('button');
  context.attachPeek(icon, 'Ingen agent kjører');
  assert.equal(icon.getAttribute('aria-label'), 'Ingen agent kjører');
  context.attachPeek(icon, 'Claude Code · 2 min');
  assert.equal(icon.getAttribute('aria-label'), 'Claude Code · 2 min',
    'the accessible name must not go stale either');

  const foreign = context.element('button');
  foreign.setAttribute('aria-label', 'Satt av noen andre');
  context.attachPeek(foreign, 'Noe');
  context.attachPeek(foreign, 'Noe annet');
  assert.equal(foreign.getAttribute('aria-label'), 'Satt av noen andre');
});

test('AgentSync Max sources do not bypass the delay with native title tooltips', () => {
  assert.doesNotMatch(src('index.html'), /\btitle\s*=/);
  for (const name of ['app.js', 'control.js', 'evaluation.js', 'wiki-review.js']) {
    const text = src(name);
    assert.doesNotMatch(text, /setAttribute\(\s*["']title["']|\.title\s*=/, name);
  }
});
