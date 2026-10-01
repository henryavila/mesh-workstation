/**
 * help-main — the `node index.js help …` entry: render the interactive command
 * help browser. The shell runner precomputes the command registry TSV and each
 * command's `--help` text, then the TUI stays read-only and side-effect-free.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { render } from 'ink';
import { ThemeProvider, detectIconSet } from '@henryavila/blink-tui';
import { registerDomainGlyphs } from './glyphs.js';
import { HelpBrowser, parseCommandsTsv, type HelpCommand } from './screens/HelpBrowser.js';

export interface HelpArgs {
  commands: string;
  detailsDir: string;
  selected?: string;
}

/** Parse the help argv (everything AFTER the subcommand). Pure. Returns null
 *  when --commands or --details-dir is missing. */
export function parseHelpArgs(argv: string[]): HelpArgs | null {
  const get = (flag: string): string | undefined => {
    const i = argv.indexOf(flag);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : undefined;
  };
  const commands = get('--commands');
  const detailsDir = get('--details-dir');
  const selected = get('--selected');
  if (!commands || !detailsDir) return null;
  return selected ? { commands, detailsDir, selected } : { commands, detailsDir };
}

function readDetails(commands: HelpCommand[], dir: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const cmd of commands) {
    try {
      out.set(cmd.name, readFileSync(join(dir, cmd.name), 'utf8').replace(/\r/g, '').split('\n'));
    } catch {
      out.set(cmd.name, [`mesh ${cmd.name}`, '', cmd.summary]);
    }
  }
  return out;
}

export async function helpMain(args: string[]): Promise<void> {
  const opts = parseHelpArgs(args);
  if (!opts) {
    process.stderr.write('mesh help: usage: help --commands <tsv> --details-dir <dir> [--selected <command>]\n');
    process.exit(1);
  }

  if (!process.stdin.isTTY) {
    process.stderr.write('mesh help: needs an interactive terminal (no TTY on stdin).\n');
    process.exit(1);
  }

  let commands: HelpCommand[] = [];
  try {
    commands = parseCommandsTsv(readFileSync(opts.commands, 'utf8'));
  } catch {
    process.exit(1);
  }
  if (commands.length === 0) process.exit(1);
  const details = readDetails(commands, opts.detailsDir);

  registerDomainGlyphs();
  const iconSet = await detectIconSet();

  let code = 0;
  let unmountFn: (() => void) | undefined;
  const finish = (c = 0) => {
    code = c;
    unmountFn?.();
  };

  const { waitUntilExit, unmount } = render(
    <ThemeProvider iconSet={iconSet}>
      <HelpBrowser commands={commands} details={details} selected={opts.selected} onExit={finish} />
    </ThemeProvider>,
  );
  unmountFn = unmount;
  await waitUntilExit();
  process.exit(code);
}
