import { describe, it, expect } from 'vitest';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { buildFormSpec, applyFormValues, resolveSelectedDefaults, incompleteRequired } from '../src/core/form-spec.js';
import { readAllManifests, flattenBundles, indexByKey } from '../src/core/manifest-reader.js';
import type { Bundle, BundleRef } from '../src/types.js';

const index = indexByKey(flattenBundles(readAllManifests()));

function sampleBundle(): { bundle: Bundle; dir: string } {
  const dir = mkdtempSync(path.join(tmpdir(), 'mesh-form-'));
  writeFileSync(path.join(dir, 'versions.txt'), '8.2\n8.3\n8.4\n8.5\n');
  const bundle = {
    name: 'sample',
    options: [
      {
        name: 'versions',
        type: 'multiselect',
        label: 'Versions',
        env: 'SAMPLE_VERSIONS',
        source: 'versions.txt',
        required_min: 1,
        default: ['8.4'],
      },
      {
        name: 'default-version',
        type: 'select',
        label: 'Default',
        env: 'SAMPLE_DEFAULT',
        derive_from: 'versions',
      },
    ],
  } as Bundle;
  return { bundle, dir };
}

describe('buildFormSpec — source file + derive_from', () => {
  const { bundle, dir } = sampleBundle();
  const spec = buildFormSpec(bundle, dir);

  it('reads versions from the source file into multiselect choices', () => {
    const versions = spec.fields.find((f) => f.name === 'versions')!;
    expect(versions.kind).toBe('multiselect');
    const ids = (versions.choices ?? []).map((c) => (typeof c === 'string' ? c : c.id));
    expect(ids).toEqual(expect.arrayContaining(['8.2', '8.3', '8.4', '8.5']));
    expect(versions.min).toBe(1);
  });

  it('maps derive_from → optionsFrom on the default-version select', () => {
    const dv = spec.fields.find((f) => f.name === 'default-version')!;
    expect(dv.kind).toBe('select');
    expect(dv.optionsFrom).toBe('versions');
  });

  it('seeds the multiselect default from the manifest', () => {
    expect(spec.values['versions']).toEqual(['8.4']);
  });
});

describe('buildFormSpec — existing params.env override', () => {
  const { bundle, dir } = sampleBundle();
  it('pre-fills from an existing SAMPLE_VERSIONS over the schema default', () => {
    const spec = buildFormSpec(bundle, dir, new Map([['SAMPLE_VERSIONS', '8.3 8.5']]));
    expect(spec.values['versions']).toEqual(['8.3', '8.5']);
  });
});

describe('applyFormValues → params', () => {
  it('serialises values to env vars; clears emptied keys', () => {
    const { bundle, dir } = sampleBundle();
    const spec = buildFormSpec(bundle, dir);
    const params = new Map<string, string>();
    applyFormValues(spec, { versions: ['8.4', '8.5'], 'default-version': '8.5' }, params);
    expect(params.get('SAMPLE_VERSIONS')).toBe('8.4 8.5');
    expect(params.get('SAMPLE_DEFAULT')).toBe('8.5');

    applyFormValues(spec, { versions: [], 'default-version': '' }, params);
    expect(params.has('SAMPLE_VERSIONS')).toBe(false);
  });
});

describe('buildFormSpec — git/config (default_from runs a command)', () => {
  it('exposes text fields with the right env mapping', () => {
    const git = index.get('git/config')!;
    const spec = buildFormSpec(git.bundle, git.topic.dir);
    const name = spec.fields.find((f) => f.name === 'user-name')!;
    expect(name.kind).toBe('text');
    expect(spec.envByName.get('user-name')!.env).toBe('GIT_NAME');
    // default_from value is whatever `git config` returns (possibly ''), a string
    expect(typeof spec.values['user-name']).toBe('string');
  });
});

