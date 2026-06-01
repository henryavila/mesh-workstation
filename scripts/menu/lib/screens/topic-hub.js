import * as p from '@clack/prompts';
import { isCancel } from '@clack/core';
import { icons, pc } from '../ui/theme.js';
import { displayName } from '../ui/format.js';
import { selectItemsForTopic } from './item-selector.js';

const ALWAYS_ON = new Set([
  '00-core',
  '05-identity',
  '10-languages',
  '20-terminal-ux',
  '30-shell',
  '40-tmux',
  '50-git',
  '95-dotfiles-personal',
]);

const TOPIC_LABELS = {
  '45-docker': 'Docker',
  '60-web-stack': 'Web Stack',
  '70-remote-access': 'Remote Access',
  '80-claude-code': 'Claude Code',
  '82-ai-tools': 'AI Tools',
  '85-code-server': 'Code Server',
  '90-editor': 'Editor',
};

const TOPIC_HINTS = {
  '45-docker': 'Colima + Docker CLI + Compose',
  '60-web-stack': 'MySQL, Redis, Valet, mkcert + extras',
  '70-remote-access': 'Tailscale, mosh, SSH',
  '80-claude-code': 'Claude CLI, syncthing, moshi, claudebar',
  '82-ai-tools': 'mdprobe, atomic-skills, rtk',
  '85-code-server': 'Standalone code-server',
  '90-editor': 'Neovim default config',
};

const CONTINUE_VALUE = '__continue__';
const EXIT_VALUE = '__exit__';

function visibleItems(items) {
  return items.filter((i) => !i.hidden);
}

function isAllOrNothing(items) {
  const visible = visibleItems(items);
  if (visible.length <= 1) return true;
  const independentItems = visible.filter((item) => {
    const isDependedOn = visible.some((other) => other.requires?.includes(item.name));
    const hasDeps = item.requires?.length > 0;
    return !item.required && !isDependedOn && !hasDeps;
  });
  return independentItems.length === 0;
}

function countSelected(topic, items, selectedEntries) {
  const visibleKeys = new Set(visibleItems(items).map((i) => `${i.topic}/${i.name}`));
  return selectedEntries.filter((e) => visibleKeys.has(e)).length;
}

function topicEntries(topic, items) {
  return visibleItems(items).map((i) => `${i.topic}/${i.name}`);
}

function buildTopicOptions(grouped, installedStatus, selectedEntries) {
  const options = [];
  for (const [topic, items] of grouped) {
    if (ALWAYS_ON.has(topic)) continue;

    const visible = visibleItems(items);
    const total = visible.length;
    const selected = countSelected(topic, items, selectedEntries);
    // Scanner now returns rich state per item; treat anything where the
    // probe came back true OR the engine has a managed marker as installed.
    // Idempotent items count as installed when managed (the engine ran them
    // at least once); otherwise pending.
    const installed = visible.filter((i) => {
      const st = installedStatus.get(`${i.topic}/${i.name}`);
      if (!st) return false;
      return st.installed === true || st.managed === true;
    }).length;
    const aon = isAllOrNothing(items);

    const name = TOPIC_LABELS[topic] ?? topic;
    let statusText;
    if (aon) {
      statusText = selected > 0 ? pc.green('included') : pc.dim('not included');
    } else {
      statusText =
        selected > 0
          ? pc.green(`${selected}/${total} selected`)
          : installed > 0
            ? pc.dim(`${installed}/${total} installed`)
            : pc.dim('not configured');
    }

    options.push({
      value: topic,
      label: `${name}  ${statusText}`,
      hint: TOPIC_HINTS[topic] ?? '',
    });
  }

  options.push({
    value: CONTINUE_VALUE,
    label: `${pc.green('→')} Done — save selections`,
    hint: 'proceed to summary & apply',
  });

  options.push({
    value: EXIT_VALUE,
    label: `${pc.dim('✕')} Exit without saving`,
  });

  return options;
}

export function getAlwaysOnTopics() {
  return [...ALWAYS_ON];
}

export function getAlwaysOnEntries(grouped) {
  const entries = [];
  for (const topic of ALWAYS_ON) {
    const items = grouped.get(topic);
    if (!items) continue;
    for (const item of items) {
      entries.push(`${item.topic}/${item.name}`);
    }
  }
  return entries;
}

export async function runTopicHub(grouped, installedStatus, previousSelections) {
  const selectedEntries = new Set(previousSelections);

  for (const entry of getAlwaysOnEntries(grouped)) {
    selectedEntries.add(entry);
  }

  while (true) {
    const currentEntries = [...selectedEntries];
    const options = buildTopicOptions(grouped, installedStatus, currentEntries);

    const choice = await p.select({
      message: 'Select a topic to configure (Enter to open, or Continue when done)',
      options,
    });

    if (isCancel(choice) || choice === EXIT_VALUE) return null;

    if (choice === CONTINUE_VALUE) {
      return {
        selectedTopics: getSelectedTopicNames(grouped, selectedEntries),
        selectedEntries: [...selectedEntries],
      };
    }

    const topic = choice;
    const items = grouped.get(topic);
    if (!items) continue;

    if (isAllOrNothing(items)) {
      const isCurrentlyOn = countSelected(topic, items, currentEntries) > 0;
      const name = TOPIC_LABELS[topic] ?? topic;
      const itemNames = visibleItems(items).map((i) => displayName(i.name)).join(', ');

      const include = await p.confirm({
        message: `${isCurrentlyOn ? 'Keep' : 'Include'} ${name}? (${itemNames})`,
        initialValue: isCurrentlyOn,
      });

      if (isCancel(include)) continue;

      const entries = topicEntries(topic, items);
      if (include) {
        for (const e of entries) selectedEntries.add(e);
      } else {
        for (const e of entries) selectedEntries.delete(e);
      }
      continue;
    }

    const prevForTopic = currentEntries.filter((e) => e.startsWith(`${topic}/`));
    const result = await selectItemsForTopic(topic, items, installedStatus, prevForTopic);

    if (result === null) {
      continue;
    }

    for (const e of currentEntries) {
      if (e.startsWith(`${topic}/`)) selectedEntries.delete(e);
    }
    for (const e of result) {
      selectedEntries.add(e);
    }
  }
}

function getSelectedTopicNames(grouped, selectedEntries) {
  const topics = new Set();
  for (const entry of selectedEntries) {
    const slash = entry.indexOf('/');
    if (slash > 0) topics.add(entry.slice(0, slash));
  }
  return [...topics].filter((t) => grouped.has(t));
}
