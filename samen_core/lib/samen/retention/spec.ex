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
    * `:storage`         — the file-storage adapter for a `:delete` sweep of a
      `storage_key`-bearing (blob-backed) resource (default `Samen.Files.Storage.Local`).
      A `:delete` purge of a blob-backed resource routes each expired row's blob through
      the governed, ref-counted `Samen.Files.delete_file/3` chokepoint (never a raw
      destroy that orphans the bytes — ADR-046 §8 residual #3); this names the adapter.
    * `:storage_config`  — the adapter config map for that governed delete (default `%{}`,
      e.g. `%{root: "/var/lib/app/files"}` for `Local`). Config, not a DB column.
  """

  @enforce_keys [:resource, :ttl_seconds, :action]
  defstruct resource: nil,
            ttl_seconds: nil,
            action: nil,
            timestamp_field: :inserted_at,
            subject_field: :subject_id,
            org_field: :org_id,
            storage: Samen.Files.Storage.Local,
            storage_config: %{}

  @type t :: %__MODULE__{
          resource: module(),
          ttl_seconds: pos_integer() | any(),
          action: :shred | :delete,
          timestamp_field: atom(),
          subject_field: atom(),
          org_field: atom(),
          storage: module(),
          storage_config: map()
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
      org_field: Map.get(attrs, :org_field, :org_id),
      storage: Map.get(attrs, :storage, Samen.Files.Storage.Local),
      storage_config: Map.get(attrs, :storage_config, %{})
    }
  end
end
