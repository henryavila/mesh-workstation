/**
 * init.ts — compute the picker's initial bundle selection, mirroring setup.sh:
 *   - saved ~/.config/mesh/selections.list present → re-run: start from it
 *     (dropping keys no longer in the manifest), always force required bundles.
 *   - absent → fresh install: the workstation column from dx-profiles.yaml.
 * Either way the requires_bundles closure is applied so deps are present.
 * Identity-only rows stay out of the picker. FlyEnv and Flock cannot both stay selected.
 */
import { closeRequires } from './delta.js';
import { identityOnlyKeys, withoutConflictPeer, workstationDefaultKeys } from './dx-profiles.js';
import { flattenBundles } from './manifest-reader.js';
import { readSelections } from './selections-io.js';
import { selectionsFile } from './paths.js';
import type { Bundle, BundleRef, Topic } from '../types.js';

/** Plan Decision 10 — mirrored in scripts/lib/no-mesh.sh NO_MESH_UNLOCK_KEYS. */
export const NO_MESH_UNLOCK_KEYS = [
  'git/config',
  'shell-terminal/cli-tools',
  'shell-terminal/zsh',
] as const;

const UNLOCK_SET: ReadonlySet<string> = new Set(NO_MESH_UNLOCK_KEYS);

/** True when setup.sh / mesh menu exported MESH_NO_MESH=1. */
export function noMeshActive(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.MESH_NO_MESH === '1';
}

/**
 * Drop bundles tagged membership: mesh and topics left empty. Remove, do not
 * grey — the picker never sees those rows under no-mesh.
 */
export function filterMembershipTopics(topics: Topic[]): Topic[] {
  const out: Topic[] = [];
  for (const t of topics) {
    const bundles = t.bundles.filter((b) => b.membership !== 'mesh');
    if (bundles.length > 0) out.push({ ...t, bundles });
  }
  return out;
}

/**
 * Under no-mesh only: demote unlock-list bundles to optional + unchecked.
 * foundation/base keeps required. Returns new refs (does not mutate inputs).
 */
export function applyNoMeshUnlocks(refs: BundleRef[]): BundleRef[] {
  return refs.map((r) => {
    if (!UNLOCK_SET.has(r.key)) return r;
    const bundle: Bundle = {
      ...r.bundle,
      required: false,
      default_selected: false,
    };
    return { ...r, bundle };
  });
}

/**
 * Apply the no-mesh catalog transform: strip membership, then unlock the
 * documented list. No-op when MESH_NO_MESH is unset/0.
 */
function hideIdentityOnly(topics: Topic[]): Topic[] {
  const hidden = identityOnlyKeys();
  const out: Topic[] = [];
  for (const t of topics) {
    const bundles = t.bundles.filter((b) => !hidden.has(`${t.id}/${b.name}`));
    if (bundles.length > 0) out.push({ ...t, bundles });
  }
  return out;
}

export function applyNoMeshCatalog(
  topics: Topic[],
  env: NodeJS.ProcessEnv = process.env,
): { topics: Topic[]; refs: BundleRef[] } {
  const base = hideIdentityOnly(topics);
  const filtered = noMeshActive(env) ? filterMembershipTopics(base) : base;
  const flat = flattenBundles(filtered);
  const refs = noMeshActive(env) ? applyNoMeshUnlocks(flat) : flat;
  // Rebuild topics from (possibly unlocked) refs so required/default_selected
  // demotions are visible to TopicPicker via topic.bundles.
  if (!noMeshActive(env)) return { topics: filtered, refs };
  const byId = new Map<string, Topic>();
  for (const r of refs) {
    const existing = byId.get(r.topic.id);
    if (!existing) {
      byId.set(r.topic.id, { ...r.topic, bundles: [r.bundle] });
    } else {
      existing.bundles.push(r.bundle);
    }
  }
  // Preserve filtered topic order.
  const rebuilt = filtered.map((t) => byId.get(t.id)!).filter(Boolean);
  return { topics: rebuilt, refs };
}

/** Fresh-install default: the workstation column in dx-profiles.yaml. */
export function defaultSelected(refs: BundleRef[]): Set<string> {
  const column = workstationDefaultKeys();
  const sel = new Set<string>();
  for (const r of refs) {
    if (column.has(r.key)) sel.add(r.key);
  }
  return sel;
}

/** Keys of required bundles — always selected, never deselectable. */
export function requiredKeys(refs: BundleRef[]): Set<string> {
  return new Set(refs.filter((r) => r.bundle.required).map((r) => r.key));
}

export interface InitialSelection {
  selected: Set<string>;
  /** True when a saved selections.list was the source (re-run vs fresh). */
  fromSaved: boolean;
}

/**
 * Resolve the starting selection set for the picker. `index` keys the valid
 * `topic/bundle` refs for the current platform (stale saved keys are dropped).
 */
export function initialSelection(
  refs: BundleRef[],
  index: Map<string, BundleRef>,
  selectionsPath: string = selectionsFile(),
): InitialSelection {
  const required = requiredKeys(refs);
  const saved = readSelections(selectionsPath);
  let base: Set<string>;
  let fromSaved: boolean;
  if (saved.size > 0) {
    base = new Set([...saved].filter((k) => index.has(k)));
    fromSaved = true;
  } else {
    base = defaultSelected(refs);
    fromSaved = false;
  }
  for (const k of required) base.add(k);
  const closed = closeRequires(base, index).selected;
  return { selected: withoutConflictPeer(closed), fromSaved };
}
