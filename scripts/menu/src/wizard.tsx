/**
 * wizard.tsx — the App component + screen router for the mesh setup wizard.
 *
 * The bootstrap (render + main) lives in app.tsx (the index.js entry); this
 * module is side-effect-free and exports <App/> so it is unit-testable.
 *
 * The App owns shared state (selection set, resolved params); each screen owns
 * its own keys (blink's headless model). Only one screen mounts at a time, so
 * exactly one useInput is live. On confirm it writes
 * ~/.config/mesh/{selections.list,params.env} and signals exit 0; cancel/quit
 * signals exit 1 so the caller falls back to the saved/default selection.
 *
 * BLINK-ONLY (feedback_mesh_ink_app_blink_only): every visible element is a
 * blink component; Ink Box/Text are layout + the unavoidable plain-text leaves.
 */
import { execSync } from 'node:child_process';
import { useMemo, useState } from 'react';
import { Box, useApp, useInput } from 'ink';
import { Dialog, useGlyph, type FormValues, type DialogAction } from '@henryavila/blink-tui';
import { detectPlatform } from './core/platform.js';
import {
  readAllManifests,
  filterByPlatform,
  indexByKey,
} from './core/manifest-reader.js';
import { scanAll } from './core/scanner.js';
import { applyNoMeshCatalog, initialSelection, requiredKeys } from './core/init.js';
import { withoutConflictPeer } from './core/dx-profiles.js';
import { closeRequires, dependentsOf, computeDelta, toggleTopicSelection } from './core/delta.js';
import { writeSelections, writeRemovals, writeParams, readParams } from './core/selections-io.js';
import { buildFormSpec, applyFormValues, resolveSelectedDefaults, incompleteRequired, type BundleFormSpec } from './core/form-spec.js';
import { TopicPicker } from './screens/TopicPicker.js';
import { OptionsForm } from './screens/OptionsForm.js';
import { SummaryConfirm } from './screens/SummaryConfirm.js';
import { UpdatesScreen, UPDATE_ENV, updateValuesFromParams } from './screens/UpdatesScreen.js';
import { IdentityOnboarding, IDENTITY_ENV, type IdentityResult } from './screens/IdentityOnboarding.js';
import { DevRootScreen, CODE_DIR_ENV } from './screens/DevRootScreen.js';
import type { Bundle, BundleRef } from './types.js';

/** The personal-identity bundle gets the dedicated create-or-adopt onboarding
 *  screen instead of the generic options form — recognised by the option that
 *  carries the identity-repo env (the stable identity contract), so no manifest
 *  flag or hard-coded topic/bundle name is needed. */
export function isIdentityOnboarding(bundle: Bundle): boolean {
  return (bundle.options ?? []).some((o) => o.env === IDENTITY_ENV.repo);
}

/** Best-effort GitHub login to pre-fill the create-from-template owner (the same
 *  default apply.sh derives from `gh api user`); '' when gh is absent/unauthed. */
