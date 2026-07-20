defmodule Samen.UI.Helpers do
  @moduledoc """
  Plain helpers + small presentational bits of the `Samen.UI` kit that don't fit a
  component family: `stylesheet_path/0` (the on-disk CSS path), the command-palette
  string helpers `humanize_resource/1` / `palette_label/1`, and the `social_links/1`
  component (+ its `social_networks/0`). Split out of the `Samen.UI` god-module
  (behaviour-identical). `Samen.UI` re-exports each via `defdelegate`, so the facade
  calls `Samen.UI.humanize_resource/1` / `Samen.UI.palette_label/1` (used by
  `Samen.UI.Overlay.command_palette/1`) stay resolvable.
  """
  use Phoenix.Component

  @doc """
  The on-disk directory of the `samen_ui.css` asset inside THIS dependency. A host that
  needs the path directly (e.g. a bespoke static plug) can call this; the recommended
  form is the `{:samen_web, "priv/static/assets"}` tuple documented in the moduledoc.
  """
  def stylesheet_path do
    Path.join([:code.priv_dir(:samen_web), "static", "assets", "samen_ui.css"])
  end

  @doc false
  # The last module segment of a result's resource name ("Driftwood.Primitives.File" → "File").
  def humanize_resource(name) when is_binary(name), do: name |> String.split(".") |> List.last()
  def humanize_resource(name), do: to_string(name)

  @doc false
  # Join the bounded NON-PII display values (already masked-safe) for a palette row.
  def palette_label(display) when is_map(display) do
    display
    |> Map.values()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  def palette_label(_), do: ""

  # ---------------------------------------------------------------------------
  # Social links (ADR-011 §9) — Tier-1 custom-field convention, non-PII
  # ---------------------------------------------------------------------------

  @doc """
  Social handles as icon-links (ADR-011 §9). `custom` is the person's Tier-1 bag;
  the recognized flat keys are `social_linkedin`, `social_twitter`, `social_github`
  (each a URL/handle STRING — the kernel custom bag has no `:map` type, so social
  handles are flat string fields, not a nested map). Unknown/blank keys render
  nothing. Non-PII business-directory data (a public profile URL) — rendered on both
  planes. Purely presentational; reads the bag it is handed, writes nothing.
  """
  attr :custom, :any, default: nil

  def social_links(assigns) do
    assigns = assign(assigns, :links, social_entries(assigns.custom))

    ~H"""
    <span :if={@links != []} class="social-links" style="display:inline-flex;align-items:center;gap:8px">
      <a
        :for={{network, url} <- @links}
        href={url}
        target="_blank"
        rel="noopener noreferrer"
        class={"social-#{network}"}
        title={social_label(network)}
        style="display:inline-flex;color:var(--muted)"
      >
        {social_glyph(network)}
      </a>
    </span>
    """
  end

  @doc "The recognized social networks (bag key `social_<network>`)."
  def social_networks, do: ~w(linkedin twitter github)

  defp social_entries(custom) when is_map(custom) do
    for network <- social_networks(),
        url = social_url(Map.get(custom, "social_#{network}")),
        url != nil,
        do: {network, url}
  end

  defp social_entries(_), do: []

  defp social_url(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp social_url(_), do: nil

  defp social_label("linkedin"), do: "LinkedIn"
  defp social_label("twitter"), do: "Twitter / X"
  defp social_label("github"), do: "GitHub"
  defp social_label(other), do: other

  defp social_glyph("linkedin") do
    Phoenix.HTML.raw(
      ~s(<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M8 11v5M8 8v.01M12 16v-3a2 2 0 0 1 4 0v3M12 16v-5"/></svg>)
    )
  end

  defp social_glyph("twitter") do
    Phoenix.HTML.raw(
      ~s(<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 4l16 16M20 4 4 20"/></svg>)
    )
  end

  defp social_glyph("github") do
    Phoenix.HTML.raw(
      ~s(<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M9 19c-5 1.5-5-2.5-7-3m14 6v-3.9a3.4 3.4 0 0 0-1-2.6c3-.3 6-1.5 6-6.6a5.1 5.1 0 0 0-1.4-3.5 4.8 4.8 0 0 0-.1-3.5s-1.1-.3-3.5 1.3a12 12 0 0 0-6 0C6.6 1.6 5.5 1.9 5.5 1.9a4.8 4.8 0 0 0-.1 3.5A5.1 5.1 0 0 0 4 8.9c0 5.1 3 6.3 6 6.6a3.4 3.4 0 0 0-1 2.6V22"/></svg>)
    )
  end

  defp social_glyph(_), do: Phoenix.HTML.raw("")
end
