// Integration regressions execute the production host and control functions.
// Only the native boundary is simulated; no model, process or user data is used.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const app = fs.readFileSync(path.join(__dirname, '../src/app.js'), 'utf8');
const control = fs.readFileSync(path.join(__dirname, '../src/control.js'), 'utf8');
const settings = fs.readFileSync(path.join(__dirname, '../src/settings.js'), 'utf8');
function fn(source, name) {
  const start = source.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.notEqual(start, -1, name);
  return source.slice(start, source.indexOf('\n}', start) + 2);
}
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
function hostFixture() {
  const calls = [], messages = [];
  const context = {
    console, state: { selection: { project: 'P:/test', agent: 'claude', model: 'claude-choice', level: 'max' }, starting: false },
    window: {}, instructionInput: { value: 'Separate unsent draft\n  keep indentation', focus() {} },
    invoke: async (command, args) => { calls.push({ command, args }); return { accepted: true, missionId: 'writer-followup' }; },
    samePath: (a, b) => a === b,
    projectByPath: p => p === 'P:/test' ? { path: p } : null,
    agentInfo: id => ['claude', 'codex'].includes(id) ? { id, available: true, model: `${id}-default` } : null,
    agentLabel: id => id,
    syncProjectGate() {}, closeBarInfo() {}, closeScopeStrip() {}, scrollToBottom() {},
    pollMissions: async () => {}, renderSetupBar() {},
    showBarInfo: text => messages.push(text), canvasNote: text => messages.push(text),
  };
  vm.createContext(context);
  if (app.includes('function composerLaunchCurrent(')) vm.runInContext(fn(app, 'composerLaunchCurrent'), context);
  vm.runInContext(fn(app, 'launchMission'), context);
  const start = app.indexOf('window.AgentSyncHost = {');
  vm.runInContext(app.slice(start, app.indexOf('\n};', start) + 3), context);
  return { context, host: context.window.AgentSyncHost, calls, messages };
}
function cardFixture() {
  // Reuse the small DOM fixture, but not its always-successful host mock.
  const box = { console, __dirname, require: id => id === 'node:test' ? () => {} : require(id) };
  vm.createContext(box);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'finding-card.test.cjs'), 'utf8')
    + '\nglobalThis.make=fixture; globalThis.sample=report;', box);
  const f = box.make();
  f.context.state.open = true;
  const callbacks = [];
  f.context.window.AgentSyncEvaluations.decorate = (_card, callback) => callbacks.push(callback);
  return { ...f, callbacks, report: structuredClone(box.sample) };
}

test('alternative finding uses the real host, target default model and exact followup link without changing canvas or draft', async () => {
  const f = cardFixture(), h = hostFixture();
  f.context.window.AgentSyncHost = h.host;
  const links = [];
  f.context.invoke = async (command, args) => { links.push({ command, args }); return {}; };
  f.context.renderFindingButtons(f.report, 'mission-1');
  const select = f.registry.controlFindingList.querySelector('select');
  assert.equal(select.disabled, true, 'alternatives also wait for the case status');
  f.callbacks[0].onCase({ followups: [] });
  select.value = 'codex'; await select.fire('change');
  const start = h.calls.find(call => call.command === 'start_mission');
  assert.equal(start?.args.request.agent, 'codex');
  assert.equal(start.args.request.model, 'codex-default');
  assert.equal(h.context.state.selection.agent, 'claude');
  assert.match(h.context.instructionInput.value, /Separate unsent draft/);
  assert.equal(links[0]?.command, 'link_finding_followup');
  const request = JSON.parse(JSON.stringify(links[0].args.request));
  // How long the finding sat in front of a person. Wall clock, so the value
  // itself is not fixed; that it is a number and is sent at all is.
  assert.equal(typeof request.deliberationMs, 'number');
  delete request.deliberationMs;
  assert.deepEqual(request, { missionId: 'mission-1', findingIndex: 0, followupMissionId: 'writer-followup' });
});

test('host still rejects stale project, unavailable target and implicit agent change', async () => {
  const f = hostFixture();
  assert.equal(await f.host.sendToAgent('finding', 'P:/other', 'codex', { allowDifferentAgent: true }), false);
  assert.equal(await f.host.sendToAgent('finding', 'P:/test', 'missing', { allowDifferentAgent: true }), false);
  assert.equal(await f.host.sendToAgent('finding', 'P:/test', 'codex'), false);
  assert.equal(f.calls.length, 0);
});

