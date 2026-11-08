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

test('each iteration relaunches the app, so no state carries over between them', () => {
  const run = workflow.jobs.repeat.steps.find(step => step.run?.includes('scripts/test-ios')).run;
  assert.match(run, /-test-repetition-relaunch-enabled YES/);
});

test('a failed run uploads its result bundle from the hidden .build folder', () => {
  const upload = workflow.jobs.repeat.steps.find(step => step.uses?.startsWith('actions/upload-artifact@'));
  assert.equal(upload.if, "failure() && steps.repeat.outcome == 'failure'");
  assert.match(upload.with.path, /^\.build\//);
  assert.equal(upload.with['include-hidden-files'], true);
  assert.equal(upload.with['if-no-files-found'], 'error');
});

test('the test step times out before the job, so a slow run still keeps its bundle', () => {
  const step = workflow.jobs.repeat.steps.find(step => step.id === 'repeat');
  assert.ok(step['timeout-minutes'] < workflow.jobs.repeat['timeout-minutes']);
});
