const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const code = fs.readFileSync(path.join(__dirname, '../src/active-memory.js'), 'utf8');
const settle = () => new Promise(resolve => setImmediate(resolve));
const A = 'P:\\Dropbox\\Alpha';
const B = 'P:\\Dropbox\\Beta';
const settings = overrides => ({ enabled: true, ramBudgetMib: 16, ...overrides });
const view = (projectPath = A, overrides = {}) => ({ projectPath, generatedUnixMs: Date.now(), entryPath: 'C:\\cache\\START-HERE.md', markdown: 'Local context for ' + projectPath, warnings: [], sourceCount: 3, cacheSource: 'rebuilt', cachedBytes: 1024, cachedProjects: 1, settings: settings(), ...overrides });

function fixture(handler, options = {}) {
  const calls = [], timers = new Map(), documentEvents = {}, copied = [];
  let now = Date.now(), serial = 0, sharing = true;
  class Clock extends Date { static now() { return now; } }
  class Element {
    constructor(tag) { this.tagName = tag.toUpperCase(); this.children = []; this.events = {}; this.attributes = {}; this.parent = null; this.textContent = ''; this.disabled = false; this.hidden = false; }
    get isConnected() { return this === body || !!this.parent?.isConnected; }
    append(...nodes) { for (const child of nodes) { child.parent = this; this.children.push(child); } }
    replaceChildren(...nodes) { for (const child of this.children) child.parent = null; this.children = []; this.textContent = ''; this.append(...nodes); }
    setAttribute(k, v) { this.attributes[k] = v; }
    getAttribute(k) { return this.attributes[k]; }
    addEventListener(k, fn) { this.events[k] = fn; }
    matches(selector) { const attr = /^\[([^=]+)="([^"]+)"\]$/.exec(selector); return attr ? this.attributes[attr[1]] === attr[2] : this.tagName === selector.toUpperCase(); }
    querySelectorAll(selectors) { return this.children.flatMap(child => [...(selectors.split(',').some(s => child.matches(s.trim())) ? [child] : []), ...child.querySelectorAll(selectors)]); }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    closest(selector) { return selector === '[hidden]' ? this.hidden ? this : this.parent?.closest(selector) || null : null; }
    focus() { document.activeElement = this; documentEvents.focusin?.({ target: this }); }
    select() { this.selected = true; }
  }
  const body = new Element('body'), button = new Element('button'), stage = new Element('main'), settingsBody = new Element('div');
  body.append(button, stage, settingsBody);
  const document = { body, createElement: tag => new Element(tag), activeElement: null, addEventListener: (name, fn) => { documentEvents[name] = fn; } };
  const window = {
    navigator: { clipboard: { writeText: async value => copied.push(value) } },
    AgentSyncSettings: { enabled: () => sharing },
    __TAURI__: { core: { invoke: async (command, args) => { calls.push([command, args]); return handler(command, args); } } }
  };
  vm.runInNewContext(code, { window, document, Date: Clock, setTimeout: (fn, delay) => { timers.set(++serial, { fn, delay }); return serial; }, clearTimeout: id => timers.delete(id) });
  const api = window.AgentSyncActiveMemory;
  api.init({ button, parent: stage, markdown: options.markdown });
  const panel = stage.children[0];
  const text = node => node.textContent + ' ' + (node.innerHTML || '') + node.children.map(text).join(' ');
  return { api, body, button, panel, calls, timers, copied, document, documentEvents, settingsBody,
    text: () => text(panel), settingsText: () => text(settingsBody),
    choose: path => api.projectChanged(path), open: () => button.events.click(),
    mountSettings: () => api.mountSettings(settingsBody),
    refresh: () => panel.querySelectorAll('button')[0].events.click(),
    settingToggle: () => settingsBody.querySelector('[role="switch"]'),
    share: value => { sharing = value; }, advance: ms => { now += ms; },
    tick: async () => { const batch = [...timers.values()]; timers.clear(); for (const timer of batch) await timer.fn(); await settle(); }
  };
}

