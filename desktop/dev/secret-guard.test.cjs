const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const code = fs.readFileSync(path.join(__dirname, '../src/secret-guard.js'), 'utf8');
const settle = () => new Promise(resolve => setImmediate(resolve));
const block = overrides => 'SECRET_GUARD:' + JSON.stringify({ code: 'SECRET_GUARD', token: 'opaque-one-use-token', operation: 'start_mission', recipient: 'provider / model', findings: [{ source: 'prompt', kind: 'API key', line: 3 }], message: 'Blocked', ...overrides });

function fixture(handler) {
  const calls = [];
  class Element {
    constructor(tag) { this.tagName = tag.toUpperCase(); this.children = []; this.events = {}; this.attributes = {}; this.parent = null; this.textContent = ''; this.hidden = false; this.disabled = false; this.open = false; }
    get isConnected() { return this === body || !!this.parent?.isConnected; }
    append(...children) { for (const child of children) { child.parent = this; this.children.push(child); } }
    replaceChildren(...children) { this.children.forEach(child => { child.parent = null; }); this.children = []; this.textContent = ''; this.append(...children); }
    setAttribute(k, v) { this.attributes[k] = v; }
    getAttribute(k) { return this.attributes[k]; }
    addEventListener(name, fn) { this.events[name] = fn; }
    querySelectorAll(selector) { return this.children.flatMap(child => [...(child.tagName.toLowerCase() === selector || selector === '[role="switch"]' && child.attributes.role === 'switch' ? [child] : []), ...child.querySelectorAll(selector)]); }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    contains(node) { return this === node || this.children.some(child => child.contains(node)); }
    focus() { document.activeElement = this; }
    click() { if (!this.disabled) return this.events.click?.(); }
    showModal() { this.open = true; }
    close() { this.open = false; this.events.close?.(); }
    remove() { if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); this.parent = null; }
    scrollIntoView() {}
  }
  const body = new Element('body'), top = new Element('header'), settings = new Element('section'), draft = new Element('textarea');
  body.append(top, settings, draft);
  draft.value = 'A private unsent draft';
  const document = { body, activeElement: draft, createElement: tag => new Element(tag), getElementById: () => null };
  const window = { __TAURI__: { core: { invoke: async (command, args) => { calls.push([command, args]); return handler(command, args); } } } };
  vm.runInNewContext(code, { window, document, structuredClone });
  const api = window.AgentSyncSecretGuard;
  const text = node => node.textContent + ' ' + node.children.map(text).join(' ');
  return { api, calls, body, top, settings, draft, document, text: () => text(body),
    init: () => api.init({ indicatorParent: top }), mount: () => api.mountSettings(settings),
    indicator: () => top.children[0], toggle: () => settings.querySelectorAll('[role="switch"]')[0],
    dialog: () => body.querySelectorAll('dialog')[0],
    button: label => body.querySelectorAll('button').find(item => item.textContent === label) };
}

test('pending and failed settings never claim off; no localStorage or implicit setting write', async () => {
  let reject;
  const f = fixture(() => new Promise((_, fail) => { reject = fail; }));
  f.init(); f.mount();
  assert.equal(f.toggle().disabled, true);
  assert.equal(f.toggle().getAttribute('aria-checked'), 'true');
  assert.doesNotMatch(f.text(), /Hemmelighetsvern av|ekstra kontroll er deaktivert/);
  reject(new Error('unavailable')); await settle();
  assert.match(f.text(), /Status er ikke bekreftet/);
  assert.equal(f.toggle().disabled, true);
  assert.ok(f.calls.every(([command]) => command === 'get_secret_guard_settings'));
});

