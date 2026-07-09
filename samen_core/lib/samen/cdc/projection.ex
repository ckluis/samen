defmodule Samen.Cdc.Projection do
  @moduledoc """
  The **token-blind projection** — the load-bearing safety mechanism of the CDC
  tier (plan T6.5; doc line 637 "The CDC pipe deliberately carries token-blind
  rows").

  Given an Ash resource (or a raw `{table, columns}` spec), compute exactly the
  set of columns that may be mirrored into the analytics tier.

  ## Default-deny for freeform content (ADR-015 · G3)

  The classifier is **default-deny for freeform content types**. A column mirrors
  ONLY if it is on an explicit allowlist; the projection is an opt-*out* surface,
  not an opt-*in* heuristic. The rule, in precedence order:

    * a **vault-routed** storage column carries a `vt_*` token → mirror it (kind
      `:token`);
    * a **freeform content** column (`:string`/`:ci_string`/`:text`/`:map`/`:jsonb`,
      or any type NOT on the structural-safe allowlist) is **REFUSED** (kind
      `:plaintext_pii`) UNLESS it carries a verifier-backed `non_pii!` clearance
      (two distinct reviewers, `cleared_by != reviewed_by`) — in which case it
      mirrors as a safe scalar. A benign-named freeform column with no seed value
      (`drv_notes`, `owner_bio`) NO LONGER reaches the mirror by naming (ADR-015
      §1, harden H-2);
    * a **structural-safe scalar** (bounded ID / enum / timestamp / number / bool,
      per `Samen.Pii.Classification`) → mirror it (kind `:bounded_id | :enum |
      :timestamp | :number | :boolean`). This is the ONLY class that mirrors
      without an explicit allowlist entry — and the over-block guard (RP-G3-3)
      proves it is not swept up by the default-deny.

  A **plaintext PII** column that is not cleared is not projected, and
  `assert_no_plaintext!/1` RAISES on an explicit demand for it — exactly the red
  path the oracle's `cdc_mirror` tier catches.

  The classifier keys on the SAME mask-unknown-by-default oracle the C4/C5
  verifiers use (`Samen.NoPlaintextPii.Context.plaintext_pii_type?/1`) — an
  unknown/custom type is freeform → refused (fail safe), never waved into the
  mirror by a `:metadata` fall-through.

  ## Why this is adapter-independent

  The projection is pure structure — it depends only on the resource's declared
  attributes and the PII classification, NOT on ClickHouse vs the local Postgres
  simulation. So the *same* projection proof holds whether the mirror is the local
  `cdc_mirror` schema (this environment) or a real ClickHouse table (production).
  That is what makes the local simulation faithful rather than a toy.
  """

  alias Samen.Pii.Info, as: PiiInfo
  alias Samen.NoPlaintextPii.Context
  alias Samen.NonPii

  @typedoc "A projected column: `{column_name, kind}`."
  @type column :: {String.t(), atom()}

  defmodule PlaintextInProjectionError do
    @moduledoc """
    Raised when a plaintext PII column reaches the CDC projection — the token-only-
    downstream invariant is broken. This is the mechanism that fails the build
    (and the oracle's `cdc_mirror` tier) rather than silently mirroring a name.
    """
    defexception [:message]
  end

  @doc "The physical table name for `resource` (delegates to the catalog)."
  @spec table_name(module()) :: String.t() | nil
  def table_name(resource) do
    AshPostgres.DataLayer.Info.table(resource)
  rescue
    _ -> nil
  end

  @doc """
  Compute the token-blind projection for `resource`.

  Returns the list of `{column_name, kind}` that are SAFE to mirror. Plaintext PII
  columns are excluded (they are not mirrored). Use `assert_no_plaintext!/1` when
  you want a HARD failure on any plaintext PII column rather than a silent drop —
  the CDC pipeline and the oracle both assert.
  """
  @spec project(module(), keyword()) :: [column()]
  def project(resource, opts \\ []) do
    resource
    |> classify_columns(opts)
    |> Enum.reject(fn {_col, kind} -> kind == :plaintext_pii end)
  end

  @doc """
  Assert a SET of columns requested for the mirror carries NO plaintext PII.
  Returns `:ok` or RAISES `PlaintextInProjectionError`.

  This is the fail-closed entry point for the *explicit* case: an operator (or the
  real ClickPipes allow-list) names the columns to mirror. If any named column is a
  plaintext PII column, the request is refused — a plaintext column must not reach
  the analytics tier. `project/1` already excludes plaintext columns silently; this
  is for when a plaintext column is *explicitly demanded* into the pipe (the red
  path the oracle catches).

  `requested` is a list of column-name strings. Defaults to the resource's FULL
  physical column set — so `assert_no_plaintext!(resource)` answers "is it safe to
  mirror ALL columns of this resource verbatim?" (false whenever it has any
  un-vaulted plaintext string).
  """
  @spec assert_no_plaintext!(module(), [String.t()] | :all, keyword()) :: :ok
  def assert_no_plaintext!(resource, requested \\ :all, opts \\ []) do
    classified = classify_columns(resource, opts)
    by_col = Map.new(classified)

    cols =
      case requested do
        :all -> Enum.map(classified, &elem(&1, 0))
        list -> list
      end

    leaks = Enum.filter(cols, fn c -> Map.get(by_col, c) == :plaintext_pii end)

    if leaks != [] do
      raise PlaintextInProjectionError,
        message:
          "CDC mirror request for #{inspect(resource)} (#{table_name(resource)}) names " <>
            "plaintext PII column(s): #{Enum.join(leaks, ", ")}. The mirror carries " <>
            "token-blind rows ONLY (doc line 637) — route these through the vault " <>
            "(pii_attribute) so the mirror sees a vt_* token, or classify them non_pii!. " <>
            "Refusing to mirror plaintext into analytics."
    end

    :ok
  end

  @doc """
  Classify every physical column of `resource` into a projection kind:

    * `:token`        — a vault-routed storage column (holds a `vt_*` token);
    * `:plaintext_pii`— a plaintext / freeform PII column (REFUSED from the mirror);
    * `:bounded_id | :enum | :timestamp | :number | :boolean` — structural-safe
      scalars, OR a freeform column that carries a two-reviewer `non_pii!` clearance.

  Exposed for the oracle + tests to inspect the full classification, including the
  refused columns.

  Options:
    * `:non_pii_entries` — inject the `non_pii!` registry entries (a list of
      `%Samen.NonPii.Entry{}` or maps with `:table_name`/`:column_name`/`:cleared_by`/
      `:reviewed_by`). Bypasses the DB registry lookup — used by tests. When absent,
      the live `Samen.NonPii.entries/0` registry is consulted (fail-closed to `[]`).
  """
  @spec classify_columns(module(), keyword()) :: [column()]
  def classify_columns(resource, opts \\ []) do
    table = table_name(resource)
    vault_routed = vault_routed_set(resource, table)
    non_pii_cleared = non_pii_cleared_set(table, opts)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(fn attr ->
      col = to_string(attr.source || attr.name)
      kind = classify(col, attr.type, vault_routed, non_pii_cleared)
      {col, kind}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # Default-deny classifier (ADR-015 §2). Precedence:
  #
  #   1. vault-routed        -> :token   (a vt_* token by construction — always safe)
  #   2. structural-safe     -> scalar_kind/1 (bounded_id/enum/timestamp/number/bool)
  #      — the ONLY class that mirrors without an explicit allowlist entry.
  #   3. freeform + cleared  -> scalar_kind/1 (the `non_pii!` two-reviewer allowlist)
  #   4. everything else freeform -> :plaintext_pii  (DEFAULT DENY)
  #
  # Structural-safe is checked BEFORE the freeform refuse so IDs/enums/dates/
  # numbers/bools are NEVER swept up by the default-deny (the RP-G3-3 over-block
  # guard). Freeform types (string/text/map/jsonb + any unknown/custom type) reach
  # step 3/4: they mirror ONLY with a distinct-two-reviewer `non_pii!` clearance,
  # never by benign naming or a `:metadata` fall-through (harden H-2).
  defp classify(col, type, vault_routed, non_pii_cleared) do
    cond do
      MapSet.member?(vault_routed, col) -> :token
      structural_safe?(type) -> scalar_kind(type)
      MapSet.member?(non_pii_cleared, col) -> scalar_kind(type)
      true -> :plaintext_pii
    end
  end

  # A type is structural-safe iff the shared mask-unknown-by-default classifier
  # says it is NOT plaintext PII: bounded id (uuid), enum (atom), timestamp
  # (utc/naive datetime, time), number (integer/float/decimal), boolean. Everything
  # the classifier calls PII — string/ci_string/text/map/jsonb and every unknown or
  # custom type — is FREEFORM and falls to the default-deny branch. Vault-routed
  # token columns are handled earlier; a raw `VaultField` type is also non-PII here.
  defp structural_safe?(type), do: not Context.plaintext_pii_type?(type)

  # Bucket a structural-safe (or cleared-freeform) type into a coarse projection
  # kind. `:metadata` is NO LONGER a default-allow fall-through — an unrecognized
  # type never reaches here as freeform (default-deny caught it upstream); a
  # `non_pii!`-cleared freeform string lands in `:metadata` as an explicitly-cleared
  # safe scalar.
  defp scalar_kind(type) do
    short = type |> inspect() |> String.trim_leading("Ash.Type.") |> String.downcase()

    cond do
      String.contains?(short, "uuid") -> :bounded_id
      String.contains?(short, "boolean") -> :boolean
      String.contains?(short, "atom") -> :enum
      String.contains?(short, "datetime") or String.contains?(short, "date") or
          String.contains?(short, "time") ->
        :timestamp

      String.contains?(short, "integer") or String.contains?(short, "float") or
          String.contains?(short, "decimal") ->
        :number

      true ->
        :metadata
    end
  end

  defp vault_routed_set(resource, table) do
    if table do
      resource
      |> PiiInfo.fields()
      |> Enum.map(fn field -> to_string(field.storage_name) end)
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  # The set of physical column names on `table` cleared by a VALID `non_pii!`
  # override (distinct second reviewer, `cleared_by != reviewed_by`). Same
  # distinct-party discipline the reveal grant + the C4 verifier enforce — a single
  # actor cannot wave a freeform column into the mirror.
  #
  # Entries may be injected via `opts[:non_pii_entries]` (tests); otherwise the live
  # `Samen.NonPii` registry is consulted, failing CLOSED to `[]` (no repo → no
  # clearances → default-deny holds) rather than opening the projection.
  defp non_pii_cleared_set(nil, _opts), do: MapSet.new()

  defp non_pii_cleared_set(table, opts) do
    (Keyword.get(opts, :non_pii_entries) || safe_registry_entries())
    |> Enum.filter(fn e ->
      to_string(e.table_name) == table and e.cleared_by != e.reviewed_by
    end)
    |> Enum.map(fn e -> to_string(e.column_name) end)
    |> MapSet.new()
  end

  defp safe_registry_entries do
    NonPii.entries()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
