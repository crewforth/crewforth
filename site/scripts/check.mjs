// Text and link gates on the BUILT site (site/dist), because that is what a reader gets — a rule that holds in the
// sources can still break in the output (a generated table, a rewritten link, a page one language lost).
//
//   pairs     every page exists in both languages (Starlight would otherwise show a fallback)
//   old name  "Claude Starter Kit", csk, … appear 0 times            (the changelog is history: exempt)
//   kit       "the kit", "bu kit", "kitin" appear 0 times, and "kit" as a word outside code  (changelog exempt)
//   slash     "slash command" / "slash komut" appear 0 times: what `/` opens is the command menu  (changelog exempt;
//             the <meta> description sits outside <main> and keeps the term for search)
//   numbers   a percentage or an "N/10" appears only if evals/README.md carries it, or the site generated it from
//             source (the context-fill thresholds)                  (changelog exempt)
//   links     every internal link and image resolves to a built file
//   3rd party no <script>/<link>/font request to another host while CF_BEACON_TOKEN is unset
//   media     no single image or video file over 4 MB — the page is someone's first download
//   counts    no agent, skill or command count is typed into site/content — it comes from {{AGENT_COUNT}},
//             {{SKILL_COUNT}} or {{COMMAND_COUNT}}; a typed one goes stale the day a component is added or hidden
//             (this gate reads the SOURCES: in dist a typed number and a generated one look the same)
//   board     the experimental team board (`crew-board`, `refs/crew/board`) is on no page, code included   (changelog exempt)
//   sound     the home page's overview video starts with sound: no `muted` or `autoplay` on it, a sound button next to
//             it, and Home.astro's script never sets `.muted = true` (it plays only when someone presses play, so a
//             muted start is a second click for nothing)
//
// Code blocks and inline code are not prose and are left out of the text gates. Each gate first runs against planted
// input it must reject and input it must accept; a gate that cannot tell them apart fails before it reads the site.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fillThresholds, read } from './lib.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, '../..');
const DIST = path.resolve(here, '../dist');
const HOST = 'crewforth.com';

const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
const isChangelog = (rel) => /^(tr\/)?changelog\//.test(rel);

// Visible prose: the <main> of a page, with scripts, styles, code blocks and inline code removed, tags stripped.
export function prose(html) {
  const main = (html.match(/<main[\s\S]*?<\/main>/) || [html])[0];
  return main.replace(/<(script|style|pre|code)[\s\S]*?<\/\1>/g, ' ').replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&').replace(/&#39;|&#x27;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ');
}

