import * as p from '@clack/prompts';
import { execSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { readAllManifests, groupByTopic } from './core/manifest-reader.js';
import { scanAll } from './core/scanner.js';
import { readSelections, writeSelections, readParams, writeParams } from './core/selections-io.js';
import { computeDelta, autoSelectDependencies } from './core/delta.js';
import { runTopicHub } from './screens/topic-hub.js';
import { promptParams } from './screens/param-prompts.js';
import { showSummary } from './screens/summary.js';
import { shortDisplayName } from './ui/format.js';

function detectPlatform() {
  try {
    const menuDir = dirname(new URL(import.meta.url).pathname);
    const detectScript = join(menuDir, '..', '..', 'lib', 'detect-os.sh');
    return execSync(`bash "${detectScript}"`, { encoding: 'utf8', timeout: 3_000 }).trim();
  } catch {
    return process.platform === 'darwin' ? 'mac' : 'linux';
  }
}

// Prime sudo so install-state checks that need root (systemsetup, plistbuddy,
// /etc/wsl.conf reads, etc.) succeed during the scan. Guards: (1) skip if
// no controlling tty (e.g. setup.sh pipes the menu through tee — isTTY
// reports false even when the user is sitting at a real terminal, see
// feedback_tty_detection_under_tee_pipe.md); (2) skip if sudo cache is hot;
// (3) hard timeout so a misconfigured askpass can't block forever.
function hasCtty() {
  try {
    execSync(': </dev/tty >/dev/null 2>&1', { stdio: 'ignore', timeout: 1_000 });
    return true;
  } catch {
    return false;
  }
}

function primeSudo() {
  if (process.env.MESH_MENU_SKIP_SUDO === '1') return;
  if (!hasCtty()) return;

  try {
    execSync('sudo -n -v', { stdio: 'ignore', timeout: 2_000 });
    return; // already cached
  } catch {
    // cold cache → ask once
  }

  p.log.info('Some install checks need sudo. Enter password (or Ctrl+C to skip):');
  try {
    // Bind stdio to /dev/tty so the prompt reaches the user even when
    // stdout is piped through tee/setup.sh.
    execSync('sudo -v </dev/tty >/dev/tty 2>/dev/tty', { stdio: 'ignore', timeout: 60_000, shell: '/bin/bash' });
  } catch {
    p.log.warn('Continuing without sudo — items that require root to verify may show as not installed.');
  }
}

export async function runWizard({ dryRun = false, topicsRoot = null, platform = null } = {}) {
  const menuDir = dirname(new URL(import.meta.url).pathname);
  if (!topicsRoot) {
    topicsRoot = join(menuDir, '..', '..', '..', 'topics');
  }
  if (!platform) {
    platform = detectPlatform();
  }

  p.intro(`mesh setup (${platform})`);

  primeSudo();

  const allItems = readAllManifests(topicsRoot, { platform });
  const grouped = groupByTopic(allItems);

  const s = p.spinner();
  s.start('Scanning installed items...');
  const installedStatus = await scanAll(allItems, { topicsRoot, platform });
  s.stop('Scan complete.');

  const previousSelections = readSelections() ?? [];
  const previousParams = readParams();

  // Hub-and-spoke: user picks topics to drill into, configures items, returns to hub
  const hubResult = await runTopicHub(grouped, installedStatus, previousSelections);
  if (hubResult === null) {
    p.outro('Cancelled.');
    return false;
  }

  const { selectedTopics, selectedEntries } = hubResult;

  const { selected: withDeps, added } = autoSelectDependencies(allItems, selectedEntries);
  if (added.length > 0) {
    p.log.info(`Auto-selected ${added.length} dep(s): ${added.map(shortDisplayName).join(', ')}`);
  }

  // Phase 3: parameters
  const params = await promptParams(selectedTopics, previousParams, { topicsRoot });
  if (params === null) {
    p.outro('Cancelled.');
    return false;
  }

  // Phase 4: summary + confirm
  const delta = computeDelta(allItems, previousSelections, withDeps);
  const confirmed = await showSummary(delta);
  if (!confirmed) {
    p.outro('No changes applied.');
    return false;
  }

  if (!dryRun) {
    writeSelections(withDeps);
    writeParams(params);
    p.log.success('Selections saved.');
  } else {
    p.log.info('Dry run — no files written.');
  }

  p.outro('Done.');
  return { selections: withDeps, params, delta };
}

