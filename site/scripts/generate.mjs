// Builds the site's pages from the repository, once per build. Nothing it writes is edited by hand: the output
// (src/content/docs, src/assets, public) is gitignored and rebuilt every time.
//
// Sources, and why each is read rather than copied:
//   site/content/{en,tr}/*.md   the documentation pages (moved out of the READMEs in 5R); text is used as written
//   kit/agents, kit/skills      the agents, the skill catalogue and the commands — a view of the payload
//   packaging/*.tr.tsv          the Turkish summaries; a missing line FAILS the build instead of showing English
//   kit/eval/gate-report.sh     the rule inventory, which it derives from the hooks
//   kit/hooks/session-guard.sh  the context-fill thresholds the pages quote
//   evals/README.md, CHANGELOG.md, README*.md   the measuring page, the changelog and the home page
//
// Usage: node scripts/generate.mjs [--root <repo>] [--out <site dir>]   (the self-test points both at copies)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  LOCALES, BuildError, fail, read, cell, tsv, agents, skillsAndCommands, fillThresholds, gateRules, checkNetworkSvgs, alwaysOn, stages, STAGES, installRows,
} from './lib.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? path.resolve(process.argv[i + 1]) : d; };
const ROOT = arg('--root', path.resolve(here, '../..'));
const SITE = arg('--out', path.resolve(here, '..'));
const REPO_URL = 'https://github.com/Crewforth/crewforth';

// The documentation pages that come from site/content. Every one must exist in every locale.
const CONTENT = ['install', 'gates', 'skills', 'studio', 'sessions-and-cost', 'verification', 'extending'];

const UI = {
  en: {
    agents: { title: 'Agents', lead: 'The {n} specialist agents, each read from its own definition when the site is built, so this list is always the one that installs.', col: ['Agent', 'What it owns'] },
    commands: { title: 'Commands', lead: 'The {n} commands you start with `/crew-…`, each read from its own definition when the site is built.', col: ['Command', 'What it does', 'Who runs it'], user: 'you', both: 'you or Claude' },
    catalogue: ['Skill', 'What it does'],
    rules: { heading: 'Enforced rules ({n})', lead: 'Read from the hooks when the site is built — the same inventory `gate-report.sh` derives — so a rule added to a hook appears here without anyone editing this page.', col: 'Rule' },
    measuring: { title: 'How we measure', note: '' },
    changelog: { title: 'Changelog', note: '' },
    homeQuick: '## Quick start',
  },
  tr: {
    agents: { title: 'Ajanlar', lead: '{n} uzman ajan; her biri site derlenirken kendi tanım dosyasından okunur, yani bu liste her zaman kurulan listedir.', col: ['Ajan', 'Sahip olduğu alan'] },
    commands: { title: 'Komutlar', lead: '`/crew-…` ile başlattığınız {n} komut; her biri site derlenirken kendi tanım dosyasından okunur.', col: ['Komut', 'Ne yapar', 'Kim çalıştırır'], user: 'siz', both: 'siz ya da Claude' },
    catalogue: ['Skill', 'Ne yapar'],
    rules: { heading: 'Uygulanan kurallar ({n})', lead: "Site derlenirken hook'lardan okunur (`gate-report.sh`'in türettiği envanterin aynısı); bir hook'a eklenen kural, bu sayfayı kimse düzenlemeden burada görünür.", col: 'Kural' },
    measuring: { title: 'Nasıl ölçüyoruz', note: "> Bu sayfa İngilizce kaynağından, `evals/README.md`'den derlenir. Ölçüm kayıtları tek bir yerde tutulur; ikinci bir kopyası yoktur.\n\n" },
    changelog: { title: 'Değişiklik günlüğü', note: "> Bu sayfa İngilizce kaynağından, `CHANGELOG.md`'den derlenir. Günlük bir tarih kaydıdır; her sürüm yayımlandığı adla anılır.\n\n" },
    homeQuick: '## Hızlı başlangıç',
  },
};

