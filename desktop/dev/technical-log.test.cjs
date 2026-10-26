// The provider's complete stderr remains in the mission record. These tests
// execute the production presentation helpers that keep its default canvas
// view compact without destroying anything the reader may need later.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const app = fs.readFileSync(path.join(__dirname, '../src/app.js'), 'utf8');

function declaration(name) {
  const start = app.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, name);
  const brace = app.indexOf('{', start);
  let depth = 0;
  let quote = '';
  let escaped = false;
  for (let index = brace; index < app.length; index += 1) {
    const char = app[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = '';
      continue;
    }
    if (char === '"' || char === "'" || char === '`') { quote = char; continue; }
    if (char === '{') depth += 1;
    if (char === '}' && --depth === 0) return app.slice(start, index + 1);
  }
  assert.fail(`unterminated ${name}`);
}

function fixture() {
  let following = true;
  const canvasChanges = [];
  const context = vm.createContext({
    TECHNICAL_LOG_PREVIEW_LINES: 6,
    TECHNICAL_LOG_PREVIEW_CHARS: 1600,
    missionContentVisible: () => true,
    isAtBottom: () => following,
    afterCanvasChange: value => canvasChanges.push(value),
  });
  vm.runInContext([
    declaration('technicalLineKey'),
    declaration('technicalOutputView'),
    declaration('renderErrors'),
    declaration('toggleTechnicalLog'),
    declaration('applyTechnicalOutput'),
  ].join('\n'), context);
  context.canvasChanges = canvasChanges;
  context.setFollowing = value => { following = value; };
  return context;
}

function node() {
  const classes = new Set();
  return {
    hidden: false,
    textContent: '',
    attributes: {},
    classList: {
      toggle(name, on) { if (on) classes.add(name); else classes.delete(name); },
      contains(name) { return classes.has(name); },
    },
    setAttribute(name, value) { this.attributes[name] = value; },
  };
}

const repeatedCodexLog = [
  '2026-09-15T09:44:48.423043Z WARN codex_core::rollout::list: unable to inspect rollout item',
  '2026-09-15T09:44:49.123043Z WARN codex_core::rollout::list: unable to inspect rollout item',
  '2026-09-15T09:44:50.223043Z WARN codex_core::rollout::list: unable to inspect rollout item',
].join('\n');

test('timestamped copies of the same provider warning become one compact line', () => {
  const context = fixture();
  const view = context.technicalOutputView(repeatedCodexLog);
  assert.equal(view.rawLines.length, 3);
  assert.equal(view.groupedLines.length, 1);
  assert.match(view.preview, /×3/);
  assert.equal(view.shortened, true);
  assert.equal(view.raw, repeatedCodexLog, 'the raw provider text is unchanged');
});

test('the compact technical view keeps both context and newest lines', () => {
  const context = fixture();
  const log = Array.from({ length: 20 }, (_, index) => `[11:44:${String(index).padStart(2, '0')}] technical ${index}`).join('\n');
  const view = context.technicalOutputView(log);
  assert.match(view.preview, /technical 0/);
  assert.match(view.preview, /technical 19/);
  assert.match(view.preview, /15 tekniske linjer skjult/);
  assert.equal(view.preview.split('\n').length, 6);
  assert.equal(view.rawLines.length, 20);
});

test('one enormous stderr line is bounded too', () => {
  const context = fixture();
  const view = context.technicalOutputView(`ERROR ${'x'.repeat(10_000)}`);
  assert.equal(view.rawLines.length, 1);
  assert.equal(view.shortened, true);
  assert.match(view.preview, /tegn skjult/);
  assert.ok(view.preview.length < 1700);
});

test('the real toggle reveals and folds the exact raw log without losing bottom-follow', () => {
  const context = fixture();
  const errors = node();
  const errorExpand = node();
  const record = { errorText: repeatedCodexLog, errors, errorExpand, errorExpanded: false };

  context.renderErrors(record);
  assert.equal(errors.classList.contains('collapsed'), true);
  assert.match(errors.textContent, /×3/);
  assert.equal(errorExpand.hidden, false);
  assert.equal(errorExpand.attributes['aria-expanded'], 'false');
  assert.match(errorExpand.textContent, /3 linjer/);

  context.toggleTechnicalLog(record);
  assert.equal(errors.classList.contains('collapsed'), false);
  assert.equal(errors.textContent, repeatedCodexLog);
  assert.equal(errorExpand.textContent, 'Vis mindre');
  assert.equal(errorExpand.attributes['aria-expanded'], 'true');
  assert.deepEqual(context.canvasChanges, [true]);

  context.setFollowing(false);
  context.toggleTechnicalLog(record);
  assert.equal(record.errorExpanded, false);
  assert.equal(errors.classList.contains('collapsed'), true);
  assert.match(errors.textContent, /×3/);
  assert.deepEqual(context.canvasChanges, [true, false]);
});

test('a short log is never clipped when there is no expand control', () => {
  const context = fixture();
  const errors = node();
  const errorExpand = node();
  const record = { errorText: 'first useful line\nsecond useful line', errors, errorExpand, errorExpanded: false };
  context.renderErrors(record);
  assert.equal(errorExpand.hidden, true);
  assert.equal(errors.classList.contains('collapsed'), false);
  assert.equal(errors.textContent, record.errorText);
});

test('an empty reset hides both the technical log and its control', () => {
  const context = fixture();
  const errors = node();
  const errorExpand = node();
  const record = { errorText: '', errors, errorExpand, errorExpanded: true };
  context.renderErrors(record);
  assert.equal(record.errorExpanded, false);
  assert.equal(errors.hidden, true);
  assert.equal(errorExpand.hidden, true);
});

test('a native buffer rollover replaces text without forgetting an open log', () => {
  const context = fixture();
  const errors = node();
  const errorExpand = node();
  const replacement = `${repeatedCodexLog}\na fourth line`;
  const record = { errorText: 'discarded native buffer prefix', errors, errorExpand, errorExpanded: true };
  assert.equal(context.applyTechnicalOutput(record, true, replacement), true);
  assert.equal(record.errorText, replacement);
  assert.equal(record.errorExpanded, true);
  assert.equal(errors.textContent, replacement);

  assert.equal(context.applyTechnicalOutput(record, true, ''), true);
  assert.equal(record.errorExpanded, false, 'an actually empty replacement has nothing left to expand');
  assert.equal(errors.hidden, true);
});
