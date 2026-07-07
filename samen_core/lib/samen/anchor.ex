defmodule Samen.Anchor do
  @moduledoc """
  The WORM anchor behaviour (T4.3; ADR-002 §3.1).

  Periodically the audit chain **head** for each org (the highest `(seq, hash)`) is
  sealed into an **external write-once store**. The anchor is the out-of-band root of
  trust that catches a *wholesale-rewrite* of the DB chain: an attacker who drops
  `aud_chain` and rebuilds it from scratch with a doctored past produces a live chain
  whose entry at the sealed `seq` has a different hash than the sealed head — but they
  cannot rewrite the sealed head, because it lives in a store they do not control. So
  `Samen.AuditChain.verify_against_anchor/2` catches the rewrite even though the rebuilt
  chain internally `verify_chain`s clean (ADR-002 §3.3).

  An anchor record is a plain map:

      %{org_id: String.t(), seq: non_neg_integer(), hash: String.t(), sealed_at: DateTime.t()}

  ## Adapters (ADR-002 §3.2)

    * `Samen.Anchor.LocalWorm` — a **faithful** append-only-file WORM stand-in
      (`O_APPEND` + fsync + verify-on-read). The default in dev/test.
    * `Samen.Anchor.S3ObjectLock` — the **production skeleton**: S3 Object Lock in
      COMPLIANCE mode. Compiles, implements the shape, every network call guarded behind
      `config :samen_core, :anchor_s3_enabled` (default false) and raises a clear
      `operator TODO` if invoked without credentials. NOT exercised in CI — no AWS
      account is required (plan HARD rule).

  Configure the active adapter with `config :samen_core, :anchor_adapter, Mod`. Defaults
  to `Samen.Anchor.LocalWorm`.
  """

  @typedoc "A sealed chain-head anchor record."
  @type anchor :: %{
          org_id: String.t(),
          seq: non_neg_integer(),
          hash: String.t(),
          sealed_at: DateTime.t()
        }

  @doc """
  Seal an anchor record into the write-once store. Returns `{:ok, receipt}` where the
  receipt is adapter-specific (a line number, an S3 version id, …) or `{:error, term}`.
  A seal NEVER overwrites a prior anchor for the same org — it appends; the newest head
  for an org is the last sealed anchor (adapters MUST honor append-only semantics).
  """
  @callback seal(anchor()) :: {:ok, term} | {:error, term}

  @doc """
  Read the CURRENT (newest, highest-seq) sealed head for `org_id`. `{:ok, :none}` when
  nothing has been sealed for the org yet.
  """
  @callback read_head(org_id :: String.t()) :: {:ok, anchor() | :none} | {:error, term}

  @doc "List the current sealed head for every org (one per org)."
  @callback list_heads() :: {:ok, [anchor()]} | {:error, term}

  @doc """
  True iff the store is a genuine append/write-once store (the anchor's tamper-defense
  is only as strong as this). `LocalWorm` returns `true` (append-only file, in-file edit
  detection); `S3ObjectLock` returns `true` (compliance-mode retention). An in-memory or
  overwritable store MUST return `false`.
  """
  @callback worm?() :: boolean()

  @doc """
  The configured anchor adapter. Defaults to `Samen.Anchor.LocalWorm`.
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:samen_core, :anchor_adapter, Samen.Anchor.LocalWorm)
  end
end
