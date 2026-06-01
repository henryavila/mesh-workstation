import { strict as assert } from 'node:assert';
import { describe, it, before, after } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { checkItem } from '../lib/core/scanner.js';

const TOPICS_ROOT = join(dirname(new URL(import.meta.url).pathname), '..', '..', '..', 'topics');

function setupFakeValetHome({ withConfig = true, tld = 'localhost' } = {}) {
  const tmpHome = mkdtempSync(join(tmpdir(), 'valet-check-test-'));

  const binDir = join(tmpHome, '.composer/vendor/bin');
  mkdirSync(binDir, { recursive: true });
  const valetBin = join(binDir, 'valet');
  // Fake valet binary: exits 0 silently. Real valet calls sudo internally
  // for --version and tld, which the scanner's sudo stub blocks.
  writeFileSync(valetBin, '#!/usr/bin/env bash\nexit 0\n');
  chmodSync(valetBin, 0o755);

  const cfgDir = join(tmpHome, '.config/valet');
  mkdirSync(cfgDir, { recursive: true });
  if (withConfig) {
    writeFileSync(
      join(cfgDir, 'config.json'),
      JSON.stringify({ tld, loopback: '127.0.0.1', paths: [] }),
    );
  }

  return tmpHome;
}

describe('valet check (TDD: sudo-free detection)', () => {
  let origHome;
  let tmpHome;

  before(() => {
    origHome = process.env.HOME;
  });

  after(() => {
    process.env.HOME = origHome;
  });

  it('returns TRUE when valet binary + config.json with tld=localhost exist', () => {
    tmpHome = setupFakeValetHome({ tld: 'localhost' });
    process.env.HOME = tmpHome;
    try {
      const item = {
        topic: '60-web-stack',
        name: 'valet',
        type: 'custom',
        script: './mac/valet.sh',
      };
      const result = checkItem(item, { topicsRoot: TOPICS_ROOT, platform: 'mac' });
      assert.strictEqual(result, true, 'valet should be detected as installed');
    } finally {
      rmSync(tmpHome, { recursive: true, force: true });
    }
  });

  it('returns FALSE when config.json has tld != localhost', () => {
    tmpHome = setupFakeValetHome({ tld: 'test' });
    process.env.HOME = tmpHome;
    try {
      const item = {
        topic: '60-web-stack',
        name: 'valet',
        type: 'custom',
        script: './mac/valet.sh',
      };
      const result = checkItem(item, { topicsRoot: TOPICS_ROOT, platform: 'mac' });
      assert.strictEqual(result, false, 'valet should be not-installed when tld != localhost');
    } finally {
      rmSync(tmpHome, { recursive: true, force: true });
    }
  });

  it('returns FALSE when config.json is missing', () => {
    tmpHome = setupFakeValetHome({ withConfig: false });
    process.env.HOME = tmpHome;
    try {
      const item = {
        topic: '60-web-stack',
        name: 'valet',
        type: 'custom',
        script: './mac/valet.sh',
      };
      const result = checkItem(item, { topicsRoot: TOPICS_ROOT, platform: 'mac' });
      assert.strictEqual(result, false, 'valet should be not-installed without config.json');
    } finally {
      rmSync(tmpHome, { recursive: true, force: true });
    }
  });

  it('returns FALSE when valet binary is missing', () => {
    tmpHome = mkdtempSync(join(tmpdir(), 'valet-check-test-'));
    process.env.HOME = tmpHome;
    try {
      const item = {
        topic: '60-web-stack',
        name: 'valet',
        type: 'custom',
        script: './mac/valet.sh',
      };
      const result = checkItem(item, { topicsRoot: TOPICS_ROOT, platform: 'mac' });
      assert.strictEqual(result, false, 'valet should be not-installed without binary');
    } finally {
      rmSync(tmpHome, { recursive: true, force: true });
    }
  });
});
