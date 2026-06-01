import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, basename } from 'node:path';

export function parseItemsYaml(content) {
  const items = [];
  let current = null;

  for (const raw of content.split('\n')) {
    const line = raw.replace(/\r$/, '');

    if (/^\s*#/.test(line) || /^\s*$/.test(line)) continue;

    const itemStart = line.match(/^-\s+(\w+):\s*(.*)/);
    if (itemStart) {
      current = {};
      items.push(current);
      current[itemStart[1]] = parseValue(itemStart[2]);
      continue;
    }

    const field = line.match(/^\s+(\w+):\s*(.*)/);
    if (field && current) {
      current[field[1]] = parseValue(field[2]);
    }
  }

  return items;
}

function parseValue(raw) {
  let v = stripInlineComment(raw).trim();
  if (!v) return '';

  if (v.startsWith('[') && v.endsWith(']')) {
    return v
      .slice(1, -1)
      .split(',')
      .map((s) => unquote(s.trim()))
      .filter(Boolean);
  }

  if (v === 'true') return true;
  if (v === 'false') return false;

  const num = Number(v);
  if (!Number.isNaN(num) && v !== '') return num;

  return unquote(v);
}

// YAML allows `key: value  # comment`. Strip the trailing `#...` so
// `idempotent: true  # explainer` parses as boolean true, not a string.
// `#` inside quoted values is preserved (we only strip when the `#` is
// outside any quote context).
function stripInlineComment(raw) {
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i];
    const prev = i > 0 ? raw[i - 1] : '';
    if (ch === "'" && !inDouble) inSingle = !inSingle;
    else if (ch === '"' && !inSingle && prev !== '\\') inDouble = !inDouble;
    else if (ch === '#' && !inSingle && !inDouble) {
      // `#` only starts a comment if preceded by whitespace or at line start.
      if (i === 0 || /\s/.test(prev)) return raw.slice(0, i);
    }
  }
  return raw;
}

function unquote(s) {
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    // Double-quoted: process backslash escapes per YAML spec
    return s
      .slice(1, -1)
      .replace(/\\(["\\nrt])/g, (_, ch) => {
        switch (ch) {
          case 'n': return '\n';
          case 'r': return '\r';
          case 't': return '\t';
          default: return ch;
        }
      });
  }
  if (s.length >= 2 && s.startsWith("'") && s.endsWith("'")) {
    // Single-quoted: literal except '' → '
    return s.slice(1, -1).replace(/''/g, "'");
  }
  return s;
}

export function readTopicManifest(topicDir) {
  const yamlPath = join(topicDir, 'items.yaml');
  if (!existsSync(yamlPath)) return null;
  const content = readFileSync(yamlPath, 'utf8');
  const items = parseItemsYaml(content);
  const topicName = basename(topicDir);
  return items.map((item) => ({
    topic: topicName,
    name: item.name ?? '',
    type: item.type ?? '',
    spec: item.spec ?? '',
    check: item.check ?? '',
    script: item.script ?? '',
    platforms: Array.isArray(item.platforms) ? item.platforms : [],
    desc: item.desc ?? '',
    requires: Array.isArray(item.requires) ? item.requires : [],
    post: item.post ?? '',
    rollback: item.rollback ?? '',
    required: item.required === true,
    hidden: item.hidden === true,
    // idempotent: the item's install action is safe-to-rerun and has no
    // stable post-install signal (e.g. config-apply, drift cleanup, font
    // re-render). Scanner skips probing it and the UI renders a neutral
    // "re-applies on every run" badge instead of a false "not installed".
    idempotent: item.idempotent === true,
    uninstall_tier: typeof item.uninstall_tier === 'number' ? item.uninstall_tier : 0,
  }));
}

export function readAllManifests(topicsRoot, { platform = null } = {}) {
  const topicDirs = readdirSync(topicsRoot, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();

  const result = [];
  for (const dir of topicDirs) {
    const items = readTopicManifest(join(topicsRoot, dir));
    if (!items) continue;
    for (const item of items) {
      if (platform && item.platforms.length > 0 && !item.platforms.includes(platform)) {
        continue;
      }
      result.push(item);
    }
  }
  return result;
}

export function groupByTopic(items) {
  const groups = new Map();
  for (const item of items) {
    if (!groups.has(item.topic)) {
      groups.set(item.topic, []);
    }
    groups.get(item.topic).push(item);
  }
  return groups;
}
