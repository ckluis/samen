defmodule Samen.AI.Catalog do
  @moduledoc """
  The D9 runtime catalog (ADR-043 §8; T66) — grounding served LIVE instead of
  hand-maintained. "Grounding is generated, not hand-maintained: a runtime
  module/endpoint serves the live equivalent of `schema.dict.json`... Serving is
  plane-aware: PII classifications ship as metadata... sample values are never
  included."

  ## Two grounding sources, one org-invariant + one org-VARIANT (the hard
  ## invariant this ADR names: "grounding must never cross orgs")

    * `schema/1` — the STATIC resource catalog (tables → resources → fields, with
      the declaration-derived `pii` flag). This is compile-time Ash resource
      metadata: identical for every org (the same resource module compiles the
      same way regardless of which org is asking), so there is no ORG dimension
      to leak — the strongest form of org isolation for this half, the same
      argument ADR-043 §6.4 makes for the token-blind analytics schema ("no
      column to leak, so token-blind holds by schema, not by filter").
    * `custom_objects/2` — the org-VARIANT half: an org's own Tier-2
      `Samen.CustomObjects` catalog (object/field DEFINITIONS, never row data),
      which genuinely differs per org and is fetched org-scoped via
      `Samen.CustomObjects.list_objects/2` — a PARAMETERIZED Ecto query filter
      (`where tnt_org_id: ^org_id`) against the `org_id` this module is HANDED,
      **not** an `Ash.Policy.Authorizer`-mediated read and **not**
      `Samen.Policy.OrgScope` (that FilterCheck governs Ash-resource reads under
      an actor; `ObjectRow`/`FieldRow` are plain Ecto schemas queried directly,
      with no actor/policy layer in between). Org B's objects are never returned
      for org A's `org_id` because the query is filtered — the mechanism is
      "correct filter parameter", not "policy enforcement"; `grounding/2` does
      not itself authorize or validate the `org_id` it derives from `scope` (§
      `org_id_of/1`) — the CALLER is responsible for handing a `scope`/`org_id`
      that is already the actor's own (exactly as every other org-scoped read in
      this codebase requires of its caller). Field definitions already carry a
      declaration-driven `pii` flag (`Samen.CustomFields` rejects PII-shaped
      values at DEFINITION, T3.9), so this half is metadata-only exactly like the
      static catalog — never a sample/row value.

  `grounding/2` composes both into the bounded-label-atom map
  `Samen.AI.Chokepoint`'s `:grounding` opt expects (ADR-043 §3.1 EG1); T66 wires
  `Samen.AI.complete/4` to auto-populate it unless the caller overrides.

  ## RP-AI-8 — parity with `mix samen.catalog.dump` BY CONSTRUCTION

  `Mix.Tasks.Samen.Catalog.Dump.build_dict/1` DELEGATES to `dict/1` below — so the
  committed `schema.dict.json` artifact and this runtime catalog are the SAME
  function call, not two implementations kept in sync by discipline. "The catalog
  cannot drift from what the AI believes" is therefore structural, not merely
  tested (the parity test in `catalog_runtime_test.exs` still asserts it, as the
  contract — a future edit that forks the two paths would be caught immediately).

  ## No sample values, ever

  Every field entry here is `{column_name, logical_name, type, pii}` — never a
  value. There is no code path in this module that reads a ROW (the static half
  is pure `Ash.Resource.Info` introspection; the org-scoped half reads `tnt_field`
  DEFINITIONS, never `tnt_record` rows). A field's `pii` flag tells the model a
  field exists and is protected; it never tells it what the field contains.

  ## Fail-safe, not fail-closed (this is enrichment, not the security gate)

  A grounding-computation failure (no domains configured, no repo wired, a
  transient DB error) degrades to an empty/partial map rather than raising —
  `Samen.AI.complete/4` must not fail a completion because grounding could not be
  assembled. The security-critical guarantee — no vault-routed value or `vt_*`
  token in `:grounding`/`:meta` — is `Samen.AI.Chokepoint`'s OWN §3.2 step-3 scrub
  (T65-F8 close), which runs on whatever this module returns regardless.
  """

  alias Samen.CustomFields.FieldRow
  alias Samen.CustomObjects

  @doc """
  The pure schema-dict builder (ADR-043 §8 / T6.3): `resources` (a list of Ash
  resource modules) → the `schema.dict.json` shape —

      %{"tables" => [
        %{"table_name" => ..., "resource" => ..., "fields" => [
          %{"column_name" => ..., "logical_name" => ..., "type" => ..., "pii" => bool}
        ]}
      ]}

  Deterministic: tables sorted by `table_name`, fields sorted by `column_name`
  (via `Samen.Catalog.fields/1`). THE source of truth `mix samen.catalog.dump`
  delegates to (see moduledoc, RP-AI-8).

  T66-F4 fix-round (delta-verifier finding): a malformed ENTRY inside `resources`
  (not itself an Ash resource — e.g. `Enum`, `nil`, a plain string) degrades that
  ONE table to absent rather than raising out of the whole call — the same
  fail-safe-enrichment posture `custom_objects/2`/`grounding/2` already document.
  A non-list `resources` argument (violating this function's own contract) still
  raises `FunctionClauseError` at the call boundary — the malformed-element case
  is what a real caller (`schema/1`, a host's `:domains`/`:resources` opt) can
  actually produce; a wrong ARGUMENT TYPE is a programmer error at the call site,
  not a data-shape defense this function owns.
  """
  @spec dict([module()]) :: map()
  def dict(resources) when is_list(resources) do
    tables =
      resources
      |> Enum.map(&table_entry/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1["table_name"])

    %{"tables" => tables}
  end

  # One table entry, or `nil` if `resource` cannot be introspected as an Ash
  # resource (fail-safe per-entry degrade, T66-F4).
  defp table_entry(resource) do
    tam = Samen.Catalog.table(resource)
    flds = Samen.Catalog.fields(resource)
    pii_columns = pii_column_set(resource)

    %{
      "table_name" => tam.table_name,
      "resource" => tam.resource,
      "fields" =>
        Enum.map(flds, fn f ->
          %{
            "column_name" => f.column_name,
            "logical_name" => f.logical_name,
            "type" => f.type,
            "pii" => MapSet.member?(pii_columns, f.column_name)
          }
        end)
    }
  rescue
    _ -> nil
  end

  @doc """
  The static schema catalog for the CURRENT host's registered resources — the
  ≈0-LOC runtime entry point (INV-5): no arguments needed. Reads the SAME
  cross-host registry every verifier/gate already reads
  (`config :samen_core, :ash_domains`, set by every host's config.exs — demo /
  driftwood / pawchart already set it for `mix samen.verify.catalog_parity` and
  friends), so a host that has already registered its domains for the shipped
  verifiers gets grounding for free — no new authored line.

  Override with `:domains` (a list of domain modules) or `:resources` (resource
  modules directly) in `opts`.

  T66-F4 fix-round (delta-verifier finding): degrades to `%{"tables" => []}`
  rather than raising if RESOLVING the resource list itself fails (a malformed
  `:domains` entry, `Ash.Domain.Info.resources/1` raising) — `dict/1`'s own
  per-entry rescue (above) covers a malformed element inside an already-resolved
  list; this covers a failure resolving the list at all.
  """
  @spec schema(keyword()) :: map()
  def schema(opts \\ []) do
    dict(resources(opts))
  rescue
    _ -> %{"tables" => []}
  end

  defp resources(opts) do
    case Keyword.get(opts, :resources) do
      list when is_list(list) -> list
      _ -> opts |> domains() |> Samen.Catalog.resource_modules()
    end
  end

  defp domains(opts) do
    case Keyword.get(opts, :domains) do
      list when is_list(list) -> list
      _ -> Application.get_env(:samen_core, :ash_domains, [])
    end
  end

  @doc """
  The org-scoped Tier-2 custom-object catalog for `org_id` (moduledoc — the
  org-VARIANT half of grounding). Returns `[]` for a `nil` org_id (no actor org
  to scope to — fail-safe, never a cross-org guess) and `[]` on ANY lookup
  failure (unconfigured repo, DB unavailable) — grounding degrades, it never
  raises out of a completion call.

  Each entry: `%{object_key:, label:, fields: [%{name:, type:, pii:}]}` — object
  and field DEFINITIONS only, never a `tnt_record` row value. Disabled objects
  are excluded (a disabled object is not a live grounding source).
  """
  @spec custom_objects(String.t() | nil, keyword()) :: [map()]
  def custom_objects(org_id, opts \\ [])
  def custom_objects(nil, _opts), do: []

  def custom_objects(org_id, opts) when is_binary(org_id) do
    repo = Keyword.get(opts, :repo)

    org_id
    |> CustomObjects.list_objects(repo)
    |> Enum.filter(& &1.tnt_enabled)
    |> Enum.map(fn object ->
      %{
        object_key: object.tnt_object_key,
        label: object.tnt_label,
        fields: object_fields(org_id, object.tnt_object_key, repo)
      }
    end)
  rescue
    _ -> []
  end

  def custom_objects(_org_id, _opts), do: []

  defp object_fields(org_id, object_key, repo) do
    org_id
    |> CustomObjects.list_object_fields(object_key, repo)
    |> Enum.map(fn %FieldRow{} = f ->
      %{name: f.tnt_field_name, type: f.tnt_type, pii: f.tnt_pii_declared}
    end)
  rescue
    _ -> []
  end

  @doc """
  The full grounding metadata map for `scope` — the shape
  `Samen.AI.Chokepoint`'s `:grounding` opt expects (a map keyed by bounded label
  atoms, ADR-043 §8). `Samen.AI.complete/4` auto-populates this unless the caller
  supplies its own `:grounding`. Never raises (moduledoc — fail-safe enrichment);
  the chokepoint's own scrub (T65-F8) is what fail-CLOSES on unsafe content.
  """
  @spec grounding(term(), keyword()) :: map()
  def grounding(scope, opts \\ []) do
    %{schema: schema(opts), custom_objects: custom_objects(org_id_of(scope), opts)}
  rescue
    _ -> %{}
  end

  # `scope` is whatever the calling actor threads through `Samen.AI.complete/4` — a
  # bare atom (test scopes), a `%{plane: ...}` map (chokepoint actor shape), a plain
  # `%{org_id: ...}` map, or a real `%Samen.Scope{actor: %{org_id: ...}}`. Anything
  # that does not resolve to a binary org_id yields `nil` — fail-safe, never a guess.
  defp org_id_of(%Samen.Scope{actor: %{org_id: id}}) when is_binary(id), do: id
  defp org_id_of(%{actor: %{org_id: id}}) when is_binary(id), do: id
  defp org_id_of(%{org_id: id}) when is_binary(id), do: id
  defp org_id_of(_), do: nil

  # The set of physical storage column names that are vault-routed PII for this
  # resource, keyed on the `pii do` DECLARATION (not a `pii_` name prefix). A
  # non-Samen / non-PII resource contributes an empty set (fail-safe: absent =>
  # not-PII is never claimed for a vault-routed field). Mirrors
  # `Mix.Tasks.Samen.Catalog.Dump`'s prior private helper verbatim (moved here,
  # RP-AI-8).
  defp pii_column_set(resource) do
    resource
    |> Samen.Pii.Info.vault_routed_columns()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end
end
