import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { data, Evaluator, Lexer, Parser } from '@actions/expressions';
import { parse } from 'yaml';

const workflow = parse(readFileSync(new URL('../../../.github/workflows/screenshots.yml', import.meta.url), 'utf8'));
const condition = new Parser(new Lexer(workflow.jobs.capture.if).lex().tokens, ['github'], []).parse();

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
