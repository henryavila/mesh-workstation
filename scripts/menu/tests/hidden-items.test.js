import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readAllManifests, groupByTopic } from '../lib/core/manifest-reader.js';
import { autoSelectDependencies } from '../lib/core/delta.js';

function setupFakeTopics(yaml) {
  const root = mkdtempSync(join(tmpdir(), 'hidden-items-test-'));
  const topicDir = join(root, '99-test');
  mkdirSync(topicDir, { recursive: true });
  writeFileSync(join(topicDir, 'items.yaml'), yaml);
  return root;
}

describe('hidden items (TDD: implementation-detail items not in menu)', () => {
  it('manifest-reader parses `hidden: true` field', () => {
    const root = setupFakeTopics(`
- name: parent
  type: custom
  script: "./parent.sh"
- name: child
  type: custom
  script: "./child.sh"
  hidden: true
  requires: [parent]
`);
    try {
      const items = readAllManifests(root);
      const child = items.find((i) => i.name === 'child');
      assert.strictEqual(child.hidden, true, 'hidden field should parse as true');
      const parent = items.find((i) => i.name === 'parent');
      assert.strictEqual(parent.hidden, false, 'missing hidden should default to false');
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('autoSelectDependencies pulls in hidden items whose requires are selected', () => {
    const manifest = [
      { topic: 't', name: 'parent', requires: [], hidden: false },
      { topic: 't', name: 'child', requires: ['parent'], hidden: true },
      { topic: 't', name: 'other', requires: [], hidden: false },
    ];
    const { selected, added } = autoSelectDependencies(manifest, ['t/parent']);
    assert.ok(selected.includes('t/child'), 'hidden child should be auto-included when parent is selected');
    assert.ok(added.includes('t/child'), 'auto-add should report hidden child');
    assert.ok(!selected.includes('t/other'), 'unrelated items should not be added');
  });

  it('autoSelectDependencies does NOT pull in hidden items when parent is not selected', () => {
    const manifest = [
      { topic: 't', name: 'parent', requires: [], hidden: false },
      { topic: 't', name: 'child', requires: ['parent'], hidden: true },
    ];
    const { selected } = autoSelectDependencies(manifest, []);
    assert.ok(!selected.includes('t/child'), 'hidden child should not appear when parent absent');
  });

  it('autoSelectDependencies leaves hidden out when parent is removed', () => {
    const manifest = [
      { topic: 't', name: 'parent', requires: [], hidden: false },
      { topic: 't', name: 'child', requires: ['parent'], hidden: true },
    ];
    // If user only has 'other' selected, child should NOT come in just because it's hidden
    const { selected } = autoSelectDependencies(manifest, ['t/other']);
    assert.ok(!selected.includes('t/child'), 'hidden items follow their requires, not blanket auto-add');
  });
});
