// The agent record shown beside a choice: how often that agent finished, and
// when it last ran. Executed as production code, so the wording is guarded too.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const app = fs.readFileSync(path.join(__dirname, '../src/app.js'), 'utf8');
function fn(name) {
  const start = app.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, name);
  const end = app.indexOf('\n}', start);
  assert.notEqual(end, -1, name);
  return app.slice(start, end + 2);
}

function fixture(records) {
  const context = { console, window: {}, state: { catalog: { agentRecords: records } } };
  vm.createContext(context);
  vm.runInContext([fn('agentRecord'), fn('agentRecordText')].join('\n'), context);
  return context;
}

const day = 86_400_000;

test('an agent with no finished run says nothing rather than guessing', () => {
  const c = fixture([{ agent: 'aider', runs: 0, completedPercent: 0, changedFiles: 0, lastRunUnixMs: 0 }]);
  assert.equal(c.agentRecordText('aider'), '');
  assert.equal(c.agentRecordText('ukjent'), '');
});

test('the record names the completion rate and when it last ran', () => {
  const c = fixture([{ agent: 'claude', runs: 20, completedPercent: 90, changedFiles: 32, lastRunUnixMs: Date.now() - 3 * day }]);
  const text = c.agentRecordText('claude');
  assert.match(text, /90 % fullført av 20 oppdrag/);
  assert.match(text, /for 3 dager siden/);
});

test('an agent nobody has run for a fortnight is called out', () => {
  // Silent rot is the expensive kind: an agent left broken looks fine until
  // the day it is needed.
  const stale = fixture([{ agent: 'cline', runs: 11, completedPercent: 27, changedFiles: 0, lastRunUnixMs: Date.now() - 20 * day }]);
  assert.match(stale.agentRecordText('cline'), /ikke brukt på to uker/);

  const fresh = fixture([{ agent: 'cline', runs: 11, completedPercent: 27, changedFiles: 0, lastRunUnixMs: Date.now() - 2 * day }]);
  assert.doesNotMatch(fresh.agentRecordText('cline'), /to uker/);
});

test('today and yesterday are said in words, not in days', () => {
  const today = fixture([{ agent: 'codex', runs: 5, completedPercent: 80, changedFiles: 4, lastRunUnixMs: Date.now() - 3_600_000 }]);
  assert.match(today.agentRecordText('codex'), /sist i dag/);

  const yesterday = fixture([{ agent: 'codex', runs: 5, completedPercent: 80, changedFiles: 4, lastRunUnixMs: Date.now() - 1.2 * day }]);
  assert.match(yesterday.agentRecordText('codex'), /sist i går/);
});

// Who last wrote each file. With six agents in one tree this is the question
// asked most often; five files in the real register carry two names.
function authorFixture() {
  const context = { console, window: {}, agentLabel: id => ({ claude: 'Claude Code', codex: 'Codex', aider: 'Aider' }[id] || id) };
  vm.createContext(context);
  vm.runInContext(fn('fileAuthorSummary'), context);
  return context;
}

test('no history means no claim about who wrote what', () => {
  const c = authorFixture();
  assert.equal(c.fileAuthorSummary([]), '');
  assert.equal(c.fileAuthorSummary(null), '');
});

test('authors are named with a count, most files first', () => {
  const c = authorFixture();
  const text = c.fileAuthorSummary([
    { file: 'a.js', agent: 'claude', also: ['claude'] },
    { file: 'b.js', agent: 'codex', also: ['codex'] },
    { file: 'c.js', agent: 'codex', also: ['codex'] },
  ]);
  assert.match(text, /Codex 2 · Claude Code 1/);
  assert.doesNotMatch(text, /registrert i oppdrag hos flere/, 'nothing shared here');
});

test('a file two agents have written is called out', () => {
  // This is where they can undo each other, and it has happened once already.
  const c = authorFixture();
  const text = c.fileAuthorSummary([
    { file: 'app-discover.js', agent: 'claude', also: ['aider', 'claude'] },
    { file: 'b.js', agent: 'codex', also: ['codex'] },
  ]);
  assert.match(text, /1 fil registrert i oppdrag hos flere agenter/);
});

// What happened in a project while you were away. Ten projects in rotation
// makes this the first question on returning to one.
function sinceFixture(seen, missions) {
  const store = new Map([['agentsync.v4.projectSeen', JSON.stringify(seen)]]);
  const context = {
    console,
    window: {},
    readPreference: (key, fallback = '') => (store.has(key) ? store.get(key) : fallback),
    writePreference: (key, value) => store.set(key, value),
    plainPath: p => String(p || ''),
    agentLabel: id => ({ claude: 'Claude Code', codex: 'Codex' }[id] || id),
    state: { catalog: { recentMissions: missions } },
    Date,
    // The key is a module-level const; extracting the functions leaves it behind.
    PROJECT_SEEN_KEY: 'agentsync.v4.projectSeen',
  };
  vm.createContext(context);
  vm.runInContext([fn('projectLastSeen'), fn('rememberProjectSeen'), fn('newSinceLastVisit')].join('\n'), context);
  return context;
}

