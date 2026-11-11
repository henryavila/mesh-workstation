import { describe, it, expect } from 'vitest';
import path from 'node:path';
import { writeFileSync } from 'node:fs';
import { initialSelection, defaultSelected, requiredKeys } from '../src/core/init.js';
import { readAllManifests, flattenBundles, indexByKey } from '../src/core/manifest-reader.js';
import { tmp } from './helpers.js';

const refs = flattenBundles(readAllManifests());
const index = indexByKey(refs);

describe('defaultSelected', () => {
  it('selects the workstation column, not identity or gpg-signing', () => {
    const sel = defaultSelected(refs);
    expect(sel.has('git/gpg-signing')).toBe(false);
    expect(sel.has('git/config')).toBe(true);
    expect(sel.has('apps/flyenv')).toBe(true);
    expect(sel.has('apps/herdr-app')).toBe(true);
    expect(sel.has('identity/identity')).toBe(false);
    expect(sel.has('personal/personal')).toBe(false);
  });
});

describe('initialSelection', () => {
  it('fresh install (no saved file) uses the default_selected closure', () => {
    const { selected, fromSaved } = initialSelection(refs, index, '/no/such/selections.list');
    expect(fromSaved).toBe(false);
    expect(selected.has('git/config')).toBe(true);
    expect(selected.has('git/gpg-signing')).toBe(false);
    // every required bundle is present
    for (const k of requiredKeys(refs)) expect(selected.has(k)).toBe(true);
  });

  it('re-run starts from the saved file, dropping stale keys, forcing required + closure', () => {
    const f = path.join(tmp(), 'selections.list');
    writeFileSync(f, 'git/lazygit\nghost/none\n');
    const { selected, fromSaved } = initialSelection(refs, index, f);
    expect(fromSaved).toBe(true);
    expect(selected.has('git/lazygit')).toBe(true);
    // stale key dropped
    expect(selected.has('ghost/none')).toBe(false);
    // required still forced in
    for (const k of requiredKeys(refs)) expect(selected.has(k)).toBe(true);
  });
});
