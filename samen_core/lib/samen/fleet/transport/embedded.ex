defmodule Samen.Fleet.Transport.Embedded do
  @moduledoc """
  `:embedded` — the zero-config, single-self-registered-row default (ADR-044 §8.1,
  J5). No credential, no secret, no HTTP call, no network dependency, and — per this
  module — **no database dependency either**: the registry is a synthesized single
  row derived from the host's own compile-time identity (OTP application name,
  release metadata), built fresh on every call via `Samen.Fleet.Report.build/1`.

  This is what makes the zero-config claim literal: `Samen.Fleet.read/2` in
  `:embedded` mode never touches Postgres, never reads an env var, and cannot fail
  for a configuration reason — there is nothing to misconfigure.
  """
  @behaviour Samen.Fleet.Transport

  alias Samen.Fleet.Report

  @impl true
  def rows(host, opts \\ []) when is_atom(host) do
    {:ok, [row(host, opts)]}
  end

  @doc """
  The single honest self-row for `host` in `:embedded` mode — §8.1's "exactly one
  row: this app, derived from its own compile-time identity". `display_name`
  defaults to the OTP application name (a compile-time atom, never runtime
  producer-chosen text, §5.2/§8.1); an operator may override it later once a real
  cockpit exists (T84).
  """
  @spec row(atom(), keyword()) :: map()
  def row(host, opts \\ []) when is_atom(host) do
    app_id = Keyword.get(opts, :app_id, self_app_id(host))
    slug = Keyword.get(opts, :slug, Atom.to_string(host))
    display_name = Keyword.get(opts, :display_name, slug)

    report =
      Report.build(
        app_id: app_id,
        env: Keyword.get(opts, :env, :dev),
        release_channel: Keyword.get(opts, :release_channel, :dev)
      )

    %{
      app_id: app_id,
      slug: slug,
      display_name: display_name,
      mode: :embedded,
      status: :active,
      transport: :embedded,
      received_at: DateTime.utc_now(),
      stale_after_s: nil,
      report: report
    }
  end

  # A stable, deterministic (per-host, per-boot) synthetic app_id — see
  # `Samen.Fleet.Report.synthetic_app_id/1`.
  defp self_app_id(host), do: Report.synthetic_app_id("embedded:" <> Atom.to_string(host))
end
