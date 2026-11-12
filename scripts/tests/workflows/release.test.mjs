import assert from 'node:assert/strict';
import test from 'node:test';
import { holds, load, render, run } from './jobs.mjs';

const workflow = load('release.yml');
const { jobs } = workflow;

test('releases start only by hand, with App Store release and screenshots on by default', () => {
  assert.deepEqual(Object.keys(workflow.on), ['workflow_dispatch']);
  const { inputs } = workflow.on.workflow_dispatch;
  assert.deepEqual(Object.keys(inputs), ['app-store-release', 'screenshots']);
  for (const input of Object.values(inputs)) {
    assert.equal(input.type, 'boolean');
    assert.equal(input.default, true);
  }
});

test('only the job that tags and publishes can write to the repository', () => {
  assert.deepEqual(workflow.permissions, { contents: 'read' });
  for (const [name, job] of Object.entries(jobs)) {
    const writes = Object.entries(job.permissions ?? {}).filter(([, level]) => level === 'write');
    assert.deepEqual(writes, name === 'github-release' ? [['contents', 'write']] : [], name);
  }
  assert.equal(JSON.stringify(jobs['github-release']).includes('secrets.'), false);
  assert.equal(jobs['github-release'].environment, undefined);
});

test('the App Store key is only read in the release environment', () => {
  for (const [name, job] of Object.entries(jobs)) {
    if (JSON.stringify(job).includes('secrets.')) assert.equal(job.environment, 'release', name);
  }
});

test('one release runs at a time and none is cancelled midway', () => {
  assert.deepEqual(workflow.concurrency, { group: 'release', 'cancel-in-progress': false });
});

test('every job and option succeeding releases on the App Store, then publishes the GitHub Release', () => {
  assert.deepEqual(run(workflow), {
    prepare: 'success', screenshots: 'success', 'app-store': 'success', 'github-release': 'success',
  });
});

test('a version that is already live is tagged and released on GitHub only', () => {
  const results = run(workflow, { inputs: { 'app-store-release': false } });
  assert.equal(results['app-store'], 'skipped');
  assert.equal(results['github-release'], 'success');
});

test('without screenshots the App Store and GitHub releases still go ahead', () => {
  for (const inputs of [{ screenshots: false }, { screenshots: false, 'app-store-release': false }]) {
    const results = run(workflow, { inputs });
    assert.equal(results.screenshots, 'skipped');
    assert.equal(results['app-store'], inputs['app-store-release'] === false ? 'skipped' : 'success');
    assert.equal(results['github-release'], 'success');
  }
});

test('a failed step stops every later release step', () => {
  for (const [failed, expected] of [
    ['prepare', { screenshots: 'skipped', 'app-store': 'skipped', 'github-release': 'skipped' }],
    ['screenshots', { 'app-store': 'skipped', 'github-release': 'skipped' }],
    ['app-store', { 'github-release': 'skipped' }],
  ]) {
    const results = run(workflow, { outcomes: { [failed]: 'failure' } });
    for (const [job, result] of Object.entries(expected)) assert.equal(results[job], result, `${failed} ${job}`);
  }
});

test('a cancelled run releases nothing more', () => {
  const results = run(workflow, { cancelled: true });
  assert.equal(results['app-store'], 'skipped');
  assert.equal(results['github-release'], 'skipped');
});

test('nothing runs outside a manual run from main', () => {
  for (const github of [{ ref: 'refs/heads/feature' }, { event_name: 'push' }]) {
    for (const result of Object.values(run(workflow, { github }))) assert.equal(result, 'skipped');
  }
});

test('screenshots are captured at the build commit and attached only when captured', () => {
  assert.equal(jobs.screenshots.uses, './.github/workflows/screenshots.yml');
  assert.equal(jobs.screenshots.with.ref, '${{ needs.prepare.outputs.sha }}');
  const download = jobs['github-release'].steps.find(step => step.uses?.startsWith('actions/download-artifact@'));
  assert.equal(download.with.name, '${{ needs.screenshots.outputs.artifact }}');
  const publish = jobs['github-release'].steps.at(-1);
  for (const [screenshots, expected] of [[true, '/runner/screenshots'], [false, '']]) {
    const context = { inputs: { screenshots }, runner: { temp: '/runner' } };
    assert.equal(holds(download.if, context), screenshots);
    assert.equal(render(publish.env.RELEASE_ASSETS, context), expected);
  }
});

test('the tag and release name the build commit that prepare found', () => {
  const env = jobs['github-release'].steps.at(-1).env;
  assert.equal(env.RELEASE_SHA, '${{ needs.prepare.outputs.sha }}');
  assert.equal(env.RELEASE_TAG, '${{ needs.prepare.outputs.tag }}');
  assert.equal(env.GH_TOKEN, '${{ github.token }}');
  assert.equal(jobs.prepare.outputs.sha, '${{ steps.source.outputs.sha }}');
});
