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

function sectionKeys(name: string): Set<string> {
  const file = path.join(REPO_ROOT, 'scripts/data/dx-profiles.yaml');
  const raw = parseYaml(readFileSync(file, 'utf8')) as Contract;
  const section = (raw.bundles ?? []).find((b) => b.name === name);
  return new Set(section?.requires_bundles ?? []);
}

export function workstationDefaultKeys(): Set<string> {
  if (cached) return cached;
  cached = sectionKeys('workstation-default');
  return cached;
}

export function identityOnlyKeys(): Set<string> {
  return sectionKeys('identity-only');
}

/** [kept-when-both, dropped-when-both] from the conflicts section. */
export function conflictPair(): [string, string] | null {
  const ids = [...sectionKeys('conflicts')];
  if (ids.length < 2) return null;
  return [ids[0], ids[1]];
}

/** One of FlyEnv and Flock. The key just added wins; otherwise keep the first. */
export function withoutConflictPeer(selected: Set<string>, justAdded?: string): Set<string> {
  const pair = conflictPair();
  if (!pair) return selected;
  const [first, second] = pair;
  if (!selected.has(first) || !selected.has(second)) return selected;
  const next = new Set(selected);
  if (justAdded === second) next.delete(first);
  else next.delete(second);
  return next;
}
