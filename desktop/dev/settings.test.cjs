// The switch hierarchy. The property that matters: turning a master off must
// never write to its children, so they come back exactly as they were.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../src/settings.js'), 'utf8');

function load(seed = {}) {
  const store = new Map();
  if (Object.keys(seed).length) store.set('agentsync.v4.settings', JSON.stringify(seed));
  const events = [];
  const context = {
    console,
    CustomEvent: class { constructor(name, init) { this.type = name; Object.assign(this, init); } },
    window: {
      localStorage: {
        getItem: key => (store.has(key) ? store.get(key) : null),
        setItem: (key, value) => store.set(key, value),
      },
      dispatchEvent: event => events.push(event),
    },
  };
  vm.createContext(context);
  vm.runInContext(source, context);
  return { settings: context.window.AgentSyncSettings, store, events };
}

test('everything is on until someone turns it off', () => {
  const { settings } = load();
  assert.equal(settings.enabled('findings.confidence'), true);
  assert.equal(settings.changedCount(), 0);
});

test('a master off takes its children out of effect without changing them', () => {
  const { settings } = load();
  settings.set('findings', false);

  assert.equal(settings.enabled('findings.confidence'), false, 'not in effect');
  assert.equal(settings.own('findings.confidence'), true, 'but its own value is untouched');
  assert.equal(settings.blockedBy('findings.confidence').id, 'findings');
});

test('turning the master back on restores exactly what was there before', () => {
  const { settings } = load();
  // The user turns two children off, then the master, then the master back on.
  settings.set('findings.test', false);
  settings.set('findings.echo', false);
  settings.set('findings', false);
  settings.set('findings', true);

  assert.equal(settings.enabled('findings.test'), false, 'stayed off, as the user left it');
  assert.equal(settings.enabled('findings.echo'), false);
  assert.equal(settings.enabled('findings.confidence'), true, 'and the untouched one is back');
});

test('a grandchild needs every master above it', () => {
  const { settings } = load();
  settings.set('validation.auto', false);
  assert.equal(settings.enabled('validation.rotate'), false, 'its parent is off');
  assert.equal(settings.blockedBy('validation.rotate').id, 'validation.auto');

  settings.set('validation.auto', true);
  settings.set('validation', false);
  assert.equal(settings.enabled('validation.rotate'), false, 'its grandparent is off');
  assert.equal(settings.blockedBy('validation.rotate').id, 'validation');
});

test('the count says how far the setup is from standard', () => {
  const { settings } = load();
  settings.set('findings.test', false);
  settings.set('record.command', false);
  assert.equal(settings.changedCount(), 2);

  settings.reset();
  assert.equal(settings.changedCount(), 0);
  assert.equal(settings.enabled('findings.test'), true);
});

test('an unknown switch is never a reason to hide something', () => {
  const { settings } = load();
  assert.equal(settings.enabled('finnes.ikke'), true, 'unknown ids must not turn features off');
  assert.equal(settings.blockedBy('finnes.ikke'), null);
});

test('a corrupt stored value falls back to the defaults', () => {
  const store = new Map([['agentsync.v4.settings', 'ikke json']]);
  const context = {
    console,
    CustomEvent: class {},
    window: { localStorage: { getItem: k => store.get(k) ?? null, setItem: () => {} }, dispatchEvent: () => {} },
  };
  vm.createContext(context);
  vm.runInContext(source, context);
  assert.equal(context.window.AgentSyncSettings.enabled('findings.test'), true);
});

test('retired cost and engine switches are not offered and legacy values survive reset', () => {
  const { settings, store } = load({'cost.shareCheckpoint':false,'engine.slowCycle':false});
  const ids = settings.groups().flatMap(group=>group.items.map(item=>item.id));
  assert.equal(ids.includes('cost.shareCheckpoint'),false);
  assert.equal(ids.includes('engine.slowCycle'),false);
  settings.reset();
  const persisted=JSON.parse(store.get(settings.KEY));
  assert.equal(persisted['cost.shareCheckpoint'],false);
  assert.equal(persisted['engine.slowCycle'],false);
});

test('the new switches hang off the right masters and default to on', () => {
  const { settings } = load();
  for (const id of ['validation.blind', 'validation.progress', 'collab.posts',
                    'collab.handovers', 'flow.shortcut', 'flow.deliberation', 'record.failures']) {
    assert.equal(settings.enabled(id), true, id);
  }
  // Blind and the progress line both die with the validation master.
  settings.set('validation', false);
  assert.equal(settings.enabled('validation.blind'), false);
  assert.equal(settings.enabled('validation.progress'), false);
  settings.set('validation', true);
  assert.equal(settings.enabled('validation.blind'), true);
});

test('turning off sharing between agents takes both halves and gives them back', () => {
  const { settings } = load();
  settings.set('collab.handovers', false);
  settings.set('collab', false);
  assert.equal(settings.enabled('collab.posts'), false);
  settings.set('collab', true);
  // The post switch returns on; the handover switch returns off, because that
  // is what it was set to. A master never writes to its children.
  assert.equal(settings.enabled('collab.posts'), true);
  assert.equal(settings.enabled('collab.handovers'), false);
});

test('the failure warning depends on the agent record, not only on the register', () => {
  const { settings } = load();
  settings.set('record.agent', false);
  assert.equal(settings.enabled('record.failures'), false);
  settings.set('record.agent', true);
  settings.set('record', false);
  assert.equal(settings.enabled('record.failures'), false);
});

test('a use is recorded, counted and kept apart from the switch value', () => {
  const { settings, store } = load();
  settings.used('findings.peek');
  const first = settings.lastUsed('findings.peek');
  assert.equal(typeof first.at, 'number');
  assert.equal(first.count, 1);
  // Within the minute the same use is not written again: a render loop must
  // not hammer storage.
  settings.used('findings.peek');
  assert.equal(settings.lastUsed('findings.peek').count, 1);
  // A switch nobody has touched simply has no record, rather than a zero that
  // reads as "used never" when the counter is younger than the feature.
  assert.equal(settings.lastUsed('findings.group'), null);
  // Two stores, so resetting the switches never erases what was used.
  assert.ok(store.has('agentsync.v4.settings.use'));
  settings.reset();
  assert.equal(settings.lastUsed('findings.peek').count, 1);
});

test('an unknown switch records nothing', () => {
  const { settings } = load();
  settings.used('finnes.ikke');
  assert.equal(settings.lastUsed('finnes.ikke'), null);
});

test('an observed child effect records active masters, but disabled features record no positive use', () => {
  const {settings} = load();
  settings.used('findings.test');
  assert.ok(settings.lastUsed('findings'));
  settings.set('validation', false);
  settings.used('validation.auto');
  assert.equal(settings.lastUsed('validation.auto'), null);
});