test('a busy alternative target cannot arm force for the unrelated composer', async () => {
  const f=hostFixture();f.context.state.forceNext=false;
  f.context.invoke=async()=>{throw Error('AGENT_BUSY: codex already runs');};
  await f.host.sendToAgent('finding','P:/test','codex',{allowDifferentAgent:true});
  assert.equal(f.context.state.forceNext,false);
  assert.match(f.context.instructionInput.value,/Separate unsent draft/);
});

test('legacy deliveries remain locked after asynchronous register status', () => {
  const f = cardFixture();
  f.report.findings[0].actedOnBy = ['claude'];
  f.context.renderFindingButtons(f.report, 'mission-1');
  f.callbacks[0].onCase({ followups: [] });
  assert.equal(f.registry.controlFindingList.querySelector('.control-finding-send').disabled, true);
});

function automaticFixture() {
  const calls = [], values = {};
  const source = { id: 'writer-fixture', purpose: 'writer', projectPath: 'P:/test', agent: 'codex', status: 'completed', changedFiles: 1, finishedUnixMs: Date.now() };
  const context = { console, Date, VALIDATOR_QUIET_MS: 1200, VALIDATION_FLOOR_FILES: 2,
    state: { enabled: true, open: true, lifecycle: 1, generation: 1, writerStates: new Map(), pendingSources: new Map(), autoMissionIds: new Map(), launchedRuns: new Set(), enabledSince: Date.now() - 5000 },
    window: { localStorage: { getItem: () => JSON.stringify(values), setItem: (_key, text) => Object.assign(values, JSON.parse(text)) }, dispatchEvent() {} },
    CustomEvent: class {}, samePath: (a,b) => a === b,
    invoke: async () => source, runControl: async options => { calls.push(options); return 'started'; },
  };
  vm.createContext(context); vm.runInContext(settings, context);
  for (const name of ['missionPurpose', 'missionActive', 'missionChangedFiles', 'belowValidationFloor', 'scheduleAutomaticValidation']) vm.runInContext(fn(control, name), context);
  return { context, calls, source, set: (id, value) => context.window.AgentSyncSettings.set(id, value) };
}

test('automatic off neither queues nor launches even one-file changes, and drops already queued work', async () => {
  const f = automaticFixture(); f.set('validation.auto', false);
  f.context.state.pendingSources.set(f.source.id, { source: f.source, since: Date.now() - 2000 });
  await f.context.scheduleAutomaticValidation([f.source]);
  assert.equal(f.calls.length, 0); assert.equal(f.context.state.pendingSources.size, 0);
});

test('switching automatic off while source read is pending blocks launch after the await', async () => {
  const f = automaticFixture(), wait = deferred();
  f.source.changedFiles = 2;
  f.context.invoke = () => wait.promise;
  f.context.state.writerStates.set(f.source.id, 'completed');
  f.context.state.pendingSources.set(f.source.id, { source: f.source, since: Date.now() - 2000 });
  const pending = f.context.scheduleAutomaticValidation([f.source]);
  f.set('validation.auto', false); wait.resolve(f.source); await pending;
  assert.equal(f.calls.length, 0);
});

test('runControl independently rejects automatic launches while off', async () => {
  const f = automaticFixture();
  vm.runInContext(fn(control,'runControl'),f.context);
  f.set('validation.auto',false);
  assert.equal(await f.context.runControl({automatic:true,source:f.source}),'skipped');
});

test('re-enabling automatic does not replay a completion that happened while off', async () => {
  const f = automaticFixture();
  Object.assign(f.context,{hidePeek(){},presentationVisible:()=>false,renderLive(){}});
  f.context.state.findings=new Map();
  vm.runInContext(fn(control,'settingsChanged'),f.context);
  f.set('validation.auto',false); f.context.settingsChanged();
  f.source.changedFiles=2; f.source.finishedUnixMs=Date.now()-1000;
  f.set('validation.auto',true); f.context.settingsChanged();
  await f.context.scheduleAutomaticValidation([f.source]);
  assert.equal(f.context.state.pendingSources.size,0);
});

