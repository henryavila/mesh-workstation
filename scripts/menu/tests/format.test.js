import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { formatItemLabel, formatHint, buildLegend, formatTopicHeader, displayName, shortDisplayName } from '../lib/ui/format.js';

describe('formatItemLabel', () => {
  it('shows checkbox + status icon for normal item', () => {
    const opt = { value: 'x', label: 'MySQL', installed: true };
    const result = formatItemLabel(opt, true, false);
    assert.ok(result.includes('MySQL'), 'should include label');
  });

  it('shows lock icon for disabled items', () => {
    const opt = { value: 'x', label: 'Core', disabled: true };
    const result = formatItemLabel(opt, true, true);
    assert.ok(result.includes('Core'), 'should include label');
  });

  it('differs between selected and unselected', () => {
    const opt = { value: 'x', label: 'Test', installed: false };
    const selected = formatItemLabel(opt, true, false);
    const unselected = formatItemLabel(opt, false, false);
    assert.notStrictEqual(selected, unselected);
  });
});

describe('formatHint', () => {
  it('returns empty for null option', () => {
    assert.strictEqual(formatHint(null, false), '');
  });

  it('signals removal possibility for installed + managed + deselected (adoptable)', () => {
    const opt = { value: 'x', installed: true, managed: true, desc: 'A thing' };
    const hint = formatHint(opt, false);
    assert.ok(/installed/.test(hint) && /remove/.test(hint), `expected adoptable hint, got: ${hint}`);
  });

  it('signals install action for not-installed + selected (pending)', () => {
    const opt = { value: 'x', installed: false, managed: false, desc: 'A thing' };
    const hint = formatHint(opt, true);
    assert.ok(/will install/.test(hint), `expected pending hint, got: ${hint}`);
  });

  it('signals steady state for installed + managed + selected', () => {
    const opt = { value: 'x', installed: true, managed: true, desc: 'A thing' };
    const hint = formatHint(opt, true);
    assert.ok(hint.includes('installed'));
  });

  it('signals foreign install for installed + !managed + deselected', () => {
    const opt = { value: 'x', installed: true, managed: false, desc: 'A thing' };
    const hint = formatHint(opt, false);
    assert.ok(/outside mesh/.test(hint), `expected foreign hint, got: ${hint}`);
  });

  it('signals drift-out for selected + managed + !installed (missing)', () => {
    const opt = { value: 'x', installed: false, managed: true, desc: 'A thing' };
    const hint = formatHint(opt, true);
    assert.ok(/missing/.test(hint) || /reinstall/.test(hint), `expected missing hint, got: ${hint}`);
  });

  it('signals idempotent rerun for idempotent + managed', () => {
    const opt = { value: 'x', idempotent: true, managed: true, installed: null, desc: 'A thing' };
    const hint = formatHint(opt, true);
    assert.ok(/idempotent/.test(hint) || /re-applies/.test(hint), `expected idempotent hint, got: ${hint}`);
  });

  it('includes desc', () => {
    const opt = { value: 'x', installed: false, desc: 'Database server' };
    const hint = formatHint(opt, false);
    assert.ok(hint.includes('Database server'));
  });

  it('includes tier', () => {
    const opt = { value: 'x', installed: true, tier: 'tier 3' };
    const hint = formatHint(opt, true);
    assert.ok(hint.includes('tier 3'));
  });

  it('includes requires', () => {
    const opt = { value: 'x', installed: false, requires: ['mysql', 'redis'] };
    const hint = formatHint(opt, false);
    assert.ok(hint.includes('mysql'));
    assert.ok(hint.includes('redis'));
  });
});

describe('buildLegend', () => {
  it('includes toggle and filter instructions', () => {
    const legend = buildLegend();
    assert.ok(legend.includes('toggle'));
    assert.ok(legend.includes('filter'));
  });

  it('includes installed and available labels', () => {
    const legend = buildLegend();
    assert.ok(legend.includes('installed'));
    assert.ok(legend.includes('available'));
  });
});

describe('formatTopicHeader', () => {
  it('shows index/total and installed count', () => {
    const header = formatTopicHeader('Web Stack', 0, 3, 7, 10);
    assert.ok(header.includes('1/3'), 'should show 1-based index');
    assert.ok(header.includes('Web Stack'));
    assert.ok(header.includes('7/10'));
  });
});

describe('displayName / shortDisplayName (strip platform suffix)', () => {
  it('strips -mac', () => {
    assert.strictEqual(displayName('mysql-mac'), 'mysql');
    assert.strictEqual(displayName('mosh-path-mac'), 'mosh-path');
  });

  it('strips -wsl', () => {
    assert.strictEqual(displayName('atuin-wsl'), 'atuin');
    assert.strictEqual(displayName('tailscale-mtu-fix-wsl'), 'tailscale-mtu-fix');
  });

  it('strips -linux', () => {
    assert.strictEqual(displayName('moshi-hook-linux'), 'moshi-hook');
  });

  it('leaves names without platform suffix untouched', () => {
    assert.strictEqual(displayName('valet'), 'valet');
    assert.strictEqual(displayName('code-server'), 'code-server');
    assert.strictEqual(displayName('docker-compose'), 'docker-compose');
  });

  it('handles edge inputs', () => {
    assert.strictEqual(displayName(''), '');
    assert.strictEqual(displayName(null), '');
    assert.strictEqual(displayName(undefined), '');
  });

  it('shortDisplayName strips topic prefix and platform suffix', () => {
    assert.strictEqual(shortDisplayName('60-web-stack/mysql-mac'), 'mysql');
    assert.strictEqual(shortDisplayName('80-claude-code/moshi-hook-linux'), 'moshi-hook');
    assert.strictEqual(shortDisplayName('valet'), 'valet');
  });
});
