defmodule Samen.Web.Geo.TileSource do
  @moduledoc """
  The FAIL-HONEST "bring-your-tiles" seam for the G7 map view (T55) — where a HOST plugs in its
  OWN raster/vector tile provider for a street-level basemap. **OFF by default.** Unconfigured,
  the map falls back to the self-contained Natural Earth SVG (`Samen.Web.Geo.NaturalEarth`) and
  makes **zero external calls** — there is NO default, NO hardcoded tile URL, and NO CDN leak
  (CLAUDE.md).

  ## Fail-honest adapter contract (ADR-014/024/026)

  An UNCONFIGURED tile source returns `{:error, :not_configured}` — never a fake `{:ok, _}`,
  never a silent call to a third-party tile host. Enabling tiles is a deliberate **host
  opt-in** that introduces an external dependency (the host's own tile server) — the host's
  choice, made explicit in config, never a surprise:

      # config/runtime.exs — the HOST decides, and names ITS OWN url template:
      config :samen_web, Samen.Web.Geo.TileSource,
        url_template: "https://tiles.acme-internal.example/{z}/{x}/{y}.png",
        attribution: "© ACME internal tiles"

  With no such config, `resolve/1` returns `{:error, :not_configured}` and `Samen.UI.map/1`
  renders the SVG basemap plus an honest "street-level tiles are not configured" notice — it
  does not reach for any network resource.

  ## Why a template, not a client

  This seam resolves a URL TEMPLATE (a `{z}/{x}/{y}` string the browser expands as it pans);
  samen makes no server-side HTTP request to the tile host. The only entity that ever contacts
  the host's tile server is the END USER'S BROWSER, and only once the host has opted in.
  """

  @app :samen_web

  @typedoc "A resolved, host-configured tile source."
  @type config :: %{url_template: String.t(), attribution: String.t() | nil}

  @doc """
  Resolve the host's configured tile source.

    * `{:ok, %{url_template: ..., attribution: ...}}` — the host opted in with a `:url_template`.
    * `{:error, :not_configured}` — no host config (the DEFAULT): the caller MUST fall back to
      the self-contained SVG basemap and make no external call.

  `overrides` (keyword) is for tests/injection: an explicit `:url_template` takes precedence
  over app config; `config: nil` forces the unconfigured branch regardless of app env.
  """
  @spec resolve(keyword()) :: {:ok, config()} | {:error, :not_configured}
  def resolve(overrides \\ []) do
    cond do
      Keyword.has_key?(overrides, :config) ->
        normalize(Keyword.get(overrides, :config))

      Keyword.has_key?(overrides, :url_template) ->
        normalize(url_template: Keyword.fetch!(overrides, :url_template))

      true ->
        normalize(Application.get_env(@app, __MODULE__))
    end
  end

  @doc "True iff a host tile source is configured (the street-level mode is available)."
  @spec configured?(keyword()) :: boolean()
  def configured?(overrides \\ []) do
    match?({:ok, _}, resolve(overrides))
  end

  # A non-empty :url_template is the ONLY thing that turns tiles on. Anything else — nil, an
  # empty template, a non-list — is the honest unconfigured error, never a faked success.
  defp normalize(nil), do: {:error, :not_configured}

  defp normalize(cfg) when is_list(cfg) or is_map(cfg) do
    template = fetch(cfg, :url_template)

    if is_binary(template) and String.trim(template) != "" do
      {:ok, %{url_template: template, attribution: fetch(cfg, :attribution)}}
    else
      {:error, :not_configured}
    end
  end

  defp normalize(_), do: {:error, :not_configured}

  defp fetch(cfg, key) when is_list(cfg), do: Keyword.get(cfg, key)
  defp fetch(cfg, key) when is_map(cfg), do: Map.get(cfg, key)
end
