import { describe, it, expect } from 'vitest';
import { writeFileSync } from 'node:fs';
import path from 'node:path';
import {
  readAllManifests,
  readTopicManifest,
  filterByPlatform,
  flattenBundles,
  indexByKey,
  appliesToPlatform,
  ManifestError,
} from '../src/core/manifest-reader.js';
import { registerDomainGlyphs, resolveDomain } from '../src/glyphs.js';
import { tmp } from './helpers.js';

describe('readAllManifests (real repo manifests)', () => {
  const topics = readAllManifests();

  it('reads all 12 topics, sorted by order', () => {
    expect(topics.length).toBe(12);
    const orders = topics.map((t) => t.header.order);
    expect([...orders]).toEqual([...orders].sort((a, b) => a - b));
    expect(topics[0].id).toBe('foundation');
  });

  it('every requires_bundles target resolves in the flattened index', () => {
    const refs = flattenBundles(topics);
    const index = indexByKey(refs);
    for (const r of refs) {
      for (const dep of r.bundle.requires_bundles ?? []) {
        expect(index.has(dep), `${r.key} requires missing ${dep}`).toBe(true);
      }
    }
  });

  it('languages/php has a multiselect + a derive_from select', () => {
    const refs = flattenBundles(topics);
    const php = indexByKey(refs).get('languages/php')!;
    const opts = php.bundle.options!;
    expect(opts.find((o) => o.name === 'versions')!.type).toBe('multiselect');
    expect(opts.find((o) => o.name === 'default-version')!.derive_from).toBe('versions');
  });

  it('no bundle desc uses screen-position wording (options live behind Enter, not "below")', () => {
    // "pick … below"/"above" contradicts the menu model: options are a level-3
    // form opened with Enter, not laid out under the description.
    for (const r of flattenBundles(topics)) {
      expect(/\b(below|above)\b/i.test(r.bundle.desc), `${r.key}: "${r.bundle.desc}"`).toBe(false);
    }
  });
});

describe('manifest icon coverage (no icon gap)', () => {
  // Every icon_name a manifest declares must resolve to a registered blink glyph
  // after registerDomainGlyphs() — otherwise that bundle renders with no domain
  // glyph. This guards the 12-name gap that was closed upstream in blink (the
  // SYSTEM pack + claude). A new manifest icon_name with no blink glyph fails here.
  registerDomainGlyphs();
  const topics = readAllManifests();
  const iconNames = [
    ...new Set(
      flattenBundles(topics)
        .map((r) => r.bundle.icon_name)
        .filter((n): n is string => Boolean(n)),
    ),
  ].sort();

  it('has icon_names to check (guards against the manifests dropping them silently)', () => {
    expect(iconNames.length).toBeGreaterThan(10);
  });

  it.each(iconNames)('icon_name %s resolves to a blink glyph', (name) => {
    expect(resolveDomain(name), `icon_name "${name}" has no blink glyph`).toBeTruthy();
  });
});

describe('filterByPlatform', () => {
  const topics = readAllManifests();
  it('mac keeps mac+universal bundles, drops wsl-only', () => {
    const mac = flattenBundles(filterByPlatform(topics, 'mac')).map((r) => r.key);
    expect(mac).toContain('remote-access/code-server');
    expect(mac).toContain('foundation/base');
  });
  it('wsl keeps universal bundles and drops mac-only ones', () => {
    const wsl = flattenBundles(filterByPlatform(topics, 'wsl')).map((r) => r.key);
    expect(wsl).toContain('foundation/base');
    expect(wsl).not.toContain('remote-access/code-server');
  });
});

describe('appliesToPlatform', () => {
  it('undefined/empty applies everywhere; wsl inherits linux', () => {
    expect(appliesToPlatform(undefined, 'mac')).toBe(true);
    expect(appliesToPlatform(['linux'], 'wsl')).toBe(true);
    expect(appliesToPlatform(['mac'], 'wsl')).toBe(false);
  });
});

describe('readTopicManifest errors', () => {
  it('rejects a manifest with no topic block', () => {
    const f = path.join(tmp(), 'manifest.yaml');
    writeFileSync(f, 'bundles: []\n');
    expect(() => readTopicManifest(f, 'x', path.dirname(f))).toThrow(ManifestError);
  });
  it('rejects a bundle with no items', () => {
    const f = path.join(tmp(), 'manifest.yaml');
    writeFileSync(f, 'topic:\n  label: X\n  order: 1\nbundles:\n  - name: a\n    label: A\n    items: []\n');
    expect(() => readTopicManifest(f, 'x', path.dirname(f))).toThrow(/no items|non-empty/);
  });
});