test('project chip does not read before use; opening and explicit refresh are bounded, close returns focus', async () => {
  const f = fixture((command, args) => command === 'get_active_memory_settings' ? settings() : view(args.projectPath));
  assert.equal(f.button.disabled, true); assert.equal(f.calls.length, 0);
  f.choose(A); assert.equal(f.button.disabled, false); assert.equal(f.calls.length, 0);
  f.open(); await settle(); assert.equal(f.calls.length, 2); assert.equal(f.calls[1][1].force, false);
  assert.match(f.text(), /3 kildeoppføringer/); assert.match(f.text(), /ikke instrukser/);
  f.refresh(); f.refresh(); await settle(); assert.equal(f.calls.length, 3); assert.equal(f.calls[2][1].force, true);
  f.open(); assert.equal(f.panel.hidden, true); assert.equal(f.document.activeElement, f.button);
});

test('project changes clear content immediately and reject late previous-project reads', async () => {
  let resolveA;
  const f = fixture((command, args) => command === 'get_active_memory_settings' ? settings() : args.projectPath === A ? new Promise(resolve => { resolveA = resolve; }) : view(B));
  f.choose(A); f.open(); await settle();
  f.choose(B); assert.equal(f.panel.hidden, true); assert.doesNotMatch(f.text(), /Local context/);
  f.open(); await settle(); assert.match(f.text(), /Beta/);
  resolveA(view(A)); await settle(); assert.match(f.text(), /Beta/); assert.doesNotMatch(f.text(), /Alpha/);
  assert.equal(f.panel.getAttribute('aria-busy'), 'false');
});

test('mismatched project response is an error, not a plausible empty context', async () => {
  const f = fixture(command => command === 'get_active_memory_settings' ? settings() : view(B)); f.choose(A); f.open(); await settle();
  assert.match(f.text(), /Ingen kontekst er bekreftet/); assert.doesNotMatch(f.text(), /Local context/);
});

test('UNC canonical identity matches, but future or old source time is never presented as fresh', async () => {
  const unc = '\\\\host\\share\\Project';
  const f = fixture(command => command === 'get_active_memory_settings' ? settings() : view('\\\\?\\UNC\\host\\share\\Project', { generatedUnixMs: Date.now() + 3600000 }));
  f.choose(unc); f.open(); await settle(); assert.match(f.text(), /fremtiden/); assert.doesNotMatch(f.text(), /Kunne ikke lese/);
  const old = fixture(command => command === 'get_active_memory_settings' ? settings() : view(A, { generatedUnixMs: Date.now() - 3600000 })); old.choose(A); old.open(); await settle(); assert.match(old.text(), /eldre eller har ukjent alder/);
});

test('historical text is inert without the trusted renderer and copy path does not launch anything', async () => {
  const f = fixture(command => command === 'get_active_memory_settings' ? settings() : view(A, { markdown: '<script>danger()</script>', warnings: ['<img onerror="danger()">'] }));
  f.choose(A); f.open(); await settle();
  assert.match(f.text(), /<script>/); assert.equal(f.panel.querySelectorAll('script').length, 0);
  const copy = f.panel.querySelectorAll('button').find(b => b.textContent === 'Kopier sti'); await copy.events.click();
  assert.deepEqual(f.copied, ['C:\\cache\\START-HERE.md']); assert.deepEqual(f.calls.map(c => c[0]), ['get_active_memory_settings', 'get_active_memory']);
});

test('failed setting writes retain the confirmed switch and explain failure', async () => {
  const f = fixture(command => command === 'get_active_memory_settings' ? settings() : Promise.reject(new Error('disk denied')));
  f.mountSettings(); await settle(); const toggle = f.settingToggle(); toggle.events.click();
  assert.equal(toggle.disabled, true); assert.equal(toggle.getAttribute('aria-checked'), 'true');
  await settle(); assert.equal(f.settingToggle().getAttribute('aria-checked'), 'true');
  assert.match(f.settingsText(), /Ikke lagret/); assert.equal(f.settingToggle().disabled, false);
});

test('zero RAM is a persisted cache budget, not a disable of memory or disk', async () => {
  let resolve;
  const f = fixture(command => command === 'get_active_memory_settings' ? settings() : new Promise(r => { resolve = r; }));
  f.mountSettings(); await settle(); const select = f.settingsBody.querySelector('select');
  select.value = '0'; select.events.change(); await settle();
  assert.equal(select.value, '16'); assert.equal(select.disabled, true);
  assert.equal(f.calls[1][1].enabled, true); assert.equal(f.calls[1][1].ramBudgetMib, 0);
  resolve(settings({ ramBudgetMib: 0 })); await settle();
  assert.equal(f.settingsBody.querySelector('select').value, '0'); assert.equal(f.settingToggle().getAttribute('aria-checked'), 'true');
});