// Bytes → tokens at the one measured ratio: a real `claude -p` turn in which 21,804 bytes of the same always-on
// material cost 9,198 tokens (quoted on the page itself). Formatted the way each language writes numbers.
const RATIO = 9198 / 21804;
function costFacts(loc, c) {
  const n = (x) => x.toLocaleString(loc === 'en' ? 'en-US' : 'tr-TR');
  const k = (b) => { const v = (b * RATIO / 1000).toFixed(1); return loc === 'en' ? `${v}k` : `${v.replace('.', ',')} bin`; };
  return {
    ALWAYS_ON_BYTES: n(c.total), ALWAYS_ON_TOKENS: k(c.total),
    DESC_BYTES: n(c.descriptions), DESC_TOKENS: k(c.descriptions),
    UI_BYTES: n(c.ui), UI_TOKENS: String(Math.round(c.ui * RATIO / 10) * 10),
  };
}

// Inline `code` in the brief's strings → <code>, after escaping everything else.
const inline = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])).replace(/`([^`]+)`/g, '<code>$1</code>');

// The home page's words (5S.b2 brief, §3). EN is the source; TR is the brief's own rewrite.
const HOME = {
  en: {
    title: { before: 'Your engineering ', accent: 'crew', after: ' for Claude Code.' },
    lead: 'Subagents, skills, commands and hooks: specialists that plan, build, review and ship a change in any stack, with the rules that matter enforced by gates.',
    docs: 'Read the docs', star: 'Star on GitHub', copy: 'Copy', copied: 'Copied',
    play: 'Play the 1-minute overview', sound: 'Sound',
    videoDesc: 'A one-minute overview: plain Claude Code, the install, the crew at work, the gates, Studio and the handoff.',
    adopt: 'Existing repository? `npx crewforth adopt` lands everything on its own branch. `main` is never touched.',
    crewHeading: 'Twelve specialists, one order',
    crewLead: 'Every request has an owner. A routing hook names it beside your prompt, and quality rises stage by stage before anything is committed.',
    stages: ['Understand', 'Produce', 'Audit', 'Close', 'Hand off'],
    stageLines: ['Scope and acceptance criteria when a request is unclear.', 'The change itself, in any stack.', 'Run in parallel by `/crew-review`.', 'A clean review, then a commit that waits for you.', 'Session fill, and the state written down for next time.'],
    skills: 'All {N} skills behind them →',
    gateHeading: 'Rule → gate',
    gateLines: ['A commit waits for your approval, in every permission mode.', 'A commit needs a clean review of that exact diff.', 'A destructive command is refused before it runs.', 'No key, token or AI-authorship trace reaches history.'],
    gateLink: 'Every hook and rule →',
    measuredHeading: 'Measured in the open.',
    measuredParas: ['The same prompt runs in a project with Crewforth and in a bare one, graded on what each left on disk. The rule a result must meet is written down before the run.', 'Every result is published with its reasoning, including the ones where the rule did not hold.'],
    measuredLink: 'Read the evals →',
    installHeading: 'Install your way',
    archive: 'No Node? Use the release archive →',
    update: 'When a new version is published, Claude asks once at the start of a session. It never updates on its own.',
    licence: 'Crewforth · MIT licence', changelog: 'Changelog',
  },
  tr: {
    title: { before: 'Claude Code için mühendislik ', accent: 'ekibiniz', after: '.' },
    lead: "Ajanlar, skill'ler, komutlar ve hook'lar: her yığında bir değişikliği planlayan, yazan, inceleyen ve teslim eden uzmanlar. Önemli kurallar ise kapılarla korunur.",
    docs: 'Belgeleri oku', star: "GitHub'da yıldız ver", copy: 'Kopyala', copied: 'Kopyalandı',
    play: 'Bir dakikalık tanıtımı oynat', sound: 'Ses', videoNote: 'Video İngilizce',
    videoDesc: 'Bir dakikalık tanıtım: sade Claude Code, kurulum, iş başındaki ekip, kapılar, Studio ve devir.',
    adopt: "Mevcut bir repo mu? `npx crewforth adopt` her şeyi ayrı bir dala koyar, `main`'e dokunmaz.",
    crewHeading: 'On iki uzman, tek düzen',
    crewLead: "Her isteğin bir sahibi var. Yönlendirme hook'u sahibini isteğinizin yanına yazar ve commit'ten önce kalite aşama aşama yükselir.",
    stages: ['Anla', 'Üret', 'Denetle', 'Kapat', 'Devret'],
    stageLines: ['İstek belirsizse kapsam ve kabul ölçütleri.', 'Değişikliğin kendisi, her yığında.', '`/crew-review` ile paralel çalışır.', 'Temiz bir inceleme, ardından sizi bekleyen bir commit.', 'Oturum doluluğu ve sonraki oturum için yazılan durum.'],
    skills: 'Arkalarındaki {N} skill →',
    gateHeading: 'Kural → kapı',
    gateLines: ['Commit her izin modunda onayınızı bekler.', "Commit, tam o diff'in temiz bir incelemesini ister.", 'Yıkıcı bir komut çalışmadan reddedilir.', 'Anahtar, token ya da AI izi geçmişe ulaşmaz.'],
    gateLink: "Tüm hook'lar ve kurallar →",
    measuredHeading: 'Açıkça ölçülür.',
    measuredParas: ['Aynı istem Crewforth kurulu bir projede ve boş bir projede çalıştırılır, her biri diskte bıraktığına göre puanlanır. Bir sonucun sağlaması gereken kural koşudan önce yazılır.', 'Tutmayanlar dahil her sonuç gerekçesiyle yayınlanır.'],
    measuredLink: 'Ölçümleri oku →',
    installHeading: 'İstediğiniz yoldan kurun',
    archive: 'Node yok mu? Sürüm arşivini kullanın →',
    update: 'Yeni sürüm çıkınca Claude oturum başında bir kez sorar. Kendiliğinden asla güncellemez.',
    licence: 'Crewforth · MIT lisansı', changelog: 'Değişiklik günlüğü',
  },
};

const prefix = (loc) => (loc === 'en' ? '' : `/${loc}`);
const yaml = (s) => JSON.stringify(String(s));

function descriptionOf(body) {
  for (const para of body.split(/\n\s*\n/)) {
    const p = para.trim();
    if (!p || /^[<|#`!>\-*\d]/.test(p) || p.startsWith('[')) continue;
    const plain = p.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1').replace(/[`*]/g, '').replace(/\s+/g, ' ').trim();
    if (plain.length <= 160) return plain;
    const cut = plain.slice(0, 157); return cut.slice(0, cut.lastIndexOf(' ')) + '…';
  }
  fail('no prose paragraph to describe the page');
}

