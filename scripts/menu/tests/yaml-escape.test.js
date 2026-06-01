import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { parseItemsYaml } from '../lib/core/manifest-reader.js';

describe('YAML parser: escape sequences in double-quoted strings', () => {
  it('unescapes \\" to " inside double-quoted scalar', () => {
    const yaml = `- name: claudebar\n  check: "jq -e '.cmd | test(\\"foo\\")' a.json"\n`;
    const items = parseItemsYaml(yaml);
    assert.strictEqual(
      items[0].check,
      `jq -e '.cmd | test("foo")' a.json`,
      'inner \\" should become "',
    );
  });

  it('unescapes \\\\ to \\ inside double-quoted scalar', () => {
    const yaml = `- name: x\n  check: "echo \\\\path"\n`;
    const items = parseItemsYaml(yaml);
    assert.strictEqual(items[0].check, 'echo \\path', 'inner \\\\ should become \\');
  });

  it('leaves single-quoted scalars untouched', () => {
    const yaml = `- name: x\n  check: 'test "foo"'\n`;
    const items = parseItemsYaml(yaml);
    assert.strictEqual(items[0].check, 'test "foo"', 'single-quoted preserves content');
  });

  it('leaves unquoted scalars untouched', () => {
    const yaml = `- name: x\n  desc: hello world\n`;
    const items = parseItemsYaml(yaml);
    assert.strictEqual(items[0].desc, 'hello world');
  });
});