test('off persists only after backend confirmation and indicator is visible across initialization', async () => {
  let resolve;
  const f = fixture(command => command === 'get_secret_guard_settings' ? { enabled: true } : new Promise(done => { resolve = done; }));
  f.init(); f.mount(); await settle();
  assert.equal(f.indicator().hidden, true);
  f.toggle().click();
  assert.equal(f.toggle().disabled, true);
  assert.equal(f.toggle().getAttribute('aria-checked'), 'true');
  assert.equal(f.indicator().hidden, true);
  resolve({ enabled: false }); await settle();
  assert.equal(f.toggle().getAttribute('aria-checked'), 'false');
  assert.equal(f.indicator().hidden, false);
  assert.equal(f.indicator().textContent, 'Hemmelighetsvern av');
  const restarted = fixture(() => ({ enabled: false })); restarted.init(); await settle();
  assert.equal(restarted.indicator().textContent, 'Hemmelighetsvern av');
});

test('failed save and remount retain confirmed state, no optimistic disabling', async () => {
  let reject;
  const f = fixture(command => command === 'get_secret_guard_settings' ? { enabled: true } : new Promise((_, fail) => { reject = fail; }));
  f.mount(); await settle(); f.toggle().click();
  f.settings.replaceChildren(); f.mount();
  assert.equal(f.toggle().disabled, true);
  reject(new Error('denied')); await settle();
  assert.equal(f.toggle().getAttribute('aria-checked'), 'true');
  assert.equal(f.toggle().disabled, false);
  assert.match(f.text(), /Ikke lagret/);
});

test('late settings reads cannot overwrite the new mounted state', async () => {
  let resolve, count = 0;
  const f = fixture(() => ++count === 1 ? new Promise(done => { resolve = done; }) : { enabled: false });
  f.mount(); f.settings.replaceChildren(); f.mount(); await settle();
  resolve({ enabled: true }); await settle();
  assert.equal(f.toggle().getAttribute('aria-checked'), 'false');
});

test('keyboard switch focus survives save but does not steal focus after moving away', async () => {
  let resolve;
  const f = fixture(command => command === 'get_secret_guard_settings' ? { enabled: true } : new Promise(done => { resolve = done; }));
  f.mount(); await settle(); f.toggle().focus(); f.toggle().click();
  resolve({ enabled: false }); await settle(); assert.equal(f.document.activeElement, f.toggle());
  f.toggle().click(); f.draft.focus(); resolve({ enabled: true }); await settle();
  assert.equal(f.document.activeElement, f.draft);
});

test('cancel transmits nothing further and leaves draft and focus intact', async () => {
  const f = fixture(() => { throw block(); });
  const sent = f.api.invoke('start_mission', { request: { prompt: 'unchanged' } });
  const rejected = assert.rejects(sent, error => error.code === 'SECRET_GUARD');
  await settle(); assert.equal(f.dialog().open, true);
  assert.equal(f.document.activeElement.textContent, 'Avbryt');
  f.button('Avbryt').click(); await rejected;
  assert.equal(f.calls.length, 1); assert.equal(f.draft.value, 'A private unsent draft');
  assert.equal(f.document.activeElement, f.draft); assert.equal(f.dialog(), undefined);
});

test('explicit exception grants then retries exact original args once despite caller mutation', async () => {
  let attempts = 0;
  const f = fixture(command => command === 'start_mission' && ++attempts === 1 ? Promise.reject(block()) : { missionId: 'ok' });
  const args = { request: { prompt: 'original', model: 'chosen-model', projectPath: 'A' } };
  const sent = f.api.invoke('start_mission', args);
  await settle(); args.request.prompt = 'later edit'; args.request.model = 'another-model';
  assert.deepEqual(f.calls.map(([command]) => command), ['start_mission']);
  f.button('Tillat denne overføringen én gang').click();
  assert.equal((await sent).missionId, 'ok');
  assert.deepEqual(f.calls.map(([command]) => command), ['start_mission', 'allow_secret_guard_once', 'start_mission']);
  assert.deepEqual(f.calls[0][1], f.calls[2][1]);
  assert.equal(f.calls[2][1].request.prompt, 'original');
  assert.equal(f.calls[1][1].token, 'opaque-one-use-token');
});

