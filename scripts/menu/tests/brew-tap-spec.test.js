import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { execSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { scanAll } from '../lib/core/scanner.js';

const TOPICS_ROOT = join(dirname(new URL(import.meta.url).pathname), '..', '..', '..', 'topics');

function brewListShort() {
  try {
    return new Set(
      execSync('brew list --formula 2>/dev/null', { encoding: 'utf8' })
        .trim()
        .split('\n')
        .map((l) => l.trim()),
    );
  } catch {
    return new Set();
  }
}

describe('brew formula detection: tap-qualified specs', () => {
  it('detects a tap-qualified spec (tap/formula or tap/repo/formula) when installed', async () => {
    const installed = brewListShort();
    if (!installed.has('moshi-hook')) {
      // Skip on hosts that don't have this tap installed
      return;
    }
    const items = [
      {
        topic: '80-claude-code',
        name: 'moshi-hook-mac',
        type: 'brew-formula',
        spec: 'rjyo/moshi/moshi-hook',
        platforms: ['mac'],
        check: '',
        requires: [],
      },
    ];
    const status = await scanAll(items, { topicsRoot: TOPICS_ROOT, platform: 'mac' });
    assert.strictEqual(
      status.get('80-claude-code/moshi-hook-mac')?.installed,
      true,
      'tap-qualified spec rjyo/moshi/moshi-hook should match installed moshi-hook',
    );
  });

  it('also detects a plain (non-tapped) spec when installed', async () => {
    const installed = brewListShort();
    // Pick any installed formula to verify the plain-spec path still works
    const sample = [...installed][0];
    if (!sample) return;
    const items = [
      {
        topic: 'test',
        name: 'sample',
        type: 'brew-formula',
        spec: sample,
        platforms: ['mac'],
        check: '',
        requires: [],
      },
    ];
    const status = await scanAll(items, { topicsRoot: TOPICS_ROOT, platform: 'mac' });
    assert.strictEqual(status.get('test/sample')?.installed, true);
  });
});
