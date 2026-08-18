# Vendored webfonts — provenance & license (T131)

These are the self-hosted typefaces for the Samen UI kit. They exist to make
`samen_ui.css` render its approved typography (Inter for text, JetBrains Mono for
tabular/monospace values) with **ZERO external network fetch** — no Google Fonts,
no CDN, works fully offline / air-gapped. This replaced a former
`@import` of the Google Fonts stylesheet (`samen_ui.css:22`, flagged by the T55 map
verifier) that fetched from an external host on **every** page load — leaking each
user's IP to a third party, breaking air-gapped self-hosting, and violating this
codebase's no-external-CDN invariant.

## Files

| File | Family | Subset | Axis | Raw size |
|------|--------|--------|------|----------|
| `Inter-latin.var.woff2` | Inter | Latin (`U+0000–00FF`, punctuation, symbols) | variable `wght 100–900` | 48,432 B |
| `JetBrainsMono-latin.var.woff2` | JetBrains Mono | Latin | variable `wght 100–800` | 31,340 B |

A **single variable file per family** covers every weight the stylesheet uses
(Inter 400/450/500/550/600/650/700; JetBrains Mono 400/500) exactly — more accurate
than the former static `@import`, which snapped the off-grid 550/650 to the nearest
loaded static instance.

## How these are served (important)

The stylesheet does **not** `<link>` or `url()` these files as separate static assets.
Their bytes are **base64-embedded as `data:` URIs inside the `@font-face` rules** in
`samen_ui.css` (see the "Self-hosted webfonts (T131)" block near the top of that file).
Rationale: the CSS is already served to every host and generated app via one
`Plug.Static` route (`only: ~w(samen_ui.css …)`); inlining lets the typeface travel
with the CSS, so **no host or generated app needs any additional static-asset config**
to get correct, air-gapped fonts. The `.woff2` files here are the **source-of-record**
for that inlined base64 (kept in-repo for license compliance and regeneration); they
are intentionally not wired into any host's `Plug.Static` `only:` list.

## Provenance

Fetched from Google Fonts' `css2` API Latin subset (the smallest hinted, production
woff2 build):

    https://fonts.googleapis.com/css2?family=Inter:wght@400;450;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap

(requested with a modern-browser User-Agent so the API returns woff2; the `latin`
`unicode-range` block of each family is a single variable woff2 — verified byte-identical
across all requested weights via md5, confirming one variable file per family).

## License

Both families are licensed under the **SIL Open Font License, Version 1.1** (OFL-1.1),
which explicitly permits bundling, embedding, and redistribution (including as a `data:`
URI inside a stylesheet) provided the license accompanies the fonts. Full texts:

- Inter — `Inter-OFL.txt` — © 2016 The Inter Project Authors (https://github.com/rsms/inter)
- JetBrains Mono — `JetBrainsMono-OFL.txt` — © 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)

## Regeneration

To refresh: re-download the `latin` variable woff2 for each family, drop them in as
`Inter-latin.var.woff2` / `JetBrainsMono-latin.var.woff2`, then re-run the base64 inline
step that rebuilds the `@font-face` block in `samen_ui.css`. The no-CDN guard test
(`test/samen/web/no_external_cdn_test.exs`) asserts the result stays external-host-free.
