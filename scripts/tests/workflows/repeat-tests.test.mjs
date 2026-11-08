import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parse } from 'yaml';

const workflow = parse(readFileSync(new URL('../../../.github/workflows/repeat-tests.yml', import.meta.url), 'utf8'));

test('repeated test runs start only by hand, so they never block a merge', () => {
  assert.deepEqual(Object.keys(workflow.on), ['workflow_dispatch']);
});

test('a repeated run can only read the repository', () => {
  assert.deepEqual(workflow.permissions, { contents: 'read' });
  assert.equal(workflow.jobs.repeat.permissions, undefined);
});

test('the run stops at the first failing iteration', () => {
  const run = workflow.jobs.repeat.steps.find(step => step.run?.includes('scripts/test-ios')).run;
  assert.match(run, /-test-iterations /);
  assert.match(run, /-run-tests-until-failure/);
});
