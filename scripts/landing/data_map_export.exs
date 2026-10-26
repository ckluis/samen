# Landing-page data-map exporter (issue #97) — renders ONE real ERD through the real
# component, so the page shows exactly what `/operator/data-map/:domain` draws.
#
#   cd driftwood && MIX_ENV=test mix run --no-start ../scripts/landing/data_map_export.exs
#
# Writes site/landing/data-map-crm.frag.html; `python3 site/landing/build.py` inlines it as
# {{DATA_MAP_ERD}}. Metadata only: the map reads compile-time catalog metadata, never a row.
out = Path.expand("../site/landing/data-map-crm.frag.html", File.cwd!())

svg =
  Samen.UI.DataMap.erd(%{
    map: Samen.DataMap.build(),
    domain: "crm",
    base_path: "/operator/data-map",
    id: "lp-erd",
    __changed__: nil
  })
  |> Phoenix.HTML.Safe.to_iodata()
  |> IO.iodata_to_binary()
  |> String.replace(~r/\n\s*\n/, "\n")

File.write!(out, svg)
IO.puts("data_map_export: wrote #{out} (#{byte_size(svg)} bytes)")
