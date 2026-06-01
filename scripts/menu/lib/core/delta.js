export function computeDelta(manifest, previousSelections, newSelections) {
  const prevSet = new Set(previousSelections ?? []);
  const newSet = new Set(newSelections);

  const install = [];
  const remove = [];
  const keep = [];

  for (const entry of newSet) {
    if (prevSet.has(entry)) {
      keep.push(entry);
    } else {
      install.push(entry);
    }
  }

  for (const entry of prevSet) {
    if (!newSet.has(entry)) {
      remove.push(entry);
    }
  }

  return { install, remove, keep };
}

export function validateDependencies(manifest, selectedEntries) {
  const selected = new Set(selectedEntries);
  const errors = [];

  const itemsByKey = new Map();
  for (const item of manifest) {
    itemsByKey.set(`${item.topic}/${item.name}`, item);
    itemsByKey.set(item.name, item);
  }

  for (const entry of selected) {
    const item = itemsByKey.get(entry);
    if (!item?.requires?.length) continue;
    for (const dep of item.requires) {
      const depKey = `${item.topic}/${dep}`;
      if (!selected.has(depKey) && !selected.has(dep)) {
        errors.push({
          item: entry,
          missing: dep,
          message: `${entry} requires ${dep} which is not selected`,
        });
      }
    }
  }

  return errors;
}

export function autoSelectDependencies(manifest, selectedEntries) {
  const selected = new Set(selectedEntries);
  const added = [];

  const itemsByName = new Map();
  for (const item of manifest) {
    itemsByName.set(item.name, item);
  }

  let changed = true;
  while (changed) {
    changed = false;
    for (const entry of [...selected]) {
      const slash = entry.indexOf('/');
      const name = slash >= 0 ? entry.slice(slash + 1) : entry;
      const topic = slash >= 0 ? entry.slice(0, slash) : null;
      const item = itemsByName.get(name);
      if (!item?.requires?.length) continue;
      for (const dep of item.requires) {
        const depKey = topic ? `${topic}/${dep}` : dep;
        if (!selected.has(depKey)) {
          selected.add(depKey);
          added.push(depKey);
          changed = true;
        }
      }
    }

    // Pull in hidden items whose requires are all currently selected.
    // Hidden items are implementation details that ride along with a parent.
    for (const item of manifest) {
      if (!item.hidden) continue;
      const entry = `${item.topic}/${item.name}`;
      if (selected.has(entry)) continue;
      if (!item.requires?.length) continue;
      const allMet = item.requires.every((dep) => {
        const depKey = `${item.topic}/${dep}`;
        return selected.has(depKey) || selected.has(dep);
      });
      if (allMet) {
        selected.add(entry);
        added.push(entry);
        changed = true;
      }
    }
  }

  return { selected: [...selected], added };
}

export function canRemove(manifest, itemEntry, selectedEntries) {
  const selected = new Set(selectedEntries);
  const slash = itemEntry.indexOf('/');
  const itemName = slash >= 0 ? itemEntry.slice(slash + 1) : itemEntry;

  const blockers = [];
  for (const entry of selected) {
    if (entry === itemEntry) continue;
    const entrySlash = entry.indexOf('/');
    const entryName = entrySlash >= 0 ? entry.slice(entrySlash + 1) : entry;
    const item = manifest.find((m) => m.name === entryName);
    if (item?.requires?.includes(itemName)) {
      blockers.push(entry);
    }
  }

  return { allowed: blockers.length === 0, blockers };
}
