// The generator's own tests, on a scratch copy of the repository: nothing here touches the real tree. Each case is
// a must-change or must-fail twin for a promise the site makes (5S §4.2):
//   1 a new agent and a new skill appear on their pages, and every count the pages quote moves with them
//   2 a skill with no Turkish line turns the build red (the site never falls back to English)
//   3 a page with no Turkish file turns the build red
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { generate } from './generate.mjs';
import { BuildError } from './lib.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(here, '../..');
const INPUTS = ['kit/agents', 'kit/skills', 'kit/hooks', 'kit/eval', 'kit/CLAUDE.md', 'packaging', 'site/content', 'assets',
  'evals/README.md', 'CHANGELOG.md', 'README.md', 'README.tr.md', 'VERSION'];

function scratch() {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'crew-site-selftest-'));
  for (const p of INPUTS) fs.cpSync(path.join(REPO, p), path.join(d, 'repo', p), { recursive: true });
  fs.mkdirSync(path.join(d, 'site'));
  fs.cpSync(path.join(REPO, 'site/media'), path.join(d, 'site/media'), { recursive: true });   // the overview video the home page serves
  return { root: path.join(d, 'repo'), site: path.join(d, 'site'), done: () => fs.rmSync(d, { recursive: true, force: true }) };
}
const page = (s, rel) => fs.readFileSync(path.join(s.site, 'src/content/docs', rel), 'utf8');
const results = [];
const check = (name, ok, detail) => { results.push({ name, ok, detail }); };
function expectFail(name, s, pattern) {
  try { generate(s.root, s.site); check(name, false, 'the build passed'); }
  catch (e) { check(name, e instanceof BuildError && pattern.test(e.message), e.message.split('\n')[0]); }
}

// 1 · add one agent and one skill (with their Turkish lines), bump the diagram subtitles as the generator would ask.
{
  const s = scratch();
  try {
    const base = generate(s.root, s.site);
    fs.writeFileSync(path.join(s.root, 'kit/agents/crew-zz-probe.md'), '---\nname: crew-zz-probe\ndescription: |\n  Probe agent added by the site self-test. Owns nothing.\nmetadata:\n  stage: audit\n---\n\nBody.\n');
    // The stage lives in two places that must agree: the frontmatter and both agent tables.
    for (const [loc, st] of [['en', 'Audit'], ['tr', 'Denetle']]) {
      const f = path.join(s.root, 'site/content', loc, 'skills.md');
      fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace(/(\| `crew-session-manager` \|[^\n]*\n)/, `$1| \`crew-zz-probe\` | ${st} | probe |\n`));
    }
    fs.mkdirSync(path.join(s.root, 'kit/skills/zz-probe'));
    fs.writeFileSync(path.join(s.root, 'kit/skills/zz-probe/SKILL.md'), '---\nname: zz-probe\ndescription: |\n  Probe skill added by the site self-test. Does nothing.\n---\n\nBody.\n');
    fs.appendFileSync(path.join(s.root, 'packaging/agent-summaries.tr.tsv'), 'crew-zz-probe\tSelf-test ajanı.\n');
    fs.appendFileSync(path.join(s.root, 'packaging/skill-summaries.tr.tsv'), 'zz-probe\tSelf-test skill.\n');
    for (const n of ['network-en-dark', 'network-en-light', 'network-tr-dark', 'network-tr-light']) {
      const f = path.join(s.root, 'assets', `${n}.svg`);
      fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace(/(\d+)( agents| ajan)( · )(\d+)( skills?)/, (m, a, b, c, d, e) => `${Number(a) + 1}${b}${c}${Number(d) + 1}${e}`));
    }
    const after = generate(s.root, s.site);
    const skillsEn = page(s, 'skills.md'); const gatesTr = page(s, 'tr/gates.md');
    check('a new agent and skill show up, and the counts move',
      after.agents === base.agents + 1 && after.skills === base.skills + 1
        && page(s, 'agents.md').includes('`crew-zz-probe`') && page(s, 'tr/agents.md').includes('Self-test ajanı.')
        && skillsEn.includes('`zz-probe`') && skillsEn.includes(`All ${base.skills + 1} skills`)
        && skillsEn.includes(`${base.agents + 1} specialist agents`) && gatesTr.includes(`| **Skill** | ${base.skills + 1} |`)
        && /"label":"Audit","agents":\[[^\]]*"crew-zz-probe"/.test(page(s, 'index.mdx'))
        && /"label":"Denetle","agents":\[[^\]]*"crew-zz-probe"/.test(page(s, 'tr/index.mdx')),
      `agents ${base.agents} → ${after.agents}, skills ${base.skills} → ${after.skills}`);
  } finally { s.done(); }
}
// 1b · an agent with no stage, and one whose stage the agents table contradicts.
{
  const s = scratch();
  try {
    const f = path.join(s.root, 'kit/agents/crew-planner.md');
    fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace(/metadata:\n  stage: understand\n/, ''));
    expectFail('an agent with no stage fails the build', s, /crew-planner\.md: metadata\.stage is missing/);
  } finally { s.done(); }
}
{
  const s = scratch();
  try {
    const f = path.join(s.root, 'site/content/en/skills.md');
    fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace('| `crew-planner` | Understand |', '| `crew-planner` | Produce |'));
    expectFail('a stage the agents table contradicts fails the build', s, /skills\.md puts crew-planner under "Produce"/);
  } finally { s.done(); }
}
// 2 · a skill whose Turkish line is gone.
{
  const s = scratch();
  try {
    const f = path.join(s.root, 'packaging/skill-summaries.tr.tsv');
    fs.writeFileSync(f, fs.readFileSync(f, 'utf8').split('\n').filter((l) => !l.startsWith('adr\t')).join('\n'));
    expectFail('a skill with no Turkish line fails the build', s, /skill-summaries\.tr\.tsv: adr/);
  } finally { s.done(); }
}
// 3 · a page whose Turkish file is gone.
{
  const s = scratch();
  try {
    fs.rmSync(path.join(s.root, 'site/content/tr/studio.md'));
    expectFail('a page with no Turkish file fails the build', s, /site\/content\/tr\/studio\.md is missing/);
  } finally { s.done(); }
}
// 4 · a release renames the version on the home page and next to the logo; a VERSION that is not one fails.
{
  const s = scratch();
  try {
    fs.writeFileSync(path.join(s.root, 'VERSION'), '9.8.7\n');
    const r = generate(s.root, s.site);
    const json = JSON.parse(fs.readFileSync(path.join(s.site, 'src/assets/version.json'), 'utf8'));
    check('the version shown is the one in VERSION',
      r.version === '9.8.7' && json.version === '9.8.7'
        && page(s, 'index.mdx').includes('"version":{"text":"v9.8.7","href":"/changelog/"}')
        && page(s, 'tr/index.mdx').includes('"version":{"text":"v9.8.7","href":"/tr/changelog/"}'),
      `generated v${r.version}, version.json ${json.version}`);
    fs.writeFileSync(path.join(s.root, 'VERSION'), 'next\n');
    expectFail('a VERSION that is not a version fails the build', s, /VERSION is not a version: 'next'/);
  } finally { s.done(); }
}

for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name} — ${r.detail}`);
if (results.some((r) => !r.ok)) process.exit(1);
console.log(`site selftest: ${results.length}/${results.length} generator twins behaved`);