test('dialog traps end-of-list Tab and prevents canvas shortcut propagation', async () => {
  const f = fixture(() => Promise.reject(block()));
  const rejected = assert.rejects(f.api.invoke('start_mission', {}));
  await settle(); const allow = f.button('Tillat denne overføringen én gang'); allow.focus();
  let prevented = 0, stopped = 0;
  f.dialog().events.keydown({ key: 'Tab', preventDefault: () => prevented++, stopPropagation: () => stopped++ });
  assert.equal(f.document.activeElement, f.button('Avbryt'));
  assert.equal(prevented, 1); assert.equal(stopped, 1);
  f.dialog().events.keydown({ key: 'Enter', ctrlKey: true, stopPropagation: () => stopped++ });
  assert.equal(stopped, 2); assert.equal(f.calls.length, 1);
  f.button('Avbryt').click(); await rejected;
});

test('second block is terminal and never starts an approval loop', async () => {
  const f = fixture(command => command === 'allow_secret_guard_once' ? null : Promise.reject(block()));
  const sent = f.api.invoke('review_workspace_changes', { projectPath: 'A' });
  const rejected = assert.rejects(sent, /fortsatt stoppet/);
  await settle(); f.button('Tillat denne overføringen én gang').click(); await rejected;
  assert.equal(f.calls.length, 3); assert.equal(f.dialog(), undefined);
});

test('failed grant does not retry the transfer', async () => {
  const f = fixture(command => Promise.reject(command === 'allow_secret_guard_once' ? new Error('expired') : block()));
  const rejected = assert.rejects(f.api.invoke('resolve_intent', { request: { text: 'original' } }), /Unntaket kunne ikke bekreftes/);
  await settle(); f.button('Tillat denne overføringen én gang').click(); await rejected;
  assert.equal(f.calls.length, 2);
});

test('automatic validator rejects safely without dialog or granting an exception', async () => {
  const f = fixture(() => Promise.reject(block()));
  await assert.rejects(f.api.invoke('start_mission', { request: { purpose: 'validator' } }), /stoppet automatisk validering/);
  assert.equal(f.dialog(), undefined); assert.equal(f.calls.length, 1);
});

test('project change closes dialog and also invalidates late guard responses', async () => {
  const f = fixture(() => Promise.reject(block()));
  const rejected = assert.rejects(f.api.invoke('start_mission', { request: {} }), /avbrutt/);
  await settle(); f.api.projectChanged(); await rejected;
  assert.equal(f.dialog(), undefined); assert.equal(f.calls.length, 1);
  let reject;
  const late = fixture(() => new Promise((_, fail) => { reject = fail; }));
  const stopped = assert.rejects(late.api.invoke('start_mission', { request: {} }), /prosjektet ble endret/);
  late.api.projectChanged(); reject(block()); await stopped;
  assert.equal(late.dialog(), undefined); assert.equal(late.calls.length, 1);
});

test('project change while grant is pending never retries old project', async () => {
  let resolve;
  const f = fixture(command => command === 'allow_secret_guard_once' ? new Promise(done => { resolve = done; }) : Promise.reject(block()));
  const rejected = assert.rejects(f.api.invoke('start_mission', { request: {} }), /prosjektet ble endret/);
  await settle(); f.button('Tillat denne overføringen én gang').click(); await settle();
  f.api.projectChanged(); resolve(null); await rejected; assert.equal(f.calls.length, 2);
});

test('malformed block never exposes raw error and cannot be bypassed', async () => {
  const f = fixture(() => Promise.reject('SECRET_GUARD:malformed-private-payload'));
  await assert.rejects(f.api.invoke('scope_mission', {}), error => error.code === 'SECRET_GUARD' && !error.message.includes('private-payload'));
  assert.equal(f.dialog(), undefined); assert.equal(f.calls.length, 1);
});

test('backend unable-to-scan block has no one-time allow button', async () => {
  const f = fixture(() => Promise.reject(block({ canAllowOnce: false, token: null, findings: [{ source: 'large.bin', kind: 'Cannot scan' }] })));
  const rejected = assert.rejects(f.api.invoke('start_mission', {}), /avbrutt/);
  await settle(); assert.match(f.text(), /kunne ikke kontrolleres/);
  assert.equal(f.button('Tillat denne overføringen én gang'), undefined);
  f.button('Avbryt').click(); await rejected; assert.equal(f.calls.length, 1);
});

