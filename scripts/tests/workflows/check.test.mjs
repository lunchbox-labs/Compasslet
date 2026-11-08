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
const pullRequest = (number, sha) => ({ event_name: 'pull_request', ref: `refs/pull/${number}/merge`, sha });
const push = sha => ({ event_name: 'push', ref: 'refs/heads/main', sha });
const manual = (ref, sha) => ({ event_name: 'workflow_dispatch', ref, sha });

test('a newer push to a pull request cancels its older run', () => {
  const older = concurrency(pullRequest(1, 'a'.repeat(40)));
  const newer = concurrency(pullRequest(1, 'b'.repeat(40)));
  assert.equal(newer.group, older.group);
  assert.equal(newer.cancels, true);
});

test('different pull requests never cancel each other', () => {
  assert.notEqual(concurrency(pullRequest(1, 'a'.repeat(40))).group, concurrency(pullRequest(2, 'a'.repeat(40))).group);
});

test('each push to main finishes, and no later push replaces it while it waits', () => {
  const first = concurrency(push('a'.repeat(40)));
  const second = concurrency(push('b'.repeat(40)));
  assert.equal(first.cancels, false);
  assert.equal(second.cancels, false);
  assert.notEqual(first.group, second.group);
});

test('manual runs never cancel or replace other runs', () => {
  const run = concurrency(manual('refs/heads/main', 'c'.repeat(40)));
  assert.equal(run.cancels, false);
  assert.notEqual(run.group, concurrency(push('a'.repeat(40))).group);
  assert.notEqual(run.group, concurrency(pullRequest(1, 'c'.repeat(40))).group);
});
