defmodule Samen.Fleet.NonceCache do
  @moduledoc """
  The replay-bound nonce cache (ADR-044 §4.4): a `nonce` seen inside the 600s TTL
  window ⇒ `409` (replay). ETS-backed, ETS-owner auto-started (the
  `Samen.Web.RateLimit`/`Samen.FeatureFlags.Cache` house pattern), so it works even
  outside a full application supervision tree in a unit test.
  """

  @table __MODULE__
  @ttl_s 600

  @doc """
  Record `{kid, nonce}` as seen. Returns `:ok` (first use) or `{:error, :replayed}`
  (seen within the TTL window).
  """
  @spec check_and_put(String.t(), String.t()) :: :ok | {:error, :replayed}
  def check_and_put(kid, nonce) when is_binary(kid) and is_binary(nonce) do
    ensure_started()
    key = {kid, nonce}
    now = System.monotonic_time(:second)
    sweep(now)

    case :ets.insert_new(@table, {key, now}) do
      true -> :ok
      false -> {:error, :replayed}
    end
  end

  @doc "Test support: clear all recorded nonces."
  @spec reset() :: :ok
  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp sweep(now) do
    cutoff = now - @ttl_s
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
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
