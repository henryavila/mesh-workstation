/**
 * MeshHelpScreen — standalone `mesh help` command reference.
 *
 * The wizard's `?` help is intentionally a small "how to use this selector"
 * dialog. Top-level `mesh help` needs command content instead, so it has its own
 * screen with a command list and a focused detail pane.
 */
import { useEffect, useMemo, useState } from 'react';
import { Box, Text, useInput } from 'ink';
import {
  Header,
  Input,
  Pane,
  List,
  DescriptionList,
  useListNavigation,
  useStdoutDimensions,
  type DescriptionItem,
  type ListRowData,
} from '@henryavila/blink-tui';

export interface HelpCommand {
  id: string;
  usage: string;
  summary: string;
  details: string[];
}

export const MESH_HELP_COMMANDS: HelpCommand[] = [
  {
    id: 'status',
    usage: 'mesh status [alias] [flags]',
    summary: 'Cross-mesh dashboard',
    details: [
      'Shows the local/fleet status panel. Pass a host alias such as crc to drill into one node.',
      'Use --json, --write, --detail, and --refresh for scriptable or persisted reports.',
    ],
  },
  {
    id: 'update',
    usage: 'mesh update [-o NAME] [-f] [-i]',
    summary: 'Pull and apply updates',
    details: [
      'Refreshes mesh-workstation and mesh-identity, then applies incremental or full install changes.',
      '-o restricts the target repo, -f runs a full apply, and -i opens the setup menu for a full workstation run.',
    ],
  },
  {
    id: 'setup',
    usage: 'mesh setup [--no-update] [setup args...]',
    summary: 'Update, then run setup.sh',
    details: [
      'Runs mesh update first, then launches the workstation setup script from the current checkout.',
      'Use --no-update when testing local edits or working offline.',
    ],
  },
  {
    id: 'menu',
    usage: 'mesh menu [--apply]',
    summary: 'Interactive bundle selector',
    details: [
      'Opens the setup TUI without running the engine by default.',
      '--apply writes the selected state and then executes the install/uninstall delta.',
    ],
  },
  {
    id: 'help',
    usage: 'mesh help [command] [--plain]',
    summary: 'Browse Mesh command help',
    details: [
      'Opens the interactive command reference, optionally focused on one command.',
      '--plain prints compact help when a terminal UI is unavailable.',
    ],
  },
  {
    id: 'doctor',
    usage: 'mesh doctor [--fix]',
    summary: 'Detect or repair drift',
    details: [
      'Reports identity deploy drift and installed-item health without mutating by default.',
      '--fix repairs broken installed items through the normal installer path.',
    ],
  },
  {
    id: 'adopt',
    usage: 'mesh adopt',
    summary: 'Backfill install markers',
    details: [
      'Read-only marker reconciliation for machines provisioned by the older v1 setup.',
      'Writes markers only for tools that are already present.',
    ],
  },
  {
    id: 'upgrade',
    usage: 'mesh upgrade [--dry-run]',
    summary: 'Upgrade flagged packages',
    details: [
      'Runs version-aware upgrades for manifest items marked autoupdate, never a blind package-manager upgrade.',
      '--dry-run lists candidates without changing the machine.',
    ],
  },
  {
    id: 'reinstall',
    usage: 'mesh reinstall shell [--dry-run]',
    summary: 'Reapply the shell layer',
    details: [
      'Reapplies managed shell, terminal and git files on an existing machine.',
      '--dry-run shows the plan without invoking the engine.',
    ],
  },
  {
    id: 'run',
    usage: 'mesh run [flags] <subcommand>',
    summary: 'Fan out safe mesh commands',
    details: [
      'Runs supported mesh subcommands across selected hosts sequentially over SSH.',
      'Use --hosts, --online, --all, or --dry-run to control the target set.',
    ],
  },
  {
    id: 'topic',
    usage: 'mesh topic list | <NN|NN-name> [...]',
    summary: 'Re-apply selected topics',
    details: [
      'Lists official workstation topic numbers or runs only the requested topic subset.',
      'Useful for focused repair when you do not want a full setup/update pass.',
    ],
  },
  {
    id: 'services',
    usage: 'mesh services <verb> [name...]',
    summary: 'Control mesh-owned daemons',
    details: [
      'Lists and controls curated services such as database, web, and sync daemons.',
      'Tracks active and enabled as separate states.',
    ],
  },
  {
    id: 'tuios',
    usage: 'mesh tuios <setup|status|doctor|disable> [--host ALIAS]',
    summary: 'Browser terminal access',
    details: [
      'Configures one protected browser URL per machine while sharing its local TUIOS session.',
      'After creating the Access app, confirm its email policy and supply its Application AUD tag.',
      'Use status and doctor to inspect the host, or disable to stop only Mesh-managed public services.',
    ],
  },
  {
    id: 'ai',
    usage: 'mesh ai [term] [--agent X]',
    summary: 'Open an agent or shell in a repo',
    details: [
      'Discovers projects, focuses an existing herdr workspace, or creates a new one.',
      'Use --grok, --claude, --codex, --shell, --list, and local picker preferences for routing.',
    ],
  },
  {
    id: 'config',
    usage: 'mesh config [term]',
    summary: 'Edit personal config',
    details: [
      'Opens files declared by the identity deploy map, shows the source diff, then refreshes deployments.',
      'Use list, --no-install, or --no-diff for narrower workflows.',
    ],
  },
  {
    id: 'secret',
    usage: 'mesh secret <verb>',
    summary: 'Manage replicated secrets',
    details: [
      'Initializes, unlocks, edits, lists, checks, deploys, and pushes the git-crypt backed personal secret layer.',
    ],
  },
  {
    id: 'syncthing',
    usage: 'mesh syncthing <verb>',
    summary: 'Pair this node into sync',
    details: [
      'Reconciles Syncthing peers and folders from the identity repo.',
      'Includes pair, init-hub, topology, status, password, and url verbs.',
    ],
  },
  {
    id: 'clean',
    usage: 'mesh clean [--apply] [--deep] [--compact]',
    summary: 'Reclaim regenerable caches',
    details: [
      'Dry-runs cache cleanup by default across macOS, WSL, and Linux.',
      '--apply deletes Tier-1 caches, --deep includes large redownloadable caches, and --compact shrinks WSL VHDX storage.',
    ],
  },
  {
    id: 'init',
    usage: 'mesh init [MODE | FLAGS]',
    summary: 'Bootstrap identity',
    details: [
      'Adopts an existing identity repo, creates one from the template, skips identity, or asks interactively.',
    ],
  },
  {
    id: 'snap',
    usage: 'mesh snap [flags]',
    summary: 'Refresh this host snapshot',
    details: [
      'Captures this machine status for the cross-mesh dashboard. Hooks usually run this automatically.',
    ],
  },
  {
    id: 'lint',
    usage: 'mesh lint',
    summary: 'Run repo invariant lints',
    details: [
      'Runs the scripts/lib/lints suite that enforces shell, manifest, path, and architecture rules.',
    ],
  },
  {
    id: 'catalog',
    usage: 'mesh catalog generate',
    summary: 'Regenerate derived listings',
    details: [
      'Rebuilds catalog files consumed by docs, status surfaces, and validation.',
    ],
  },
  {
    id: 'template-check',
    usage: 'mesh template-check [flags]',
    summary: 'Verify template parity',
    details: [
      'Compares mesh-workstation/template against the private identity structure, honoring the declared skip namespaces.',
    ],
  },
  {
    id: 'personal-clone',
    usage: 'mesh personal-clone [flags]',
    summary: 'Clone personal repos',
    details: [
      'Reads the identity repo catalog and clones missing private projects onto the current machine.',
    ],
  },
];