test('keyboard RAM changes keep focus through redraw so successive choices remain usable', async () => {
  let resolve;
  const f = fixture(command => command === 'get_active_memory_settings' ? settings() : new Promise(r => { resolve = r; }));
  f.mountSettings(); await settle();
  const select = f.settingsBody.querySelector('select'); select.focus(); select.value = '8'; select.events.change(); await settle();
  // Chromium blurs a disabled/removed focused control to the body.
  f.document.activeElement = f.body;
  resolve(settings({ ramBudgetMib: 8 })); await settle();
  const replacement = f.settingsBody.querySelector('select');
  assert.notEqual(replacement, select); assert.equal(f.document.activeElement, replacement);
  replacement.value = '16'; replacement.events.change(); await settle();
  f.document.activeElement = f.body; resolve(settings({ ramBudgetMib: 16 })); await settle();
  assert.equal(f.document.activeElement, f.settingsBody.querySelector('select'));
  assert.equal(f.document.activeElement.value, '16');
});

test('failed RAM save and successful switch save restore the initiating control only', async () => {
  let reject, resolve;
  const f = fixture(command => command === 'get_active_memory_settings' ? settings() : new Promise((done, error) => { resolve = done; reject = error; }));
  f.mountSettings(); await settle(); const select = f.settingsBody.querySelector('select');
  select.focus(); select.value = '8'; select.events.change(); await settle(); f.document.activeElement = f.body;
  reject(new Error('save failed')); await settle();
  assert.equal(f.document.activeElement, select); assert.equal(select.value, '16');
  const toggle = f.settingToggle(); toggle.focus(); toggle.events.click(); await settle(); f.document.activeElement = f.body;
  resolve(settings({ enabled: false })); await settle();
  assert.equal(f.document.activeElement, f.settingToggle()); assert.equal(f.settingToggle().getAttribute('aria-checked'), 'false');
});

test('saving never steals focus after the user moves away, closes, or remounts Settings', async () => {
  for (const leave of ['focus', 'pointer', 'tab', 'escape', 'hidden', 'remount']) {
    let resolve;
    const f = fixture(command => command === 'get_active_memory_settings' ? settings() : new Promise(r => { resolve = r; }));
    f.mountSettings(); await settle(); const select = f.settingsBody.querySelector('select');
    select.focus(); select.value = '8'; select.events.change(); await settle(); f.document.activeElement = f.body;
    if (leave === 'focus') { f.button.focus(); f.document.activeElement = f.body; }
    if (leave === 'pointer') f.documentEvents.pointerdown({ target: f.body });
    if (leave === 'tab' || leave === 'escape') f.documentEvents.keydown({ key: leave === 'tab' ? 'Tab' : 'Escape', preventDefault() {} });
    if (leave === 'hidden') f.settingsBody.hidden = true;
    if (leave === 'remount') { f.settingsBody.replaceChildren(); f.mountSettings(); }
    resolve(settings({ ramBudgetMib: 8 })); await settle();
    assert.equal(f.document.activeElement, f.body, leave);
  }
});

test('disabled memory never initiates preparation or a project read from the panel', async () => {
  const f = fixture(() => settings({ enabled: false })); f.mountSettings(); await settle();
  f.choose(A); f.api.prepare(A); f.open(); await settle(); await f.tick();
  assert.deepEqual(f.calls.map(c => c[0]), ['get_active_memory_settings']); assert.match(f.text(), /prosjektminne er av/);
});

test('a remounted settings panel cannot be overwritten by a late read or mutation', async () => {
  let resolveWrite, n = 0;
  const f = fixture(command => command === 'set_active_memory_settings' ? new Promise(r => { resolveWrite = r; }) : settings({ enabled: ++n === 1 }));
  f.mountSettings(); await settle(); f.settingToggle().events.click(); await settle();
  f.settingsBody.replaceChildren(); f.mountSettings();
  resolveWrite(settings({ enabled: false })); await settle();
  assert.equal(f.settingToggle().getAttribute('aria-checked'), 'false');
  assert.equal(f.calls.filter(c => c[0] === 'get_active_memory_settings').length, 2);
});

