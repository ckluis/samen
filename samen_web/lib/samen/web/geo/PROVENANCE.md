# Vendored base-map data — provenance & license (T55 / G7)

## Source

**Natural Earth** — https://www.naturalearthdata.com — 1:110m physical **land** layer
(`ne_110m_land`), the small-scale continental land outline.

## License

**Public domain.** Natural Earth's terms (naturalearthdata.com/about/terms-of-use):

> "Natural Earth is free for use in any type of project ... No permission is needed to use
> Natural Earth. Crediting the authors is unnecessary."

There are **no restrictions** on use, redistribution, or modification. It is one of the few
truly public-domain global vector datasets, which is exactly why it was chosen (ADR-037 §5.10 /
M4: server-side SVG basemap, no PostGIS, no CDN).

## Version

Natural Earth **v5.1.1** (the 1:110m physical land release line) is the reference version this
schematic is derived from.

## What is actually vendored here (honest note)

The file `natural_earth.ex` does **not** embed the verbatim Natural Earth vertex set. It embeds
a **hand-simplified, low-vertex continental schematic** authored in the equirectangular frame
`Samen.Web.Geo.Projection` uses — continent-level rings of tens of vertices each. This is a
deliberate repo-weight choice (M4: "do not vendor a giant multi-MB dataset if a simplified one
suffices"): the shipped asset is a few KB of Elixir data, renders fully offline, and gives a
legible world basemap behind projected pins.

It is **derived from / in the style of** the public-domain Natural Earth 110m land layer, not a
faithful reproduction of it. A vertical that needs country/coastline fidelity vendors a fuller
public-domain Natural Earth ring set behind the SAME `Samen.Web.Geo.NaturalEarth.regions/0` API
(the projection + renderer are unchanged).

## Repo weight

`lib/samen/web/geo/natural_earth.ex` — a single Elixir source file, a few KB (see the T55
summary for the exact byte count recorded at ship). No binary blob, no `priv/` data asset, no
runtime download.
