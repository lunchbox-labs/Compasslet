import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { data, Evaluator, Lexer, Parser } from '@actions/expressions';
import { parse } from 'yaml';

const workflow = parse(readFileSync(new URL('../../../.github/workflows/pages.yml', import.meta.url), 'utf8'));

// Fills in each ${{ }} of a workflow value, as Actions does for a concurrency setting.
function render(value, github) {
  return String(value).replace(/\$\{\{([\s\S]*?)\}\}/g, (_, expression) => {
    const tree = new Parser(new Lexer(expression).lex().tokens, ['github'], []).parse();
    const context = JSON.parse(JSON.stringify({ github }), data.reviver);
    return String(new Evaluator(tree, context).evaluate().value);
  });
}

const concurrency = (event_name, ref) => ({
  group: render(workflow.concurrency.group, { event_name, ref }),
  cancels: render(workflow.concurrency['cancel-in-progress'], { event_name, ref }) === 'true',
});

test('a newer push to a pull request cancels its older build', () => {
  const older = concurrency('pull_request', 'refs/pull/3/merge');
  const newer = concurrency('pull_request', 'refs/pull/3/merge');
  assert.equal(newer.group, older.group);
  assert.equal(newer.cancels, true);
});

test('runs on main, which deploy, are never cancelled', () => {
  assert.equal(concurrency('push', 'refs/heads/main').cancels, false);
  assert.equal(concurrency('workflow_dispatch', 'refs/heads/main').cancels, false);
});

test('pull request builds never cancel a run on main', () => {
  assert.notEqual(concurrency('pull_request', 'refs/pull/3/merge').group, concurrency('push', 'refs/heads/main').group);
});
