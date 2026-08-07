defmodule Mix.Tasks.Samen.Verify.FleetWire do
  @shortdoc "Verify the FleetReport wire's type discipline, route surface, and closed-catalog membership (ADR-044 J2/T84b)."

  @moduledoc """
  `mix samen.verify.fleet_wire` — the ADR-044 §5.2 point-4 build gate, beside
  `samen.verify.aggregate_privacy` / `samen.verify.no_pii_columns`. Three checks:

  ## 1. RP-J-4 — the wire cannot carry PII (schema class discipline)

  Every field `Samen.Fleet.Report.Schema` declares must be one of
  `Samen.WideEvent.Schema.bounded_types/0` (`:opaque_id | :token | :enum |
  :number`) — never `:string`/`:binary`/`:text`/`:atom`/`:map`/`:any`/`:term`/
  `:list`. Delegates to `Schema.class_discipline_violations/0` (the direct,
  per-forbidden-type-atom assertion) and asserts the schema's permitted class
  set is a SUBSET of the inherited discipline (never widened).

  ## 2. RP-J-4b — the route surface is closed (optional, needs a router)

  With `--router MyAppWeb.Router`, cross-checks the compiled router's `/fleet/*`
  + `/operator/fleet*` routes against `Samen.Fleet.RouteTable.declared/0` (the
  ADR §4.4a table) in BOTH directions: a route present in the router but absent
  from the table (an undeclared read endpoint smuggled in), or vice versa (the
  table promises a route nothing mounts), fails the build. Skipped (not a
  violation) when `--router` is omitted — samen_core itself has no Phoenix
  router; a host adopting the fleet wire passes its own.

  ## 3. P8 (phase6-punchlist) — closed-catalog MEMBERSHIP, not just shape

  T82 shipped a SHAPE-only stopgap for the four catalog sentinels
  (`checks[].name`, `mrr_by_tier[].tier`, `oban[].queue`,
  `activity_counts[].event_kind`) — `^[a-z][a-z0-9_]{0,39}$` rejects any PII
  shape but admits any out-of-vocabulary label. This check reads the CURRENT
  host's declared catalogs (`Samen.Fleet.Report.Catalogs.for_host/1`,
  `config :my_app, :fleet_wire_catalogs, ...`) and:

    * fails if a host DECLARES a sentinel with an EMPTY (or malformed) list —
      a catalog that claims to be closed but admits nothing/anything is worse
      than not declaring one;
    * for every NON-EMPTY declared catalog, runs a LIVE smoke-check: builds a
      minimal valid `FleetReport` payload carrying a shape-valid label that is
      NOT a member of the declared catalog, and asserts
      `Samen.Fleet.Report.Schema.validate/2` REJECTS it — proving membership
      enforcement is actually wired, not merely declared.

  A host that has not adopted `:fleet_wire_catalogs` at all is NOT a violation
  (cohort/catalog data is opt-in, §5.3) — the shape-only stopgap stands for
  that host, exactly as before this task existed.

  ## Usage

      mix samen.verify.fleet_wire
      mix samen.verify.fleet_wire --host driftwood
      mix samen.verify.fleet_wire --host samen_web --router Samen.WebTest.Router

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `Samen.Verifier`).
  """
  use Mix.Task

  alias Samen.Fleet.Report.{Catalogs, Schema}

  @task_name "samen.verify.fleet_wire"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} = OptionParser.parse(args, strict: [host: :string, router: :string])

    host = host_from(opts)
    router = router_from(opts)

    Samen.Verifier.halt_if_violations(@task_name, violations(host: host, router: router))
  end

  @doc """
  The full violation list, separated from `run/1` so tests can call it without
  halting. `opts`: `:host` (otp_app atom, default `Mix.Project.config()[:app]`),
  `:router` (a compiled Phoenix router module, optional).
  """
  def violations(opts \\ []) do
    host = Keyword.get(opts, :host) || Mix.Project.config()[:app]
    router = Keyword.get(opts, :router)

    class_discipline_violations() ++
      subset_violations() ++
      catalog_violations(host) ++
      route_violations(router)
  end

  # ---------------------------------------------------------------------------
  # RP-J-4 — class discipline
  # ---------------------------------------------------------------------------

  defp class_discipline_violations, do: Schema.class_discipline_violations()

  defp subset_violations do
    schema_types = MapSet.new(Schema.bounded_types())
    inherited = MapSet.new(Samen.WideEvent.Schema.bounded_types())

    if MapSet.subset?(schema_types, inherited) do
      []
    else
      widened = MapSet.difference(schema_types, inherited)

      [
        "Samen.Fleet.Report.Schema.bounded_types/0 #{inspect(MapSet.to_list(widened))} is NOT " <>
          "a subset of Samen.WideEvent.Schema.bounded_types/0 #{inspect(MapSet.to_list(inherited))} — " <>
          "the fleet wire has WIDENED the inherited type discipline (the exact class of mistake " <>
          "the first ADR-044 draft made with :semver/:slug)."
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # P8 — closed-catalog membership
  # ---------------------------------------------------------------------------

  defp catalog_violations(host) do
    declared_raw = Application.get_env(host, :fleet_wire_catalogs, [])
    catalogs = Catalogs.for_host(host)

    declared_keys =
      case declared_raw do
        raw when is_list(raw) or is_map(raw) -> raw |> Enum.into(%{}) |> Map.keys()
        _ -> []
      end

    empty_or_malformed =
      for sentinel <- declared_keys, sentinel in Catalogs.sentinels(), Map.get(catalogs, sentinel, []) == [] do
        "#{inspect(host)} declares #{inspect(sentinel)} in :fleet_wire_catalogs but the list is " <>
          "empty or malformed (every entry must be a non-empty list of strings) — a catalog that " <>
          "claims to be closed but admits nothing is worse than not declaring one at all."
      end

    smoke_check_violations =
      catalogs
      |> Enum.filter(fn {_sentinel, members} -> members != [] end)
      |> Enum.flat_map(fn {sentinel, members} -> smoke_check(sentinel, members, catalogs) end)

    empty_or_malformed ++ smoke_check_violations
  end

  # Build a minimal valid FleetReport payload carrying ONE shape-valid, catalog-
  # SHAPED label for `sentinel` that is deliberately NOT a member of `members`,
  # and assert Schema.validate/2 REJECTS it (proving membership enforcement is
  # actually wired for this sentinel, not merely declared in config).
  defp smoke_check(sentinel, members, catalogs) do
    outsider = out_of_catalog_label(members)
    payload = fixture_payload_for(sentinel, outsider)

    case Schema.validate(payload, catalogs) do
      {:error, errors} ->
        if Enum.any?(errors, &String.contains?(&1, inspect(sentinel))) do
          []
        else
          [
            "P8 smoke-check: #{inspect(sentinel)}'s declared catalog rejected the payload, but not " <>
              "for the expected sentinel — got: #{inspect(errors)}"
          ]
        end

      :ok ->
        [
          "P8 smoke-check FAILED for #{inspect(sentinel)}: a label (#{inspect(outsider)}) that is " <>
            "NOT a member of the declared closed catalog #{inspect(members)} was ACCEPTED by " <>
            "Schema.validate/2 — closed-catalog membership is not actually enforced for this " <>
            "sentinel."
        ]
    end
  end

  # A bounded, shape-valid label guaranteed absent from `members` (append a
  # disambiguating suffix to a fixed stem; catalog labels are bounded to 40
  # chars, so keep this short).
  defp out_of_catalog_label(members) do
    candidate = "zz_not_in_catalog"

    if candidate in members, do: candidate <> "_x", else: candidate
  end

  defp fixture_payload_for(:closed_check_catalog, label) do
    base_payload()
    |> Map.put("checks", [%{"name" => label, "status" => "ok"}])
  end

  defp fixture_payload_for(:closed_plan_tier_catalog, label) do
    base_payload()
    |> Map.put("mrr_by_tier", [%{"tier" => label, "mrr_cents" => 0, "tenant_count" => 0}])
  end

  defp fixture_payload_for(:closed_app_queue_catalog, label) do
    base_payload()
    |> Map.put("oban", [
      %{
        "queue" => label,
        "available" => 0,
        "executing" => 0,
        "retryable" => 0,
        "discarded" => 0,
        "oldest_available_age_s" => 0
      }
    ])
  end

  defp fixture_payload_for(:closed_audit_taxonomy_catalog, label) do
    base_payload()
    |> Map.put("activity_counts", [%{"event_kind" => label, "count" => 0}])
  end

  defp base_payload do
    Samen.Fleet.Report.build(app_id: "11111111-1111-4111-8111-111111111111")
    |> Samen.Fleet.Report.to_wire()
  end

  # ---------------------------------------------------------------------------
  # RP-J-4b — route surface (optional, needs a compiled router module)
  # ---------------------------------------------------------------------------

  defp route_violations(nil), do: []

  defp route_violations(router) when is_atom(router) do
    if Code.ensure_loaded?(router) and function_exported?(router, :__routes__, 0) do
      compare_routes(router)
    else
      [
        "--router #{inspect(router)} is not a compiled Phoenix router (no __routes__/0) — " <>
          "cannot cross-check the route surface."
      ]
    end
  end

  defp compare_routes(router) do
    actual =
      router.__routes__()
      |> Enum.filter(&fleet_shaped?/1)
      |> Enum.map(&{&1.verb, &1.path})
      |> MapSet.new()

    declared = Samen.Fleet.RouteTable.declared() |> Enum.map(&{&1.verb, &1.path}) |> MapSet.new()

    undeclared = MapSet.difference(actual, declared)
    unmounted = MapSet.difference(declared, actual)

    undeclared_errors =
      for {verb, path} <- undeclared do
        "route #{verb} #{path} is mounted on #{inspect(router)} but is NOT in " <>
          "Samen.Fleet.RouteTable.declared/0 (ADR-044 §4.4a) — an undeclared fleet route was added."
      end

    unmounted_errors =
      for {verb, path} <- unmounted do
        "Samen.Fleet.RouteTable.declared/0 promises #{verb} #{path} but #{inspect(router)} does not " <>
          "mount it."
      end

    undeclared_errors ++ unmounted_errors
  end

  # Only the fleet-shaped paths are in scope for this cross-check — every other
  # route on a host router (crm/billing/accounts/...) is out of scope. The
  # trailing "/resolve" clause catches the §5.3 tier-2 deep-link routes, which
  # live under the existing deliverability/automation/activity families rather
  # than under "/fleet" — nothing else in the operator plane ends a path in
  # "/resolve", so this is precise without needing the full declared list here.
  defp fleet_shaped?(%{path: path}) do
    String.starts_with?(path, "/fleet") or
      String.starts_with?(path, "/operator/fleet") or
      (String.starts_with?(path, "/operator/") and String.ends_with?(path, "/resolve"))
  end

  defp host_from(opts) do
    case Keyword.get(opts, :host) do
      nil -> Mix.Project.config()[:app]
      str -> String.to_atom(str)
    end
  end

  defp router_from(opts) do
    case Keyword.get(opts, :router) do
      nil -> nil
      str -> Module.concat([str])
    end
  end
end
