import pc from 'picocolors';

const unicode =
  process.platform !== 'win32'
    ? process.env.TERM !== 'linux'
    : !!(
        process.env.CI ||
        process.env.WT_SESSION ||
        process.env.TERM_PROGRAM === 'vscode' ||
        process.env.TERM === 'xterm-256color' ||
        process.env.TERM === 'alacritty'
      );

const u = (a, b) => (unicode ? a : b);

export const icons = {
  installed: u('✓', '+'),
  available: u('○', 'o'),
  willRemove: u('✗', 'x'),
  locked: u('🔒', '#'),
  diamond: u('◆', '*'),
  diamondOpen: u('◇', 'o'),
  square: u('■', 'x'),
  warning: u('▲', '!'),
  bar: u('│', '|'),
  end: u('└', '-'),
  checkboxOn: u('◼', '[+]'),
  checkboxOff: u('◻', '[ ]'),
  radio: u('●', '>'),
  radioOff: u('○', ' '),
  // Drift-state icons (added 2026-05-28 alongside marker-based scanner).
  rerun: u('↻', '~'),       // idempotent: re-runs on every apply
  foreign: u('◇', '?'),     // installed but no mesh marker (user installed manually)
  missing: u('▲', '!'),     // selected but not installed (will reinstall)
};

export const status = {
  installed: (text) => pc.green(`${icons.installed} ${text}`),
  available: (text) => pc.yellow(`${icons.available} ${text}`),
  willRemove: (text) => pc.red(`${icons.willRemove} ${text}`),
  required: (text) => pc.dim(`${icons.locked} ${text}`),
};

export const symbol = (state) => {
  switch (state) {
    case 'initial':
    case 'active':
      return pc.cyan(icons.diamond);
    case 'cancel':
      return pc.red(icons.square);
    case 'error':
      return pc.yellow(icons.warning);
    case 'submit':
      return pc.green(icons.diamondOpen);
    default:
      return pc.cyan(icons.diamond);
  }
};

export { pc };
