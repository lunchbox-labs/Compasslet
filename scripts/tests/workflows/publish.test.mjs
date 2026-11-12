import assert from 'node:assert/strict';
import test from 'node:test';
import { holds, load, render, run } from './jobs.mjs';

const workflow = load('publish.yml');
const { jobs } = workflow;

test('builds are published only by hand, submitting for App Review by default', () => {
  assert.deepEqual(Object.keys(workflow.on), ['workflow_dispatch']);
  assert.deepEqual(workflow.on.workflow_dispatch.inputs.submit, {
    description: workflow.on.workflow_dispatch.inputs.submit.description, type: 'boolean', default: true,
  });
});

test('nothing can write to the repository and every App Store job uses the release environment', () => {
  assert.deepEqual(workflow.permissions, { contents: 'read' });
  for (const [name, job] of Object.entries(jobs)) {
    assert.equal(job.permissions, undefined, name);
    if (JSON.stringify(job).includes('secrets.')) assert.equal(job.environment, 'release', name);
  }
});

test('a submitted build uploads, captures the listing at its commit, then syncs and submits', () => {
  assert.deepEqual(run(workflow), { publish: 'success', 'listing-screenshots': 'success', metadata: 'success' });
  assert.equal(jobs['listing-screenshots'].uses, './.github/workflows/screenshots.yml');
  assert.deepEqual(jobs['listing-screenshots'].with, { ref: '${{ github.sha }}', set: 'listing', 'max-parts': '1' });
});

test('a TestFlight-only build skips the listing capture and still syncs the copy', () => {
  const results = run(workflow, { inputs: { submit: false } });
  assert.equal(results['listing-screenshots'], 'skipped');
  assert.equal(results.metadata, 'success');
});

test('a failed upload or listing capture syncs and submits nothing', () => {
  for (const failed of ['publish', 'listing-screenshots']) {
    assert.equal(run(workflow, { outcomes: { [failed]: 'failure' } }).metadata, 'skipped', failed);
  }
  assert.equal(run(workflow, { outcomes: { publish: 'failure' }, inputs: { submit: false } }).metadata, 'skipped');
  assert.equal(run(workflow, { cancelled: true }).metadata, 'skipped');
});

test('nothing runs outside a manual run from main', () => {
  for (const github of [{ ref: 'refs/heads/feature' }, { event_name: 'push' }]) {
    for (const result of Object.values(run(workflow, { github }))) assert.equal(result, 'skipped');
  }
});

test('the review step gets the listing screenshots exactly when it submits', () => {
  const steps = jobs.metadata.steps;
  const download = steps.find(step => step.uses?.startsWith('actions/download-artifact@'));
  const review = steps.find(step => step.run === 'python3 scripts/app_store.py review');
  assert.ok(steps.indexOf(download) < steps.indexOf(review));
  assert.equal(download.with.name, '${{ needs.listing-screenshots.outputs.artifact }}');
  for (const [submit, expected] of [[true, '/runner/listing'], [false, '']]) {
    const context = { inputs: { submit }, runner: { temp: '/runner' } };
    assert.equal(holds(download.if, context), submit);
    assert.equal(render(review.env.SUBMIT, context), String(submit));
    assert.equal(render(review.env.LISTING_SCREENSHOTS, context), expected);
  }
});

test('the text copy syncs before the notes, screenshots and submission', () => {
  const runs = jobs.metadata.steps.map(step => step.run).filter(Boolean);
  assert.deepEqual(runs, ['python3 scripts/metadata_sync.py', 'python3 scripts/app_store.py review']);
});
