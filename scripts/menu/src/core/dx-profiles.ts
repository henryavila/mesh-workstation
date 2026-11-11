/**
 * Workstation column from scripts/data/dx-profiles.yaml.
 * The menu checks these keys on a fresh install. It does not keep a second list.
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { parse as parseYaml } from 'yaml';
import { REPO_ROOT } from './paths.js';

interface Section {
  name?: string;
  requires_bundles?: string[];
}

interface Contract {
  bundles?: Section[];
}

let cached: Set<string> | null = null;

export function workstationDefaultKeys(): Set<string> {
  if (cached) return cached;
  const file = path.join(REPO_ROOT, 'scripts/data/dx-profiles.yaml');
  const raw = parseYaml(readFileSync(file, 'utf8')) as Contract;
  const section = (raw.bundles ?? []).find((b) => b.name === 'workstation-default');
  cached = new Set(section?.requires_bundles ?? []);
  return cached;
}
