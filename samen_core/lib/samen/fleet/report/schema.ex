defmodule Samen.Fleet.Report.Schema do
  @moduledoc """
  The **closed `FleetReport` v1 wire schema** (ADR-044 §5.1 — WS-J J2, T82's half:
  the schema declaration + ingest re-validation; the standalone build-time verifier
  `mix samen.verify.fleet_wire` cross-checking the router is T84's, per ADR §5.2
  point 4 / the T81 carried-LOWs).

  Adopts `Samen.WideEvent.Schema.bounded_types/0` **unchanged** — the four permitted
  classes are exactly `:opaque_id`, `:token`, `:enum`, `:number` — and **narrows**
  each field with a declared `form:` (opaque_id/token) or `range:` (number), plus a
  `max_len:` on every list. There is no field of any text-carrying class: a laundered
  PII value has nowhere to land (the precedent's own argument, quoted in the ADR).

  ## Carried-LOW 3 (T82) — closed here

  §5.3 originally mis-stated the residue budget as `20 + 16×256` bytes; the correct
  figure is **THREE** cohort lists × `max_len: 256` × 16 bytes = `20 + 16×768 =
  12,308` bytes (ADR §5.2b/§13, corrected). `%Samen.Aggregate.Suppressed{}`'s five
  producer-supplied fields (`reason`, `k`, `l`, `observed`, `limit`) get explicit
  bounds here: `reason` is a closed enum, the rest are ranged non-negative integers.

  ## Carried-LOW 5 (T82 half) — closed here

  `attention[].since_us` and `activity_counts[].count` now carry the `range:` every
  `:number` field is supposed to (they were the two fields the T81 carry named as
  missing it).

  ## H1 (phase-6 SEC dogfood) — the closed-member premise reaches the NESTED level

  "A laundered PII value has nowhere to land" is only true if EVERY level of the payload
  is closed. T82's BLOCKER-2 remediation closed the TOP level (`unknown_key_errors/1`)
  and stopped there: `validate_item/5` and `validate_suppressed/4` each walked only the
  DECLARED field table and never inspected the keys actually present, so a producer with
  a valid heartbeat credential could smuggle free text / PII in an UNDECLARED key inside
  any list item or any `%{"suppressed" => true}` cell — `validate/2` returned `:ok` and
  `Samen.Fleet.Registry.record_report/4` stored the payload verbatim in
  `flt_report.payload`. Both nested validators now reject undeclared keys exactly as the
  top level does (`unknown_item_key_errors/4`, `unknown_suppressed_key_errors/1`), and
  every nested string value carries an explicit `max_nested_string_bytes/0` ceiling
  consistent with the top level's widest declared string form (40 bytes).
  """

  @bounded_types Samen.WideEvent.Schema.bounded_types()

  @typedoc "A declared field type — must be one of Samen.WideEvent.Schema.bounded_types/0."
  @type field_type :: :opaque_id | :token | :enum | :number

  @typedoc "A field spec: {name, type, opts}. opts carries form:/range:/allowed:/max_len:."
  @type field_spec :: {atom(), field_type(), keyword()}

  # A microsecond unix timestamp plausibility window: not before 2020-01-01, not more
  # than ~10 years past "now" at schema-authoring time — bounds `generated_at_us` /
  # `since_us` / `received_at`-adjacent producer timestamps without parsing a date
  # string (§5.1: "utc_datetime_usec is gone ... no date string is ever parsed").
  @us_2020 1_577_836_800_000_000
  @us_2035 2_051_222_400_000_000

  @doc "The plausibility range every microsecond-unix `:number` timestamp field uses."
  @spec timestamp_range_us() :: {integer(), integer()}
  def timestamp_range_us, do: {@us_2020, @us_2035}

  @count_range {0, 2_147_483_647}
  @cents_range {0, 9_007_199_254_740_992}

  @attention_kinds ~w(incident dunning sla_breach automation_trip deliverability_degraded queue_backlog heartbeat_stale heartbeat_rejected)a
  @attention_severities ~w(info warn critical)a
  @suppressed_reasons ~w(k_anonymity l_diversity query_budget)a
  @env_values ~w(dev staging prod)a
  @release_channels ~w(stable rc beta dev)a
  @window_values ~w(instant hour_1 day_1)a
  @check_status ~w(ok degraded unknown down)a
  @health_status ~w(ok degraded down)a

  @cohort_max_len 256

  @doc "The three tier-2 cohort list names (§5.3) — used by the residue-budget math."
  @spec cohort_list_names() :: [atom()]
  def cohort_list_names, do: [:deliverability, :automation, :activity]

  @doc "The corrected §5.2b/§13 residue budget in bytes (carried-LOW 3)."
  @spec residue_budget_bytes() :: pos_integer()
  def residue_budget_bytes do
    git_sha_bytes = 20
    handle_bytes = 16
    cohort_lists = length(cohort_list_names())
    git_sha_bytes + handle_bytes * cohort_lists * @cohort_max_len
  end

  # ---------------------------------------------------------------------------
  # Top-level scalar fields (§5.1)
  # ---------------------------------------------------------------------------
  @top_level_fields [
    {:app_id, :opaque_id, form: {:uuid_v4}},
    {:schema_version, :number, range: {1, 1}},
    {:generated_at_us, :number, range: {@us_2020, @us_2035}},
    {:window, :enum, allowed: @window_values},
    {:release_major, :number, range: {0, 9999}},
    {:release_minor, :number, range: {0, 9999}},
    {:release_patch, :number, range: {0, 9999}},
    {:release_channel, :enum, allowed: @release_channels},
    {:git_sha, :opaque_id, form: {:hex, 40}, optional: true},
    {:env, :enum, allowed: @env_values},
    {:health_status, :enum, allowed: @health_status},
    {:health_score, :number, range: {0, 100}},
    # Fix round (MED, J5 honesty — ADR-044 §8.2 rule 2: "a metric the app
    # cannot compute renders — with a not_available reason, NEVER 0"). Every
    # BUSINESS/vertical-dependent metric below is now `optional: true`: a
    # bare framework install with no billing/support/deliverability/
    # automation substrate wired OMITS the section entirely rather than
    # fabricating a 0 (or, worse, a perfect 100 health_index) it cannot back.
    # `Samen.Fleet.Report.build/1`'s default builder now leaves these `nil`
    # (never emitted by `to_wire/1`); a vertical's `:enrich` MFA populates
    # the ones it can genuinely compute. `health_status`/`health_score`
    # above stay REQUIRED — the framework's own liveness claim ("this
    # process is alive and answering") is genuinely computable everywhere.
    {:mrr_cents, :number, range: @cents_range, optional: true},
    {:arr_cents, :number, range: @cents_range, optional: true},
    {:active_subscriptions, :number, range: {0, 2_147_483_647}, optional: true},
    {:delinquent_subs, :number, range: {0, 2_147_483_647}, optional: true},
    {:tenant_count, :number, range: @count_range, optional: true},
    {:active_tenant_count, :number, range: @count_range, optional: true},
    {:new_tenants_24h, :number, range: @count_range, optional: true},
    {:open_tickets, :number, range: @count_range, optional: true},
    {:breaching_sla, :number, range: @count_range, optional: true},
    {:oldest_open_age_s, :number, range: @count_range, optional: true},
    {:sent, :number, range: @count_range, optional: true},
    {:delivered, :number, range: @count_range, optional: true},
    {:bounced, :number, range: @count_range, optional: true},
    {:complained, :number, range: @count_range, optional: true},
    {:suppressed, :number, range: @count_range, optional: true},
    {:deliverability_health_index, :number, range: {0, 100}, optional: true},
    {:rules_active, :number, range: @count_range, optional: true},
    {:rules_tripped_24h, :number, range: @count_range, optional: true},
    {:kill_switches_engaged, :number, range: @count_range, optional: true},
    {:engine_version, :number, range: @count_range},
    {:applied_fleet_revision, :number, range: @count_range},
    {:handle_key_version, :number, range: @count_range, optional: true},
    {:suppressed_count, :number, range: @count_range}
  ]

  # ---------------------------------------------------------------------------
  # Repeated (list) sections — each carries a max_len: (§5.1 cardinality caps).
  # ---------------------------------------------------------------------------
  @list_fields [
    checks: [
      max_len: 32,
      fields: [
        {:name, :enum, allowed: :closed_check_catalog},
        {:status, :enum, allowed: @check_status}
      ]
    ],
    mrr_by_tier: [
      max_len: 16,
      fields: [
        {:tier, :enum, allowed: :closed_plan_tier_catalog},
        {:mrr_cents, :number, range: @cents_range},
        {:tenant_count, :number, range: @count_range}
      ]
    ],
    oban: [
      max_len: 32,
      fields: [
        {:queue, :enum, allowed: :closed_app_queue_catalog},
        {:available, :number, range: @count_range},
        {:executing, :number, range: @count_range},
        {:retryable, :number, range: @count_range},
        {:discarded, :number, range: @count_range},
        {:oldest_available_age_s, :number, range: @count_range}
      ]
    ],
    attention: [
      max_len: 64,
      fields: [
        {:kind, :enum, allowed: @attention_kinds},
        {:severity, :enum, allowed: @attention_severities},
        {:count, :number, range: @count_range},
        # carried-LOW 5 (T82 half): since_us now carries the plausibility range every
        # :number field is supposed to, exactly like generated_at_us.
        {:since_us, :number, range: {@us_2020, @us_2035}}
      ]
    ],
    activity_counts: [
      max_len: 64,
      fields: [
        {:event_kind, :enum, allowed: :closed_audit_taxonomy_catalog},
        # carried-LOW 5 (T82 half): count now carries an explicit range (a
        # cardinality count, bounded the same as every other count field).
        {:count, :number, range: @count_range}
      ]
    ],
    # Tier-2 cohort rows (§5.3, OPTIONAL — only emitted when the app opts in).
    # `handle` is `:token {:hex, 32}` — the fleet_handle pseudonym, never an org_id.
    # A cell may carry `%Samen.Aggregate.Suppressed{}` in place of its numeric value
    # (bound below) wherever the source's k/l floor fired.
    deliverability: [
      max_len: @cohort_max_len,
      fields: [
        {:handle, :token, form: {:hex, 32}},
        {:sent, :number, range: @count_range, suppressible: true},
        {:bounced, :number, range: @count_range, suppressible: true},
        {:complained, :number, range: @count_range, suppressible: true},
        {:health_index, :number, range: {0, 100}, suppressible: true}
      ]
    ],
    automation: [
      max_len: @cohort_max_len,
      fields: [
        {:handle, :token, form: {:hex, 32}},
        {:rules_tripped, :number, range: @count_range, suppressible: true},
        {:kill_switches_engaged, :number, range: @count_range, suppressible: true}
      ]
    ],
    activity: [
      max_len: @cohort_max_len,
      fields: [
        {:handle, :token, form: {:hex, 32}},
        {:event_kind, :enum, allowed: :closed_audit_taxonomy_catalog},
        {:count, :number, range: @count_range, suppressible: true}
      ]
    ]
  ]

  # ---------------------------------------------------------------------------
  # %Samen.Aggregate.Suppressed{} field bounds (carried-LOW 3, new).
  # Five producer-supplied fields; `reason` is a closed enum, the rest are ranged
  # non-negative integers (or absent — k/l/observed/limit are each nil unless their
  # reason uses them, per Samen.Aggregate.Suppressed's own struct shape).
  # ---------------------------------------------------------------------------
  @suppressed_fields [
    {:reason, :enum, allowed: @suppressed_reasons},
    {:k, :number, range: {0, 2_147_483_647}, nilable: true},
    {:l, :number, range: {0, 2_147_483_647}, nilable: true},
    {:observed, :number, range: {0, 2_147_483_647}, nilable: true},
    {:limit, :number, range: {0, 2_147_483_647}, nilable: true}
  ]

  @doc "The bound `%Samen.Aggregate.Suppressed{}` wire fields (carried-LOW 3)."
  @spec suppressed_fields() :: [field_spec()]
  def suppressed_fields, do: @suppressed_fields

  @doc "The top-level scalar field table."
  @spec top_level_fields() :: [field_spec()]
  def top_level_fields, do: @top_level_fields

  @doc "The declared list sections and their per-item field tables + max_len."
  @spec list_fields() :: keyword()
  def list_fields, do: @list_fields

  @doc "The bounded types this schema is a strict subset of (RP-J-4's direct assertion)."
  @spec bounded_types() :: [atom()]
  def bounded_types, do: @bounded_types

  @doc "Is `type` one of the four permitted bounded classes?"
  @spec bounded_type?(atom()) :: boolean()
  def bounded_type?(type), do: type in @bounded_types

  @doc """
  Every declared type atom across the top-level + list + Suppressed field tables is a
  member of `bounded_types/0` — the direct "never widens the inherited discipline"
  assertion RP-J-4 names. Returns violations (empty = clean).
  """
  @spec class_discipline_violations() :: [String.t()]
  def class_discipline_violations do
    all_types =
      (@top_level_fields ++ @suppressed_fields ++ list_item_specs())
      |> Enum.map(fn {_name, type, _opts} -> type end)
      |> Enum.uniq()

    for type <- all_types, not bounded_type?(type) do
      "field type #{inspect(type)} is not a member of Samen.WideEvent.Schema.bounded_types/0 " <>
        "#{inspect(@bounded_types)} — the fleet wire must never widen the inherited discipline"
    end
  end

  defp list_item_specs do
    Enum.flat_map(@list_fields, fn {_name, opts} -> Keyword.fetch!(opts, :fields) end)
  end

  # ---------------------------------------------------------------------------
  # Ingest re-validation (§5.2 point 4 — T82's half; a non-conforming report is
  # rejected 422 and NOT stored). Structural: out-of-schema key, out-of-range
  # number, malformed form:, over-max_len list ⇒ {:error, reason}.
  # ---------------------------------------------------------------------------

  @doc """
  Validate a decoded report payload (a plain map with STRING keys, as received off
  the wire / out of `flt_report.payload` jsonb) against this schema. Returns `:ok`
  or `{:error, reasons}` — a non-empty list of violation strings. Never raises: a
  malformed payload is data, not a crash.

  ## `catalogs` (P8, ADR-044 §5.2b / phase6-punchlist P8) — closed-catalog MEMBERSHIP

  A "catalog" field (`checks`/`mrr_by_tier`/`oban`/`activity_counts` item enum keys —
  declared with a SENTINEL `allowed: :closed_check_catalog` etc., not a literal list,
  because the real member vocabulary is per-vertical) is bounded to the
  `^[a-z][a-z0-9_]{0,39}$` SHAPE unconditionally (rejects any PII shape). That shape
  bound is NOT a closed member-list check — `"totally_made_up_queue_9"` passes shape
  but was never declared by any host. `catalogs` closes the gap: an OPTIONAL
  `%{sentinel_atom => [String.t()]}` map (see `Samen.Fleet.Report.Catalogs`) — when a
  sentinel's closed list is SUPPLIED, membership is enforced (a shape-valid-but-
  undeclared label is now REJECTED, not merely shape-checked); a sentinel with no
  entry in `catalogs` falls back to the shape-only stopgap (so a host that has not
  yet adopted per-vertical catalogs, or a caller validating without one, keeps the
  EXACT pre-P8 behaviour — this is purely additive). `mix samen.verify.fleet_wire`
  is the BUILD-TIME backstop that a host adopting cohort/catalog data must declare
  non-empty catalogs at all, so "closed member list" stops being aspirational.
  """
  @spec validate(map(), %{atom() => [String.t()]}) :: :ok | {:error, [String.t()]}
  def validate(payload, catalogs \\ %{})

  def validate(payload, catalogs) when is_map(payload) and is_map(catalogs) do
    top_errors =
      Enum.flat_map(@top_level_fields, fn {name, type, opts} ->
        validate_field(payload, Atom.to_string(name), name, type, opts, catalogs)
      end)

    list_errors =
      Enum.flat_map(@list_fields, fn {name, opts} ->
        validate_list(payload, name, opts, catalogs)
      end)

    unknown_key_errors = unknown_key_errors(payload)

    case top_errors ++ list_errors ++ unknown_key_errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate(_non_map, _catalogs), do: {:error, ["payload must be a map"]}

  defp validate_field(payload, key, name, type, opts, catalogs) do
    optional? = Keyword.get(opts, :optional, false)

    case Map.fetch(payload, key) do
      :error ->
        if optional?, do: [], else: ["missing required field #{inspect(name)}"]

      {:ok, value} ->
        validate_value(name, type, value, opts, catalogs)
    end
  end

  defp validate_value(name, :number, value, opts, _catalogs) do
    case Keyword.get(opts, :range) do
      {lo, hi} when is_integer(value) and value >= lo and value <= hi ->
        []

      {lo, hi} ->
        ["#{inspect(name)} = #{inspect(value)} is out of declared range #{lo}..#{hi}"]

      nil ->
        if is_integer(value), do: [], else: ["#{inspect(name)} must be an integer"]
    end
  end

  defp validate_value(name, :enum, value, opts, catalogs) do
    case Keyword.get(opts, :allowed) do
      allowed when is_list(allowed) ->
        atom_value = safe_to_atom(value)

        if atom_value in allowed do
          []
        else
          ["#{inspect(name)} = #{inspect(value)} is not in the closed enum #{inspect(allowed)}"]
        end

      # A closed CATALOG enum (checks/mrr_by_tier/oban/activity_counts item keys) —
      # the actual closed member list is per-vertical (§5.2b). BLOCKER-2 fix (fix
      # round, ATK-6/INV-2): the SHAPE bound `^[a-z][a-z0-9_]{0,39}$` is enforced
      # unconditionally (rejects any PII shape — no `@`, no spaces, no uppercase,
      # no unicode, bounded length). P8 (phase6-punchlist): when `catalogs` (passed
      # by the caller — the ingest path, `mix samen.verify.fleet_wire`'s own tests,
      # or a host that has declared its `:fleet_wire_catalogs`) supplies a NON-EMPTY
      # member list for this sentinel, MEMBERSHIP is enforced too — a shape-valid
      # but never-declared label (e.g. a typo'd queue name) is now REJECTED, not
      # merely shape-checked. No entry for this sentinel in `catalogs` ⇒ the
      # shape-only stopgap (unchanged pre-P8 behaviour) — additive, never a
      # regression for a caller that passes no catalogs.
      catalog_sentinel ->
        cond do
          not catalog_label?(value) ->
            ["#{inspect(name)} = #{inspect(value)} is not a bounded catalog label (^[a-z][a-z0-9_]{0,39}$)"]

          (members = Map.get(catalogs, catalog_sentinel)) not in [nil, []] and
              to_string(value) not in members ->
            ["#{inspect(name)} = #{inspect(value)} is not a member of the declared closed catalog #{inspect(catalog_sentinel)} #{inspect(members)}"]

          true ->
            []
        end
    end
  end

  defp validate_value(name, :opaque_id, value, opts, _catalogs) do
    case Keyword.get(opts, :form) do
      {:uuid_v4} ->
        if is_binary(value) and uuid_v4?(value),
          do: [],
          else: ["#{inspect(name)} = #{inspect(value)} is not a canonical UUID"]

      {:hex, len} ->
        if is_binary(value) and hex_of_length?(value, len),
          do: [],
          else: ["#{inspect(name)} = #{inspect(value)} is not #{len} hex chars"]

      nil ->
        ["#{inspect(name)} declares no form:"]
    end
  end

  defp validate_value(name, :token, value, opts, _catalogs) do
    case Keyword.get(opts, :form) do
      {:hex, len} ->
        if is_binary(value) and hex_of_length?(value, len),
          do: [],
          else: ["#{inspect(name)} = #{inspect(value)} is not #{len} hex chars"]

      nil ->
        ["#{inspect(name)} declares no form:"]
    end
  end

  defp validate_list(payload, name, opts, catalogs) do
    key = Atom.to_string(name)
    max_len = Keyword.fetch!(opts, :max_len)
    item_fields = Keyword.fetch!(opts, :fields)

    case Map.fetch(payload, key) do
      :error ->
        []

      {:ok, items} when is_list(items) ->
        len_errors =
          if length(items) > max_len,
            do: ["#{inspect(name)} exceeds max_len #{max_len}"],
            else: []

        item_errors =
          items
          |> Enum.with_index()
          |> Enum.flat_map(fn {item, idx} -> validate_item(name, idx, item, item_fields, catalogs) end)

        len_errors ++ item_errors

      {:ok, other} ->
        ["#{inspect(name)} = #{inspect(other)} must be a list"]
    end
  end

  defp validate_item(list_name, idx, item, item_fields, catalogs) when is_map(item) do
    declared_errors =
      Enum.flat_map(item_fields, fn {name, type, opts} ->
        key = Atom.to_string(name)
        suppressible? = Keyword.get(opts, :suppressible, false)

        case Map.fetch(item, key) do
          :error ->
            ["#{inspect(list_name)}[#{idx}].#{name} missing"]

          {:ok, %{"suppressed" => true} = sup} when suppressible? ->
            validate_suppressed(list_name, idx, name, sup)

          {:ok, value} ->
            validate_value(name, type, value, opts, catalogs)
            |> Enum.map(&"#{inspect(list_name)}[#{idx}].#{&1}")
        end
      end)

    declared_errors ++
      unknown_item_key_errors(list_name, idx, item, item_fields) ++
      oversized_string_errors("#{inspect(list_name)}[#{idx}]", item)
  end

  defp validate_item(list_name, idx, _other, _fields, _catalogs),
    do: ["#{inspect(list_name)}[#{idx}] must be a map"]

  # H1 (phase6 SEC dogfood, INV-2 hole) — the SAME closed-member discipline
  # `unknown_key_errors/1` enforces at the TOP level, one level DOWN. Before this,
  # `validate_item/5` iterated only the DECLARED item fields and NEVER inspected the keys
  # actually present, so an undeclared free-text/PII key inside ANY declared list item —
  # `%{"handle" => "<32hex>", …, "leak_note" => "alice@example.com / SSN 111-22-3333"}` —
  # validated `:ok` and `Samen.Fleet.Registry.record_report/4` stored the raw payload
  # VERBATIM in `flt_report.payload`. The T82 BLOCKER-2 remediation closed the top level
  # only; INV-2's "a laundered PII value has nowhere to land" was therefore FALSE for every
  # list surface (checks/mrr_by_tier/oban/attention/activity_counts + the three §5.3 cohort
  # lists). Every DECLARED item field is a bounded class (opaque_id/token/enum/number), so
  # once undeclared keys are rejected an item has no unbounded free-text landing zone left.
  defp unknown_item_key_errors(list_name, idx, item, item_fields) do
    declared = MapSet.new(item_fields, fn {name, _t, _o} -> Atom.to_string(name) end)

    for key <- Map.keys(item), key not in declared do
      "#{inspect(list_name)}[#{idx}] unknown field #{safe_key(key)} — not declared in the " <>
        "#{inspect(list_name)} item schema"
    end
  end

  defp validate_suppressed(list_name, idx, field_name, sup) do
    reason = sup["reason"]

    field_errs =
      Enum.flat_map(@suppressed_fields, fn {name, type, opts} ->
        key = Atom.to_string(name)
        nilable? = Keyword.get(opts, :nilable, false)

        case Map.fetch(sup, key) do
          :error when name == :reason -> ["suppressed reason missing"]
          :error -> []
          {:ok, nil} when nilable? -> []
          {:ok, value} -> validate_value(name, type, value, opts, %{})
        end
      end)

    errs =
      field_errs ++
        unknown_suppressed_key_errors(sup) ++
        oversized_string_errors("suppressed", sup)

    Enum.map(errs, &"#{inspect(list_name)}[#{idx}].#{field_name}.#{&1} (reason=#{inspect(reason)})")
  end

  # H1 (phase6 SEC dogfood, INV-2 hole — the SUPPRESSED-cell half). A suppressed cell
  # (`%{"suppressed" => true, …}`) may carry ONLY the `"suppressed"` discriminator plus the
  # five declared `%Samen.Aggregate.Suppressed{}` fields. Before this, `validate_suppressed/4`
  # iterated only `@suppressed_fields`, so `%{"suppressed" => true, "reason" => "k_anonymity",
  # "leak_note" => "<PII>"}` validated `:ok` and was stored verbatim — the same hole one level
  # deeper. Same closed-member rejection as the item level.
  defp unknown_suppressed_key_errors(sup) do
    declared =
      @suppressed_fields
      |> MapSet.new(fn {name, _t, _o} -> Atom.to_string(name) end)
      |> MapSet.put("suppressed")

    for key <- Map.keys(sup), key not in declared do
      "unknown field #{safe_key(key)} — not declared in Samen.Aggregate.Suppressed"
    end
  end

  # H1, secondary angle — a LENGTH BOUND on nested string values, consistent with the bound
  # every TOP-LEVEL string already carries by construction. At the top level no declared
  # string can exceed 40 bytes (a 40-hex `git_sha`, a 36-char uuid `app_id`, a
  # `^[a-z][a-z0-9_]{0,39}$` catalog label), so an accepted top-level payload is
  # length-bounded by its `form:`/`allowed:` declarations. Nested item/suppressed values had
  # NO such ceiling on any key the declared-field walk did not visit — up to `max_len` items
  # × arbitrary-size strings, a storage-amplification / covert-channel bandwidth far beyond
  # the §5.2b 12,308-byte residue budget. `@max_nested_string_bytes` is that same ceiling
  # made EXPLICIT and unconditional: it applies to every string value present in an item or
  # a suppressed cell, declared or not, so it holds even if a future field ships with a
  # looser `form:` than today's. Defense in depth beside the closed-member rejection above —
  # neither guard is load-bearing for the other.
  @max_nested_string_bytes 64

  @doc """
  The byte ceiling on ANY string value inside a wire list item or suppressed cell (H1).
  Consistent with the top level, whose widest declared string form is 40 bytes.
  """
  @spec max_nested_string_bytes() :: pos_integer()
  def max_nested_string_bytes, do: @max_nested_string_bytes

  defp oversized_string_errors(prefix, map) when is_map(map) do
    for {key, value} <- map,
        is_binary(value),
        byte_size(value) > @max_nested_string_bytes do
      "#{prefix} field #{safe_key(key)} carries a #{byte_size(value)}-byte string, over the " <>
        "#{@max_nested_string_bytes}-byte nested value bound"
    end
  end

  # BLOCKER-2 fix (fix round, ATK-6/INV-2, hole (a)): "cohorts" is NO LONGER a
  # blanket-allowed, unvalidated top-level key. It previously whitelisted the
  # literal string "cohorts" here with NOTHING ever inspecting its contents —
  # {"cohorts": {"leak_note": "<arbitrary PII>"}} (or a multi-hundred-KB blob)
  # validated :ok. This implementation's §5.3 cohort lists (`deliverability`/
  # `automation`/`activity`) are declared and validated as ordinary TOP-LEVEL
  # `@list_fields` (each bounded: max_len 256, per-field types/ranges) — a
  # "cohorts" WRAPPER key is not part of that shape and nothing in
  # `Samen.Fleet.Report.to_wire/1` ever emits one, so a payload carrying it is
  # now correctly rejected as an unknown field (422, not stored) rather than
  # silently passed through unvalidated.
  defp unknown_key_errors(payload) do
    declared_top = MapSet.new(@top_level_fields, fn {name, _t, _o} -> Atom.to_string(name) end)
    declared_lists = MapSet.new(@list_fields, fn {name, _o} -> Atom.to_string(name) end)
    declared = MapSet.union(declared_top, declared_lists)

    for key <- Map.keys(payload), key not in declared do
      "unknown field #{safe_key(key)} — not declared in Samen.Fleet.Report.Schema"
    end
  end

  # R6 (phase-6 SEC fix round) — every "unknown field" / bound-violation message
  # interpolates an ATTACKER-CONTROLLED key NAME. Those strings travel into logs and
  # (for the `mix samen.verify.fleet_wire` path) onto a terminal, so an unbounded key
  # name is itself an unbounded free-text channel out of the rejection path — the very
  # thing the closed schema exists to deny. `safe_key/1` bounds the echoed name to
  # `@max_echoed_key_bytes` and appends a truncation marker naming the real byte size,
  # so the message stays diagnostic without becoming the smuggling channel.
  @max_echoed_key_bytes 64

  defp safe_key(key) when is_binary(key) do
    if byte_size(key) > @max_echoed_key_bytes do
      inspect(binary_part(key, 0, @max_echoed_key_bytes)) <>
        " (truncated from #{byte_size(key)} bytes)"
    else
      inspect(key)
    end
  end

  defp safe_key(key), do: key |> to_string() |> safe_key()

  defp uuid_v4?(value) do
    Regex.match?(
      ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i,
      value
    )
  end

  defp hex_of_length?(value, len) do
    byte_size(value) == len and Regex.match?(~r/\A[0-9a-f]+\z/i, value)
  end

  @catalog_label_pattern ~r/\A[a-z][a-z0-9_]{0,39}\z/

  defp catalog_label?(value) when is_binary(value), do: Regex.match?(@catalog_label_pattern, value)
  defp catalog_label?(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: value |> Atom.to_string() |> catalog_label?()

  defp catalog_label?(_), do: false

  defp safe_to_atom(value) when is_atom(value), do: value

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :__unknown_atom__
  end

  defp safe_to_atom(_), do: :__unknown_atom__
end
