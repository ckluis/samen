defmodule Samen.BreakGlass.AnchorRow do
  @moduledoc """
  Tracks which local break-glass entries have been anchored into the central T4.3
  chain (T4.4 clause (b)). One row per anchored local entry, keyed by the local
  entry's content hash (`brc_local_hash`, UNIQUE) so reconciliation is idempotent —
  a re-run never double-anchors.

  Abbrev-prefixed (`brc_*`) per the self-qualifying-storage idiom. Token-only: local
  hash, local seq, org/subject/actor/correlation ids — never plaintext.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true, source: :brc_id}
  schema "brc_break_glass_anchor" do
    field(:local_hash, :string, source: :brc_local_hash)
    field(:local_seq, :integer, source: :brc_local_seq)
    field(:org_id, :string, source: :brc_org_id)
    field(:subject_id, :string, source: :brc_subject_id)
    field(:actor_id, :string, source: :brc_actor_id)
    field(:correlation_id, :string, source: :brc_correlation_id)
    field(:anchored_at, :utc_datetime_usec, source: :brc_anchored_at)
  end
end
