/**
 * app.tsx — bootstrap entry for the mesh setup wizard (loaded by index.js via
 * tsx). Detects the icon set, registers the domain glyph packs, renders <App/>,
 * and exits with the App's code:
 *   0   = wrote selections + applied (setup.sh proceeds with them)
 *   130 = user left without applying (quit / Ctrl-C) → setup.sh ABORTS
 *   1   = could not launch (no TTY) → setup.sh falls back to saved/default
 * The default is EXIT_CANCEL, so a crash/Ctrl-C mid-render aborts rather than
 * silently installing defaults the user never chose. The App component lives in
 * wizard.tsx so it stays side-effect-free and testable.
 */
import { render } from 'ink';
import { ThemeProvider, detectIconSet } from '@henryavila/blink-tui';
import { registerDomainGlyphs } from './glyphs.js';
import { App, EXIT_CANCEL } from './wizard.js';

async function main() {
  // `prompt` subcommand → a single-field blink-tui input for bash (the secret
  // key, init fields, confirmations) — the SAME engine as the wizard, not a
  // bare `read`. Loaded dynamically so the wizard path is untouched.
  const argv = process.argv.slice(2);
  if (argv[0] === 'prompt') {
    const { promptMain } = await import('./prompt-main.js');
    await promptMain(argv.slice(1));
    return;
  }

  // `ai-pick` subcommand → the realtime-filter project picker for `mesh ai`
  // (scripts/runners/ai.sh feeds candidates, reads the chosen line back).
  if (argv[0] === 'ai-pick') {
    const { aiPickMain } = await import('./ai-pick-main.js');
    await aiPickMain(argv.slice(1));
    return;
  }

  // `help` subcommand → the interactive `mesh help` browser. The shell runner
  // feeds command metadata plus precomputed `mesh <cmd> --help` text.
  if (argv[0] === 'help') {
    const { helpMain } = await import('./help-main.js');
    await helpMain(argv.slice(1));
    return;
  }

  // The wizard is keyboard-interactive (Ink raw mode), which needs a real TTY.
  // Without one (piped stdin, CI, or a non-interactive `!`-style shell) Ink's
  // useInput would throw a raw-mode stack trace, so fail clearly instead and let
  // the caller fall back to the saved/default selection.
  if (!process.stdin.isTTY) {
    process.stderr.write(
      'mesh menu: needs an interactive terminal (no TTY on stdin).\n' +
        'Run it directly in your terminal, e.g.\n' +
        '  node scripts/menu/index.js\n' +
        'or use the non-interactive flow: NON_INTERACTIVE=1 bash setup.sh\n',
    );
    process.exit(1);
  }

  registerDomainGlyphs();
  const dryRun = process.argv.slice(2).includes('--dry-run');
  const iconSet = await detectIconSet();

  let code = EXIT_CANCEL;
  const { waitUntilExit } = render(
    <ThemeProvider iconSet={iconSet}>
      <App dryRun={dryRun} onExit={(c) => (code = c)} />
    </ThemeProvider>,
  );
  await waitUntilExit();
  process.exit(code);
}

main();
