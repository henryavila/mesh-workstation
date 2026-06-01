import { icons, pc } from './theme.js';

// Strip the platform suffix (-mac, -wsl, -linux) for display. The suffix is
// meaningful in the manifest (per-platform variants share a base name) but
// noise in the UI — the user already chose a platform.
export function displayName(name) {
  return String(name ?? '').replace(/-(mac|wsl|linux)$/, '');
}

export function shortDisplayName(entry) {
  const slash = String(entry ?? '').lastIndexOf('/');
  const name = slash >= 0 ? entry.slice(slash + 1) : String(entry ?? '');
  return displayName(name);
}

// Drift state classifier — turns the four axes (selected, installed,
// managed, idempotent) into one of six display states:
//
//   steady       selected && installed && managed         (green ✓)
//   adoptable    !selected && installed && managed        (green ✓ but unticked)
//   foreign      !selected && installed && !managed       (gray ◇)
//   missing      selected && !installed && managed        (red ▲ — drift-out)
//   pending      selected && !installed && !managed       (yellow ○)
//   unmanaged    !selected && !installed                  (dim ○)
//   idempotent_ready    idempotent && managed             (cyan ↻)
//   idempotent_pending  idempotent && !managed            (yellow ↻)
//
// `installed === null` means "can't probe" (npx, git-clone). Treat as
// unknown and lean on managed-state alone for those.
export function classifyState({ selected, installed, managed, idempotent }) {
  if (idempotent) {
    return managed ? 'idempotent_ready' : 'idempotent_pending';
  }
  const isInstalled =
    installed === true || (installed === null && managed === true);
  if (selected && isInstalled && managed) return 'steady';
  if (selected && isInstalled && !managed) return 'foreign_selected';
  if (selected && !isInstalled) return managed ? 'missing' : 'pending';
  if (!selected && isInstalled && managed) return 'adoptable';
  if (!selected && isInstalled && !managed) return 'foreign';
  return 'unmanaged';
}

// Status icon (the second column, before the label). Mirrors classifyState.
export function statusIcon(state) {
  switch (state) {
    case 'steady':
      return pc.green(icons.installed);
    case 'adoptable':
      return pc.green(icons.installed);
    case 'foreign':
    case 'foreign_selected':
      return pc.gray(icons.foreign);
    case 'missing':
      return pc.red(icons.missing);
    case 'pending':
      return pc.yellow(icons.available);
    case 'idempotent_ready':
      return pc.cyan(icons.rerun);
    case 'idempotent_pending':
      return pc.yellow(icons.rerun);
    case 'unmanaged':
    default:
      return pc.dim(icons.available);
  }
}

// One-line hint shown to the right of the focused row.
export function stateHint(state) {
  switch (state) {
    case 'steady':
      return pc.dim('installed');
    case 'adoptable':
      return pc.green('installed · untick to remove');
    case 'foreign':
      return pc.yellow('installed outside mesh · tick to adopt');
    case 'foreign_selected':
      return pc.yellow('installed outside mesh · will be adopted');
    case 'missing':
      return pc.red('previously installed, now missing · will reinstall');
    case 'pending':
      return pc.green('not installed · will install');
    case 'idempotent_ready':
      return pc.cyan('idempotent · re-applies on each run');
    case 'idempotent_pending':
      return pc.yellow('idempotent · pending first run');
    case 'unmanaged':
    default:
      return pc.dim('not installed');
  }
}

export function formatItemLabel(option, isSelected, isFocused) {
  const label = option.label ?? String(option.value);
  const state = classifyState({
    selected: isSelected,
    installed: option.installed,
    managed: option.managed,
    idempotent: option.idempotent,
  });
  const sIcon = statusIcon(state);
  const checkbox = isSelected ? pc.green(icons.checkboxOn) : pc.dim(icons.checkboxOff);

  if (option.disabled) {
    return `${pc.dim(icons.locked)} ${pc.dim(label)}`;
  }
  return `${checkbox} ${sIcon} ${isFocused ? label : pc.dim(label)}`;
}

export function formatHint(option, isSelected) {
  if (!option) return '';
  const state = classifyState({
    selected: isSelected,
    installed: option.installed,
    managed: option.managed,
    idempotent: option.idempotent,
  });
  const parts = [stateHint(state)];

  if (option.desc) parts.push(pc.dim(option.desc));
  if (option.tier) parts.push(pc.dim(`tier: ${option.tier}`));
  if (option.requires?.length) {
    parts.push(pc.dim(`requires: ${option.requires.join(', ')}`));
  }
  return parts.join(pc.dim(' · '));
}

export function buildLegend() {
  return [
    `${pc.dim('Enter = toggle')} ${pc.dim('·')} ${pc.dim('Type to filter')} ${pc.dim('·')} ${pc.dim('[ Confirm ] = back to topics')}`,
    [
      `${pc.green(icons.installed)} ${pc.dim('installed')}`,
      `${pc.yellow(icons.available)} ${pc.dim('available')}`,
      `${pc.gray(icons.foreign)} ${pc.dim('foreign')}`,
      `${pc.red(icons.missing)} ${pc.dim('missing')}`,
      `${pc.cyan(icons.rerun)} ${pc.dim('idempotent')}`,
    ].join('  '),
  ].join('\n');
}

export function formatTopicHeader(topicName, index, total, installedCount, totalCount) {
  return `${pc.dim(`${index + 1}/${total}`)}  ${topicName}  ${pc.dim(`${installedCount}/${totalCount} installed`)}`;
}
