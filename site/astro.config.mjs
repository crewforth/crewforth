// crewforth.com — Astro + Starlight. Every page is generated from the repository by scripts/generate.mjs before the
// build (see there); this file only wires the site. No request leaves for a third party: fonts are bundled, search
// is Pagefind (static), and the analytics beacon is added only when CF_BEACON_TOKEN is set (5b sets it).
import { defineConfig, passthroughImageService } from 'astro/config';
import starlight from '@astrojs/starlight';
import fs from 'node:fs';

const beacon = process.env.CF_BEACON_TOKEN;
const t = (en, tr) => ({ label: en, translations: { tr } });

export default defineConfig({
  site: 'https://crewforth.com',
  image: { service: passthroughImageService() },
  integrations: [
    starlight({
      title: 'Crewforth',
      description: 'Crewforth is your engineering crew for Claude Code: subagents, skills, slash commands and hooks.',
      logo: { dark: './src/assets/logo.svg', light: './src/assets/logo-light.svg', replacesTitle: true },
      favicon: '/favicon.svg',
      defaultLocale: 'root',
      locales: {
        root: { label: 'English', lang: 'en' },
        tr: { label: 'Türkçe', lang: 'tr' },
      },
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/Crewforth/crewforth' }],
      // The home page draws its own heading; see src/components/PageTitle.astro.
      // and every page's logo carries the release it describes; see src/components/SiteTitle.astro.
      components: { PageTitle: './src/components/PageTitle.astro', SiteTitle: './src/components/SiteTitle.astro' },
      customCss: [
        '@fontsource/inter/400.css',
        '@fontsource/inter/600.css',
        '@fontsource/inter/700.css',
        '@fontsource/inter/800.css',
        './src/styles/theme.css',
      ],
      head: [
        { tag: 'meta', attrs: { property: 'og:image', content: 'https://crewforth.com/social-preview.png' } },
        { tag: 'meta', attrs: { name: 'twitter:card', content: 'summary_large_image' } },
        // A picture in a page opens at its full size when pressed (src/scripts/zoom.js). Inline, first-party, and
        // run once the page is parsed.
        { tag: 'script', attrs: { type: 'module' }, content: fs.readFileSync(new URL('./src/scripts/zoom.js', import.meta.url), 'utf8') },
        ...(beacon
          ? [{ tag: 'script', attrs: { defer: true, src: 'https://static.cloudflareinsights.com/beacon.min.js', 'data-cf-beacon': JSON.stringify({ token: beacon }) } }]
          : []),
      ],
      sidebar: [
        { ...t('Start here', 'Başlangıç'), items: [{ slug: 'install' }] },
        { ...t('The crew', 'Ekip'), items: [{ slug: 'agents' }, { slug: 'commands' }, { slug: 'skills' }] },
        { ...t('How it holds', 'Nasıl işler'), items: [{ slug: 'gates' }, { slug: 'studio' }, { slug: 'sessions-and-cost' }] },
        { ...t('Proof', 'Kanıt'), items: [{ slug: 'verification' }, { slug: 'measuring' }] },
        { ...t('Reference', 'Başvuru'), items: [{ slug: 'extending' }, { slug: 'changelog' }] },
      ],
    }),
  ],
});
