defmodule Samen.NonPii.TypeClearance do
  @moduledoc """
  The reviewer-gated **type-level** `:non_pii` clearance registry (ADR-034; §limits
  keystone; sibling of `Samen.NonPii`).

  A host application can define a custom Ash type that self-classifies as `:non_pii`
  by exporting `samen_pii_class/0 => :non_pii`. That opts **every column of that
  type** out of masking (plaintext, unmasked) — a far broader lever than the
  per-column `non_pii!` override. Left ungoverned, it is a **single-party escape
  hatch**: one developer can wave a whole type out of the mask-unknown-by-default
  keystone with no second reviewer, whereas opting a single *column* out already
  requires the two-distinct-party clearance `Samen.NonPii.register/1` enforces.

  This module closes that asymmetry. A type's `:non_pii` self-classification is
  honored by `Samen.Pii.Classification.classify/1` **only** when the type module is
  named in a valid, two-distinct-party clearance — mirroring `Samen.NonPii`'s
  `cleared_by != reviewed_by` invariant. An ungoverned (or self-reviewed)
  `:non_pii` self-classification is treated as **PII** (masked) — fail-closed, the
  same safe direction the mask-unknown default already picks.

  ## Why config-based, not DB-backed

  Unlike the per-column `non_pii!` registry (`Samen.NonPii`, DB-backed, consulted
  by the erasure arm and the offline verifier), `classify/1` is a **hot, pure,
  compile-time-and-runtime** function: the `pii_classify` verifier calls it while
  compiling, and the read resolver calls it on every read. The clearance check
  must therefore be pure and cheap — it reads an application-config allowlist,
  never the database.

  ## Configuring a clearance

      config :samen_core, :non_pii_type_clearances, [
        %{
          type: MyApp.SomeNonPiiType,
          cleared_by: "alice",
          reviewed_by: "bob",
          reason: "opaque tenant-scoped enum token, never carries PII"
        }
      ]

  A clearance is **valid** for a module only when the entry:

    * names that exact `:type` module,
    * carries a non-blank `:cleared_by` AND a non-blank `:reviewed_by` that are
      **distinct** (`cleared_by != reviewed_by` — no self-review), and
    * carries a non-blank `:reason`.

  Any missing/blank key, a self-review, or a non-map entry makes the clearance
  invalid — fail-closed, so a malformed clearance leaves the type masked, never
  accidentally plain.
  """

  @config_key :non_pii_type_clearances

  # The foundry-SHIPPED clearance manifest (ADR-036 D1/D5): entries samen_core
  # itself carries, honored in EVERY host application with no per-host config
  # required (unlike a host's own `config :samen_core, :non_pii_type_clearances`,
  # which only that host's OWN config.exs would see — a library's config.exs is not
  # loaded by a dependent app). Two distinct, named parties per entry — the same
  # governed-opt-out discipline `valid_clearance_for?/2` enforces for host-supplied
  # entries below. `Samen.Type.Money` (H1) is the first: money is categorically
  # non-PII (a deal value / a price a tenant sets, not a subject's own data).
  @shipped_clearances [
    %{
      type: Samen.Type.Money,
      cleared_by: "fable (T12 orchestrator)",
      reviewed_by: "T11 (ADR-036 WS-H design review)",
      reason:
        "categorically non-PII financial scalar (a deal value / a tenant's price point, " <>
          "never a subject's own data); PII-shaped uses would route to the vault per " <>
          "ADR-036 D3, not through this type"
    },
    # ADR-036 D2/D5 (T13): the H2 bounded-scalar family and H3's URL — each a
    # categorically non-PII measurement/enum/link scalar. PII-shaped uses (e.g. a
    # personal-profile URL, ADR-036 §3 H3 caveat) route to the vault via
    # pii_attribute, never through a bare plaintext column of these types.
    %{
      type: Samen.Type.Percent,
      cleared_by: "fable (T13 orchestrator)",
      reviewed_by: "T11 (ADR-036 WS-H design review)",
      reason:
        "categorically non-PII measurement scalar (a completion rate / a discount " <>
          "percentage, never a subject's own data); PII-shaped uses route to the vault " <>
          "per ADR-036 D3, not through this type"
    },
    %{
      type: Samen.Type.Score,
      cleared_by: "fable (T13 orchestrator)",
      reviewed_by: "T11 (ADR-036 WS-H design review)",
      reason:
        "categorically non-PII measurement scalar (a health/lead score, an NPS rating, " <>
          "never a subject's own data); PII-shaped uses route to the vault per " <>
          "ADR-036 D3, not through this type"
    },
    %{
      type: Samen.Type.Duration,
      cleared_by: "fable (T13 orchestrator)",
      reviewed_by: "T11 (ADR-036 WS-H design review)",
      reason:
        "categorically non-PII measurement scalar (an SLA window, a task estimate, " <>
          "never a subject's own data); PII-shaped uses route to the vault per " <>
          "ADR-036 D3, not through this type"
    },
    %{
      type: Samen.Type.Priority,
      cleared_by: "fable (T13 orchestrator)",
      reviewed_by: "T11 (ADR-036 WS-H design review)",
      reason:
        "categorically non-PII ordered-enum scalar (a ticket/deal priority, never a " <>
          "subject's own data); PII-shaped uses route to the vault per ADR-036 D3, not " <>
          "through this type"
    },
    %{
      type: Samen.Type.URL,
      cleared_by: "fable (T13 orchestrator)",
      reviewed_by: "T11 (ADR-036 WS-H design review)",
      reason:
        "categorically non-PII link scalar (a marketing site / docs / webhook target, " <>
          "never a subject's own data) BY DEFAULT; a personal-identifying (profile) URL " <>
          "is the ADR-036 §3 H3 caveat and routes to the vault via pii_attribute, not " <>
          "through a bare plaintext column of this type"
    }
  ]

  @doc """
  Is `module` cleared to honor its `:non_pii` self-classification?

  Returns `true` iff the shipped manifest or the app config carries at least one
  valid, two-distinct-party clearance naming `module`. Fail-closed for everything
  else (no config, malformed entry, self-review, non-module argument).
  """
  @spec cleared?(module()) :: boolean()
  def cleared?(module) when is_atom(module) and not is_nil(module) do
    Enum.any?(clearances(), &valid_clearance_for?(&1, module))
  end

  def cleared?(_), do: false

  @doc """
  The clearance entries in effect: the foundry-shipped manifest (`@shipped_clearances`)
  followed by the configured entries (`config :samen_core, :non_pii_type_clearances`).
  A single map is wrapped into a list so a host that configures one clearance without
  a surrounding list still works. Configured entries default to `[]` when unconfigured.
  """
  @spec clearances() :: [term()]
  def clearances do
    @shipped_clearances ++
      (Application.get_env(:samen_core, @config_key, [])
       |> List.wrap())
  end

  defp valid_clearance_for?(%{} = clearance, module) do
    with {:ok, type} when type == module <- Map.fetch(clearance, :type),
         {:ok, cleared_by} <- present(clearance, :cleared_by),
         {:ok, reviewed_by} <- present(clearance, :reviewed_by),
         {:ok, _reason} <- present(clearance, :reason) do
      # The distinct-party invariant, identical in spirit to Samen.NonPii.register/1:
      # a single actor cannot wave a whole type out of masking.
      cleared_by != reviewed_by
    else
      _ -> false
    end
  end

  defp valid_clearance_for?(_not_a_map, _module), do: false

  # A required party/reason field must be present and non-blank. Mirrors the
  # `validate_required` discipline of the DB-backed `Samen.NonPii.register/1`,
  # which rejects a blank string as missing.
  defp present(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_binary(v) ->
        if String.trim(v) == "", do: :error, else: {:ok, v}

      _ ->
        :error
    end
  end
end
