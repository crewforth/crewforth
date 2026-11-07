# Detection: patterns to grep for, lever by lever

Loaded from `frontend-design` before handing UI back. Each row is a pattern you can search the diff for, and the
fix. Stack-neutral: the CSS names stand for whatever the project's styling layer compiles to. A hit is a question
to answer, not an automatic finding: say why it stays when it does.

## Layout
| Pattern | Fix |
|---|---|
| a grid track `1fr`, or a flex child holding text, with no `min-width: 0` | `minmax(0, 1fr)` / `min-width: 0`, so long content cannot push the track wider |
| `width: 100vw` | `100%`: `vw` includes the scrollbar and causes a horizontal scroll |
| `height: 100vh` on a full-screen view | `100dvh` (with `100vh` before it as the fallback): mobile toolbars change the visible height |
| a fixed `height` on a box that holds text | `min-height`, so translated or zoomed text can grow |
| `@media` width queries inside a reusable component | `@container`: the component does not know the page's width |
| `env(safe-area-inset-*)` with no `viewport-fit=cover` in the viewport meta | add it, or the insets read as 0 |
| a sticky header and in-page anchors with no `scroll-padding-top` | set it to the header's height |

## Type
| Pattern | Fix |
|---|---|
| `line-height` with a unit (`24px`) | unitless (`1.5`), so it scales with the font size |
| numbers in tables, prices or timers in a proportional face | `font-variant-numeric: tabular-nums` |
| a weight under 400 on text under 18 px | 400 or more: thin weights break up at small sizes |
| an input with a font size under 16 px | 16 px on mobile, or iOS zooms the page when it gets focus |
| `text-wrap: balance` on paragraphs | headings only; `pretty` for paragraphs |
| `-webkit-line-clamp` without `display: -webkit-box` and `-webkit-box-orient: vertical` | add both, or the clamp does nothing |
| user-supplied names inserted into a sentence in a mixed-direction UI | wrap them in `<bdi>` |

## Color
| Pattern | Fix |
|---|---|
| a primitive token (`blue-500`) used in a component | a semantic token (`--color-action`), so a theme is one swap |
| a hue in a semantic name (`--color-blue-button`) | name the role, not the colour |
| text with alpha (`rgba(…, .6)`, `opacity`) | measure the contrast of the pair as rendered over its real background |
| a wide-gamut colour (`oklch`, `display-p3`) with no sRGB value before it | put the sRGB fallback first |

## Motion
| Pattern | Fix |
|---|---|
| `transition: all` | name the properties: `transform`, `opacity` |
| `@keyframes` driven by a toggled class for a state change | a `transition`: keyframes restart instead of reversing when interrupted |
| `:hover` styles outside `@media (hover: hover)` | gate them, or they stick after a tap on touch screens |
| a scrolling dialog or sheet with no `overscroll-behavior: contain` | add it, or the page behind scrolls too |
| a focus or selection ring drawn only with `box-shadow` | add a transparent `outline` or border: forced-colours mode removes shadows |