function ghLogin(): string {
  try {
    return execSync('gh api user -q .login', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
}

type Screen = 'devroot' | 'picker' | 'options' | 'identity' | 'summary' | 'updates' | 'help' | 'confirmRemove';

/** Exit code when the user leaves the menu WITHOUT applying (quit / Ctrl-C).
 *  Distinct from a launch failure (setup.sh treats 1/2 as "menu unavailable" and
 *  falls back to the default selection) so an explicit cancel ABORTS the run
 *  instead of silently installing defaults the user never chose. */
export const EXIT_CANCEL = 130;

interface Editing {
  ref: BundleRef;
  spec: BundleFormSpec;
  values: FormValues;
  /** Set when opened by the required-option gate — the reason banner to show. */
  notice?: string;
}

interface AppProps {
  dryRun: boolean;
  onExit: (code: number) => void;
}

export function App({ dryRun, onExit }: AppProps) {
  const ink = useApp();

  // ── boot (computed once) ──
  // MESH_NO_MESH=1: strip membership: mesh rows and demote the unlock list
  // before requiredKeys / initialSelection so locks and defaults match setup.sh.
  const platform = useMemo(() => detectPlatform(), []);
  const catalog = useMemo(() => {
    const platformTopics = filterByPlatform(readAllManifests(), platform);
    return applyNoMeshCatalog(platformTopics);
  }, [platform]);
  const topics = catalog.topics;
  const refs = catalog.refs;
  const index = useMemo(() => indexByKey(refs), [refs]);
  const scan = useMemo(() => scanAll(refs, platform), [refs, platform]);
  const required = useMemo(() => requiredKeys(refs), [refs]);
  const init = useMemo(() => initialSelection(refs, index), [refs, index]);
  // Apply baseline: saved selection on re-run, empty on a fresh install (so the
  // summary shows the defaults as "install", not "keep").
  const prevSelection = useMemo(
    () => (init.fromSaved ? new Set(init.selected) : new Set<string>()),
    [init],
  );

  // Dev root (CODE_DIR) is collected up-front — the wizard's first screen — so
  // the value lands once before the picker, universal (not web-gated). Pre-filled
  // from params on a re-run, so it's a single Enter to keep.
  const [screen, setScreen] = useState<Screen>('devroot');
  const [selected, setSelected] = useState<Set<string>>(() => init.selected);
  const [params, setParams] = useState<Map<string, string>>(() => readParams());
  const [banner, setBanner] = useState<string | null>(null);
  const [editing, setEditing] = useState<Editing | null>(null);
  const [identity, setIdentity] = useState<{ notice?: string; defaultOwner: string } | null>(null);
  const [updateValues, setUpdateValues] = useState<FormValues>({});
  const [confirm, setConfirm] = useState<{ key: string; deps: string[] } | null>(null);

  // Selected bundles as refs — shared by the default resolver and the required-
  // option gate (recomputed when the selection changes).
  const selectedRefs = useMemo(
    () => [...selected].map((k) => index.get(k)).filter((r): r is BundleRef => r !== undefined),
    [selected, index],
  );

  const finish = (code: number) => {
    if (code === 0 && !dryRun) {
      // Persist resolved option defaults for every selected bundle, not just the
      // ones whose options form was opened — otherwise a default_from value
      // (e.g. personal/repo → MESH_IDENTITY_REPO) never reaches params.env and
      // the engine fails on it. Copy params so the resolve doesn't mutate state.
      const resolved = resolveSelectedDefaults(selectedRefs, new Map(params));
      const persisted = withoutConflictPeer(selected);
      writeSelections([...persisted]);
      // Persist the deselected set so the Apply uninstalls it before installing
      // (Frente A). On a fresh install prevSelection is empty → no removals.
      writeRemovals(computeDelta(prevSelection, persisted).remove);
      writeParams(resolved);
    }
    onExit(code);
    ink.exit();
  };

  // Apply-time gate (Option A): a selected bundle with an unfilled REQUIRED
  // option can't advance to the summary — the interactive menu owns prompting
  // (the engine does not ask in interactive mode), so route the user straight to
  // the first offender's options form with a banner. secret-type required
  // options are exempt (collected via secrets.env, not the menu).
  const tryContinue = () => {
    const missing = incompleteRequired(selectedRefs, params);
    if (missing.length === 0) {
      setScreen('summary');
      return;
    }
    const first = missing[0];
    const reason =
      missing.length === 1
        ? `${first.bundle.label} needs a required value before you can apply`
        : `${missing.length} bundles need a required value — starting with ${first.bundle.label}`;
    setBanner(reason);
    editOptions(first, reason);
  };

  // ── selection handlers (closure + auto-select banner + dependent guard) ──
  const toggle = (key: string) => {
    if (required.has(key)) return;
    if (selected.has(key)) {
      const deps = dependentsOf(key, selected, index);
      if (deps.length) {
        setConfirm({ key, deps });
        setScreen('confirmRemove');
        return;
      }
      const next = new Set(selected);
      next.delete(key);
      setSelected(next);
      setBanner(null);
    } else {
      const { selected: closed, added } = closeRequires([...selected, key], index);
      setSelected(withoutConflictPeer(closed, key));
      setBanner(added.length ? `Auto-selected: ${added.join(', ')}` : null);
    }
  };

  const removeWithDependents = () => {
    if (!confirm) return setScreen('picker');
    const next = new Set(selected);
    next.delete(confirm.key);
    for (const d of confirm.deps) next.delete(d);
    setSelected(next);
    setBanner(`Removed ${confirm.key} + ${confirm.deps.length} dependent(s)`);
    setConfirm(null);
    setScreen('picker');
  };

  // Space while the Topics pane is focused → toggle ALL of the topic's bundles
  // (not just its first one). Standard toggle-all: fills if any are off, else
  // clears the selectable ones.
  const toggleTopic = (topicId: string) => {
    const topic = topics.find((t) => t.id === topicId);
    if (!topic) return;
    const keys = topic.bundles.map((b) => `${topicId}/${b.name}`);
    const res = toggleTopicSelection(keys, required, selected, index);
    setSelected(withoutConflictPeer(res.selected));
    if (res.added.length) setBanner(`Auto-selected: ${res.added.join(', ')}`);
    else if (res.removed.length) setBanner(`${topic.header.label}: deselected ${res.removed.length} bundle(s)`);
    else setBanner(`${topic.header.label}: all selected`);
  };

  const selectAll = () => {
    setSelected(withoutConflictPeer(new Set(refs.map((r) => r.key))));
    setBanner(null);
  };
  const selectNone = () => {
    setSelected(closeRequires(required, index).selected);
    setBanner(null);
  };

  const editOptions = (ref: BundleRef, notice?: string) => {
    // The identity bundle's value (existing repo xor create-from-template) can't
    // be a flat option form — route it to the dedicated onboarding screen.
    if (isIdentityOnboarding(ref.bundle)) {
      setIdentity({ notice, defaultOwner: ghLogin() });
      setScreen('identity');
      return;
    }
    const spec = buildFormSpec(ref.bundle, ref.topic.dir, params);
    setEditing({ ref, spec, values: spec.values, notice });
    setScreen('options');
  };
  const closeDevRoot = (resolved: string | null) => {
    if (resolved !== null) {
      const next = new Map(params);
      next.set(CODE_DIR_ENV, resolved);
      setParams(next);
      setBanner(`Dev root: ${resolved}`);
    }
    setScreen('picker');
  };
  const closeIdentity = (result: IdentityResult | null) => {
    if (result) {
      const next = new Map(params);
      for (const [env, val] of Object.entries(result.params)) {
        if (val === null) next.delete(env);
        else next.set(env, val);
      }
      setParams(next);
      setBanner('Saved identity repo');
    }
    setIdentity(null);
    setScreen('picker');
  };
  const closeOptions = (saved: boolean) => {
    if (saved && editing) {
      const next = new Map(params);
      applyFormValues(editing.spec, editing.values, next);
      setParams(next);
      setBanner(`Saved options for ${editing.ref.key}`);
    }
    setEditing(null);
    setScreen('picker');
  };

  const openUpdates = () => {
    setUpdateValues(updateValuesFromParams(params));
    setScreen('updates');
  };
  const closeUpdates = (saved: boolean) => {
    if (saved) {
      const next = new Map(params);
      for (const [name, env] of Object.entries(UPDATE_ENV)) {
        next.set(env, updateValues[name] ? '1' : '0');
      }
      setParams(next);
      setBanner('Update categories saved');
    }
    setScreen('picker');
  };

  // ── screens ──
  if (screen === 'devroot') {
    return (
      <DevRootScreen initial={params.get(CODE_DIR_ENV) ?? ''} onClose={closeDevRoot} />
    );
  }
  if (screen === 'options' && editing) {
    return (
      <OptionsForm
        bundleKey={editing.ref.key}
        bundleLabel={editing.ref.bundle.label}
        fields={editing.spec.fields}
        values={editing.values}
        notice={editing.notice}
        onChange={(v) => setEditing((e) => (e ? { ...e, values: v } : e))}
        onClose={closeOptions}
      />
    );
  }
  if (screen === 'identity' && identity) {
    return (
      <IdentityOnboarding
        initial={params}
        notice={identity.notice}
        defaultOwner={identity.defaultOwner}
        onClose={closeIdentity}
      />
    );
  }
  if (screen === 'summary') {
    return (
      <SummaryConfirm
        delta={computeDelta(prevSelection, selected)}
        index={index}
        applyLabel={dryRun ? 'dry-run (nothing written)' : 'writes selections.list + params.env'}
        onConfirm={() => finish(0)}
        onBack={() => setScreen('picker')}
        onQuit={() => finish(EXIT_CANCEL)}
      />
    );
  }
  if (screen === 'updates') {
    return (
      <UpdatesScreen
        values={updateValues}
        onChange={setUpdateValues}
        onClose={closeUpdates}
      />
    );
  }
  if (screen === 'help') {
    return <HelpScreen onClose={() => setScreen('picker')} />;
  }
  if (screen === 'confirmRemove' && confirm) {
    return (
      <RemoveDialog
        target={confirm.key}
        deps={confirm.deps}
        onRemoveAll={removeWithDependents}
        onKeep={() => {
          setConfirm(null);
          setScreen('picker');
        }}
      />
    );
  }

  return (
    <TopicPicker
      topics={topics}
      platform={platform}
      selected={selected}
      required={required}
      scan={scan}
      banner={banner}
      onToggle={toggle}
      onToggleTopic={toggleTopic}
      onSelectAll={selectAll}
      onSelectNone={selectNone}
      onEditOptions={editOptions}
      onContinue={tryContinue}
      onUpdates={openUpdates}
      onHelp={() => setScreen('help')}
      onQuit={() => finish(EXIT_CANCEL)}
    />
  );
}

const HELP_LINES = [
  'Choose the bundles to install, then press  c  to apply.',
  'Move      ↑ ↓ / k j     within a pane',
  '          Tab / ← →     switch topics ⇄ bundles',
  'Select    Space         add / remove a bundle',
  '          a / n         select all / none',
  'Options   Enter         edit a bundle’s options',
  'Updates   u             what `mesh update` upgrades',
  'Finish    c  apply       ·    q  cancel',
];

export function HelpScreen({ onClose }: { onClose: () => void }) {
  useInput(() => onClose());
  // Legend built from the active icon set (not hardcoded unicode) so the glyphs
  // shown here match exactly what the TopicPicker rows + quick legend render.
  // Mirrors blink's selectionIntents (checkbox*) + stateIntents (check/half/cross).
  const g = useGlyph();
  const lines = [
    ...HELP_LINES,
    '',
    `Status    ${g('checkboxOn')} selected   ${g('checkboxOff')} off   ${g('checkboxLock')} required`,
    `          ${g('check')} installed   ${g('half')} partial   ${g('cross')} not installed`,
  ];
  return (
    <Box flexDirection="column">
      <Dialog title="how to use" tone="default" lines={lines} actions={[{ key: 'any', label: 'close' }]} width={62} />
    </Box>
  );
}

function RemoveDialog({
  target,
  deps,
  onRemoveAll,
  onKeep,
}: {
  target: string;
  deps: string[];
  onRemoveAll: () => void;
  onKeep: () => void;
}) {
  useInput((input, key) => {
    if (input === 'y') return onRemoveAll();
    if (input === 'k' || key.escape) return onKeep();
  });
  const actions: DialogAction[] = [
    { key: 'y', label: 'remove all', primary: true },
    { key: 'k', label: 'keep' },
  ];
  const lines = [
    `${target} is required by:`,
    ...deps.map((d) => `  • ${d}`),
    '',
    'Remove it and the dependents above, or keep them?',
  ];
  return (
    <Box flexDirection="column">
      <Dialog title="remove dependency" tone="error" lines={lines} actions={actions} width={64} />
    </Box>
  );
}
