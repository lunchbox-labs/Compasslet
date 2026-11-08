import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { data, Evaluator, Lexer, Parser } from '@actions/expressions';
import { parse } from 'yaml';

const workflow = parse(readFileSync(new URL('../../../.github/workflows/check.yml', import.meta.url), 'utf8'));

function evaluate(expression, github) {
  const tree = new Parser(new Lexer(expression).lex().tokens, ['github'], []).parse();
  const context = JSON.parse(JSON.stringify({ github }), data.reviver);
  return new Evaluator(tree, context).evaluate().value;
}

// Fills in each ${{ }} of a workflow value, as Actions does for a concurrency setting.
function render(value, github) {
  return String(value).replace(/\$\{\{([\s\S]*?)\}\}/g, (_, expression) => String(evaluate(expression, github)));
}

const concurrency = github => ({
  group: render(workflow.concurrency.group, github),
  cancels: render(workflow.concurrency['cancel-in-progress'], github) === 'true',
});
const sha = 'a'.repeat(40);
let runs = 0;
const run = (event_name, ref, commit = sha) => ({ event_name, ref, sha: commit, run_id: String(++runs) });
const pullRequest = (number, commit) => run('pull_request', `refs/pull/${number}/merge`, commit);
const push = commit => run('push', 'refs/heads/main', commit);
const manual = (ref, commit) => run('workflow_dispatch', ref, commit);

test('a newer push to a pull request cancels its older run', () => {
  const older = concurrency(pullRequest(1, 'a'.repeat(40)));
  const newer = concurrency(pullRequest(1, 'b'.repeat(40)));
  assert.equal(newer.group, older.group);
  assert.equal(newer.cancels, true);
});

test('different pull requests never cancel each other', () => {
  assert.notEqual(concurrency(pullRequest(1)).group, concurrency(pullRequest(2)).group);
});

test('pushes to main never cancel or replace each other, even at the same commit', () => {
  for (const [first, second] of [[push('a'.repeat(40)), push('b'.repeat(40))], [push(), push()]]) {
    assert.equal(concurrency(first).cancels, false);
    assert.equal(concurrency(second).cancels, false);
    assert.notEqual(concurrency(first).group, concurrency(second).group);
  }
});

test('manual runs never cancel or replace other runs, even at the same commit', () => {
  const first = concurrency(manual('refs/heads/main'));
  const second = concurrency(manual('refs/heads/main'));
  const onBranch = concurrency(manual('refs/heads/feature'));
  assert.equal(first.cancels, false);
  assert.equal(onBranch.cancels, false);
  for (const other of [second, onBranch, concurrency(push()), concurrency(pullRequest(1))]) {
    assert.notEqual(first.group, other.group);
  }
});

const native = workflow.jobs.native;
const testStep = native.steps.find(step => step.run?.includes('scripts/test-ios'));
const upload = native.steps.find(step => step.uses?.startsWith('actions/upload-artifact@'));

test('a failed simulator test run uploads its result bundle from the hidden .build folder', () => {
  assert.equal(testStep.id, 'test');
  assert.equal(upload.if, "failure() && steps.test.outcome == 'failure'");
  assert.match(upload.with.path, /^\.build\/test-results\./);
  assert.equal(upload.with['include-hidden-files'], true);
  assert.equal(upload.with['if-no-files-found'], 'error');
  assert.equal(upload.with['retention-days'], 7);
});

test('the result bundle uploads after the tests, under a name unique to each attempt', () => {
  assert.ok(native.steps.indexOf(upload) > native.steps.indexOf(testStep));
  assert.match(upload.with.name, /\$\{\{ github\.run_number \}\}/);
  assert.match(upload.with.name, /\$\{\{ github\.run_attempt \}\}/);
});

test('the simulator test step times out before the job, so a hung run still keeps its bundle', () => {
  assert.ok(testStep['timeout-minutes'] < native['timeout-minutes']);
});
