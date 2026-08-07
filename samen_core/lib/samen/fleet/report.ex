defmodule Samen.Fleet.Report do
  @moduledoc """
  The `FleetReport` v1 envelope struct (ADR-044 §5.1) plus the `:embedded` builder
  (§8.1) — the ONE builder every transport shares (`Samen.Fleet.Report.build/1`),
  so there is no drift between what an app pushes, what it serves at
  `GET /fleet/health`, and what `:embedded` mode renders of itself (§4.7).

  ## Honesty floor (§8.1, §9.2, fix round MED — §8.2 rule 2)

  A freshly generated app with ZERO authored aggregate code must still produce "a
  complete, truthful report" — so this builder emits only what is GENUINELY
  computable from compile-time/framework-visible substrate: build/release identity
  (real, from `Application.spec/2`) and a minimal liveness `health` claim ("this
  process is alive and answering" — true by construction, since the code computing
  it is executing). Every BUSINESS metric (billing, tenancy, support, deliverability,
  automation) is `optional: true` on the wire (`Samen.Fleet.Report.Schema`) and stays
  `nil` here unless a vertical's `:enrich` MFA populates it — `to_wire/1` OMITS a
  `nil` field from the payload entirely. This is §8.2 rule 2's literal requirement
  ("a metric the app cannot compute renders — with a not_available reason, NEVER 0")
  satisfied at the WIRE level: omission IS the not-available signal, so a metric the
  app cannot compute has nowhere to land as a fabricated 0 (or, for
  `deliverability_health_index`, a fabricated PERFECT 100) — there is structurally no
  way for this builder to emit a value it did not compute.
  """

  alias Samen.Fleet.Report.Schema

  # Fix round (MED, J5 honesty): every field commented "optional (J5)" below
  # defaults to `nil` — OMITTED, never fabricated — and `to_wire/1` leaves it
  # out of the payload entirely unless a vertical's `:enrich` MFA populated
  # it. `Samen.Fleet.Report.Schema` marks the SAME fields `optional: true`,
  # so their absence is a green, honest report — never a validation failure
  # and never a smuggled 0/100.
  @enforce_keys [:app_id, :schema_version, :generated_at_us, :window]
  defstruct app_id: nil,
            schema_version: 1,
            generated_at_us: nil,
            window: :instant,
            release_major: 0,
            release_minor: 0,
            release_patch: 0,
            release_channel: :dev,
            git_sha: nil,
            env: :dev,
            health_status: :ok,
            health_score: 100,
            checks: [],
            mrr_cents: nil,
            arr_cents: nil,
            active_subscriptions: nil,
            delinquent_subs: nil,
            mrr_by_tier: [],
            tenant_count: nil,
            active_tenant_count: nil,
            new_tenants_24h: nil,
            oban: [],
            open_tickets: nil,
            breaching_sla: nil,
            oldest_open_age_s: nil,
            sent: nil,
            delivered: nil,
            bounced: nil,
            complained: nil,
            suppressed: nil,
            deliverability_health_index: nil,
            rules_active: nil,
            rules_tripped_24h: nil,
            kill_switches_engaged: nil,
            attention: [],
            activity_counts: [],
            engine_version: 1,
            applied_fleet_revision: 0,
            handle_key_version: nil,
            cohorts: nil,
            suppressed_count: 0

  @type t :: %__MODULE__{}

  @doc """
  Build a `FleetReport` for `otp_app` from framework-visible substrate only
  (§8.1's embedded builder; also the default `GET /fleet/health` body for modes
  A/B when no vertical enrichment MFA is configured). `opts`:

    * `:app_id` — required, the cockpit-assigned (or self-assigned, `:embedded`) id.
    * `:enrich` — optional `{mod, fun, args}` MFA (§9.2's optional projection seam);
      called with the built report struct, returning an enriched struct. A vertical
      wires this to add REAL billing/queue/deliverability numbers from its own
      substrate. Absent ⇒ the honest, empty-sections default above.
  """
  @spec build(keyword()) :: t()
  def build(opts) do
    app_id = Keyword.fetch!(opts, :app_id)
    release = release_info()

    report = %__MODULE__{
      app_id: app_id,
      schema_version: 1,
      generated_at_us: System.os_time(:microsecond),
      window: Keyword.get(opts, :window, :instant),
      release_major: release.major,
      release_minor: release.minor,
      release_patch: release.patch,
      release_channel: Keyword.get(opts, :release_channel, :dev),
      git_sha: Keyword.get(opts, :git_sha),
      env: Keyword.get(opts, :env, :dev),
      health_status: :ok,
      health_score: 100,
      applied_fleet_revision: Keyword.get(opts, :applied_fleet_revision, 0),
      handle_key_version: Keyword.get(opts, :handle_key_version)
    }

    case Keyword.get(opts, :enrich) do
      {mod, fun, args} -> apply(mod, fun, args ++ [report])
      nil -> report
    end
  end

  defp release_info do
    version =
      case Application.spec(:samen_core, :vsn) do
        vsn when is_list(vsn) -> List.to_string(vsn)
        _ -> "0.0.0"
      end

    case String.split(version, ".") do
      [maj, min, patch | _] ->
        %{major: to_int(maj), minor: to_int(min), patch: to_int(patch)}

      _ ->
        %{major: 0, minor: 0, patch: 0}
    end
  end

  defp to_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  @doc """
  A stable, deterministic, UUIDv4-SHAPED synthetic `app_id` derived from
  `name` — used wherever a caller needs a schema-conforming `app_id` but has no
  cockpit-assigned one: `:embedded` mode's self-row (§8.1), and mode A's
  `GET /fleet/health` self-report (mode A has no enroll step, so the app never
  learns a cockpit-assigned id; the cockpit already knows which app it queried
  by `base_url`, so this value only needs to be schema-conforming, not globally
  meaningful). NOT cryptographically meaningful — deterministic on purpose, so
  the SAME name reports the SAME id across calls without persisting anything.
  """
  @spec synthetic_app_id(String.t()) :: String.t()
  def synthetic_app_id(name) when is_binary(name) do
    <<b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15>> =
      :crypto.hash(:md5, "samen-fleet-synthetic:" <> name)

    b6 = Bitwise.bor(Bitwise.band(b6, 0x0F), 0x40)
    b8 = Bitwise.bor(Bitwise.band(b8, 0x3F), 0x80)

    hex =
      <<b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15>>
      |> Base.encode16(case: :lower)

    <<p1::binary-size(8), p2::binary-size(4), p3::binary-size(4), p4::binary-size(4),
      p5::binary-size(12)>> = hex

    "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
  end

  @doc """
  Serialize a `%Samen.Fleet.Report{}` to the STRING-keyed wire map
  `Samen.Fleet.Report.Schema.validate/1` expects (JSON-round-trip shape — every
  list item becomes a string-keyed map too). `cohorts` is included only when
  non-nil (§5.3 — the section is optional-by-omission, never sent empty-but-present
  when the app opted out). Fix round (MED, J5 honesty): every BUSINESS metric
  field is likewise omitted when `nil` — the app never computed it, so it is
  not on the wire at all, never a fabricated `0`.
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = report) do
    base = %{
      "app_id" => report.app_id,
      "schema_version" => report.schema_version,
      "generated_at_us" => report.generated_at_us,
      "window" => Atom.to_string(report.window),
      "release_major" => report.release_major,
      "release_minor" => report.release_minor,
      "release_patch" => report.release_patch,
      "release_channel" => Atom.to_string(report.release_channel),
      "env" => Atom.to_string(report.env),
      "health_status" => Atom.to_string(report.health_status),
      "health_score" => report.health_score,
      "checks" => Enum.map(report.checks, &wire_check/1),
      "mrr_by_tier" => report.mrr_by_tier,
      "oban" => report.oban,
      "attention" => Enum.map(report.attention, &wire_attention/1),
      "activity_counts" => report.activity_counts,
      "engine_version" => report.engine_version,
      "applied_fleet_revision" => report.applied_fleet_revision,
      "suppressed_count" => report.suppressed_count
    }

    base
    |> maybe_put("git_sha", report.git_sha)
    |> maybe_put("handle_key_version", report.handle_key_version)
    |> maybe_put("mrr_cents", report.mrr_cents)
    |> maybe_put("arr_cents", report.arr_cents)
    |> maybe_put("active_subscriptions", report.active_subscriptions)
    |> maybe_put("delinquent_subs", report.delinquent_subs)
    |> maybe_put("tenant_count", report.tenant_count)
    |> maybe_put("active_tenant_count", report.active_tenant_count)
    |> maybe_put("new_tenants_24h", report.new_tenants_24h)
    |> maybe_put("open_tickets", report.open_tickets)
    |> maybe_put("breaching_sla", report.breaching_sla)
    |> maybe_put("oldest_open_age_s", report.oldest_open_age_s)
    |> maybe_put("sent", report.sent)
    |> maybe_put("delivered", report.delivered)
    |> maybe_put("bounced", report.bounced)
    |> maybe_put("complained", report.complained)
    |> maybe_put("suppressed", report.suppressed)
    |> maybe_put("deliverability_health_index", report.deliverability_health_index)
    |> maybe_put("rules_active", report.rules_active)
    |> maybe_put("rules_tripped_24h", report.rules_tripped_24h)
    |> maybe_put("kill_switches_engaged", report.kill_switches_engaged)
  end

  defp wire_check(%{name: name, status: status}),
    do: %{"name" => to_string(name), "status" => Atom.to_string(status)}

  defp wire_attention(%{kind: kind, severity: severity, count: count, since_us: since_us}) do
    %{
      "kind" => Atom.to_string(kind),
      "severity" => Atom.to_string(severity),
      "count" => count,
      "since_us" => since_us
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Validate a decoded wire payload against the closed schema (delegates to Schema.validate/1)."
  @spec validate_wire(map()) :: :ok | {:error, [String.t()]}
  def validate_wire(payload), do: Schema.validate(payload)
end
