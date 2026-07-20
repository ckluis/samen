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
  """

  @enforce_keys [:resource, :ttl_seconds, :action]
  defstruct resource: nil,
            ttl_seconds: nil,
            action: nil,
            timestamp_field: :inserted_at,
            subject_field: :subject_id

  @type t :: %__MODULE__{
          resource: module(),
          ttl_seconds: pos_integer() | any(),
          action: :shred | :delete,
          timestamp_field: atom(),
          subject_field: atom()
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
      subject_field: Map.get(attrs, :subject_field, :subject_id)
    }
  end
end
