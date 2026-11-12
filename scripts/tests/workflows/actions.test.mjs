import assert from 'node:assert/strict';
import { readdirSync } from 'node:fs';
import test from 'node:test';
import { load } from './jobs.mjs';

const directory = new URL('../../../.github/workflows/', import.meta.url);

test('every workflow uses actions pinned to a full commit or workflows from this repository', () => {
  for (const name of readdirSync(directory).filter(file => file.endsWith('.yml'))) {
    for (const [jobName, job] of Object.entries(load(name).jobs)) {
      for (const uses of [job.uses, ...(job.steps ?? []).map(step => step.uses)].filter(Boolean)) {
        assert.match(uses, /^(\.\/\.github\/workflows\/[\w-]+\.yml|[\w.-]+\/[\w.-]+@[0-9a-f]{40})$/, `${name} ${jobName}`);
      }
    }
  }
});
