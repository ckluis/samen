defmodule Samen.Billing.FakeMirror do
  @moduledoc """
  The in-memory `Samen.Billing.Mirror` test double (ADR-038 §7.2; T21/B3). Ships in lib
  per the "test infra ships in lib" house precedent (`Samen.RedPath`, `Samen.Factory`,
  `Samen.Billing.FakeProvider`).

  It is an honest mirror: it stores exactly what a real host mirror would (the
  subscription snapshot keyed by `provider_subscription_id`, its convergence watermark +
  last-applied event id, and per-subscription entitlement rows), so the
  `Samen.Billing.Reconciler`'s idempotency + out-of-order convergence are provable
  hermetically against it — no Postgres, no vendor credentials.

  ## Lifecycle

      {:ok, ref} = FakeMirror.start()
      FakeMirror.seed_entitlement(ref, "sub_123", :advanced_reporting)
      # ... drive Reconciler.reconcile(event, mirror: FakeMirror, mirror_ref: ref, ...)
      FakeMirror.get_subscription(ref, "sub_123")     # the mirrored snapshot
      FakeMirror.list_entitlements(ref, "sub_123")    # entitlement rows (expires_at set on grace)
      FakeMirror.change_count(ref)                     # how many write_snapshot/3 calls MUTATED state

  ## `change_count` — the idempotency witness

  `change_count/1` counts only writes that ACTUALLY changed the mirror. A duplicate /
  stale event is refused by the reconciler BEFORE `write_snapshot/3` is called, so a
  fixture replayed twice leaves `change_count` at 1 — the table-driven idempotency
  assertion (done-criterion 2). (The reconciler is the guard; the fake just records
  truthfully, so a REGRESSION that lets a stale event through shows up here as an extra
  change — anti-tautology.)
  """

  @behaviour Samen.Billing.Mirror

  @doc "Start a fresh in-memory mirror; returns `{:ok, ref}` (the ref is an Agent pid)."
  @spec start() :: {:ok, pid()}
  def start do
    Agent.start_link(fn -> %{subs: %{}, entitlements: %{}, changes: 0} end)
  end

  @doc "Start a fresh mirror, raising on failure; returns the ref directly (test sugar)."
  @spec new() :: pid()
  def new do
    {:ok, ref} = start()
    ref
  end

  @impl true
  def read_state(ref, provider_subscription_id) do
    state =
      Agent.get(ref, fn %{subs: subs} ->
        case Map.get(subs, provider_subscription_id) do
          nil ->
            %{exists: false, watermark: nil, last_event_id: nil}

          sub ->
            %{
              exists: true,
              watermark: Map.get(sub, :provider_event_at),
              last_event_id: Map.get(sub, :last_event_id)
            }
        end
      end)

    {:ok, state}
  end

  @impl true
  def write_snapshot(ref, %{provider_subscription_id: sub_id} = snapshot, entitlement_action) do
    Agent.update(ref, fn %{subs: subs, entitlements: ents, changes: changes} = st ->
      %{
        st
        | subs: Map.put(subs, sub_id, snapshot),
          entitlements: entitlement_transition(ents, sub_id, entitlement_action),
          changes: changes + 1
      }
    end)

    {:ok, %{provider_subscription_id: sub_id, applied: true}}
  end

  @doc """
  T24 — apply an entitlement-ONLY transition for `sub_id`, touching ONLY the
  entitlement rows (never `subs`/watermark bookkeeping). This is the seam
  `Samen.Billing.Dunning` writes through so a payment-failure grace/recovery
  transition never resets the subscription reconciler's own convergence state.
  """
  @impl true
  def apply_entitlement(ref, sub_id, entitlement_action) do
    Agent.update(ref, fn %{entitlements: ents} = st ->
      %{st | entitlements: entitlement_transition(ents, sub_id, entitlement_action)}
    end)

    {:ok, %{provider_subscription_id: sub_id, applied: true}}
  end

  # ---------------------------------------------------------------------------
  # Entitlement transition on the in-memory rows.

  # Grace: a cancel (or a T24 dunning payment failure) ends every entitlement AT
  # PERIOD END (`dt`) — not immediately.
  defp entitlement_transition(ents, sub_id, {:grace_until, dt}) do
    Map.update(ents, sub_id, [], fn rows ->
      Enum.map(rows, &Map.put(&1, :expires_at, dt))
    end)
  end

  # Active (T24 recovery seam): CLEAR any previously-set grace expiry — full
  # access restored, not merely "left as-is" (a payment recovering, or a
  # subscription un-cancelling, must undo an earlier grace/expiry).
  defp entitlement_transition(ents, sub_id, :active) do
    Map.update(ents, sub_id, [], fn rows ->
      Enum.map(rows, &Map.put(&1, :expires_at, nil))
    end)
  end

  # :none — no entitlement change implied (e.g. a metadata-only update).
  defp entitlement_transition(ents, _sub_id, _action), do: ents

  # ---------------------------------------------------------------------------
  # Test-support surface (assertions + seeding).

  @doc "Seed an entitlement row (`granted`, no expiry) for a subscription."
  @spec seed_entitlement(pid(), String.t(), atom()) :: :ok
  def seed_entitlement(ref, sub_id, feature) do
    Agent.update(ref, fn %{entitlements: ents} = st ->
      row = %{feature: feature, granted: true, expires_at: nil}
      %{st | entitlements: Map.update(ents, sub_id, [row], &[row | &1])}
    end)
  end

  @doc "The mirrored subscription snapshot for `sub_id` (or `nil`)."
  @spec get_subscription(pid(), String.t()) :: map() | nil
  def get_subscription(ref, sub_id), do: Agent.get(ref, &get_in(&1, [:subs, sub_id]))

  @doc "The entitlement rows for `sub_id` (each a `%{feature:, granted:, expires_at:}` map)."
  @spec list_entitlements(pid(), String.t()) :: [map()]
  def list_entitlements(ref, sub_id), do: Agent.get(ref, &Map.get(&1.entitlements, sub_id, []))

  @doc "How many `write_snapshot/3` calls actually mutated the mirror (the idempotency witness)."
  @spec change_count(pid()) :: non_neg_integer()
  def change_count(ref), do: Agent.get(ref, & &1.changes)
end
