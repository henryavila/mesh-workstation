import { execSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';

const ENGINE_DIR = join(dirname(new URL(import.meta.url).pathname), '..', '..', '..', 'lib');

function installStateDir() {
  if (process.env.MESH_INSTALL_STATE_DIR) return process.env.MESH_INSTALL_STATE_DIR;
  const stateHome = process.env.XDG_STATE_HOME ?? join(homedir(), '.local', 'state');
  return join(stateHome, 'mesh', 'installed');
}

// Read the marker directory once per scan and build a Set of "topic/name"
// strings. The marker is the engine's authoritative record of "mesh
// successfully installed this item" — see scripts/lib/install-state.sh.
function readManagedSet() {
  const dir = installStateDir();
  const managed = new Set();
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return managed; // no marker dir yet → nothing managed
  }
  for (const entry of entries) {
    if (!entry.endsWith('.env')) continue;
    const base = entry.slice(0, -4);
    const sep = base.indexOf('__');
    if (sep <= 0) continue;
    const topic = base.slice(0, sep);
    const name = base.slice(sep + 2);
    managed.add(`${topic}/${name}`);
  }
  return managed;
}

export function checkItem(item, { topicsRoot, platform = 'mac' } = {}) {
  if (item.check) {
    return runShellCheck(item.check);
  }

  if (item.type === 'custom') {
    if (!item.script) return false;
    const topicDir = join(topicsRoot, item.topic);
    const scriptPath = item.script.startsWith('./')
      ? join(topicDir, item.script)
      : item.script;
    return checkCustomScript(scriptPath);
  }

  return checkViaDriver(item);
}

function runShellCheck(cmd) {
  try {
    execSync(cmd, { stdio: 'pipe', timeout: 5_000 });
    return true;
  } catch {
    return false;
  }
}

function checkCustomScript(scriptPath) {
  if (!existsSync(scriptPath)) return false;
  try {
    const content = readFileSync(scriptPath, 'utf8');
    if (!/^check\s*\(\)/m.test(content)) return false;

    // BREW_BIN is a mac-only concept. On WSL/Linux the value would point
    // at a path that doesn't exist; cross-platform scripts already gate
    // brew usage on `uname -s == Darwin`, so the export is at best
    // cosmetic and at worst confusing. Skip it off-mac.
    const onMac = process.platform === 'darwin';
    const brewExport = onMac
      ? `BREW_BIN="${process.env.HOMEBREW_PREFIX
          ? `${process.env.HOMEBREW_PREFIX}/bin/brew`
          : '/opt/homebrew/bin/brew'}"`
      : '';
    const result = execSync(
      `bash -c '
        set +e
        # Allow only non-interactive sudo so the menu scan never blocks
        # on a password prompt. If sudo cache is hot, real checks work;
        # if cold, sudo -n fails immediately (exit 1, no prompt).
        sudo() { command sudo -n "$@" 2>/dev/null; }
        export -f sudo
        source "${ENGINE_DIR}/log.sh" 2>/dev/null
        source "${ENGINE_DIR}/env.sh" 2>/dev/null
        ${brewExport}
        source "${scriptPath}" 2>/dev/null
        if declare -f check >/dev/null 2>&1; then
          check && echo __INSTALLED__ || echo __NOT_INSTALLED__
        else
          echo __NO_CHECK__
        fi
      '`,
      { stdio: ['pipe', 'pipe', 'pipe'], timeout: 5_000, encoding: 'utf8' },
    );
    return result.includes('__INSTALLED__');
  } catch {
    return false;
  }
}