// Rewrites the GitHub-relative paths the site/content pages carry (they are written to render on GitHub too).
function relink(text, loc, base) {
  return text
    .replace(/(\]\(|src=")\.\.\/\.\.\/\.\.\/assets\//g, '$1/assets/')
    .replace(/\]\(\.\.\/\.\.\/\.\.\/evals\/README\.md\)/g, `](${prefix(loc)}/measuring/)`)
    .replace(/\]\(\.\.\/\.\.\/\.\.\/([^)]+)\)/g, `](${REPO_URL}/blob/main/$1)`)
    .replace(/\]\((?!https?:|mailto:|#|\/)([^)]+)\)/g, (m, p) => `](${REPO_URL}/blob/main/${path.posix.join(base, p)})`);
}

function page(file, fm, body) {
  const head = Object.entries(fm).map(([k, v]) => (typeof v === 'object' ? `${k}:\n${Object.entries(v).map(([a, b]) => `  ${a}: ${yaml(b)}`).join('\n')}` : `${k}: ${typeof v === 'string' ? yaml(v) : v}`)).join('\n');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `---\n${head}\n---\n\n${body.trim()}\n`);
}

export function generate(root = ROOT, site = SITE) {
  const docs = path.join(site, 'src/content/docs');
  for (const d of [docs, path.join(site, 'src/assets'), path.join(site, 'public')]) fs.rmSync(d, { recursive: true, force: true });

  const ag = agents(root);
  const { skills, commands } = skillsAndCommands(root);
  const fill = fillThresholds(root);
  const rules = gateRules(root);
  const cost = alwaysOn(root);
  const stageOf = stages(root);
  checkNetworkSvgs(root, ag.length, skills.length);

  const tr = {
    agents: tsv(path.join(root, 'packaging/agent-summaries.tr.tsv')),
    commands: tsv(path.join(root, 'packaging/command-summaries.tr.tsv')),
    skills: tsv(path.join(root, 'packaging/skill-summaries.tr.tsv')),
    rules: tsv(path.join(root, 'packaging/gate-rules.tr.tsv')),
  };
  const missing = [
    ...ag.filter((a) => !tr.agents.has(a.name)).map((a) => `agent-summaries.tr.tsv: ${a.name}`),
    ...commands.filter((c) => !tr.commands.has(c.name)).map((c) => `command-summaries.tr.tsv: ${c.name}`),
    ...skills.filter((s) => !tr.skills.has(s.name)).map((s) => `skill-summaries.tr.tsv: ${s.name}`),
    ...rules.filter((r) => !tr.rules.has(r)).map((r) => `gate-rules.tr.tsv: ${r}`),
  ];
  if (missing.length) fail(`no Turkish line for ${missing.length} item(s) — add them, the site never falls back to English:\n  ${missing.join('\n  ')}`);

  const summary = (loc, kind, item) => (loc === 'en' ? item.summary : tr[kind].get(item.name));

  for (const loc of LOCALES) {
    const out = loc === 'en' ? docs : path.join(docs, loc);
    const u = UI[loc];

    // Documentation pages from site/content.
    for (const slug of CONTENT) {
      const src = path.join(root, 'site/content', loc, `${slug}.md`);
      if (!fs.existsSync(src)) fail(`site/content/${loc}/${slug}.md is missing — every page exists in every language`);
      let text = read(src);
      const h1 = text.match(/^# (.+)\n/);
      if (!h1) fail(`site/content/${loc}/${slug}.md has no H1 to take the title from`);
      text = text.slice(h1[0].length);
      text = text.replaceAll('{{FILL_WARN}}', String(fill.warn)).replaceAll('{{FILL_ALERT}}', String(fill.alert));
      for (const [k, v] of Object.entries(costFacts(loc, cost))) text = text.replaceAll(`{{${k}}}`, v);
      const counts = { AGENT_COUNT: ag.length, SKILL_COUNT: skills.length, COMMAND_COUNT: commands.length };
      for (const [k, v] of Object.entries(counts)) text = text.replaceAll(`{{${k}}}`, String(v));
      if (/\{\{[A-Z_]+\}\}/.test(text)) fail(`site/content/${loc}/${slug}.md: an unknown placeholder ${text.match(/\{\{[A-Z_]+\}\}/)[0]}`);
      if (slug === 'skills') {
        if (!text.includes('<!-- CATALOGUE -->')) fail(`site/content/${loc}/skills.md: the <!-- CATALOGUE --> marker is gone`);
        const rows = skills.map((s) => `| \`${s.name}\` | ${cell(summary(loc, 'skills', s))} |`).join('\n');
        text = text.replace('<!-- CATALOGUE -->', `| ${u.catalogue[0]} | ${u.catalogue[1]} |\n|:--|:--|\n${rows}`);
      }
      if (slug === 'gates') {
        const rows = rules.map((r) => `| ${cell(loc === 'en' ? r : tr.rules.get(r))} |`).join('\n');
        text += `\n\n## ${u.rules.heading.replace('{n}', rules.length)}\n\n${u.rules.lead}\n\n| ${u.rules.col} |\n|:--|\n${rows}\n`;
      }
      text = relink(text, loc, 'site/content/' + loc);
      page(path.join(out, `${slug}.md`), { title: h1[1].trim(), description: descriptionOf(text) }, text);
    }

    // Generated pages: agents and commands.
    const agentRows = ag.map((a) => `| \`${a.name}\` | ${cell(summary(loc, 'agents', a))} |`).join('\n');
    const agentLead = u.agents.lead.replace('{n}', ag.length);
    page(path.join(out, 'agents.md'), { title: u.agents.title, description: agentLead.replace(/`/g, '') },
      `${agentLead}\n\n| ${u.agents.col[0]} | ${u.agents.col[1]} |\n|:--|:--|\n${agentRows}`);
    const cmdRows = commands.map((c) => `| \`/${c.name}\` | ${cell(summary(loc, 'commands', c))} | ${c.userOnly ? u.commands.user : u.commands.both} |`).join('\n');
    const cmdLead = u.commands.lead.replace('{n}', commands.length);
    page(path.join(out, 'commands.md'), { title: u.commands.title, description: cmdLead.replace(/`/g, '') },
      `${cmdLead}\n\n| ${u.commands.col[0]} | ${u.commands.col[1]} | ${u.commands.col[2]} |\n|:--|:--|:--|\n${cmdRows}`);

    // The measuring page and the changelog, compiled from their one source each.
    for (const [slug, file, base] of [['measuring', 'evals/README.md', 'evals'], ['changelog', 'CHANGELOG.md', '']]) {
      let text = read(path.join(root, file)).replace(/^# .+\n/, '');
      text = relink(text, loc, base);
      page(path.join(out, `${slug}.md`), { title: u[slug].title, description: descriptionOf(text) }, u[slug].note + text);
    }

    // Home (design B, 5S.b2): the strings are the brief's; every list and number comes from the repository.
    const H = HOME[loc];
    const p = prefix(loc);
    const d = {
      mark: '/assets/mark.svg', title: H.title, lead: H.lead, command: 'npx crewforth init',
      copy: H.copy, copied: H.copied, docsLabel: H.docs, docsHref: `${p}/install/`, starLabel: H.star, starHref: REPO_URL, adopt: inline(H.adopt),
      video: { src: '/media/crewforth-hero.mp4', poster: '/media/crewforth-hero-poster.jpg', play: H.play, sound: H.sound, desc: H.videoDesc, note: H.videoNote ?? '' },
      crew: {
        heading: H.crewHeading, lead: H.crewLead,
        // The longest agent name sizes every chip so it fits its card; read here so a longer name resizes them too.
        chipChars: Math.max(...ag.map((a) => a.name.length)),
        stages: STAGES.map((s, i) => ({ label: H.stages[i], agents: ag.filter((a) => stageOf.get(a.name) === s).map((a) => a.name), line: inline(H.stageLines[i]) })),
        skills: { text: H.skills.replace('{N}', skills.length), href: `${p}/skills/` },
      },
      gate: { heading: H.gateHeading, lines: H.gateLines, link: { text: H.gateLink, href: `${p}/gates/` } },
      measured: { heading: H.measuredHeading, paras: H.measuredParas, link: { text: H.measuredLink, href: `${p}/measuring/` } },
      install: { heading: H.installHeading, cards: installRows(root, loc), archive: { text: H.archive, href: `${p}/install/` }, update: H.update },
      footer: { licence: H.licence, links: [{ text: H.changelog, href: `${p}/changelog/` }, { text: 'GitHub', href: REPO_URL }, { text: 'npm', href: 'https://www.npmjs.com/package/crewforth' }] },
    };
    const depth = loc === 'en' ? '../../' : '../../../';
    fs.writeFileSync(path.join(out, 'index.mdx'),
      `---\ntitle: ${yaml('Crewforth')}\ndescription: ${yaml(H.lead)}\ntemplate: splash\nprev: false\nnext: false\n` +
      `head:\n  - tag: title\n    content: ${yaml(`Crewforth — ${H.title.before}${H.title.accent}${H.title.after}`.replace(/\.$/, ''))}\n---\n\n` +
      `import Home from '${depth}components/Home.astro';\n\n<Home d={${JSON.stringify(d)}} />\n`);
  }

  // Static files: the repository's assets, the logo pair, the favicon, the social card, robots.txt.
  fs.cpSync(path.join(root, 'assets'), path.join(site, 'public/assets'), { recursive: true });
  // The home page's overview video and its poster: the site's own files, served from its own origin.
  fs.cpSync(path.join(site, 'media'), path.join(site, 'public/media'), { recursive: true });
  fs.mkdirSync(path.join(site, 'src/assets'), { recursive: true });
  for (const f of ['logo.svg', 'logo-light.svg']) fs.copyFileSync(path.join(root, 'assets', f), path.join(site, 'src/assets', f));
  fs.copyFileSync(path.join(root, 'assets/icon.svg'), path.join(site, 'public/favicon.svg'));
  fs.copyFileSync(path.join(root, 'assets/social-preview.png'), path.join(site, 'public/social-preview.png'));
  fs.writeFileSync(path.join(site, 'public/robots.txt'), 'User-agent: *\nAllow: /\n\nSitemap: https://crewforth.com/sitemap-index.xml\n');

  return { agents: ag.length, skills: skills.length, commands: commands.length, rules: rules.length, fill, cost };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const r = generate();
    console.log(`site: generated ${CONTENT.length + 5} pages × ${LOCALES.length} languages · ${r.agents} agents · ${r.skills} skills · ${r.commands} commands · ${r.rules} rules · fill ${r.fill.warn}/${r.fill.alert} · always-on ${r.cost.total} B (discipline ${r.cost.discipline}, agents ${r.cost.agents}, skills ${r.cost.skills})`);
  } catch (e) {
    if (e instanceof BuildError) { console.error(`site: ${e.message}`); process.exit(1); }
    throw e;
  }
}
