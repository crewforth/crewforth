#!/usr/bin/env node
// Studio's design tokens, generated from the design system.
//
//   node packaging/gen-studio-tokens.mjs            write kit/studio/web/tokens.css
//   node packaging/gen-studio-tokens.mjs --check    exit 1 if that file differs from what this would write
//   node packaging/gen-studio-tokens.mjs --stdout   print it instead
//
// The source is packaging/design/tokens.json, a byte copy of the Crewforth design system's tokens. Nothing in
// kit/studio/web/ carries a colour of its own: style.css reads these custom properties and derives the in-between
// tones from them with color-mix().
//
// Dark is the primary theme, so it is what a bare :root gets. Light arrives two ways, and both blocks carry the
// same declarations: the system asks for it and the viewer has not chosen dark, or the viewer chose it with the
// theme button.
//
// No dependencies. A token the generator cannot place stops the build rather than being written as it came: a
// colour missing a theme would render as the other theme's value, which looks like a design decision.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const SOURCE = path.join(ROOT, 'packaging', 'design', 'tokens.json');
export const TARGET = path.join(ROOT, 'kit', 'studio', 'web', 'tokens.css');

export const DARK = ':root';
export const LIGHT_SYSTEM = ':root:not([data-theme="dark"])';
export const LIGHT_SYSTEM_MEDIA = '(prefers-color-scheme: light)';
export const LIGHT_CHOSEN = ':root[data-theme="light"]';

const HEX = /^#[0-9a-fA-F]{6}$/;
const REF = /^\{([\w-]+)\}$/;

/** One theme's colours, references resolved. */
function colours(tokens, theme) {
  const byName = new Map(tokens.color.tokens.map((t) => [t.name, t]));
  const resolve = (name, seen) => {
    const t = byName.get(name);
    if (!t) throw new Error(`colour "${name}" is referenced and not defined`);
    const v = t.value?.[theme];
    if (typeof v !== 'string') throw new Error(`colour "${name}" has no ${theme} value`);
    const ref = REF.exec(v);
    if (ref) {
      if (seen.includes(ref[1])) throw new Error(`colour "${name}" refers to itself through ${seen.join(' → ')}`);
      return resolve(ref[1], seen.concat(ref[1]));
    }
    if (!HEX.test(v)) throw new Error(`colour "${name}" (${theme}) is "${v}", not #rrggbb or a {reference}`);
    return v;
  };
  return tokens.color.tokens.map((t) => [`--${t.name}`, resolve(t.name, [t.name])]);
}

/** Everything that does not change with the theme. */
function constants(tokens) {
  const out = [];
  for (const [name, stack] of Object.entries(tokens.type.families)) out.push([`--font-${name}`, stack]);
  for (const group of tokens.type.groups) {
    for (const s of group.styles) {
      out.push([`--type-${s.name}-size`, s.fontSize]);
      out.push([`--type-${s.name}-line`, s.lineHeight]);
      out.push([`--type-${s.name}-weight`, String(s.fontWeight)]);
      if (s.letterSpacing) out.push([`--type-${s.name}-tracking`, s.letterSpacing]);
    }
  }
  for (const t of tokens.spacing.tokens) out.push([`--${t.name}`, t.value]);
  for (const t of tokens.radius.tokens) out.push([`--${t.name}`, t.value]);
  for (const [k, v] of out) {
    if (typeof v !== 'string' || v === '' || /[;{}]/.test(v)) throw new Error(`token ${k} has an unusable value`);
  }
  return out;
}

const block = (selector, decls, indent = '') => [
  `${indent}${selector} {`,
  ...decls.map(([k, v]) => `${indent}  ${k}: ${v};`),
  `${indent}}`,
].join('\n');

export function render(tokens) {
  const themes = tokens.color.themes.map((t) => t.id);
  if (themes.join() !== 'dark,light') throw new Error(`expected the themes dark and light, got ${themes.join()}`);
  const dark = [['color-scheme', 'dark'], ...colours(tokens, 'dark')];
  const light = [['color-scheme', 'light'], ...colours(tokens, 'light')];
  return [
    `/* GENERATED from packaging/design/tokens.json (${tokens.name}, version ${tokens.version}) by`,
    '   packaging/gen-studio-tokens.mjs. Do not edit: change the JSON and run the generator. */',
    '',
    block(DARK, [...dark, ...constants(tokens)]),
    '',
    `@media ${LIGHT_SYSTEM_MEDIA} {`,
    block(LIGHT_SYSTEM, light, '  '),
    '}',
    '',
    block(LIGHT_CHOSEN, light),
    '',
  ].join('\n');
}

const isMain = process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const css = render(JSON.parse(fs.readFileSync(SOURCE, 'utf8')));
  const rel = path.relative(ROOT, TARGET);
  if (process.argv.includes('--stdout')) {
    process.stdout.write(css);
  } else if (process.argv.includes('--check')) {
    const have = fs.existsSync(TARGET) ? fs.readFileSync(TARGET, 'utf8') : null;
    if (have !== css) {
      process.stderr.write(`${rel} is ${have === null ? 'missing' : 'stale'} — run: node packaging/gen-studio-tokens.mjs\n`);
      process.exit(1);
    }
    process.stdout.write(`${rel} is what the generator writes (${css.length} bytes)\n`);
  } else {
    fs.writeFileSync(TARGET, css);
    process.stdout.write(`wrote ${rel} (${css.length} bytes)\n`);
  }
}
