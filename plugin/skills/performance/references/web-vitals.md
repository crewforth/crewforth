# Core Web Vitals

Loaded from `performance` when the work is a web page's loading or responsiveness. checked: 2026-11-07 against
web.dev's published thresholds; re-check when this date is more than 90 days old.

## Thresholds (good, at the 75th percentile of real visits)
| Metric | Measures | Good | Poor |
|---|---|---|---|
| LCP, Largest Contentful Paint | when the main content has loaded | ≤ 2.5 s | > 4.0 s |
| INP, Interaction to Next Paint | how fast the page answers a tap, click or key | ≤ 200 ms | > 500 ms |
| CLS, Cumulative Layout Shift | how much the page jumps while it loads | ≤ 0.1 | > 0.25 |

INP replaced FID in March 2024; a report that still names FID is out of date.

## Field data and lab data
- **Field data** (real users: the Chrome UX Report, the site's own RUM) is what the thresholds are judged on, at the
  75th percentile, split by mobile and desktop.
- **Lab data** (Lighthouse, a local trace) is one run on one machine. Use it to find the cause and to check a fix,
  never as the verdict. A green Lighthouse score with poor field data is still a poor page.
- Report which one a number is, and say "not measured" when there is no field data.

## Where LCP time goes
LCP splits into four parts; fix the largest:
1. **Time to first byte**: server and network. Cache, a CDN, less work before the response.
2. **Resource load delay**: the browser found the LCP image late. Put it in the HTML (not set by script), `fetchpriority="high"`, no `loading="lazy"` on it.
3. **Resource load time**: the image itself. Right size, a modern format, compressed.
4. **Render delay**: blocking CSS or script, or a client-rendered page that paints late.

## Common causes
- **INP**: long tasks on the main thread during an interaction. Break the work up, yield to the browser, move it off the main thread, and do less in the handler.
- **CLS**: media without `width`/`height` or `aspect-ratio`, late-loading fonts that change metrics (`font-display` and size-adjusted fallbacks), content inserted above what the user is reading.