test('background preparation debounces, shares manual reads, and throttles repeat work', async () => {
  let resolveRead;
  const f = fixture(command => command === 'get_active_memory_settings' ? settings() : new Promise(r => { resolveRead = r; }));
  f.mountSettings(); await settle(); f.choose(A); f.api.prepare(A); f.api.prepare(A);
  assert.equal(f.timers.size, 1);
  const tick = f.tick(); await settle(); f.open(); await settle();
  assert.equal(f.calls.filter(c => c[0] === 'get_active_memory').length, 1);
  resolveRead(view(A)); await tick; await settle(); assert.match(f.text(), /Local context/);
  f.api.invalidateAndPrepare(A); assert.equal(f.timers.size, 1);
  assert.ok([...f.timers.values()][0].delay >= 29000);
});

test('queued preparation follows only the latest selected project and sharing can stop it', async () => {
  const f = fixture((command, args) => command === 'get_active_memory_settings' ? settings() : view(args.projectPath));
  f.mountSettings(); await settle(); f.choose(A); f.api.prepare(A); f.choose(B); f.api.prepare(B); await f.tick();
  assert.deepEqual(f.calls.filter(c => c[0] === 'get_active_memory').map(c => c[1].projectPath), [B]);
  f.api.invalidateAndPrepare(B); f.share(false); await f.tick();
  assert.equal(f.calls.filter(c => c[0] === 'get_active_memory').length, 1);
});

test('missing settings backend does not guess on and failed reads remain visible', async () => {
  const f = fixture(() => Promise.reject(new Error('unavailable'))); f.mountSettings(); await settle();
  f.choose(A); f.api.prepare(A); await f.tick(); assert.equal(f.settingToggle(), null); assert.match(f.settingsText(), /Status er ikke bekreftet/);
  f.open(); await settle(); assert.match(f.text(), /Ingen kontekst er bekreftet/);
  assert.equal(f.panel.getAttribute('aria-busy'), 'false');
});

test('startup prepares the selected project without opening Settings, and coalesces startup settings reads', async () => {
  const f = fixture((command, args) => command === 'get_active_memory_settings' ? settings() : view(args.projectPath));
  f.choose(A); f.api.prepare(A); await settle(); await f.tick();
  assert.deepEqual(f.calls.map(c => c[0]), ['get_active_memory_settings', 'get_active_memory']);
  assert.equal(f.panel.hidden, true); assert.equal(f.settingsBody.children.length, 0);
});

test('valid custom backend RAM budgets remain editable rather than appearing corrupt', async () => {
  const f = fixture(() => settings({ ramBudgetMib: 7 })); f.mountSettings(); await settle();
  assert.equal(f.settingsBody.querySelector('select').value, '7'); assert.match(f.settingsText(), /7 MiB · egendefinert/);
  assert.equal(f.calls.filter(c => c[0] === 'get_active_memory_settings').length, 1);
});

test('a writer completion invalidates a concurrent old read and leaves no stale answer visible', async () => {
  let resolve;
  const f = fixture(command => command === 'get_active_memory_settings' ? settings() : new Promise(r => { resolve = r; }));
  f.choose(A); f.open(); await settle(); f.api.invalidateAndPrepare(A);
  resolve(view(A, { markdown: 'STALE ANSWER' })); await settle();
  assert.doesNotMatch(f.text(), /STALE ANSWER/); assert.match(f.text(), /Nytt skrivearbeid/);
  assert.equal(f.panel.getAttribute('aria-busy'), 'false');
});

test('integration keeps the reader explicit and refreshes only current completed writers', () => {
  const app = fs.readFileSync(path.join(__dirname, '../src/app.js'), 'utf8');
  const html = fs.readFileSync(path.join(__dirname, '../src/index.html'), 'utf8');
  assert.match(html, /id="activeMemoryButton"/);
  assert.ok(html.indexOf('src="active-memory.js"') < html.indexOf('src="app.js"'));
  assert.match(app, /AgentSyncActiveMemory\?\.projectChanged\?\.\(nextProject\)/);
  assert.match(app, /wasActive && !record\.history && mission\.status === "completed" && record\.purpose === "writer"/);
  assert.match(app, /markdown: markdownToHtml/);
});
