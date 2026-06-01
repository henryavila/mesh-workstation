import { isCancel } from '@clack/core';
import { AutocompleteMultiselectPrompt } from '../ui/autocomplete-multiselect.js';
import { formatItemLabel, formatHint, buildLegend, displayName } from '../ui/format.js';
import { icons, pc, symbol } from '../ui/theme.js';

export async function selectItemsForTopic(
  topicName,
  allItems,
  installedStatus,
  previousSelections = [],
) {
  const items = allItems.filter((item) => !item.hidden);
  const options = items.map((item) => {
    const key = `${item.topic}/${item.name}`;
    // Scanner returns { installed, managed, idempotent } per item now.
    // Tolerate the older boolean shape for any test that hands us a raw map.
    const raw = installedStatus.get(key);
    const state =
      raw && typeof raw === 'object'
        ? raw
        : { installed: raw === true, managed: false, idempotent: false };
    return {
      value: key,
      label: displayName(item.name),
      hint: item.desc ?? '',
      desc: item.desc ?? '',
      installed: state.installed,         // true | false | null
      managed: state.managed === true,    // engine marker present
      idempotent: item.idempotent === true || state.idempotent === true,
      disabled: item.required ?? false,
      tier: item.tier,
      requires: item.requires,
    };
  });

  const initialValues = options
    .filter((o) => {
      if (previousSelections.length > 0) return previousSelections.includes(o.value);
      // Fresh install path: preselect anything the system already has or
      // mesh previously installed. Idempotent items only preselect if they
      // were managed at least once (otherwise they'd be silently re-applied
      // on every menu run, which the user may not want for a fresh box).
      if (o.idempotent) return o.managed;
      return o.installed === true || o.managed;
    })
    .map((o) => o.value);

  const installedCount = options.filter(
    (o) => o.installed === true || o.managed === true,
  ).length;

  const prompt = new AutocompleteMultiselectPrompt({
    options,
    initialValues,
    required: false,
    render() {
      const title = `${topicName}  ${pc.dim(`${installedCount}/${items.length} installed`)}`;

      switch (this.state) {
        case 'submit': {
          const selected = this.options
            .filter((_, i) => this.selectedValues.has(i))
            .map((o) => o.label);
          const summary =
            selected.length > 0
              ? selected.length <= 5
                ? selected.join(', ')
                : selected.slice(0, 4).join(', ') + `, +${selected.length - 4}`
              : pc.dim('none');
          return `${symbol('submit')}  ${title}\n${pc.gray(icons.bar)}  ${pc.dim(summary)}\n`;
        }
        case 'cancel':
          return `${symbol('cancel')}  ${title}\n${pc.gray(icons.bar)}\n`;
        default: {
          const lines = [];
          lines.push(`${symbol(this.state)}  ${title}`);

          if (this.search) {
            lines.push(`${pc.cyan(icons.bar)}  ${pc.dim('filter:')} ${this.search}`);
          } else {
            lines.push(`${pc.cyan(icons.bar)}  ${pc.dim('type to filter...')}`);
          }

          lines.push(`${pc.cyan(icons.bar)}`);

          const maxVisible = Math.max(process.stdout.rows - 10, 5);
          const totalRows = this.filteredIndices.length + 1;
          let startIdx = 0;
          if (totalRows > maxVisible) {
            startIdx = Math.max(
              0,
              Math.min(this.cursor - Math.floor(maxVisible / 2), totalRows - maxVisible),
            );
          }
          const endIdx = Math.min(startIdx + maxVisible, this.filteredIndices.length);

          if (startIdx > 0) {
            lines.push(`${pc.cyan(icons.bar)}  ${pc.dim('...')}`);
          }

          for (let vi = startIdx; vi < endIdx; vi++) {
            const realIdx = this.filteredIndices[vi];
            const opt = this.options[realIdx];
            const isFocused = vi === this.cursor;
            const isSelected = this.selectedValues.has(realIdx);
            const label = formatItemLabel(opt, isSelected, isFocused);
            const hint = isFocused ? formatHint(opt, isSelected) : '';
            const line = hint ? `${label}  ${hint}` : label;
            lines.push(`${pc.cyan(icons.bar)}  ${line}`);
          }

          if (endIdx < this.filteredIndices.length) {
            lines.push(`${pc.cyan(icons.bar)}  ${pc.dim('...')}`);
          }

          // Confirm row
          const confirmFocused = this.cursorOnConfirm;
          lines.push(`${pc.cyan(icons.bar)}`);
          if (confirmFocused) {
            lines.push(
              `${pc.cyan(icons.bar)}  ${pc.green(pc.bold('[ Confirm ]'))}  ${pc.dim('press Enter to go back')}`,
            );
          } else {
            lines.push(`${pc.cyan(icons.bar)}  ${pc.dim('[ Confirm ]')}`);
          }

          lines.push(`${pc.cyan(icons.bar)}`);
          lines.push(`${pc.cyan(icons.end)}  ${buildLegend()}`);

          return lines.join('\n');
        }
      }
    },
  });

  const result = await prompt.prompt();

  if (isCancel(result)) return null;
  return result;
}
