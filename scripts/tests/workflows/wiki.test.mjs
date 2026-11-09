import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { data, Evaluator, Lexer, Parser } from '@actions/expressions';
import { parse } from 'yaml';

const workflow = parse(readFileSync(new URL('../../../.github/workflows/wiki.yml', import.meta.url), 'utf8'));
const condition = new Parser(new Lexer(workflow.jobs.sync.if).lex().tokens, ['github'], []).parse();

function publishes(eventName, ref) {
  if (!Object.hasOwn(workflow.on, eventName)) return false;
  const branches = workflow.on[eventName]?.branches;
  if (branches && !branches.includes(ref.replace('refs/heads/', ''))) return false;
  const context = JSON.parse(JSON.stringify({ github: { event_name: eventName, ref } }), data.reviver);
  return new Evaluator(condition, context).evaluate().value;
}

for (const [eventName, ref, expected] of [
  ['push', 'refs/heads/main', true],
  ['workflow_dispatch', 'refs/heads/main', true],
  ['push', 'refs/heads/feature', false],
  ['workflow_dispatch', 'refs/heads/feature', false],
  ['workflow_dispatch', 'refs/tags/v1.0', false],
  ['pull_request', 'refs/pull/1/merge', false],
]) {
  test(`${eventName} on ${ref} publishes the wiki: ${expected}`, () => {
    assert.equal(publishes(eventName, ref), expected);
  });
}

test('pushes to main publish only when the wiki or this workflow change', () => {
  assert.deepEqual(workflow.on.push.paths, ['wiki/**', '.github/workflows/wiki.yml']);
});

test('only the sync job can write, and an in-progress sync is never cancelled', () => {
  assert.deepEqual(workflow.permissions, {});
  assert.deepEqual(workflow.jobs.sync.permissions, { contents: 'write' });
  assert.equal(workflow.concurrency['cancel-in-progress'], false);
});

test('every run publishes the newest main, not the commit that started it', () => {
  const checkout = workflow.jobs.sync.steps.find(step => step.uses?.startsWith('actions/checkout@'));
  assert.equal(checkout.with.ref, 'main');
});