function commandSearchScore(cmd: HelpCommand, query: string): number | null {
  const q = query.trim().toLowerCase();
  if (!q) return 0;

  const id = cmd.id.toLowerCase();
  const usage = cmd.usage.toLowerCase();
  const summary = cmd.summary.toLowerCase();
  const details = cmd.details.map((text) => text.toLowerCase());
  if (id === q) return 1;
  if (id.startsWith(q)) return 2;
  if (id.includes(q)) return 3;
  if (usage.includes(q)) return 4;
  if (summary.includes(q)) return 5;
  if (details.some((text) => text.includes(q))) return 6;
  return null;
}

function filterHelpCommands(commands: HelpCommand[], query: string): HelpCommand[] {
  const q = query.trim();
  if (!q) return commands;

  return commands
    .map((cmd, index) => ({ cmd, index, score: commandSearchScore(cmd, q) }))
    .filter((entry): entry is { cmd: HelpCommand; index: number; score: number } => entry.score !== null)
    .sort((a, b) => a.score - b.score || a.index - b.index)
    .map((entry) => entry.cmd);
}

export function parseHelpExtensionCommands(raw = ''): HelpCommand[] {
  return raw
    .split('\n')
    .map((line) => line.replace(/\r$/, ''))
    .filter((line) => line.trim().length > 0)
    .map((line) => {
      const [id, usage, summary, ...details] = line.split('\t').map((part) => part.trim());
      if (!id || !usage || !summary) return null;
      return {
        id,
        usage,
        summary,
        details: details.filter((value) => value.length > 0),
      };
    })
    .filter((cmd): cmd is HelpCommand => cmd !== null);
}

