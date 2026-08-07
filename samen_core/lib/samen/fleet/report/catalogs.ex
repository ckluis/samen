defmodule Samen.Fleet.Report.Catalogs do
  @moduledoc """
  The HOST-declared closed member lists for `Samen.Fleet.Report.Schema`'s four
  catalog SENTINELS (`checks[].name`, `mrr_by_tier[].tier`, `oban[].queue`,
  `activity_counts[].event_kind` / the `activity` cohort's `event_kind`) —
  ADR-044 §5.2b's "closed member list" premise, phase6-punchlist P8.

  ## Why per-host, not per-schema

  The schema (samen_core, framework-owned) cannot name the real catalog: check
  names, oban queue names, plan tiers, and audit-taxonomy event kinds are
  PER-VERTICAL vocabularies (driftwood's queues are not pawchart's). T82 shipped
  a SHAPE-only stopgap (`^[a-z][a-z0-9_]{0,39}$`) precisely because the real
  member list "is declared at the vertical level" — this module is where a host
  declares it, and `Samen.Fleet.Report.Schema.validate/2` + `mix
  samen.verify.fleet_wire` are what CONSUME the declaration.

  ## The seam

      config :my_app, :fleet_wire_catalogs,
        closed_check_catalog: ~w(db_reachable redis_reachable queue_healthy),
        closed_plan_tier_catalog: ~w(free pro enterprise),
        closed_app_queue_catalog: ~w(mailers webhooks reports),
        closed_audit_taxonomy_catalog: ~w(login logout org_update billing_update)

  Plain data (no MFA — a catalog is a static, host-authored list, not a
  computed authorization decision), read via `Application.get_env/2`. Absent
  entirely, or an entry absent/empty for one sentinel, means that sentinel
  stays on the shape-only stopgap (`Schema.validate/2`'s documented fallback) —
  additive, never a silent tightening a host didn't opt into for THAT sentinel.
  """

  @doc "The four closed-catalog sentinel atoms `Samen.Fleet.Report.Schema` declares."
  @spec sentinels() :: [atom()]
  def sentinels,
    do: [
      :closed_check_catalog,
      :closed_plan_tier_catalog,
      :closed_app_queue_catalog,
      :closed_audit_taxonomy_catalog
    ]

  @doc """
  The `%{sentinel => [String.t()]}` catalogs `otp_app` has declared via
  `config :otp_app, :fleet_wire_catalogs, ...`. Fail-CLOSED to `%{}` (never a
  crash, never a fabricated catalog) for a missing config, a non-keyword/map
  value, or a per-sentinel value that is not a list of strings (that one
  sentinel's entry is dropped, others kept — one malformed entry does not
  disable every catalog's membership check).
  """
  @spec for_host(atom()) :: %{atom() => [String.t()]}
  def for_host(otp_app) when is_atom(otp_app) do
    Application.get_env(otp_app, :fleet_wire_catalogs, [])
    |> normalize()
  end

  def for_host(_), do: %{}

  defp normalize(raw) when is_list(raw) or is_map(raw) do
    raw
    |> Enum.into(%{})
    |> Enum.filter(fn {k, v} -> k in sentinels() and is_list(v) and Enum.all?(v, &is_binary/1) end)
    |> Map.new()
  end

  defp normalize(_), do: %{}
end
