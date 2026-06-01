import { Prompt, isCancel } from '@clack/core';

export class AutocompleteMultiselectPrompt extends Prompt {
  options;
  cursor = 0;
  search = '';
  selectedValues;
  filteredIndices = [];
  required;
  _confirmRow = false;

  get _value() {
    return this.options
      .filter((_, i) => this.selectedValues.has(i))
      .map((o) => o.value);
  }

  get cursorOnConfirm() {
    return this.cursor === this.filteredIndices.length;
  }

  constructor(opts) {
    super(
      {
        validate: opts.validate,
        render: opts.render,
        input: opts.input,
        output: opts.output,
        signal: opts.signal,
      },
      false,
    );

    this.options = opts.options;
    this.required = opts.required ?? false;
    this._confirmRow = true;
    this.selectedValues = new Set(
      opts.initialValues
        ? opts.options
            .map((o, i) => (opts.initialValues.includes(o.value) ? i : -1))
            .filter((i) => i >= 0)
        : [],
    );
    this._refilter();
    this.value = this._value;

    const baseOnKeypress = this.onKeypress;
    this.onKeypress = (char, key) => {
      if (key?.name === 'return') {
        if (this.cursorOnConfirm) {
          this.value = this._value;
          this.state = 'submit';
          this.emit('finalize');
          this.render();
          this.close();
          return;
        }
        this._toggle();
        if (this.state === 'error') this.state = 'active';
        this.render();
        return;
      }
      baseOnKeypress(char, key);
    };

    this.on('cursor', (action) => {
      const totalRows = this.filteredIndices.length + 1;
      switch (action) {
        case 'up':
          this.cursor = totalRows === 0 ? 0 : (this.cursor - 1 + totalRows) % totalRows;
          break;
        case 'down':
          this.cursor = totalRows === 0 ? 0 : (this.cursor + 1) % totalRows;
          break;
      }
    });

    this.on('key', (char) => {
      if (char === '\t') {
        if (!this.cursorOnConfirm) this._toggle();
        return;
      }
      if (char === '\x7F' || char === '\b') {
        this.search = this.search.slice(0, -1);
        this._refilter();
        return;
      }
      if (char.length === 1 && char >= ' ' && char !== '\x1B') {
        this.search += char;
        this._refilter();
      }
    });

    this.on('finalize', () => {
      this.value = this._value;
    });
  }

  _toggle() {
    if (this.filteredIndices.length === 0) return;
    if (this.cursorOnConfirm) return;
    const realIndex = this.filteredIndices[this.cursor];
    const opt = this.options[realIndex];
    if (opt.disabled) return;
    if (this.selectedValues.has(realIndex)) {
      this.selectedValues.delete(realIndex);
    } else {
      this.selectedValues.add(realIndex);
    }
    this.value = this._value;
  }

  _refilter() {
    const q = this.search.toLowerCase();
    this.filteredIndices = this.options
      .map((o, i) => {
        if (!q) return i;
        const label = (o.label ?? String(o.value)).toLowerCase();
        const hint = (o.hint ?? '').toLowerCase();
        const desc = (o.desc ?? '').toLowerCase();
        return label.includes(q) || hint.includes(q) || desc.includes(q)
          ? i
          : -1;
      })
      .filter((i) => i >= 0);
    if (this.cursor > this.filteredIndices.length) {
      this.cursor = this.filteredIndices.length;
    }
  }

  focusedOption() {
    if (this.cursorOnConfirm) return null;
    if (this.filteredIndices.length === 0) return null;
    return this.options[this.filteredIndices[this.cursor]];
  }

  focusedRealIndex() {
    if (this.cursorOnConfirm) return -1;
    if (this.filteredIndices.length === 0) return -1;
    return this.filteredIndices[this.cursor];
  }

  isSelected(realIndex) {
    return this.selectedValues.has(realIndex);
  }
}
