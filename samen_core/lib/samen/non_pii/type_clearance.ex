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

  @doc """
  Is `module` cleared to honor its `:non_pii` self-classification?

  Returns `true` iff the app config carries at least one valid, two-distinct-party
  clearance naming `module`. Fail-closed for everything else (no config, malformed
  entry, self-review, non-module argument).
  """
  @spec cleared?(module()) :: boolean()
  def cleared?(module) when is_atom(module) and not is_nil(module) do
    Enum.any?(clearances(), &valid_clearance_for?(&1, module))
  end

  def cleared?(_), do: false

  @doc """
  The configured clearance entries (raw, unfiltered). A single map is wrapped into
  a list so a host that configures one clearance without a surrounding list still
  works. Defaults to `[]` when unconfigured.
  """
  @spec clearances() :: [term()]
  def clearances do
    Application.get_env(:samen_core, @config_key, [])
    |> List.wrap()
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
