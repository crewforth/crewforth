# Worst realistic data

Loaded from `frontend` (the four states) and `verify-contract.md` (probe fixtures). A screen that only works with
the demo data is not done. `crew-test-expert` may reuse this list for probe fixtures.

## 1. List what the screen shows
For each field on the screen, one row: the field, where it comes from, the limit the schema puts on it, and whether
it can be missing. A user-supplied field with no limit is a finding on its own: "unbounded" is not a size the
layout can be designed for.

## 2. Feed it the worst realistic values
- a very long name, and one with no break points (`Wolfeschlegelsteinhausenbergerdorff`, a 60-character email)
- a one-letter name, and an empty optional field
- emoji, combining characters, a script with no spaces (Thai, Japanese), right-to-left text (Arabic, Hebrew)
- 0, 1 and 1,000 items; a list that grows while it is shown
- extreme numbers: 0, negative, 9,999,999.99, many decimals, a different locale's separators
- a missing image, a slow image, a broken image URL
- dates at the edges: today, far in the past, far in the future, another time zone

## 3. At these widths and settings
320 px, the widest supported layout, 200% zoom, dark mode, right-to-left, and the narrowest container the
component is placed in.

## 4. Failure → cause → fix
| What you see | Usual cause | Fix |
|---|---|---|
| an icon or avatar squeezed by long text | flex item allowed to shrink | `flex-shrink: 0` on the fixed item |
| text pushes the layout wider than the screen | flex or grid child with an automatic minimum | `min-width: 0`, `minmax(0, 1fr)` |
| an unbroken word or URL overflows | no wrapping opportunity | `overflow-wrap: anywhere` (or `break-word`) |
| a name cut in the middle of a character or emoji | cutting by code unit | cut by grapheme (`Intl.Segmenter`) |
| "1 items", wrong plural in Russian or Arabic | hand-written plural | `Intl.PluralRules` / the i18n library's plural |
| numbers jump width as they change | proportional digits | `font-variant-numeric: tabular-nums` |
| `1000000` or `1,000.5` in the wrong locale | numbers formatted by hand | `Intl.NumberFormat` with the user's locale |
| a broken image icon | no fallback | `onError` to an initials avatar or placeholder |
| a file name loses its extension when cut | truncating the end | truncate the middle, keep the extension |