test('closing the control removes a pinned popup and cancels its delayed hover', async () => {
  const f = cardFixture(); f.context.renderFindingButtons(f.report, 'mission-1');
  await f.registry.controlFindingList.querySelector('.control-finding-peek').fire('click');
  const start = control.indexOf('window.AgentSyncControl = {');
  vm.runInContext(control.slice(start, control.indexOf('\n};', start) + 3), f.context);
  f.context.window.AgentSyncControl.close();
  assert.equal(f.context.peek.node.hidden, true); assert.equal(f.context.peek.pinned, false);
});

test('a failed followup link retries only persistence, never the agent', async () => {
  const f = cardFixture(), h = hostFixture();
  f.context.window.AgentSyncHost = h.host;
  let linkCalls = 0;
  f.context.invoke = async () => { if (++linkCalls === 1) throw Error('write locked'); return {}; };
  f.context.renderFindingButtons(f.report, 'mission-1'); f.callbacks[0].onCase({ followups: [] });
  const pick = f.registry.controlFindingList.querySelector('select');
  pick.value = 'codex'; await pick.fire('change');
  const retry = f.registry.controlVerdict.querySelector('button');
  assert.ok(retry); await retry.fire('click');
  assert.equal(linkCalls, 2); assert.equal(h.calls.length, 1);
  assert.ok(f.report.findings[0].actedOnBy.includes('codex'));
});

test('composer submission consumes only its own unchanged draft after success', async () => {
  const f = hostFixture(), original = f.context.instructionInput.value;
  await f.context.launchMission({ ...f.context.state.selection, prompt: original.trim(), composerDraft: original });
  assert.equal(f.context.instructionInput.value, '');
  const wait = deferred(); f.context.invoke = () => wait.promise;
  f.context.instructionInput.value = 'original';
  const pending = f.context.launchMission({ ...f.context.state.selection, prompt: 'original', composerDraft: 'original' });
  f.context.instructionInput.value = 'new unrelated draft'; wait.resolve({ accepted: true }); await pending;
  assert.equal(f.context.instructionInput.value, 'new unrelated draft');
});

test('file provenance reads coalesce and late results cannot replace newer bar information', async () => {
  const wait = deferred(); let reads = 0;
  const context = {
    state: { selection: { project: 'P:/test' }, barInfoGeneration: 0, projectAuthorReads: new Map() }, window: {},
    invoke: async () => { reads++; return wait.promise; }, projectSetupKey: p => p.toLowerCase(),
    projectByPath: p => ({path:p}), projectParentLabel: () => '', projectDisplayName: () => 'Test', activeMissionsForProject: () => [],
    fileAuthorSummary: () => ' · one record', handoverSummary: () => '', showBarInfo(text) { context.state.barInfoGeneration++; context.lastText=text; },
    // showProjectInfo also reports what happened since the last visit.
    newSinceLastVisit: () => '', rememberProjectSeen() {},
  };
  vm.createContext(context);
  vm.runInContext(fn(app, 'projectFileAuthors')+'\n'+fn(app, 'showProjectInfo'), context);
  const first = context.showProjectInfo(), second = context.showProjectInfo();
  assert.equal(reads, 1);
  context.showBarInfo('Newer quota explanation'); wait.resolve({ files: [{}], warning: 'one unreadable record' });
  await Promise.all([first,second]);
  assert.equal(context.lastText, 'Newer quota explanation'); assert.equal(context.state.projectAuthorReads.size, 0);
});

test('command visibility keeps the journal text and activity nodes available when switched back on', () => {
  const command = {dataset:{command:'true'}, hidden:false}, activity = {dataset:{command:'false'}, hidden:false};
  let show = false;
  const record = { activityNodes: [command, activity], activity: {hidden:false}, activityMore: {hidden:false}, output:'Kommando: codex exec', finished:true };
  const context = {window:{AgentSyncSettings:{enabled:()=>show}}, ACTIVITY_DONE_EDGE:3, ACTIVITY_LIVE_TAIL:6};
  vm.createContext(context); vm.runInContext(fn(app,'layoutActivity'),context);
  context.layoutActivity(record); assert.equal(command.hidden,true); assert.equal(activity.hidden,false);
  show=true; context.layoutActivity(record); assert.equal(command.hidden,false); assert.equal(record.output,'Kommando: codex exec');
});

