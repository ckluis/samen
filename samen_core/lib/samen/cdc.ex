defmodule Samen.Cdc do
  @moduledoc """
  The **optional ClickHouse CDC tier** (plan T6.5; doc §data "The data tier",
  §runs oracle block). The analytics mirror — opt-in per product, default off.

  > The optional upgrade. When a specific product outgrows Postgres analytics,
  > flip on the managed clickhouse.com path: native CDC (ClickPipes/PeerDB)
  > mirrors the append-only event stream into ClickHouse, queried via a second
  > Ecto repo (ecto_ch). live = Postgres, analytics = ClickHouse, seconds-stale.
  > It is not free … so it is opt-in per product, default off. Most products never
  > turn it on. The rule that keeps both honest: **never read a "current" value
  > from the analytics tier.** (doc line 635)

  ## The token-only-downstream invariant is what makes the mirror safe

  > The CDC mirror … carry vault tokens, not plaintext PII. … The CDC pipe
  > deliberately carries token-blind rows, so the analytics plane inherits erasure
  > for free instead of forking a second compliance surface. (doc line 637)

  So the mirror **never** carries plaintext PII. It carries: vault-FK `vt_*`
  tokens, bounded IDs, enums, timestamps, and numbers. Destroying a subject's
  external-KMS key renders the subject's vault ciphertext undecryptable across the
  live, replica, backup/PITR, **CDC-mirror**, rollup, and audit tiers *at once* —
  the mirror inherits erasure for free because it never held a decryptable copy.

  ## What this module IS and is NOT (honest edge)

  There is **no ClickHouse in this environment** (plan HARD note). So T6.5 ships
  the *mechanism* + a *faithful local simulation* + a *production skeleton*, never
  a fake pass:

    * `Samen.Cdc` — this behaviour: the contract a CDC adapter implements
      (`ensure_mirror/2`, `mirror_row/4`, `mirror_table/3`, `mirrored_columns/2`,
      `scan_no_plaintext/2`, `read_current/3`).
    * `Samen.Cdc.Projection` — the **token-blind projection**: given a resource /
      catalog, compute exactly the columns that may be mirrored, and REFUSE any
      `pii_` plaintext column. This is the load-bearing safety mechanism; it is
      adapter-independent.
    * `Samen.Cdc.LocalPostgres` — a FAITHFUL LOCAL SIMULATION: mirrors the
      projection into a second local Postgres schema (`cdc_mirror`) standing in for
      ClickHouse. Proves the projection excludes `pii_` plaintext columns and that
      post-shred the mirror holds only dangling tokens.
    * `Samen.Cdc.ClickHouse` — a PRODUCTION SKELETON (`ecto_ch`, config-flagged,
      NOT connected in this repo): the real ClickPipes-fed second Ecto repo shape,
      with the operator-TODO seam documented inline.

  ## Opt-in / default off

  `Samen.Cdc.enabled?/0` is false unless the host explicitly wires an adapter via
  `config :samen_core, :cdc, adapter: …, repo: …`. When disabled, the whole tier
  is inert: the destruction oracle's `cdc_mirror` tier emits a `:pass` stating the
  mirror is off, and nothing mirrors. See `Samen.Cdc.Config`.

  ## The never-read-current rule

  The analytics mirror is *seconds-stale* by construction — it must NEVER be the
  source of a "current" value (a value the app reads back and acts on). This is
  enforced two ways: (1) `read_current/3` on the behaviour ALWAYS raises (there is
  no legitimate current-read against the analytics tier), and (2) a build-time lint
  (`mix samen.verify.never_read_current`) flags any code that queries the CDC repo
  outside an analytics/reporting context. See `Samen.Cdc.NeverReadCurrent`.
  """

  alias Samen.Cdc.Config

  @typedoc "A CDC adapter module implementing this behaviour."
  @type adapter :: module()

  @typedoc """
  A projected column safe to mirror: `{column_name, kind}` where `kind` is one of
  `:token | :bounded_id | :enum | :timestamp | :number | :metadata`.
  """
  @type projected_column :: {String.t(), atom()}

  @doc """
  Ensure the mirror table for `table` exists with the token-blind `columns`
  projection. Idempotent. Returns `:ok` or `{:error, reason}`.
  """
  @callback ensure_mirror(table :: String.t(), columns :: [projected_column()]) ::
              :ok | {:error, term()}

  @doc """
  Mirror one row's token-blind projection into the mirror table. `values` is a map
  of `column_name => value` restricted to the projected columns.
  """
  @callback mirror_row(
              table :: String.t(),
              columns :: [projected_column()],
              values :: map(),
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @doc """
  The physical columns that currently exist on the mirror table (for the oracle's
  token-only assertion). Returns `{:ok, [column_name]}` or `{:error, reason}`.
  """
  @callback mirrored_columns(table :: String.t(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Oracle scan: does any row in the mirror for `subject_id` carry a decryptable
  plaintext value? A token-blind mirror ALWAYS answers `{:ok, :no_plaintext}` —
  it holds only `vt_*` tokens whose ciphertext lives in the (shredded) vault, so
  the mirror has nothing to decrypt. Returns `{:leaks, details}` if the mirror
  ever grew a plaintext column (a projection bug the oracle must catch).
  """
  @callback scan_no_plaintext(subject_id :: String.t(), opts :: keyword()) ::
              {:ok, :no_plaintext} | {:leaks, [String.t()]}

  @doc """
  ALWAYS raises. There is no legitimate "current"-value read against the analytics
  tier — it is seconds-stale by construction. Exists as a poisoned chokepoint so a
  caller reaching for a current value from the mirror fails loudly at runtime, in
  addition to the build-time `never_read_current` lint.
  """
  @callback read_current(table :: String.t(), key :: term(), opts :: keyword()) :: no_return()

  # ---------------------------------------------------------------------------
  # Facade
  # ---------------------------------------------------------------------------

  @doc "Is the CDC mirror tier enabled (an adapter wired)? Default off."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

  @doc "The configured CDC adapter module, or `nil` when the tier is off."
  @spec adapter() :: adapter() | nil
  def adapter, do: Config.adapter()

  @doc """
  Ensure a mirror table for `resource` (or an explicit `{table, columns}`).

  When the tier is off, this is a no-op returning `{:ok, :disabled}` — the whole
  point of default-off is that a product that never turns it on pays nothing.
  """
  @spec ensure_mirror_for(module() | {String.t(), [projected_column()]}) ::
          :ok | {:ok, :disabled} | {:error, term()}
  def ensure_mirror_for(resource_or_table) do
    if enabled?() do
      {table, columns} = normalize(resource_or_table)
      adapter().ensure_mirror(table, columns)
    else
      {:ok, :disabled}
    end
  end

  @doc """
  Mirror a row for `resource` given its full `values` map. Only the token-blind
  projected columns are forwarded — plaintext PII columns are dropped by the
  projection (they are not even representable in the mirror table). No-op when off.
  """
  @spec mirror(module() | {String.t(), [projected_column()]}, map(), keyword()) ::
          :ok | {:ok, :disabled} | {:error, term()}
  def mirror(resource_or_table, values, opts \\ []) do
    if enabled?() do
      {table, columns} = normalize(resource_or_table)
      keep = ["cdc_subject_id", :cdc_subject_id | Enum.map(columns, &elem(&1, 0))]
      projected = Map.take(values, keep)
      adapter().mirror_row(table, columns, projected, opts)
    else
      {:ok, :disabled}
    end
  end

  @doc "Oracle scan delegate — `{:ok, :no_plaintext}` when the tier is off."
  @spec scan_no_plaintext(String.t(), keyword()) :: {:ok, :no_plaintext} | {:leaks, [String.t()]}
  def scan_no_plaintext(subject_id, opts \\ []) do
    if enabled?(), do: adapter().scan_no_plaintext(subject_id, opts), else: {:ok, :no_plaintext}
  end

  @doc "Mirrored physical columns delegate — `{:ok, []}` when the tier is off."
  @spec mirrored_columns(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def mirrored_columns(table, opts \\ []) do
    if enabled?(), do: adapter().mirrored_columns(table, opts), else: {:ok, []}
  end

  defp normalize({table, columns}) when is_binary(table) and is_list(columns),
    do: {table, columns}

  defp normalize(resource) when is_atom(resource) do
    {Samen.Cdc.Projection.table_name(resource), Samen.Cdc.Projection.project(resource)}
  end
end
