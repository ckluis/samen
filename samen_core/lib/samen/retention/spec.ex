defmodule Samen.Retention.Spec do
  @moduledoc """
  One per-resource retention rule (F3.2). See `Samen.Retention`.

    * `:resource`        — the Ash resource module whose rows are swept.
    * `:ttl_seconds`     — positive integer; rows older than this are expired. A
      non-positive / non-integer value is REFUSED at sweep time (fail-closed).
    * `:action`          — `:shred` (crypto-shred each expired row's subject) or
      `:delete` (hard-delete the expired row).
    * `:timestamp_field` — the retention clock (default `:inserted_at`).
    * `:subject_field`   — REQUIRED for `:shred`; the attribute holding the subject id
      to crypto-shred (default `:subject_id`).
    * `:org_field`       — the attribute carrying the row's owning org (default
      `:org_id`). A `:shred` sweep threads this org into `Samen.Erasure.shred/2` so the
      erasure event rides the TENANT's T4.3 chain (ADR-002), not the reserved
      `"__global__"` operator/system chain (D5 / ADR-046 §4.4). Config, not a DB
      column — every subject-bearing resource already carries the injected `org_id`.
  """

  @enforce_keys [:resource, :ttl_seconds, :action]
  defstruct resource: nil,
            ttl_seconds: nil,
            action: nil,
            timestamp_field: :inserted_at,
            subject_field: :subject_id,
            org_field: :org_id

  @type t :: %__MODULE__{
          resource: module(),
          ttl_seconds: pos_integer() | any(),
          action: :shred | :delete,
          timestamp_field: atom(),
          subject_field: atom(),
          org_field: atom()
        }

  @doc "Coerce a plain map/keyword spec into a `%Spec{}` with defaults filled."
  @spec normalize(t() | map() | keyword()) :: t()
  def normalize(%__MODULE__{} = spec), do: spec

  def normalize(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      resource: Map.fetch!(attrs, :resource),
      ttl_seconds: Map.fetch!(attrs, :ttl_seconds),
      action: Map.fetch!(attrs, :action),
      timestamp_field: Map.get(attrs, :timestamp_field, :inserted_at),
      subject_field: Map.get(attrs, :subject_field, :subject_id),
      org_field: Map.get(attrs, :org_field, :org_id)
    }
  end
end
