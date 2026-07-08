defmodule Samen.Cdc.Projection do
  @moduledoc """
  The **token-blind projection** — the load-bearing safety mechanism of the CDC
  tier (plan T6.5; doc line 637 "The CDC pipe deliberately carries token-blind
  rows").

  Given an Ash resource (or a raw `{table, columns}` spec), compute exactly the
  set of columns that may be mirrored into the analytics tier. The rule:

    * a **vault-routed** storage column carries a `vt_*` token → mirror it (kind
      `:token`);
    * a structurally-non-PII scalar (bounded ID / enum / timestamp / number /
      metadata, per `Samen.Pii.Classification`) → mirror it;
    * a **plaintext PII** column → **REFUSE**. It is not projected, and
      `assert_no_plaintext!/1` RAISES on it. A plaintext PII column in the CDC
      projection is exactly the red path the oracle's `cdc_mirror` tier catches.

  The classifier is the SAME mask-unknown-by-default oracle the C4/C5 verifiers use
  (`Samen.NoPlaintextPii.Context.plaintext_pii_type?/1`) — an unknown/custom type
  is treated as PII (fail safe), never waved into the mirror.

  ## Why this is adapter-independent

  The projection is pure structure — it depends only on the resource's declared
  attributes and the PII classification, NOT on ClickHouse vs the local Postgres
  simulation. So the *same* projection proof holds whether the mirror is the local
  `cdc_mirror` schema (this environment) or a real ClickHouse table (production).
  That is what makes the local simulation faithful rather than a toy.
  """

  alias Samen.Pii.Info, as: PiiInfo
  alias Samen.NoPlaintextPii.Context

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
  @spec project(module()) :: [column()]
  def project(resource) do
    resource
    |> classify_columns()
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
  @spec assert_no_plaintext!(module(), [String.t()] | :all) :: :ok
  def assert_no_plaintext!(resource, requested \\ :all) do
    classified = classify_columns(resource)
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
    * `:plaintext_pii`— a plaintext PII column (REFUSED from the mirror);
    * `:bounded_id | :enum | :timestamp | :number | :metadata` — safe scalars.

  Exposed for the oracle + tests to inspect the full classification, including the
  refused columns.
  """
  @spec classify_columns(module()) :: [column()]
  def classify_columns(resource) do
    table = table_name(resource)
    vault_routed = vault_routed_set(resource, table)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(fn attr ->
      col = to_string(attr.source || attr.name)
      kind = classify(col, attr.type, vault_routed)
      {col, kind}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # A vault-routed storage column is a token by construction — always safe.
  # Otherwise the DECLARED Ash type decides: plaintext-PII types are refused;
  # everything the shared classifier calls non-PII is a safe scalar we bucket into
  # a coarse projection kind (bounded_id / enum / timestamp / number / metadata).
  defp classify(col, type, vault_routed) do
    cond do
      MapSet.member?(vault_routed, col) -> :token
      Context.plaintext_pii_type?(type) -> :plaintext_pii
      true -> scalar_kind(type)
    end
  end

  defp scalar_kind(type) do
    short = type |> inspect() |> String.trim_leading("Ash.Type.") |> String.downcase()

    cond do
      String.contains?(short, "uuid") -> :bounded_id
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
end