describe('resolveSelectedDefaults — persist defaults without opening the form (T-500 footgun)', () => {
  const makeRef = (options: unknown[]): BundleRef =>
    ({ key: 't/b', topic: { id: 't', dir: '/tmp' }, bundle: { name: 'b', options } }) as unknown as BundleRef;
  const modeOpt = { name: 'mode', type: 'select', label: 'Mode', env: 'X_MODE', default: 'fast' };

  it('fills a selected bundle option default into params', () => {
    const params = new Map<string, string>();
    resolveSelectedDefaults([makeRef([modeOpt])], params);
    expect(params.get('X_MODE')).toBe('fast');
  });

  it('never overwrites a value the user already set', () => {
    const params = new Map([['X_MODE', 'slow']]);
    resolveSelectedDefaults([makeRef([modeOpt])], params);
    expect(params.get('X_MODE')).toBe('slow');
  });

  it('is a no-op for a bundle with no options', () => {
    const params = new Map<string, string>();
    resolveSelectedDefaults([makeRef([])], params);
    expect(params.size).toBe(0);
  });
});

describe('incompleteRequired — apply-time required-option gate (Option A)', () => {
  // No `source`/`default_from` options here so topic.dir is irrelevant and the
  // gate never shells out — pure in-memory resolution.
  const refWith = (key: string, options: unknown[]): BundleRef =>
    ({
      key,
      topic: { id: key.split('/')[0], dir: '/tmp' },
      bundle: { name: key.split('/')[1], label: key, options },
    }) as unknown as BundleRef;
  const reqText = { name: 'repo', type: 'text', label: 'Repo', env: 'X_REPO', required: true };

  it('flags a selected bundle whose required text option is empty', () => {
    const refs = [refWith('t/needs', [reqText])];
    expect(incompleteRequired(refs).map((r) => r.key)).toEqual(['t/needs']);
  });

  it('passes once the required value is present in params', () => {
    const refs = [refWith('t/needs', [reqText])];
    expect(incompleteRequired(refs, new Map([['X_REPO', 'git@github:me/x.git']]))).toEqual([]);
  });

  it('passes when a static default satisfies the required option', () => {
    const refs = [refWith('t/dflt', [{ ...reqText, default: 'me/x' }])];
    expect(incompleteRequired(refs)).toEqual([]);
  });

  it('ignores a non-required empty option', () => {
    const refs = [refWith('t/opt', [{ ...reqText, required: false }])];
    expect(incompleteRequired(refs)).toEqual([]);
  });

  it('excludes a required SECRET option (collected via secrets.env, not the menu)', () => {
    const secret = { name: 'tok', type: 'secret', label: 'Token', env: 'X_TOK', required: true };
    expect(incompleteRequired([refWith('t/sec', [secret])])).toEqual([]);
  });

  it('still gates a required text option even when a sibling required secret is exempt', () => {
    const secret = { name: 'tok', type: 'secret', label: 'Token', env: 'X_TOK', required: true };
    const refs = [refWith('t/mix', [secret, reqText])];
    expect(incompleteRequired(refs).map((r) => r.key)).toEqual(['t/mix']);
  });

  it('is a no-op for a bundle with no options', () => {
    expect(incompleteRequired([refWith('t/none', [])])).toEqual([]);
  });

  it('returns only the incomplete bundles, in input order', () => {
    const refs = [
      refWith('t/ok', [{ ...reqText, default: 'me/x' }]),
      refWith('t/bad1', [reqText]),
      refWith('t/bad2', [reqText]),
    ];
    expect(incompleteRequired(refs).map((r) => r.key)).toEqual(['t/bad1', 't/bad2']);
  });

  // required_min is the multiselect flavour of "required" — the gate must agree
  // with the OptionsForm's save-time validateForm (which enforces min).
  const reqMin = {
    name: 'vers',
    type: 'multiselect',
    label: 'Versions',
    env: 'X_VERS',
    required_min: 1,
    choices: [{ value: '8.4', label: '8.4' }],
  };

  it('flags a multiselect below its required_min', () => {
    expect(incompleteRequired([refWith('t/min', [reqMin])]).map((r) => r.key)).toEqual(['t/min']);
  });

  it('passes a required_min multiselect satisfied by its default', () => {
    expect(incompleteRequired([refWith('t/min', [{ ...reqMin, default: ['8.4'] }])])).toEqual([]);
  });

  it('exempts a required select with no resolvable choices (uncollectable — would trap the user)', () => {
    const reqSelect = { name: 'mode', type: 'select', label: 'Mode', env: 'X_MODE', required: true };
    expect(incompleteRequired([refWith('t/uncollectable', [reqSelect])])).toEqual([]);
  });
});