export const oldName = (t) => [...t.matchAll(/claude starter kit|claude-starter-kit|claude-starter\/|@byerlikaya\/|(^|[^a-z0-9])csk([^a-z0-9]|$)/gi)].map((m) => m[0].trim());
export const kitPhrase = (t) => [...t.matchAll(/(^|[^a-zçğıöşü0-9])(the kit|bu kit|kitin)(?![a-zçğıöşü0-9])/gi)].map((m) => m[2]);
// "kit" as a word on its own, outside code: the product's old name, or an eval arm written as prose instead of as
// the `kit` it is in the runner's output. A path or a file name (kit/, kit.conf, kit-manifest) is not a word.
export const kitWord = (t) => [...t.matchAll(/(^|[^a-zçğıöşü0-9_./-])(kit(?:s|i|in|e|te|ten)?)(?![a-zçğıöşü0-9_\/-]|\.[a-z])/gi)].map((m) => m[2]);
export const slashCommand = (t) => [...t.matchAll(/slash[ -]?(command|komut)/gi)].map((m) => m[0]);
export const MEDIA_MAX = 4 * 1024 * 1024;
export const bigMedia = (entries) => entries.filter(([f, size]) => /\.(mp4|webm|mov|gif|png|jpe?g|webp|avif|svg)$/i.test(f) && size > MEDIA_MAX).map(([f, size]) => `${f} (${(size / 1048576).toFixed(1)} MB)`);
export const handCount = (md) => [...md.matchAll(/(?<![\w.{])\d+\s+(?:specialist\s+|uzman\s+)?(?:agents?|skills?|commands?|ajan\p{L}*|skill\p{L}*|komut\p{L}*)/giu)].map((m) => m[0]);
export const boardWord = (html) => [...html.matchAll(/crew-board|refs\/crew\/board/gi)].map((m) => m[0]);
// The overview <video> on a built home page: a muted or autoplaying start, a missing sound button, or no video at all.
export function overviewSound(html) {
  const tag = (html.match(/<video\b[^>]*\bcf-hero\b[^>]*>/i) || [])[0];
  if (!tag) return ['no overview <video class="cf-hero"> on the page'];
  const out = [...tag.matchAll(/\s(muted|autoplay)(?=[\s>=\/])/gi)].map((m) => `<video> carries "${m[1]}"`);
  if (!/<button\b[^>]*\bcf-sound\b/i.test(html)) out.push('no sound button (.cf-sound) next to the video');
  return out;
}
export const mutesOnPlay = (src) => [...src.matchAll(/\.muted\s*=\s*(?:true|!0)\b/g)].map((m) => m[0]);
export function numbers(t, allowed) {
  return [...t.matchAll(/[0-9]+(?:[.,][0-9]+)?%|%[0-9]+(?:[.,][0-9]+)?|[0-9]+\/10(?![0-9])/g)].map((m) => m[0]).filter((n) => !allowed(n));
}
export function thirdParty(html, css) {
  const out = [];
  for (const m of html.matchAll(/<(script|link|img|iframe)\b[^>]*\b(?:src|href)="(https?:)?\/\/([^/"]+)[^"]*"[^>]*>/gi)) {
    const tag = m[1].toLowerCase(); const host = m[3];
    if (host === HOST || host.endsWith('.' + HOST)) continue;
    if (tag === 'link' && !/rel="(stylesheet|preload|preconnect|dns-prefetch|modulepreload|icon)"/i.test(m[0])) continue;
    out.push(`${tag} → ${host}`);
  }
  for (const m of css.matchAll(/(?:@import\s+|url\()\s*["']?(?:https?:)?\/\/([^/"')]+)/gi)) if (m[1] !== HOST) out.push(`css → ${m[1]}`);
  return out;
}
export function brokenLinks(html, rel, exists) {
  const out = [];
  for (const m of html.matchAll(/\b(?:href|src)="([^"#?]+)[^"]*"/g)) {
    let u = m[1];
    if (/^(https?:|mailto:|data:|javascript:)/.test(u)) { if (!u.startsWith(`https://${HOST}`)) continue; u = u.slice(`https://${HOST}`.length) || '/'; }
    const target = u.startsWith('/') ? u.slice(1) : path.posix.join(path.posix.dirname(rel), u);
    const cands = [target, path.posix.join(target, 'index.html')];
    if (!cands.some(exists)) out.push(`${rel} → ${m[1]}`);
  }
  return out;
}

function selftest(allowed) {
  const must = (ok, what) => { if (!ok) throw new Error(`check.mjs twin failed: ${what} — this gate reads nothing`); };
  must(oldName('Welcome to Claude Starter Kit').length === 1 && oldName('run csk now').length === 1, 'old name not caught');
  must(oldName('the task is quick, a desk and ask').length === 0, 'old name flagged plain words');
  must(kitPhrase('Install the kit once. Bu kitin dosyaları.').length === 2, 'kit phrase not caught');
  must(kitPhrase('a toolkit, kitchen, the kits? kit.conf').length === 0, 'kit phrase flagged other words');
  must(kitWord('Cost $3.80 kit · $1.52 bare. Kit: no code, nine kit sessions').length === 3, 'a plain kit word not caught');
  must(kitWord('see kit/hooks and kit.conf, kit-manifest.txt, a toolkit').length === 0, 'kit word flagged a path');
  must(slashCommand('Run the slash command. 11 slash komutu, a Slash-Command').length === 3, 'slash command not caught');
  must(slashCommand('doubled slashes, start it with /crew-review, the command menu').length === 0, 'slash command flagged other words');
  must(bigMedia([['media/a.mp4', 5 * 1048576], ['media/b.jpg', 80000], ['assets/c.svg', 3 * 1048576]]).length === 1, 'an over-size video not caught, or a small file flagged');
  must(boardWord('<code>/crew-board</code> and refs/crew/board').length === 2 && boardWord('crew-review, board.sh, a board').length === 0, 'board check cannot tell the command from other words');
  must(handCount("all 12 agents and 40 skills · 12 ajanın ve 40 skill'in · 10 commands").length === 5, 'a typed count not caught');
  must(handCount('{{AGENT_COUNT}} agents, {{SKILL_COUNT}} skills, the four UI skills, 12 hooks, v2 commands').length === 0, 'a generated count or another number flagged');
  must(numbers('bare 7/10 and 93% of runs', allowed).length === 2, 'unbacked numbers not caught');
  must(numbers('hands off at %25 and 95%', allowed).length === 0, 'generated thresholds flagged');
  must(thirdParty('<script src="https://evil.example/x.js"></script><link rel="stylesheet" href="https://fonts.googleapis.com/css">', '@import url("https://fonts.x.com/a.css");').length === 3, 'third party not caught');
  must(thirdParty('<script src="/_astro/a.js"></script><a href="https://github.com/x">', '').length === 0, 'first-party flagged');
  must(overviewSound('<video class="cf-hero" controls muted playsinline></video>').length === 2 && overviewSound('<p>no video</p>').length === 1
    && overviewSound('<video autoplay class="cf-hero"><button class="cf-sound">').length === 1, 'a muted or autoplaying overview, or a missing one, not caught');
  must(overviewSound('<video class="cf-hero" controls playsinline data-muted-note="x"></video><button class="cf-sound">').length === 0, 'a video that starts with sound flagged');
  must(mutesOnPlay('video.muted = true; v.muted=!0').length === 2 && mutesOnPlay('video.muted = !video.muted; if (v.muted === true)').length === 0, 'a muted start in the script not caught, or the toggle flagged');
  must(brokenLinks('<a href="/nope/"></a><img src="/assets/x.gif">', 'index.html', (p) => p === 'assets/x.gif').length === 1, 'broken link not caught');
}

function main() {
  if (!fs.existsSync(DIST)) { console.error('site check: no dist/ — run `npm run build` first'); process.exit(1); }
  const evals = read(path.join(ROOT, 'evals/README.md'));
  const fill = fillThresholds(ROOT);
  const generated = new Set(fill.tiers.flatMap((n) => [`${n}%`, `%${n}`]));
  const allowed = (n) => generated.has(n) || evals.includes(n);
  selftest(allowed);

  const files = walk(DIST).map((f) => path.relative(DIST, f).split(path.sep).join('/'));
  const set = new Set(files);
  const exists = (p) => set.has(p);
  const pages = files.filter((f) => f.endsWith('.html') && f !== '404.html' && !f.startsWith('tr/404'));
  const css = files.filter((f) => f.endsWith('.css')).map((f) => read(path.join(DIST, f))).join('\n');
  const problems = [];

  const en = pages.filter((p) => !p.startsWith('tr/')); const tr = pages.filter((p) => p.startsWith('tr/'));
  for (const p of en) if (!set.has(`tr/${p}`)) problems.push(`pair: ${p} has no Turkish page`);
  for (const p of tr) if (!set.has(p.slice(3))) problems.push(`pair: ${p} has no English page`);

  const CONTENT = path.resolve(here, '../content');
  for (const loc of ['en', 'tr']) for (const f of fs.readdirSync(path.join(CONTENT, loc)).filter((x) => x.endsWith('.md'))) {
    for (const h of handCount(read(path.join(CONTENT, loc, f)))) problems.push(`count: content/${loc}/${f}: "${h}" is typed — use {{AGENT_COUNT}}, {{SKILL_COUNT}} or {{COMMAND_COUNT}}`);
  }

  let checked = 0;
  for (const rel of pages) {
    const html = read(path.join(DIST, rel)); const text = prose(html); checked++;
    if (!isChangelog(rel)) {
      for (const h of oldName(text)) problems.push(`old name: ${rel}: "${h}"`);
      for (const h of kitPhrase(text)) problems.push(`kit: ${rel}: "${h}"`);
      for (const h of kitWord(text)) problems.push(`kit word: ${rel}: "${h}" outside code`);
      for (const h of slashCommand(text)) problems.push(`slash command: ${rel}: "${h}" — the docs call it a command`);
      for (const h of boardWord(html)) problems.push(`board: ${rel}: "${h}" — the team board is experimental and stays off the site`);
      for (const h of numbers(text, allowed)) problems.push(`number: ${rel}: ${h} is not in evals/README.md`);
    }
    for (const b of brokenLinks(html, rel, exists)) problems.push(`link: ${b}`);
    if (!process.env.CF_BEACON_TOKEN) for (const t of thirdParty(html, '')) problems.push(`third party: ${rel}: ${t}`);
  }
  if (!process.env.CF_BEACON_TOKEN) for (const t of thirdParty('', css)) problems.push(`third party: css: ${t}`);
  for (const home of ['index.html', 'tr/index.html']) {
    if (!set.has(home)) { problems.push(`sound: ${home} is missing`); continue; }
    for (const h of overviewSound(read(path.join(DIST, home)))) problems.push(`sound: ${home}: ${h}`);
  }
  for (const h of mutesOnPlay(read(path.join(here, '../src/components/Home.astro')))) problems.push(`sound: Home.astro sets "${h}" — the overview starts with sound`);
  for (const m of bigMedia(files.map((f) => [f, fs.statSync(path.join(DIST, f)).size]))) problems.push(`media: ${m} is over 4 MB`);

  if (checked < 20) problems.push(`FIXTURE: only ${checked} page(s) found in dist/ — the build broke, not the text`);
  if (problems.length) {
    console.error(`site check: ${problems.length} problem(s)\n  ${problems.slice(0, 40).join('\n  ')}`);
    process.exit(1);
  }
  console.log(`site check: ${checked} pages (${en.length} EN + ${tr.length} TR, paired) · no old name, no "the kit" or plain "kit" outside code, no "slash command", no board, no typed count, no medium over 4 MB, no unbacked number, no broken link, no third-party request, the overview starts with sound · twins: each gate rejected planted input and accepted clean input`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
