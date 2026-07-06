defmodule Samen.WideEvent.Schema do
  @moduledoc """
  The **declared field schema** for structured wide events + spans (J2 / doc §runs 4b).

  Every field a wide event or span may carry is declared here with a **bounded
  field type**. The doc's rule is categorical:

  > "Every wide-event field is an opaque ID, a token, a bounded enum, or a
  > number — never a plaintext PII value or a query containing one. … a
  > build-time check fails on any span/wide-event field not typed as a bounded
  > ID / token / enum / number, so a future debug field can't smuggle a name
  > into Honeycomb."

  This module is the single source of truth the J2 build check
  (`mix samen.verify.sink_schema`) reads. If a field is not declared here, or is
  declared with a **forbidden type** (a free-form string, a binary, `:any`,
  `:map`, …), the build fails. This is the **laundered-leak backstop** the layered
  design (C3 AST + J2 sink schema) promises: a laundered PII value cannot occupy a
  typed sink field, because no free-string field exists to hold it.

  ## Bounded field types (the ONLY types allowed at a sink)

    * `:opaque_id`  — a bounded, non-PII identifier: `request_id`, `trace_id`,
      `span_id`, `tenant_id` (the org's opaque id). UUID/ULID-shaped, never a name.
    * `:token`      — a vault-FK token (`vt_*`) or a per-subject-keyed pseudonym
      (`actor_id = HMAC(psk_S, subject_id)`). One-way; unlinkable on key-shred.
    * `:enum`       — a value drawn from a **declared, closed** set (`allowed:`).
      The J2 check requires the closed set; an enum with no `allowed:` is rejected.
    * `:number`     — an integer/float measurement: `row_count`, `duration_ms`,
      `queue_depth`. A count or a timing, never text.

  ## Forbidden field types (the J2 check FAILS on any of these)

  A field typed `:string`, `:binary`, `:text`, `:atom`, `:map`, `:any`, `:term`,
  or any type not in `bounded_types/0` is a **potential name-carrier** and fails
  the build. There is no "trusted string" — the whole point is that a laundered
  name has nowhere to land. (Operator-authored free text lives in `aud_event`
  audit rows — a first-class DB tier the oracle scans — NOT in the trace sink.)

  ## The canonical wide event (doc §runs 4b field list)

  `canonical_fields/0` is the exact field set the doc names:

      request_id, trace_id, tenant_id, actor_id, action, row_count,
      operation (op+table+duration summary — NO SQL text), queue_depth

  A `Samen.WideEvent` struct is validated against this schema at emit time
  (runtime defence) AND the schema itself is validated at build time (the J2
  static defence — a new field with a forbidden type never compiles green).
  """

  @bounded_types [:opaque_id, :token, :enum, :number]

  # The forbidden types we recognise by name for a precise diagnostic. Anything
  # NOT in @bounded_types is forbidden; these just give a clearer message.
  @known_forbidden [:string, :binary, :text, :atom, :map, :any, :term, :list, :float_text]

  @typedoc "A declared field type — only bounded types are permitted at a sink."
  @type field_type :: :opaque_id | :token | :enum | :number

  @typedoc "A field spec: `{name, type, opts}` where opts may carry `allowed:` for enums."
  @type field_spec :: {atom(), atom(), keyword()}

  # The canonical wide-event field schema. This IS the allow-list. To add a debug
  # field you MUST add it here with a bounded type — and the J2 build check
  # enforces that the type is bounded (an enum must declare its closed `allowed:`
  # set). A `:string` field added here fails `mix samen.verify.sink_schema`.
  #
  # `operation` is the op+table+duration SUMMARY, decomposed into bounded fields:
  # `op` (enum), `table` (opaque_id — the abbrev-qualified table name, a bounded
  # catalog identifier, never SQL text), `duration_ms` (number). This is the
  # "operation + table + duration, not SQL text" the doc mandates.
  @canonical_fields [
    {:request_id, :opaque_id, []},
    {:trace_id, :opaque_id, []},
    {:span_id, :opaque_id, []},
    {:tenant_id, :opaque_id, []},
    {:actor_id, :token, []},
    {:action, :enum, [allowed: :open]},
    {:op, :enum, [allowed: ~w(select insert update delete none)a]},
    {:table, :opaque_id, []},
    {:row_count, :number, []},
    {:duration_ms, :number, []},
    {:queue_depth, :number, []}
  ]

  @doc "The list of bounded (permitted-at-sink) field types."
  @spec bounded_types() :: [atom()]
  def bounded_types, do: @bounded_types

  @doc "Known forbidden type atoms (for precise diagnostics; the check rejects ANY non-bounded type)."
  @spec known_forbidden_types() :: [atom()]
  def known_forbidden_types, do: @known_forbidden

  @doc "The canonical wide-event field schema (doc §runs 4b)."
  @spec canonical_fields() :: [field_spec()]
  def canonical_fields, do: @canonical_fields

  @doc "The set of declared field names (atoms)."
  @spec field_names() :: MapSet.t(atom())
  def field_names, do: @canonical_fields |> Enum.map(&elem(&1, 0)) |> MapSet.new()

  @doc "Is `type` a bounded (permitted-at-sink) type?"
  @spec bounded_type?(atom()) :: boolean()
  def bounded_type?(type), do: type in @bounded_types

  @doc """
  Look up a field's spec by name. Returns `{:ok, {name, type, opts}}` or `:error`.
  """
  @spec fetch(atom()) :: {:ok, field_spec()} | :error
  def fetch(name) when is_atom(name) do
    case Enum.find(@canonical_fields, fn {n, _t, _o} -> n == name end) do
      nil -> :error
      spec -> {:ok, spec}
    end
  end

  @doc """
  Validate the SCHEMA ITSELF — the J2 build-time check (`mix samen.verify.sink_schema`).

  Returns a list of violation strings (empty = clean). A field is a violation iff:

    * its declared type is not a bounded type (`:string`/`:binary`/`:map`/… — the
      name-carrier surface), OR
    * it is an `:enum` with no closed `allowed:` set (an open enum could carry an
      arbitrary label — it must enumerate its values, `allowed: :open` being the
      ONE reserved sentinel for `action`, whose closed set is enforced at emit
      via `Samen.WideEvent.action_allowed?/1`).

  This is a **pure function over the declared schema** so the mix task and tests
  drive it identically. It also accepts an override field list (used by red-path
  tests to prove the check catches a seeded string field WITHOUT mutating the
  real schema).
  """
  @spec violations([field_spec()]) :: [String.t()]
  def violations(fields \\ @canonical_fields) do
    Enum.flat_map(fields, &field_violations/1)
  end

  defp field_violations({name, type, opts}) do
    cond do
      not bounded_type?(type) ->
        [
          "field #{inspect(name)} is typed #{inspect(type)} — a FORBIDDEN (name-carrier) " <>
            "type. Wide-event/span fields must be one of #{inspect(@bounded_types)} " <>
            "(bounded ID / token / enum / number). A #{inspect(type)} field could carry a " <>
            "laundered plaintext PII value into the trace sink (doc §runs 4b, J2)."
        ]

      type == :enum and not valid_enum_opts?(opts) ->
        [
          "enum field #{inspect(name)} declares no closed `allowed:` set. An open enum " <>
            "could carry an arbitrary label — declare `allowed: [..]` (or the reserved " <>
            "`allowed: :open` sentinel whose closed set is enforced at emit)."
        ]

      true ->
        []
    end
  end

  defp field_violations(other) do
    ["malformed field spec #{inspect(other)} — expected {name, type, opts}."]
  end

  # A valid enum declares either a non-empty closed list, or the reserved :open
  # sentinel (used ONLY for :action, whose set is enforced at emit time).
  defp valid_enum_opts?(opts) do
    case Keyword.get(opts, :allowed) do
      :open -> true
      [_ | _] -> true
      _ -> false
    end
  end
end
