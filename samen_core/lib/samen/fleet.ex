defmodule Samen.Fleet do
  @moduledoc """
  The fleet facade (ADR-044 §2/§3.2, WS-J J1+J5) — `mode/1` (config-driven, defaults
  `:embedded` with ZERO configuration) and `read/2` (the ONE read surface a cockpit
  LiveView calls; per §8.3 it never knows which transport produced a row).

      # router.ex — reporting side (every product, including cockpits)
      samen_fleet_routes()

      # config.exs — mode. Omit entirely for the zero-config :embedded default.
      config :my_app, :fleet, mode: :heartbeat   # + SAMEN_FLEET_ENROLL_TOKEN, SAMEN_FLEET_COCKPIT_URL

  `read/2`'s non-embedded branches (`:manual`/`:heartbeat`) return the registry rows
  for a mounted cockpit `namespace` (a `Samen.Fleet.Scope`-mounted Ash domain) —
  the DATA layer T84's cockpit LiveView renders. `:embedded` never touches a
  namespace/database at all (§8.1).
  """

  alias Samen.Fleet.Registry

  @doc """
  The configured fleet mode for `otp_app`. Defaults to `:embedded` — the
  zero-configuration floor (§8.1/§9.2: "Omit entirely for the zero-config
  `:embedded` default").
  """
  @spec mode(atom()) :: :embedded | :manual | :heartbeat
  def mode(otp_app) when is_atom(otp_app) do
    Application.get_env(otp_app, :fleet, []) |> Keyword.get(:mode, :embedded)
  end

  @doc """
  Read the fleet as this host sees it. `:embedded` ⇒ the single honest self-row,
  zero DB/network. `:manual`/`:heartbeat` ⇒ the registry rows for the cockpit
  `namespace` given via `opts[:namespace]` (required in those modes) — staleness
  computed cockpit-side (§4.6/§8.2 rule 3), n-of-m disclosure included.

  Returns `{:ok, %{rows: [row], reporting: n, total: m}}` or `{:error, reason}`.
  A row is a plain map: `%{app_id:, slug:, display_name:, mode:, status:, transport:,
  received_at:, stale_after_s:, report:}` — `status` is one of `:active |
  :stale | :unreachable | :revoked | :deregistered`; `report` is the last
  `%Samen.Fleet.Report{}` (or `nil` when never reported, e.g. a freshly-enrolled app).
  """
  @spec read(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(otp_app, opts \\ []) when is_atom(otp_app) do
    case mode(otp_app) do
      :embedded ->
        # Fix round (LOW, §8.3 "no n==1 branch"): reporting/total are DERIVED
        # from the row list (length/1), not hardcoded literals — the same
        # arithmetic Registry.read_rows/2 uses, so :embedded's n=1 case is
        # never a special-cased number, just what `length/1` happens to
        # return for a one-element list.
        {:ok, rows} = Samen.Fleet.Transport.Embedded.rows(otp_app, opts)
        reporting = Enum.count(rows, &(&1.status == :active))
        {:ok, %{rows: rows, reporting: reporting, total: length(rows)}}

      mode when mode in [:manual, :heartbeat] ->
        case Keyword.fetch(opts, :namespace) do
          {:ok, namespace} -> Registry.read_rows(namespace, opts)
          :error -> {:error, {:missing_namespace, mode}}
        end

      other ->
        {:error, {:invalid_mode, other}}
    end
  end
end
