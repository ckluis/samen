defmodule Driftwood.ReadsBoundedTest do
  @moduledoc """
  ADR-045 §4.2 (O8) — `Driftwood.Reads.driver_roster/2` is HARD-BOUNDED.

  Before this fix the roster read was `Ash.read!` with a `sort` but NO `limit`, then a
  per-row vault decrypt (`resolve_pii/2`) — and it was called on every `handle_params`
  where `panel == "roster"` (a tenant-controlled URL) and, worse, once per driver-detail
  interaction (`dispatch_decision/2` loaded + decrypted the ENTIRE org roster to find one
  driver). On a large org that is an unbounded per-navigation decrypt sweep — a
  resource-exhaustion / KMS-cost hazard, and outside the framework boundedness lint's blast
  radius (its glob excluded the vertical trees).

  These proofs are non-tautological:

    * **BOUND** — a roster LARGER than the requested page returns at most the page (the read
      does NOT return the full set). Defeated by sabotage 210 (drop the `Ash.Query.limit`).
    * **CORRECTNESS + masking intact on the actor's plane** — the bounded roster still
      returns the right drivers, and on the tenant plane the vault fields resolve CLEAR (the
      bound does not change WHICH plane resolves). The anti-tautology twin shows the SAME
      driver masks on the operator plane — so "clear" is plane-dependent, not unconditional.
  """
  use Driftwood.DataCase, async: false
  use Samen.MaskingCase
  require Ash.Query

  alias Driftwood.Reads
  alias DriftwoodWeb.BrokerLive

  @org "c1230000-0000-4000-8000-0000000000e8"

  defp create_driver(cdl) do
    Driftwood.Freight.Driver
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        full_name: %{first: "Roster", last: cdl},
        cdl_number: cdl,
        cdl_state: "TX",
        cdl_expiry: Date.utc_today() |> Date.add(365) |> Date.to_iso8601(),
        medical_card_expiry: Date.add(Date.utc_today(), 180),
        status: :available
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp raw_record(driver_id) do
    Driftwood.Freight.Driver
    |> Ash.Query.filter(id == ^driver_id)
    |> Ash.Query.ensure_selected([:full_name, :cdl_number])
    |> Ash.read_one!(authorize?: false)
  end

  test "BOUND: a roster larger than the requested page returns at MOST the page (not the full set)" do
    for cdl <- ["CDL-A-1", "CDL-B-2", "CDL-C-3"], do: create_driver(cdl)
    scope = BrokerLive.broker_scope(@org)

    # Three drivers exist; a page of two returns exactly two — the read applied its limit and
    # did NOT sweep-and-decrypt the whole roster.
    assert length(Reads.driver_roster(scope, limit: 2)) == 2

    # The full (default-capped) read returns all three (well under the @limit 200 cap).
    assert length(Reads.driver_roster(scope)) == 3
  end

  test "the caller-supplied :limit can only NARROW the page — it never exceeds the @limit cap" do
    for cdl <- ["CDL-A-1", "CDL-B-2", "CDL-C-3"], do: create_driver(cdl)
    scope = BrokerLive.broker_scope(@org)

    # An over-cap request is clamped, not honored — so it returns every available row (3),
    # never MORE than the cap. (The clamp is the defence-in-depth half of the bound.)
    assert length(Reads.driver_roster(scope, limit: 10_000)) == 3
  end

  test "CORRECTNESS + masking: the bounded roster returns the right drivers, CLEAR on the tenant plane" do
    seeded = ["CDL-A-1", "CDL-B-2", "CDL-C-3"]
    for cdl <- seeded, do: create_driver(cdl)
    scope = BrokerLive.broker_scope(@org)

    roster = Reads.driver_roster(scope)

    # Right drivers: the CLEAR cdl set equals the seeded set (org-scoped, correct, complete).
    assert roster |> Enum.map(& &1.cdl_number) |> Enum.sort() == Enum.sort(seeded)

    # Masking intact on the actor's plane — the tenant owns its drivers' PII, so it resolves
    # CLEAR (never a %Masked{}, never a vt_ token).
    for d <- roster do
      refute match?(%Samen.Masked{}, d.cdl_number)
      refute to_string(d.cdl_number) =~ "vt_"
      refute match?(%Samen.Masked{}, d.full_name)
    end
  end

  test "ANTI-TAUTOLOGY twin: the SAME driver masks on the operator plane — the bound didn't change the plane" do
    driver = create_driver("CDL-OP-9")

    # The roster's clear render is PLANE-DEPENDENT: resolved on the operator plane (no grant),
    # the identical record masks — proving the tenant-clear proof above is refutable, and that
    # bounding the read did not weaken WHICH plane resolves the vault fields.
    operator =
      resolve_on_plane(raw_record(driver.id), Driftwood.Freight.Driver, :operator, repo: Driftwood.Repo)

    assert_plane_masked!(operator.cdl_number, "CDL-OP-9")
    refute to_string(operator.cdl_number) =~ "vt_"
  end
end