test('a project you have never opened makes no claim about what is new', () => {
  const c = sinceFixture({}, [{ agent: 'claude', startedUnixMs: Date.now() }]);
  assert.equal(c.newSinceLastVisit('P:/proj', c.state.catalog.recentMissions), '');
});

test('only runs newer than your last visit are counted, and the agents named', () => {
  const hour = 3_600_000;
  const seen = { 'p:/proj': Date.now() - 2 * hour };
  const missions = [
    { agent: 'claude', projectPath: 'P:/proj', startedUnixMs: Date.now() - 3 * hour },
    { agent: 'claude', projectPath: 'P:/proj', startedUnixMs: Date.now() - hour },
    { agent: 'codex', projectPath: 'P:/proj', startedUnixMs: Date.now() - hour / 2 },
  ];
  const c = sinceFixture(seen, missions);
  const text = c.newSinceLastVisit('P:/proj', missions);
  assert.match(text, /2 kjøringer siden sist/, 'the one before the visit does not count');
  assert.match(text, /Claude Code og Codex/);
});

test('opening project information marks only the catalog coverage as seen', () => {
  const c = sinceFixture({}, []);
  const coverage = Date.now() - 60_000;
  assert.equal(c.projectLastSeen('P:/proj'), 0);
  c.rememberProjectSeen('P:/proj', coverage);
  assert.equal(c.projectLastSeen('P:/proj'), coverage);
  const later = [{projectPath: 'P:/proj', agent: 'claude', startedUnixMs: coverage + 10_000}];
  assert.match(c.newSinceLastVisit('P:/proj', later), /1 kjøring siden sist/);
});

test('unknown catalog coverage cannot mark unseen records, and an older snapshot cannot rewind the mark', () => {
  const seen = Date.now() - 20_000;
  const c = sinceFixture({'p:/proj': seen}, []);
  c.rememberProjectSeen('P:/proj');
  c.rememberProjectSeen('P:/proj', Number.NaN);
  c.rememberProjectSeen('P:/proj', seen - 5_000);
  assert.equal(c.projectLastSeen('P:/proj'), seen);
});

test('a bounded or incomplete catalog presents the count as a lower bound', () => {
  const c = sinceFixture({'p:/proj': 10}, []);
  c.state.catalog.recentMissionsTruncated = true;
  assert.match(c.newSinceLastVisit('P:/proj', [{projectPath: 'P:/proj', agent: 'claude', startedUnixMs: 20}]), /minst 1 kjøring/);
  assert.match(c.newSinceLastVisit('P:/proj', []), /ufullstendig/);
});

test('runs in other projects are not reported as having happened here', () => {
  const hour = 3_600_000;
  const seen = { 'p:/proj': Date.now() - 2 * hour };
  const missions = [
    { agent: 'claude', projectPath: 'P:/proj', startedUnixMs: Date.now() - hour },
    { agent: 'codex', projectPath: 'P:/annet', startedUnixMs: Date.now() - hour },
  ];
  const c = sinceFixture(seen, missions);
  const text = c.newSinceLastVisit('P:/proj', missions);
  assert.match(text, /1 kjøring siden sist/);
  assert.doesNotMatch(text, /Codex/, 'the other project is not this one');
});

test('an agent whose last runs all failed is called out, even on a good rate', () => {
  // cline sits near 70 per cent over its whole history. What matters before
  // handing it the next job is that the last three runs failed.
  const c = fixture([{ agent: 'cline', runs: 20, completedPercent: 73, changedFiles: 9,
    lastRunUnixMs: Date.now() - 2 * 60 * 60 * 1000, recentFailures: 3 }]);
  const text = c.agentRecordText('cline');
  assert.match(text, /73 % fullført av 20 oppdrag/);
  assert.match(text, /de 3 siste kjøringene feilet/);
});

test('one failure is not a pattern and is left unsaid', () => {
  const c = fixture([{ agent: 'codex', runs: 12, completedPercent: 92, changedFiles: 4,
    lastRunUnixMs: Date.now() - 60 * 60 * 1000, recentFailures: 1 }]);
  assert.doesNotMatch(c.agentRecordText('codex'), /feilet/);
});

test('the warning is a switch, and an old record without the count is silent', () => {
  const off = { window: { AgentSyncSettings: { enabled: id => id !== 'record.failures', used() {} } } };
  const c = fixture([{ agent: 'cline', runs: 20, completedPercent: 73, changedFiles: 9,
    lastRunUnixMs: Date.now(), recentFailures: 3 }]);
  Object.assign(c.window, off.window);
  assert.doesNotMatch(c.agentRecordText('cline'), /feilet/);
  // A record written before the count existed must not read as three failures.
  const old = fixture([{ agent: 'aider', runs: 5, completedPercent: 80, changedFiles: 2, lastRunUnixMs: Date.now() }]);
  assert.doesNotMatch(old.agentRecordText('aider'), /feilet/);
});
