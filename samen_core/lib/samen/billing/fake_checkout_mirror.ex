defmodule Samen.Billing.FakeCheckoutMirror do
  @moduledoc """
  The in-memory `Samen.Billing.CheckoutMirror` test double (T20/B2). Ships in lib per
  the house "test infra ships in lib" precedent (`Samen.RedPath`, `Samen.Factory`,
  `Samen.Billing.FakeMirror`/`FakeProvider`).

  Proves `Samen.Billing.Checkout.reconcile/2`'s routing + idempotency hermetically — no
  DB, no Ash resources, no vendor credentials. The REAL storage (an actual Subscription
  + Entitlement row per plan feature) is proven separately against
  `Samen.Billing.AshCheckoutMirror` (samen_web's `Samen.WebTest.Billing` mounted test
  domain), since a fake-in-memory Subscription would not prove anything about the Ash
  write path this task must ship.

  `change_count/1` is the idempotency witness (mirrors `FakeMirror.change_count/1`): a
  fixture replayed twice must leave it at 1.
  """

  @behaviour Samen.Billing.CheckoutMirror

  @doc "Start a fresh in-memory mirror; returns `{:ok, ref}` (the ref is an Agent pid)."
  @spec start() :: {:ok, pid()}
  def start do
    Agent.start_link(fn -> %{subs: %{}, changes: 0} end)
  end

  @doc "Start a fresh mirror, raising on failure; returns the ref directly (test sugar)."
  @spec new() :: pid()
  def new do
    {:ok, ref} = start()
    ref
  end

  @impl true
  def subscription_exists?(ref, provider_subscription_id) do
    exists = Agent.get(ref, fn %{subs: subs} -> Map.has_key?(subs, provider_subscription_id) end)
    {:ok, exists}
  end

  @impl true
  def activate(ref, %{snapshot: %{provider_subscription_id: sub_id}} = attrs) do
    {:ok, already?} = subscription_exists?(ref, sub_id)

    if already? do
      {:ok, :duplicate}
    else
      Agent.update(ref, fn st ->
        %{st | subs: Map.put(st.subs, sub_id, attrs), changes: st.changes + 1}
      end)

      {:ok, %{provider_subscription_id: sub_id, org_id: Map.fetch!(attrs, :org_id)}}
    end
  end

  @doc "The activation attrs recorded for `sub_id` (or `nil` if never activated)."
  @spec get_activation(pid(), String.t()) :: map() | nil
  def get_activation(ref, sub_id), do: Agent.get(ref, &get_in(&1, [:subs, sub_id]))

  @doc "How many `activate/2` calls actually created a new row (the idempotency witness)."
  @spec change_count(pid()) :: non_neg_integer()
  def change_count(ref), do: Agent.get(ref, & &1.changes)
end
