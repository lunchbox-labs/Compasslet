import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { data, Evaluator, Lexer, Parser } from '@actions/expressions';
import { parse } from 'yaml';

const workflow = parse(readFileSync(new URL('../../../.github/workflows/screenshots.yml', import.meta.url), 'utf8'));
const condition = new Parser(new Lexer(workflow.jobs.build.if).lex().tokens, ['github'], []).parse();

function requestsCapture(eventName, event = {}) {
  if (!Object.hasOwn(workflow.on, eventName)) return false;
  const types = workflow.on[eventName]?.types;
  if (types && !types.includes(event.action)) return false;
  const context = JSON.parse(JSON.stringify({ github: { event_name: eventName, event } }), data.reviver);
  return new Evaluator(condition, context).evaluate().value;
}

function pullRequest(action, labels, addedLabel) {
  return {
    action,
    pull_request: { labels: labels.map(name => ({ name })) },
    ...(addedLabel === undefined ? {} : { label: { name: addedLabel } }),
  };
}

for (const action of ['opened', 'synchronize', 'reopened']) {
  for (const [labels, expected] of [
    [[], false],
    [['bug'], false],
    [['screenshots-extra'], false],
    [['screenshots'], true],
    [['bug', 'screenshots'], true],
  ]) {
    test(`${action} with labels ${JSON.stringify(labels)} requests capture: ${expected}`, () => {
      assert.equal(requestsCapture('pull_request', pullRequest(action, labels)), expected);
    });
  }
}

for (const [addedLabel, labels, expected] of [
  ['screenshots', ['screenshots'], true],
  ['screenshots', ['bug', 'screenshots'], true],
  ['bug', ['bug', 'screenshots'], false],
  ['screenshots-extra', ['screenshots-extra', 'screenshots'], false],
  ['bug', ['bug'], false],
]) {
  test(`adding ${addedLabel} with labels ${JSON.stringify(labels)} requests capture: ${expected}`, () => {
    assert.equal(requestsCapture('pull_request', pullRequest('labeled', labels, addedLabel)), expected);
  });
}

test('removing the label stops later push captures and re-adding enables them', () => {
  for (const [action, labels, changedLabel, expected] of [
    ['labeled', ['screenshots'], 'screenshots', true],
    ['synchronize', ['screenshots'], undefined, true],
    ['synchronize', ['screenshots'], undefined, true],
    ['unlabeled', [], 'screenshots', false],
    ['synchronize', [], undefined, false],
    ['labeled', ['screenshots'], 'screenshots', true],
    ['synchronize', ['screenshots'], undefined, true],
  ]) {
    assert.equal(requestsCapture('pull_request', pullRequest(action, labels, changedLabel)), expected);
  }
});

test('manual capture does not need a pull request or label', () => {
  assert.equal(requestsCapture('workflow_dispatch'), true);
});

for (const eventName of ['push', 'pull_request_target']) {
  test(`${eventName} does not request a capture`, () => {
    assert.equal(requestsCapture(eventName, pullRequest('synchronize', ['screenshots'])), false);
  });
}

// Fills in each ${{ }} of a workflow value, as Actions does for a concurrency setting.
function render(value, github) {
  return String(value).replace(/\$\{\{([\s\S]*?)\}\}/g, (_, expression) => {
    const tree = new Parser(new Lexer(expression).lex().tokens, ['github'], []).parse();
    const context = JSON.parse(JSON.stringify({ github }), data.reviver);
    return String(new Evaluator(tree, context).evaluate().value);
  });
}

let runs = 0;
function run(eventName, event = {}) {
  const github = {
    event_name: eventName,
    run_id: String(++runs),
    event: eventName === 'pull_request' ? { pull_request: { number: 7 }, ...event } : event,
  };
  const { concurrency } = workflow;
  return {
    group: render(concurrency.group, github),
    cancels: render(concurrency['cancel-in-progress'], github) === 'true',
  };
}

function capture(eventName, number) {
  return run(eventName, eventName === 'pull_request'
    ? { action: 'synchronize', pull_request: { number, labels: [{ name: 'screenshots' }] } }
    : {});
}

test('a newer capture for a pull request cancels its run in progress', () => {
  const older = capture('pull_request', 7);
  const newer = capture('pull_request', 7);
  assert.equal(newer.group, older.group);
  assert.equal(newer.cancels, true);
});

test('captures for different pull requests never cancel each other', () => {
  assert.notEqual(capture('pull_request', 7).group, capture('pull_request', 8).group);
});

test('manual captures never cancel or replace another run', () => {
  const first = capture('workflow_dispatch');
  assert.equal(first.cancels, false);
  for (const other of [capture('workflow_dispatch'), capture('pull_request', 7), capture('pull_request', 1)]) {
    assert.notEqual(first.group, other.group);
  }
});

// The workflow-level group stands in for job-level concurrency, so a run that captures nothing
// must never share a pull request's group, or it would cancel the capture in progress.
test('only a run that requests a capture enters its pull request group', () => {
  const capturing = capture('pull_request', 7).group;
  const events = [];
  for (const action of ['opened', 'synchronize', 'reopened', 'labeled', 'unlabeled']) {
    for (const labels of [[], ['bug'], ['screenshots-extra'], ['screenshots'], ['bug', 'screenshots']]) {
      for (const label of [undefined, 'screenshots', 'bug']) {
        events.push(pullRequest(action, labels, label));
      }
    }
  }
  for (const event of events.filter(item => workflow.on.pull_request.types.includes(item.action))) {
    const event7 = { ...event, pull_request: { ...event.pull_request, number: 7 } };
    assert.equal(run('pull_request', event7).group === capturing,
      requestsCapture('pull_request', event7), JSON.stringify(event7));
  }
});

test('the capture jobs share one build and the collect job waits for every capture', () => {
  assert.deepEqual(workflow.jobs.capture.needs, 'build');
  assert.equal(workflow.jobs.capture.strategy['fail-fast'], false);
  assert.deepEqual(workflow.jobs.collect.needs, ['build', 'capture']);
  assert.equal(workflow.jobs.capture.concurrency, undefined);
  assert.equal(workflow.jobs.build.concurrency, undefined);
});
