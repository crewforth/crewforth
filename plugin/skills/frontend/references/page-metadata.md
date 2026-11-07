# Page metadata

Loaded from `frontend` when a page will be found by search engines or shared as a link. A checklist; the values come
from the project's content, never placeholders.

- [ ] **Title**: unique per page, the page's subject first, about 50–60 characters.
- [ ] **Meta description**: unique, says what the page offers, about 150–160 characters.
- [ ] **Canonical**: `<link rel="canonical">` with the absolute URL of the version that should rank; filtered,
  sorted and tracking-parameter URLs point to it.
- [ ] **Open Graph and social cards**: `og:title`, `og:description`, `og:image` (an absolute URL, about 1200×630),
  `og:url`, `og:type`; `twitter:card` when the project uses it.
- [ ] **Language**: `<html lang>`; `hreflang` alternates when the page exists in several languages.
- [ ] **Robots**: no `noindex` left over from staging on a page meant to be found; staging itself is not indexed.
- [ ] **Sitemap**: the page is in `sitemap.xml` with its canonical URL; `robots.txt` names the sitemap.
- [ ] **Structured data**: JSON-LD that parses, uses a schema.org type that fits the page, matches what the page
  shows, and holds no placeholder values (`"name": "Product name"`, `"price": "0"`).
- [ ] **No duplicates**: two pages never share a title, description or canonical.
