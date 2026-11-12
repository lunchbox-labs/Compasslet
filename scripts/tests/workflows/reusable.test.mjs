import assert from 'node:assert/strict';
import test from 'node:test';
import { load } from './jobs.mjs';

const screenshots = load('screenshots.yml');
const call = screenshots.on.workflow_call;
const dispatch = screenshots.on.workflow_dispatch;

test('the called Screenshots workflow takes the same inputs and defaults as a manual run', () => {
  assert.deepEqual(Object.keys(call.inputs), Object.keys(dispatch.inputs));
  for (const [name, input] of Object.entries(call.inputs)) {
    if (name !== 'ref') assert.equal(input.default, dispatch.inputs[name].default, name);
  }
  assert.equal(call.inputs.ref.required, true);
});

test('callers pass only declared inputs, with values a manual run accepts', () => {
  for (const name of ['publish.yml', 'release.yml']) {
    for (const [jobName, job] of Object.entries(load(name).jobs)) {
      if (job.uses !== './.github/workflows/screenshots.yml') continue;
      for (const [input, value] of Object.entries(job.with)) {
        assert.ok(input in call.inputs, `${name} ${jobName} ${input}`);
        const { options } = dispatch.inputs[input];
        if (options && !String(value).includes('${{')) assert.ok(options.includes(value), `${name} ${jobName} ${input}`);
      }
      assert.ok(job.with.ref, `${name} ${jobName} names the commit to capture`);
    }
  }
});

test('the artifact name callers download is the one the capture uploads', () => {
  const capture = screenshots.jobs.capture;
  assert.equal(call.outputs.artifact.value, '${{ jobs.capture.outputs.artifact }}');
  assert.equal(capture.outputs.artifact, '${{ env.ARTIFACT }}');
  const upload = capture.steps.find(step => step.uses?.startsWith('actions/upload-artifact@'));
  assert.equal(upload.with.name, '${{ env.ARTIFACT }}');
});