test('settings rows are named and described, while V displays confirmed runtime state', async () => {
  const f = cardFixture(), nodes = {settingsBody:new f.Element('div'),settingsChanged:new f.Element('span'),railSettingsDot:new f.Element('span')};
  const lookup = id => nodes[id] || Object.values(nodes).flatMap(root=>[...root.querySelectorAll('button'), ...root.querySelectorAll('div')]).find(node=>node.id===id);
  const context = { console, window:{localStorage:{getItem:()=>null,setItem(){}},dispatchEvent(){}}, CustomEvent:class{},
    state:{selection:{project:'P:/test'},validator:{enabled:true,changing:false}}, document:{activeElement:null},
    byId:lookup, element:f.context.element, invoke:async (_command,args)=>({enabled:args.enabled}), projectByPath:()=>({}),
    renderRail(){}, syncControlPanel(){}, showBarInfo(text){context.message=text;}, ensurePolling(){}, canvasNote(){},
  };
  vm.createContext(context); vm.runInContext(settings,context);
  vm.runInContext(fn(app,'renderSettings')+'\n'+fn(app,'setValidatorEnabled'),context);
  context.renderSettings();
  for(const toggle of nodes.settingsBody.querySelectorAll('button')) {
    assert.ok(toggle.attributes['aria-label'].length>3);
    for(const id of toggle.attributes['aria-describedby'].split(' ')) assert.ok(lookup(id),id);
  }
  await context.setValidatorEnabled(false);
  assert.equal(context.window.AgentSyncSettings.own('validation'),false);
  assert.equal(lookup('setting-validation').attributes['aria-checked'],'false');
  context.window.AgentSyncSettings.set('validation.auto',false);
  await context.setValidatorEnabled(true);
  assert.match(context.message,/manuell kontroll/);
  assert.match(context.message,/Automatisk start er av/);
});

test('enabled validator with automatic off presents manual mode, not a pending automatic check', () => {
  const registry={controlLiveBadge:{},controlLiveText:{closest:()=>null}};
  const context={window:{AgentSyncSettings:{enabled:()=>false}},state:{enabled:true,runs:[],pendingSources:new Map()},presentationVisible:()=>true,byId:id=>registry[id],missionActive:()=>false};
  vm.createContext(context);vm.runInContext(fn(control,'renderLive'),context);context.renderLive();
  assert.equal(registry.controlLiveBadge.textContent,'på · manuelt');
  assert.match(registry.controlLiveText.textContent,/Automatisk start er av/);
});

test('manual control remains permitted when only automatic start is off', async () => {
  const f=automaticFixture(); f.set('validation.auto',false);
  f.context.state.agent='claude'; f.context.state.project='P:/test'; f.context.state.started=new Set();
  Object.assign(f.context,{
    byId:id=>({value:id==='controlPrompt'?'Harmless manual check':'',checked:true}),validatorDiffersFromWriter:()=>true,
    setStatus(){},syncRunButton(){},rememberStartedRun(){},showFindings:async()=>{},
    invoke:async(command,args)=>{f.calls.push({command,args});return {missionId:'manual-fixture'};},
  });
  vm.runInContext(fn(control,'runControl'),f.context);
  assert.equal(await f.context.runControl(),'started');
  assert.equal(f.calls[0].args.request.purpose,'manualControl');
});

test('duplicate send during a pending native start stays locked across card redraws', async () => {
  const f=cardFixture(),h=hostFixture(),wait=deferred();
  let starts=0;
  h.context.invoke=async()=>{starts++;return wait.promise;};
  f.context.window.AgentSyncHost=h.host;
  f.context.renderFindingButtons(f.report,'mission-1');f.callbacks[0].onCase({followups:[]});
  const original=f.registry.controlFindingList.querySelector('select');original.value='codex';
  const pending=original.fire('change');
  f.context.renderFindingButtons(f.report,'mission-1');f.callbacks.at(-1).onCase({followups:[]});
  const second=f.registry.controlFindingList.querySelector('select');second.value='codex';
  assert.equal(second.disabled,true);await second.fire('change');assert.equal(starts,1);
  wait.resolve({accepted:true,missionId:'writer-followup'});await pending;
  assert.equal(f.context.state.findingDeliveries.size,0);
});