test('untrusted labels are inert text, raw message and secret values are not displayed', async () => {
  const f = fixture(() => Promise.reject(block({ recipient: '<img src=x onerror=alert(1)>', message: 'private-value-not-for-ui', findings: [{ source: '<script>notcode()</script>', kind: 'API key', line: 7, value: 'another-private-value' }] })));
  const rejected = assert.rejects(f.api.invoke('start_mission', {}));
  await settle(); assert.match(f.text(), /<script>/); assert.match(f.text(), /linje 7/);
  assert.doesNotMatch(f.text(), /private-value/); assert.equal(f.body.querySelectorAll('script').length, 0);
  assert.equal(f.body.querySelectorAll('img').length, 0);
  f.button('Avbryt').click(); await rejected;
});

test('concurrent blocked transfers do not replace the user approval target', async () => {
  const f = fixture(() => Promise.reject(block()));
  const first = assert.rejects(f.api.invoke('start_mission', { request: { prompt: 'first' } }));
  await settle(); const dialog = f.dialog();
  await assert.rejects(f.api.invoke('start_mission', { request: { prompt: 'second' } }), /annen overføring venter/);
  assert.equal(f.dialog(), dialog); f.button('Avbryt').click(); await first;
  assert.equal(f.calls.length, 2);
});

test('ordinary backend errors and unrelated reads keep their previous behavior', async () => {
  const f = fixture(() => Promise.reject('ordinary failure'));
  await assert.rejects(f.api.invoke('scope_mission', {}), error => error === 'ordinary failure');
  const reads = fixture(() => ({ result: 'normal' }));
  assert.equal((await reads.api.invoke('get_mission_summaries', {})).result, 'normal');
  assert.equal(reads.dialog(), undefined);
});

test('production integrations load guard before callers and stop cancelled advisory scoping', () => {
  for (const [html, script] of [['index.html', 'control.js'], ['classic.html', 'classic.js']]) {
    const source = fs.readFileSync(path.join(__dirname, '../src', html), 'utf8');
    assert.ok(source.indexOf('src="secret-guard.js"') < source.indexOf(`src="${script}"`));
    assert.match(source, /href="secret-guard.css"/);
  }
  const app = fs.readFileSync(path.join(__dirname, '../src/app.js'), 'utf8');
  const scopeCatch = app.slice(app.indexOf('scope = await invoke("scope_mission"'), app.indexOf('if (!composerLaunchCurrent(launch))'));
  assert.match(scopeCatch, /AgentSyncSecretGuard\?\.isBlocked\(error\)[\s\S]*?return;/);
  for (const name of ['app.js', 'control.js', 'classic.js']) {
    assert.match(fs.readFileSync(path.join(__dirname, '../src', name), 'utf8'), /AgentSyncSecretGuard\?\.invoke/);
  }
});

test('actual composer scope cancellation preserves its draft and never falls through to writer startup', async () => {
  const box = { console, __dirname, require: id => id === 'node:test' ? () => {} : require(id) };
  vm.createContext(box);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'health-421.test.cjs'), 'utf8') + '\nglobalThis.makeWriter = writerFixture;', box);
  const writer = box.makeWriter();
  const guard = fixture(() => Promise.reject(block({ operation: 'scope_mission' })));
  writer.context.window.AgentSyncSecretGuard = guard.api;
  writer.context.invoke = guard.api.invoke;
  const prompt = writer.context.instructionInput.value;
  const pending = writer.context.startMission();
  await settle(); assert.equal(guard.dialog().open, true);
  guard.button('Avbryt').click(); await pending;
  assert.deepEqual(guard.calls.map(([command]) => command), ['scope_mission']);
  assert.equal(writer.context.instructionInput.value, prompt);
  assert.equal(writer.context.state.starting, false);
});
