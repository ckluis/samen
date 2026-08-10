defmodule Samen.Fleet.Attention do
  @moduledoc """
  A minimal, ETS-backed in-process log for cockpit-side `attention` signals raised
  OUTSIDE a report payload — today, exactly `:heartbeat_rejected` (ADR-044 §4.4a):
  a burst of signature-invalid heartbeat traffic against one `kid` raises an entry
  here, so the cockpit can render *"being flooded"* rather than a silent *"stale"*
  (T84 wires this into the rendered attention list; this module is the registry-
  layer signal it reads).

  Deliberately NOT `flt_report`-shaped or persisted: this is an OPERATIONAL signal
  about the wire, not part of any app's reported business state, and does not need
  to survive a cockpit restart to be useful (a fresh flood raises a fresh entry).
  """

  @table __MODULE__

  @type entry :: %{kind: atom(), key: String.t(), at: DateTime.t(), detail: map()}

  @doc """
  Raise an attention entry of `kind` for `key` (e.g. an app_id / kid), with an optional
  `detail` map (P10, ADR-044 §4.6) carrying the accountable identity — e.g. the operator id
  that published a directive, or the `fleet_revision`/target of a forged push. Kept in the
  entry so the cockpit renders *who* alongside *what*, not just a bare signal.
  """
  # Phase-6 EDGE-LOW L6 — the ETS table is `:set` (never `:bag`/`:duplicate_bag`),
  # keyed on `{kind, key}` (see `ensure_started/0` below). This makes
  # `raise_entry/3` idempotent-by-key BY CONSTRUCTION: a repeat call for the
  # SAME `{kind, key}` (e.g. a kid-holder flooding signature-invalid heartbeats
  # to keep re-tripping `:heartbeat_rejected` for one `kid`) OVERWRITES the
  # existing entry's timestamp/detail rather than inserting a second row.
  # `list/1`'s `:ets.tab2list/1` can therefore NEVER return more than ONE
  # `:heartbeat_rejected` entry per `kid`, no matter how many bad-signature
  # requests that kid's flood generates — a flood can refresh/keep-open the
  # ONE entry, never amplify it into N. If this module's table type or key
  # shape ever changes, this bound must be re-derived (see the L6 sabotage
  # twin + `fleet_ingress_test.exs`'s coalescing test, which fails loudly if
  # the bound is lost).
  @spec raise_entry(atom(), String.t(), map()) :: :ok
  def raise_entry(kind, key, detail \\ %{}) when is_atom(kind) and is_binary(key) and is_map(detail) do
    ensure_started()
    :ets.insert(@table, {{kind, key}, DateTime.utc_now(), detail})
    :ok
  end

  @doc "List attention entries, optionally filtered by kind."
  @spec list(atom() | nil) :: [entry()]
  def list(kind \\ nil) do
    ensure_started()

    :ets.tab2list(@table)
    |> Enum.map(fn {{k, key}, at, detail} -> %{kind: k, key: key, at: at, detail: detail} end)
    |> Enum.filter(fn entry -> is_nil(kind) or entry.kind == kind end)
  end

  @doc "Has `kind` been raised for `key`?"
  @spec raised?(atom(), String.t()) :: boolean()
  def raised?(kind, key) when is_atom(kind) and is_binary(key) do
    ensure_started()
    :ets.member(@table, {kind, key})
  end

  @doc "Test support: clear all entries."
  @spec reset() :: :ok
  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ensure_started do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
        rescue
          ArgumentError -> :ok
        end

        :ok

      _tid ->
        :ok
    end
  end
end
