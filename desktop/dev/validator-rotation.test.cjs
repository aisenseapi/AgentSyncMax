// Automatic validation must not always land on the same agent: one agent's
// blind spot would become every validation's blind spot. Executed as production
// code in a small fixture.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const control = fs.readFileSync(path.join(__dirname, '../src/control.js'), 'utf8');

function fn(name) {
  const start = control.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.notEqual(start, -1, name);
  const end = control.indexOf('\n}', start);
  assert.notEqual(end, -1, name);
  return control.slice(start, end + 2);
}

const AGENTS = [
  { id: 'claude', label: 'Claude Code', available: true, model: 'claude-opus-5' },
  { id: 'codex', label: 'Codex', available: true, model: 'gpt-5.6-sol' },
  { id: 'opencode', label: 'OpenCode', available: true, model: 'deepseek-v4-pro' },
  { id: 'antigravity', label: 'Antigravity', available: true, model: 'gemini-3.7-flash' },
];

function fixture({ writer = 'claude', saved = { agent: 'opencode', model: 'deepseek-v4-pro', level: '' } } = {}) {
  const store = new Map();
  const context = {
    console,
    AGENT_ORDER: ['claude', 'codex', 'opencode', 'antigravity', 'cline', 'aider'],
    VALIDATOR_ROTATION_KEY: 'agentsync.v4.validatorRotation',
    state: { project: 'P:/proj', catalog: { models: {} } },
    readPreference: (key, fallback = '') => (store.has(key) ? store.get(key) : fallback),
    plainPath: p => String(p || ''),
    window: { localStorage: { setItem: (k, v) => store.set(k, v) } },
    availableAgents: () => AGENTS,
    validatorSetup: () => saved,
    writerSetup: () => ({ agent: writer, model: 'claude-opus-5' }),
  };
  vm.createContext(context);
  vm.runInContext([fn('validatorRotation'), fn('rememberValidatorUse'), ...(control.includes('function comparableModel(') ? [fn('comparableModel')] : []), fn('validatorChoiceForSource')].join('\n'), context);
  return context;
}

const source = { projectPath: 'P:/proj', agent: 'claude', resolvedModel: 'claude-opus-5' };

test('with nothing used yet, the writer is still never the validator', () => {
  const c = fixture();
  const choice = c.validatorChoiceForSource(source);
  assert.notEqual(choice.agent, 'claude', 'the writer cannot check its own work');
});

test('four validations in a row use four different agents', () => {
  const c = fixture();
  const picked = [];
  for (let i = 0; i < 3; i++) {
    const choice = c.validatorChoiceForSource(source);
    picked.push(choice.agent);
    c.rememberValidatorUse(choice.project, choice.agent);
  }
  assert.equal(new Set(picked).size, picked.length, `expected distinct agents, got ${picked.join(', ')}`);
  assert.ok(!picked.includes('claude'), 'the writer stays out of the rotation');
});

test('once every candidate has run, the least recent comes back first', () => {
  const c = fixture();
  const order = [];
  for (let i = 0; i < 6; i++) {
    const choice = c.validatorChoiceForSource(source);
    order.push(choice.agent);
    c.rememberValidatorUse(choice.project, choice.agent);
  }
  // Three eligible agents, so the fourth pick repeats the first.
  assert.equal(order[3], order[0], `expected the cycle to repeat, got ${order.join(', ')}`);
  assert.equal(order[4], order[1]);
});

test('rotation is remembered per project', () => {
  const c = fixture();
  const first = c.validatorChoiceForSource(source);
  c.rememberValidatorUse('P:/proj', first.agent);
  const other = c.validatorChoiceForSource({ ...source, projectPath: 'P:/annet' });
  assert.equal(c.validatorRotation('P:/annet').length, 0, 'another project starts fresh');
  assert.ok(other.agent);
});

test('transport aliases cannot disguise the same model as an independent validator', () => {
  const c = fixture({saved: {}});
  c.availableAgents = () => [{id: 'opencode', available: true, model: 'ollama-cloud/QWEN3.5:397b'}];
  assert.equal(c.validatorChoiceForSource({...source, resolvedModel: 'qwen3.5:397b'}), null);
});

test('model comparison preserves unknown namespaces and quantization variants', () => {
  const c = fixture();
  c.availableAgents = () => [{id: 'opencode', available: true, model: 'team-a/model:q8'}];
  assert.ok(c.validatorChoiceForSource({...source, resolvedModel: 'team-b/model:q8'}));
  c.availableAgents = () => [{id: 'opencode', available: true, model: 'ollama/model:q8'}];
  assert.ok(c.validatorChoiceForSource({...source, resolvedModel: 'ollama/model:q4'}));
});