function checkViaDriver(item) {
  const spec = item.spec;
  if (!spec) return false;

  switch (item.type) {
    case 'brew-formula':
      return runShellCheck(`brew list --formula -- ${spec} 2>/dev/null`);
    case 'brew-cask':
      return runShellCheck(`brew list --cask -- ${spec} 2>/dev/null`);
    case 'apt':
      return runShellCheck(`dpkg -s -- ${spec} 2>/dev/null`);
    case 'npm-global':
      return runShellCheck(`npm list -g ${spec} 2>/dev/null`);
    case 'cargo':
      return runShellCheck(`command -v ${spec} 2>/dev/null`);
    case 'pip':
      return runShellCheck(`pip show ${spec} 2>/dev/null`);
    // git-clone and npx have no reliable on-disk probe outside the
    // engine marker — return null so we don't shadow the marker state
    // with a guaranteed-false probe. The marker IS the detection.
    case 'git-clone':
    case 'npx':
      return null;
    default:
      return null;
  }
}

function scanAllSync(items, { topicsRoot, platform = 'mac' } = {}) {
  const brewFormulas = [];
  const brewCasks = [];
  const probed = new Map();

  for (const item of items) {
    if (item.idempotent) continue;
    if (item.type === 'brew-formula' && !item.check && item.spec) {
      brewFormulas.push(item);
    } else if (item.type === 'brew-cask' && !item.check && item.spec) {
      brewCasks.push(item);
    }
  }

  const installedFormulas = batchBrewCheck('--formula', brewFormulas.map((i) => i.spec));
  const installedCasks = batchBrewCheck('--cask', brewCasks.map((i) => i.spec));

  for (const item of brewFormulas) {
    probed.set(`${item.topic}/${item.name}`, installedFormulas.has(item.spec));
  }
  for (const item of brewCasks) {
    probed.set(`${item.topic}/${item.name}`, installedCasks.has(item.spec));
  }

  for (const item of items) {
    const key = `${item.topic}/${item.name}`;
    if (probed.has(key)) continue;
    if (item.idempotent) {
      probed.set(key, null); // idempotent items are not probed
      continue;
    }
    probed.set(key, checkItem(item, { topicsRoot, platform }));
  }

  // Compose final state: { installed, managed, idempotent } per item.
  // `installed` reflects what the system probe sees right now (true/false),
  // or null when probing is impossible (npx, git-clone, idempotent items).
  // `managed` reflects whether mesh's install-engine has recorded a
  // successful install marker for this item.
  const managedSet = readManagedSet();
  const results = new Map();
  for (const item of items) {
    const key = `${item.topic}/${item.name}`;
    const probedValue = probed.get(key);
    results.set(key, {
      installed: probedValue,
      managed: managedSet.has(key),
      idempotent: item.idempotent === true,
    });
  }

  return results;
}

export async function scanAll(items, { topicsRoot, platform = 'mac' } = {}) {
  const thisFile = new URL(import.meta.url).pathname;
  return new Promise((resolve, reject) => {
    const worker = new Worker(thisFile, {
      workerData: {
        items: items.map((i) => ({ ...i })),
        topicsRoot,
        platform,
      },
    });
    worker.on('message', (entries) => {
      resolve(new Map(entries));
    });
    worker.on('error', reject);
    worker.on('exit', (code) => {
      if (code !== 0) reject(new Error(`Scanner exited with code ${code}`));
    });
  });
}

function batchBrewCheck(flag, specs) {
  if (specs.length === 0) return new Set();
  try {
    const output = execSync(`brew list ${flag} 2>/dev/null`, {
      stdio: 'pipe',
      timeout: 10_000,
      encoding: 'utf8',
    });
    const installed = new Set(output.trim().split('\n').map((l) => l.trim()));
    // `brew list` emits short names. A spec may be plain (e.g. `mysql`) or
    // tap-qualified (e.g. `rjyo/moshi/moshi-hook`); the last `/`-segment is
    // always the short name that appears in `brew list` output.
    return new Set(
      specs.filter((s) => {
        if (installed.has(s)) return true;
        const slash = s.lastIndexOf('/');
        if (slash >= 0 && installed.has(s.slice(slash + 1))) return true;
        return false;
      }),
    );
  } catch {
    return new Set();
  }
}

if (!isMainThread) {
  const { items, topicsRoot, platform } = workerData;
  const results = scanAllSync(items, { topicsRoot, platform });
  parentPort.postMessage([...results.entries()]);
}
