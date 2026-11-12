/**
 * no-mesh-menu.test.ts — F1: MESH_NO_MESH=1 hides membership, unlocks the
 * documented list (unchecked), keeps foundation/base locked; unflagged path
 * Identity-only rows are hidden on the unflagged path too.
 */
import { afterEach, describe, expect, it } from 'vitest';
import {
  applyNoMeshCatalog,
  defaultSelected,
  filterMembershipTopics,
  NO_MESH_UNLOCK_KEYS,
  noMeshActive,
  requiredKeys,
} from '../src/core/init.js';
import {
  filterByPlatform,
  flattenBundles,
  readAllManifests,
} from '../src/core/manifest-reader.js';

const MEMBERSHIP_KEYS = [
  'personal/personal',
  'identity/identity',
  'syncthing/syncthing',
  'remote-access/tailscale',
  'remote-access/code-server',
] as const;

afterEach(() => {
  delete process.env.MESH_NO_MESH;
});

describe('noMeshActive', () => {
  it('is true only when MESH_NO_MESH=1', () => {
    expect(noMeshActive({})).toBe(false);
    expect(noMeshActive({ MESH_NO_MESH: '0' })).toBe(false);
    expect(noMeshActive({ MESH_NO_MESH: '1' })).toBe(true);
  });
});

describe('unflagged catalog (MESH_NO_MESH unset)', () => {
  // mac keeps code-server (mac-only) so all five membership keys are visible.
  const topics = filterByPlatform(readAllManifests(), 'mac');
  const { refs } = applyNoMeshCatalog(topics, {});
  const required = requiredKeys(refs);
  const keys = new Set(refs.map((r) => r.key));

  it('hides identity-only rows and keeps optional remote-access rows', () => {
    expect(keys.has('identity/identity')).toBe(false);
    expect(keys.has('personal/personal')).toBe(false);
    expect(keys.has('syncthing/syncthing')).toBe(false);
    expect(keys.has('remote-access/tailscale')).toBe(true);
    expect(keys.has('remote-access/code-server')).toBe(true);
  });

  it('does not lock personal and identity as required', () => {
    expect(required.has('personal/personal')).toBe(false);
    expect(required.has('identity/identity')).toBe(false);
    expect(required.has('foundation/base')).toBe(true);
    expect(required.has('git/config')).toBe(true);
    expect(required.has('shell-terminal/cli-tools')).toBe(true);
    expect(required.has('shell-terminal/zsh')).toBe(true);
  });
});

describe('no-mesh catalog (MESH_NO_MESH=1)', () => {
  const platformTopics = filterByPlatform(readAllManifests(), 'mac');
  const { topics, refs } = applyNoMeshCatalog(platformTopics, { MESH_NO_MESH: '1' });
  const keys = new Set(refs.map((r) => r.key));
  const required = requiredKeys(refs);
  const selected = defaultSelected(refs);

  it('removes membership bundles (not greyed — absent)', () => {
    for (const k of MEMBERSHIP_KEYS) {
      expect(keys.has(k), `membership row still present: ${k}`).toBe(false);
    }
    expect(topics.some((t) => t.id === 'syncthing')).toBe(false);
    expect(topics.some((t) => t.id === 'personal')).toBe(false);
    expect(topics.some((t) => t.id === 'identity')).toBe(false);
  });

  it('keeps non-membership rows including unlock list and foundation', () => {
    expect(keys.has('foundation/base')).toBe(true);
    expect(keys.has('remote-access/ssh')).toBe(true);
    for (const k of NO_MESH_UNLOCK_KEYS) {
      expect(keys.has(k), k).toBe(true);
    }
  });

  it('keeps the workstation column selected; the shell rejects this env before launch', () => {
    expect(required.has('foundation/base')).toBe(true);
    expect(selected.has('foundation/base')).toBe(true);
    expect(selected.has('git/config')).toBe(true);
    expect(selected.has('shell-terminal/cli-tools')).toBe(true);
    expect(selected.has('shell-terminal/zsh')).toBe(true);
  });

  it('skips identity onboarding because identity bundle is absent', () => {
    expect(keys.has('identity/identity')).toBe(false);
  });

  it('filterMembershipTopics alone drops only membership rows', () => {
    const filtered = filterMembershipTopics(platformTopics);
    const flat = new Set(flattenBundles(filtered).map((r) => r.key));
    for (const k of MEMBERSHIP_KEYS) {
      expect(flat.has(k)).toBe(false);
    }
    // Without applyNoMeshUnlocks, unlock keys stay required in the raw manifests.
    const rawRefs = flattenBundles(filtered);
    expect(requiredKeys(rawRefs).has('git/config')).toBe(true);
  });
});

describe('NO_MESH_UNLOCK_KEYS sync with no-mesh.sh', () => {
  it('matches the bash NO_MESH_UNLOCK_KEYS array', () => {
    const { readFileSync } = require('node:fs') as typeof import('node:fs');
    const { resolve } = require('node:path') as typeof import('node:path');
    const sh = readFileSync(
      resolve(__dirname, '../../../scripts/lib/no-mesh.sh'),
      'utf8',
    );
    const block = sh.match(/NO_MESH_UNLOCK_KEYS=\(([\s\S]*?)\)/);
    expect(block, 'NO_MESH_UNLOCK_KEYS array in no-mesh.sh').toBeTruthy();
    const bashKeys = block![1]
      .split(/\n/)
      .map((l) => l.replace(/#.*$/, '').trim())
      .filter(Boolean);
    expect([...NO_MESH_UNLOCK_KEYS].sort()).toEqual([...bashKeys].sort());
  });
});