function mergeHelpCommands(extensionCommands: HelpCommand[]): HelpCommand[] {
  const builtInIds = new Set(MESH_HELP_COMMANDS.map((cmd) => cmd.id));
  return [...MESH_HELP_COMMANDS, ...extensionCommands.filter((cmd) => !builtInIds.has(cmd.id))];
}

export function MeshHelpScreen({
  onClose,
  extensionCommands = parseHelpExtensionCommands(process.env.MESH_HELP_EXTENSION_COMMANDS),
}: {
  onClose: () => void;
  extensionCommands?: HelpCommand[];
}) {
  const [query, setQuery] = useState('');
  const commands = useMemo(() => mergeHelpCommands(extensionCommands), [extensionCommands]);
  const filtered = useMemo(
    () => filterHelpCommands(commands, query),
    [commands, query],
  );
  const commandIds = useMemo(() => filtered.map((c) => c.id), [filtered]);
  const [focusId, setFocusId] = useState<string | null>(commandIds[0] ?? null);
  useEffect(() => {
    if (focusId === null || !commandIds.includes(focusId)) {
      setFocusId(commandIds[0] ?? null);
    }
  }, [commandIds, focusId]);
  const nav = useListNavigation({ ids: commandIds, focusedId: focusId, onFocusChange: setFocusId });
  const { rows: rawRows, columns: rawCols } = useStdoutDimensions();
  const rows = rawRows >= 12 ? rawRows : 24;
  const cols = rawCols >= 60 ? rawCols : 88;
  const screenH = Math.max(10, rows - 1);
  // Leave one spare row under the fixed header/body/footer bands. A frame that
  // exactly fills the TTY can trigger Ink's full-screen redraw path and hide the
  // bottom footer in real terminals even when ink-testing-library sees it.
  const contentH = Math.max(5, screenH - 6);
  const commandWidth = Math.max(28, Math.min(42, Math.round(cols * 0.36)));
  const focused = filtered.find((c) => c.id === nav.focusedId) ?? filtered[0] ?? null;

  useInput((input, key) => {
    if (input === 'q' || key.escape) return onClose();
    if (key.downArrow) return nav.focusNext();
    if (key.upArrow) return nav.focusPrev();
    if (key.backspace || key.delete) return setQuery((q) => q.slice(0, -1));
    if (input.length > 0 && !key.ctrl && !key.meta && !key.tab) {
      setQuery((q) => q + input);
    }
  });

  const commandRows: ListRowData[] =
    filtered.length > 0
      ? filtered.map((cmd) => ({
          id: cmd.id,
          label: cmd.id,
        }))
      : [{ id: 'no-results', label: 'No commands match', muted: true }];
  const detail: DescriptionItem[] = focused
    ? [
        { value: focused.summary, state: 'info' },
        { value: ' ' },
        { term: 'Usage', value: focused.usage },
        ...focused.details.map((value) => ({ value })),
      ]
    : [{ value: 'No command matches the current search.', state: 'warn' }];

  return (
    <Box flexDirection="column" height={screenH}>
      <Box flexShrink={0}>
        <Header title="mesh help" subtitle={`interactive command reference - ${commands.length} commands`} />
      </Box>
      <Box flexShrink={0}>
        <Input title="search" value={query} placeholder="type command or keyword..." focused />
      </Box>
      <Box flexDirection="row" height={contentH} flexShrink={1} minHeight={0} overflow="hidden">
        <Pane title="Commands" tone="focus" width={commandWidth} flexGrow={0}>
          <List rows={commandRows} focusedId={filtered.length > 0 ? nav.focusedId : null} height={contentH - 2} scrolloff={2} />
        </Pane>
        <Pane title={focused?.id ?? 'No match'} flexGrow={1}>
          <DescriptionList items={detail} gutter={8} />
        </Pane>
      </Box>
      <Box flexShrink={0}>
        <Text> q  close   esc  close </Text>
      </Box>
    </Box>
  );
}
