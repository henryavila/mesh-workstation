import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { join, dirname } from 'node:path';
import { checkItem, scanAll } from '../lib/core/scanner.js';

const TOPICS_ROOT = join(dirname(new URL(import.meta.url).pathname), '..', '..', '..', 'topics');

describe('checkItem', () => {
  it('returns true for a check command that succeeds', () => {
    const item = { topic: 'test', name: 'true-cmd', check: 'true', type: 'custom' };
    assert.strictEqual(checkItem(item, { topicsRoot: TOPICS_ROOT }), true);
  });

  it('returns false for a check command that fails', () => {
    const item = { topic: 'test', name: 'false-cmd', check: 'false', type: 'custom' };
    assert.strictEqual(checkItem(item, { topicsRoot: TOPICS_ROOT }), false);
  });

  it('returns false for custom type without check field', () => {
    const item = { topic: 'test', name: 'no-check', type: 'custom', script: './fake.sh' };
    assert.strictEqual(checkItem(item, { topicsRoot: TOPICS_ROOT }), false);
  });

  it('returns true for brew-formula that is installed', () => {
    const item = { topic: 'test', name: 'node-check', check: 'command -v node', type: 'brew-formula', spec: 'node' };
    const result = checkItem(item, { topicsRoot: TOPICS_ROOT });
    assert.strictEqual(result, true);
  });

  it('returns false for brew-formula with nonexistent spec', () => {
    const item = { topic: 'test', name: 'fake', type: 'brew-formula', spec: 'this-package-does-not-exist-xyz123' };
    assert.strictEqual(checkItem(item, { topicsRoot: TOPICS_ROOT }), false);
  });

  it('returns null for git-clone type (marker-only detection)', () => {
    const item = { topic: 'test', name: 'clone', type: 'git-clone', spec: 'repo' };
    assert.strictEqual(checkItem(item, { topicsRoot: TOPICS_ROOT }), null);
  });

  it('returns null for npx type (marker-only detection)', () => {
    const item = { topic: 'test', name: 'npx', type: 'npx', spec: 'some-pkg' };
    assert.strictEqual(checkItem(item, { topicsRoot: TOPICS_ROOT }), null);
  });

  it('returns null for unknown type', () => {
    const item = { topic: 'test', name: 'unknown', type: 'unknown-driver', spec: 'x' };
    assert.strictEqual(checkItem(item, { topicsRoot: TOPICS_ROOT }), null);
  });

  it('respects timeout on slow commands', () => {
    const item = { topic: 'test', name: 'slow', check: 'sleep 60', type: 'custom' };
    const start = Date.now();
    const result = checkItem(item, { topicsRoot: TOPICS_ROOT });
    const elapsed = Date.now() - start;
    assert.strictEqual(result, false);
    assert.ok(elapsed < 10_000, `should timeout in <10s, took ${elapsed}ms`);
  });
});

describe('scanAll', () => {
  it('scans real topics without hanging', async () => {
    const items = [
      { topic: '20-terminal-ux', name: 'fzf-mac', type: 'brew-formula', spec: 'fzf', platforms: ['mac'], check: '', requires: [] },
      { topic: '20-terminal-ux', name: 'bat-mac', type: 'brew-formula', spec: 'bat', platforms: ['mac'], check: '', requires: [] },
      { topic: '82-ai-tools', name: 'mdprobe', type: 'npm-global', spec: '@henryavila/mdprobe', check: 'command -v mdprobe', platforms: ['mac', 'wsl'], requires: [] },
    ];
    const start = Date.now();
    const results = await scanAll(items, { topicsRoot: TOPICS_ROOT, platform: 'mac' });
    const elapsed = Date.now() - start;
    assert.strictEqual(results.size, 3);
    assert.ok(elapsed < 15_000, `scan should complete in <15s, took ${elapsed}ms`);
    for (const [, v] of results) {
      assert.ok(typeof v === 'object' && v !== null, 'scanAll values are rich state objects');
      assert.ok('installed' in v && 'managed' in v && 'idempotent' in v);
    }
  });

  it('batches brew formula checks', async () => {
    const items = Array.from({ length: 10 }, (_, i) => ({
      topic: 'test', name: `brew${i}`, type: 'brew-formula',
      spec: `nonexistent-pkg-${i}`, platforms: ['mac'], check: '', requires: [],
    }));
    const start = Date.now();
    const results = await scanAll(items, { topicsRoot: TOPICS_ROOT, platform: 'mac' });
    const elapsed = Date.now() - start;
    assert.strictEqual(results.size, 10);
    assert.ok(elapsed < 15_000, `10 brew checks should batch, took ${elapsed}ms`);
    for (const [, v] of results) {
      assert.strictEqual(v.installed, false);
      assert.strictEqual(v.managed, false);
      assert.strictEqual(v.idempotent, false);
    }
  });

  it('marks idempotent items without probing', async () => {
    const items = [
      { topic: 'test', name: 'idem', type: 'custom', script: './does-not-exist.sh',
        platforms: ['mac'], check: '', requires: [], idempotent: true },
    ];
    const results = await scanAll(items, { topicsRoot: TOPICS_ROOT, platform: 'mac' });
    const v = results.get('test/idem');
    assert.strictEqual(v.idempotent, true);
    assert.strictEqual(v.installed, null);
  });
});
