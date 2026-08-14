defmodule Samen.Web.WebhookDlqAuthzTest do
  @moduledoc """
  S14 (luminary panel-2 MED) — the operator DLQ `replay`/`resolve` WRITE actions are
  role-gated and read through a governed, surface-bounded fetch.

  ## The hole this closes

  `Samen.Web.Operator.WebhookDlqLive`'s `replay`/`resolve` handlers used a bare
  `Event.get(repo, id)` — no operator-org guard (the mount's own `no_org` fail-secure
  applied to the READ path only), no bound to the rows the surface actually exposes
  actions for (`status == "dead"`), and NO role check at all: all four operator roles —
  including `:operator_readonly`, whose contract is "read the operator CRM only" —
  could mutate the webhook store and enqueue processing jobs.

  ## The fix under test (T146 role-derivation pattern)

    * the role comes ONLY from `:samen_operator_role` — the assign
      `Samen.Web.Operator.Authz`'s `:require_operator` on_mount derived from the
      AUTHENTICATED session principal (fail-closed: `nil`/unknown → refuse);
    * `:operator_readonly` may never mutate; `:operator_admin`/`:operator_support` may;
    * the fetch is `Event.get_dead/2` — bounded to the DLQ's own actionable set
      (`status == "dead"`), so a crafted event id cannot reset a live/processed
      envelope; and it runs only when the mount resolves an operator org (the same
      `no_org` guard `load/1` already enforces — parity, fail-secure).

  ## Anti-tautology

  Every refusal is paired with a positive control on the same surface: an
  `:operator_admin` replay still flips dead → received, an `:operator_support`
  resolve still flips dead → processed.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Operator.WebhookDlqLive
  alias Samen.Webhook.Event

  @operator_org "00000000-0000-0000-0000-00000000beef"

  setup do
    {:ok, :inserted, row} =
      Event.insert_received(Repo, %{
        provider: "test",
        event_id: "evt_dlq_authz_#{System.unique_integer([:positive])}",
        kind: "checkout_completed",
        domain: "billing",
        occurred_at: DateTime.utc_now(),
        payload: %{"amount" => 4900, "currency" => "usd"}
      })

    {:ok, dead} = Event.mark_dead(Repo, row, "handler crashed")
    %{dead: dead}
  end

  defp socket(role, org_id \\ @operator_org) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_operator_mount(org_id))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:samen_operator_role, role)
  end

  defp status(id), do: Event.get(Repo, id).status

  # ==========================================================================
  # RED — :operator_readonly (and an unresolved role) may not mutate
  # ==========================================================================

  test ":operator_readonly replay is REFUSED — the dead envelope stays dead", %{dead: dead} do
    {:noreply, _} = WebhookDlqLive.handle_event("replay", %{"id" => dead.id}, socket(:operator_readonly))

    assert status(dead.id) == "dead",
           "S14 regression: a readonly operator performed a WRITE (replay reset the envelope)"
  end

  test ":operator_readonly resolve is REFUSED — the dead envelope stays dead", %{dead: dead} do
    {:noreply, _} = WebhookDlqLive.handle_event("resolve", %{"id" => dead.id}, socket(:operator_readonly))

    assert status(dead.id) == "dead",
           "S14 regression: a readonly operator performed a WRITE (resolve marked the envelope processed)"
  end

  test "a socket with NO resolved operator role (nil) is refused — fail closed", %{dead: dead} do
    {:noreply, _} = WebhookDlqLive.handle_event("replay", %{"id" => dead.id}, socket(nil))
    assert status(dead.id) == "dead"
  end

  # ==========================================================================
  # RED — the governed read: no_org guard parity + dead-only bound
  # ==========================================================================

  test "an admin replay on a mount that resolves NO operator org is refused (no_org parity)", %{dead: dead} do
    {:noreply, _} = WebhookDlqLive.handle_event("replay", %{"id" => dead.id}, socket(:operator_admin, nil))

    assert status(dead.id) == "dead",
           "S14 regression: the write path ignored the mount's own no_org fail-secure guard"
  end

  test "a crafted id of a NON-dead envelope cannot be reset (the read is bounded to the DLQ's actionable set)" do
    {:ok, :inserted, row} =
      Event.insert_received(Repo, %{
        provider: "test",
        event_id: "evt_live_#{System.unique_integer([:positive])}",
        kind: "checkout_completed",
        domain: "billing",
        occurred_at: DateTime.utc_now(),
        payload: %{}
      })

    {:ok, processed} = Event.mark_processed(Repo, row)

    {:noreply, _} = WebhookDlqLive.handle_event("replay", %{"id" => processed.id}, socket(:operator_admin))

    assert status(processed.id) == "processed",
           "S14 regression: a bare repo.get let a crafted id reset an envelope the surface never exposed"
  end

  # ==========================================================================
  # POSITIVE CONTROLS (anti-tautology) — the authorized path still works
  # ==========================================================================

  test "POSITIVE CONTROL — an :operator_admin replay resets dead → received", %{dead: dead} do
    {:noreply, _} = WebhookDlqLive.handle_event("replay", %{"id" => dead.id}, socket(:operator_admin))

    replayed = Event.get(Repo, dead.id)
    assert replayed.status == "received"
    assert replayed.last_error == nil
  end

  test "POSITIVE CONTROL — an :operator_support resolve marks dead → processed", %{dead: dead} do
    {:noreply, _} = WebhookDlqLive.handle_event("resolve", %{"id" => dead.id}, socket(:operator_support))

    assert status(dead.id) == "processed"
  end
end
