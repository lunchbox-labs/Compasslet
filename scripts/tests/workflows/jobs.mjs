// Runs a workflow's job graph the way Actions decides which jobs start, so tests can check the
// gating of each job for given inputs and job outcomes.
import { readFileSync } from 'node:fs';
import { data, Evaluator, Lexer, Parser } from '@actions/expressions';
import { parse } from 'yaml';

export function load(name) {
  return parse(readFileSync(new URL(`../../../.github/workflows/${name}`, import.meta.url), 'utf8'));
}

const CONTEXTS = ['github', 'inputs', 'needs', 'runner', 'steps', 'env', 'vars', 'secrets'];
const STATUS = /\b(success|failure|cancelled|always)\s*\(/;

export function evaluate(expression, context, status = {}) {
  const functions = [
    { name: 'success', minArgs: 0, maxArgs: 0, call: () => new data.BooleanData(status.success ?? true) },
    { name: 'failure', minArgs: 0, maxArgs: 0, call: () => new data.BooleanData(status.failure ?? false) },
    { name: 'cancelled', minArgs: 0, maxArgs: 0, call: () => new data.BooleanData(status.cancelled ?? false) },
    { name: 'always', minArgs: 0, maxArgs: 0, call: () => new data.BooleanData(true) },
  ];
  const tree = new Parser(new Lexer(String(expression)).lex().tokens, CONTEXTS, functions).parse();
  const values = JSON.parse(JSON.stringify(context), data.reviver);
  return new Evaluator(tree, values, new Map(functions.map(f => [f.name, f]))).evaluate().value;
}

// Fills in each ${{ }} of a workflow value.
export function render(value, context) {
  return String(value).replace(/\$\{\{([\s\S]*?)\}\}/g, (_, expression) => String(evaluate(expression, context)));
}

const strip = expression => String(expression).replace(/^\$\{\{([\s\S]*)\}\}$/, '$1');

// A step or job condition, written with or without ${{ }}.
export const holds = (condition, context) => evaluate(strip(condition), context);

// Each job's result: 'skipped' when its condition is false, otherwise its outcome
// (default 'success'). A condition without a status function needs every need to succeed.
export function run(workflow, { inputs = {}, github = {}, outcomes = {}, cancelled = false } = {}) {
  const defaults = Object.fromEntries(Object.entries(workflow.on.workflow_dispatch?.inputs ?? {})
    .map(([name, input]) => [name, input.default]));
  const context = {
    github: { event_name: 'workflow_dispatch', ref: 'refs/heads/main', sha: 'a'.repeat(40), ...github },
    inputs: { ...defaults, ...inputs },
  };
  const results = {};
  const pending = Object.keys(workflow.jobs);
  while (pending.length) {
    const name = pending.find(job => [workflow.jobs[job].needs ?? []].flat().every(need => need in results));
    if (!name) throw new Error('The job graph has a cycle.');
    pending.splice(pending.indexOf(name), 1);
    const job = workflow.jobs[name];
    const needs = [job.needs ?? []].flat();
    const success = needs.every(need => results[need] === 'success') && !cancelled;
    const condition = job.if === undefined ? 'success()' : strip(job.if);
    const gated = STATUS.test(condition) ? condition : `success() && (${condition})`;
    const needed = Object.fromEntries(needs.map(need => [need, { result: results[need], outputs: {} }]));
    const starts = evaluate(gated, { ...context, needs: needed },
      { success, failure: needs.some(need => results[need] === 'failure'), cancelled });
    results[name] = starts ? (outcomes[name] ?? 'success') : 'skipped';
  }
  return results;
}
