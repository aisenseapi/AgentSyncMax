// The distance from a finding on screen to something happening, and what that
// distance cost. Executed as production code, so the wording is guarded too.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const control = fs.readFileSync(path.join(__dirname, '../src/control.js'), 'utf8');
function fn(name) {
  const start = control.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, name);
  const end = control.indexOf('\n}', start);
  assert.notEqual(end, -1, name);
  return control.slice(start, end + 2);
}

// --- 76: how long it has been going ----------------------------------------
function progressFixture(estimates = new Map()) {
  const context = {
    console, window: {}, SECONDS_PER_CHANGED_FILE: 80,
    state: { autoEstimates: estimates },
    missionChangedFiles: mission => mission.changedFiles || 0,
  };
  vm.createContext(context);
  vm.runInContext([fn('runProgress'), fn('runStatus')].join('\n'), context);
  return context;
}

const minute = 60_000;

test('a control that has just started says so rather than nothing', () => {
  const c = progressFixture();
  const status = c.runStatus({ status: 'running', phase: 'arbeider', startedUnixMs: Date.now() - 20_000 });
  assert.match(status, /arbeider · under ett minutt/);
});

test('minutes are counted while it runs, and only while it runs', () => {
  const c = progressFixture();
  const started = Date.now() - 7 * minute;
  assert.match(c.runStatus({ status: 'running', phase: 'arbeider', startedUnixMs: started }), /7 min/);
  assert.match(c.runStatus({ status: 'queued', phase: '', startedUnixMs: started }), /venter · 7 min/);
  // A run that ended is a result, not a duration.
  assert.equal(c.runStatus({ status: 'completed', startedUnixMs: started }), 'ferdig');
  assert.equal(c.runStatus({ status: 'failed', startedUnixMs: started }), 'feilet');
});

test('past double the estimate it says so, and without an estimate it says nothing about one', () => {
  const kept = new Map([['mission-1', 3]]);
  const c = progressFixture(kept);
  const started = Date.now() - 7 * minute;
  assert.match(c.runStatus({ id: 'mission-1', status: 'running', phase: 'arbeider', startedUnixMs: started }),
    /over dobbelt av anslaget på 3 min/);
  // Still inside twice the estimate: the elapsed time is enough on its own.
  assert.doesNotMatch(c.runStatus({ id: 'mission-1', status: 'running', phase: 'arbeider', startedUnixMs: Date.now() - 5 * minute }),
    /anslaget/);
  // A manual control has no change to estimate from, so it claims none.
  assert.doesNotMatch(c.runStatus({ id: 'manual', status: 'running', phase: 'arbeider', startedUnixMs: started }),
    /anslaget/);
});

test('the progress line is a switch, and a run without a start time is left alone', () => {
  const c = progressFixture(new Map([['mission-1', 3]]));
  c.window.AgentSyncSettings = { enabled: id => id !== 'validation.progress' };
  assert.equal(c.runStatus({ id: 'mission-1', status: 'running', phase: 'arbeider', startedUnixMs: Date.now() - 7 * minute }), 'arbeider');
  c.window.AgentSyncSettings = null;
  assert.equal(c.runStatus({ id: 'mission-1', status: 'running', phase: 'arbeider', startedUnixMs: 0 }), 'arbeider');
});

// --- 77 and 78: the shortcut, and what the wait cost ------------------------
function cardFixture() {
  const box = { console, __dirname, require: id => (id === 'node:test' ? () => {} : require(id)) };
  vm.createContext(box);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'finding-card.test.cjs'), 'utf8')
    + '\nglobalThis.make=fixture; globalThis.sample=report;', box);
  return { ...box.make(), report: structuredClone(box.sample) };
}

test('the keyboard reaches the topmost finding, and only once the register has answered', async () => {
  const f = cardFixture();
  f.context.renderFindingButtons(f.report, 'mission-1');
  assert.equal(typeof f.context.state.topSend, 'function');
  // Before the register says what happened to this finding the button is
  // disabled, and the shortcut goes through that same guard.
  f.context.state.topSend();
  assert.equal(f.sent.length, 0, 'nothing is sent while the status is unknown');

  f.caseCallbacks[0].onCase({ followups: [] });
  await f.context.state.topSend();
  assert.equal(f.sent.length, 1, 'and it sends once the button would');
});

test('a verdict with no cards leaves no shortcut aimed at the list before it', () => {
  const f = cardFixture();
  f.context.renderFindingButtons(f.report, 'mission-1');
  assert.equal(typeof f.context.state.topSend, 'function');
  // A clean verdict has no card to send, and drawing one must drop the
  // shortcut rather than leave it aimed at the list that was there before.
  f.context.renderFindingButtons({ ...f.report, outcome: 'clean', findings: [] }, 'mission-1');
  assert.equal(f.context.state.topSend, null);
});

test('the clock starts when the findings are put in front of someone, and a redraw does not restart it', () => {
  const f = cardFixture();
  f.context.renderFindingButtons(f.report, 'mission-1');
  const first = f.context.state.findingsShownAt.get('mission-1');
  assert.equal(typeof first, 'number');
  f.context.renderFindingButtons(f.report, 'mission-1');
  assert.equal(f.context.state.findingsShownAt.get('mission-1'), first, 'the reader started once');
});

test('a list rendered into a hidden panel starts no clock nobody is watching', () => {
  const f = cardFixture();
  f.context.presentationVisible = () => false;
  f.context.renderFindingButtons(f.report, 'mission-2');
  assert.equal(f.context.state.findingsShownAt.has('mission-2'), false);
});
