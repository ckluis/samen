defmodule Samen.Web.ReadsBoundedTest do
  @moduledoc """
  The `read!`-elimination LINT (`Samen.Web.Reads.bounded!/4`) — RP-G1-5, the pinned A2
  gate carry A2-N1 (WS-A design §1.1). The guarantee: a `ListLive` reads function CANNOT
  silently return the full set; a `page!/3`-routed read is BOUNDED, and an
  intentionally-unbounded read is LOUDLY REJECTED (raises), never silently honored.

  ## Anti-tautology posture (the pairing this file exists for)

  Both directions are proven live against real DB rows:

    * **GREEN** — the conventional `page!/3`-routed reads fn (the ListFixture shape every
      vertical inherits) PASSES `bounded!`, and does so NON-VACUOUSLY: the seeded dataset
      EXCEEDS the probe page size, so "bounded" means the limit actually held, not that
      there was nothing to over-return.
    * **RED (RP-G1-5)** — a hand-rolled UNBOUNDED reads fn (a raw `Ash.read!` stuffing
      every row into `page.items`, no `limit`) makes `bounded!` RAISE. This is the
      sabotage the design demands: an unbounded caller must FAIL, not silently return the
      full set. If the lint were a no-op (the tautology), this test would not raise and
      would fail.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Mount
  alias Samen.Web.Reads
  alias Samen.Web.Reads.UnboundedReadError

  @probe_size 5
  # Seed strictly MORE than the probe size so the bound is OBSERVABLE (an unbounded read
  # returns all `@dataset` rows; a bounded read returns at most @probe_size).
  @dataset 14

  # -- reads fns under lint ----------------------------------------------------

  # The CONVENTIONAL bounded reads fn — routes through page!/3 (the design's chosen
  # mechanism). This is the exact shape ListFixture / Samen.Web.CRM.Reads use.
  defp bounded_reads(mount, scope, state) do
    Mount.resource(mount, Person)
    |> Ash.Query.ensure_selected([:display_name, :job_title])
    |> Reads.page!(state, scope: scope, filter_fields: [:display_name])
  end

  # The SABOTAGE: an UNBOUNDED reads fn. It honors the %Page{} carrier SHAPE (so the type
  # check passes) but ignores the limit entirely — a raw Ash.read! that returns EVERY row.
  # This is precisely the A2-N1 failure mode the lint must reject.
  defp unbounded_reads(mount, scope, _state) do
    items =
      Mount.resource(mount, Person)
      |> Ash.Query.sort(display_name: :asc)
      |> Ash.read!(scope: scope)

    %Samen.Web.Page{items: items, page_size: Reads.bounded_page_size(@probe_size)}
  end

  # A reads fn that lies about the shape entirely (returns a bare list, not a %Page{}).
  defp not_a_page_reads(mount, scope, _state) do
    Mount.resource(mount, Person)
    |> Ash.read!(scope: scope)
  end

  defp seed(mount) do
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    for i <- 1..@dataset do
      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          display_name: "Row #{String.pad_leading(to_string(i), 2, "0")}",
          job_title: "Broker",
          full_name: %Samen.Type.FullName{first: "R", last: "#{i}"}
        },
        authorize?: false
      )
      |> Ash.create!()
    end

    scope
  end

  # ---------------------------------------------------------------------------

  test "GREEN: a page!/3-routed reads fn PASSES bounded! (non-vacuous — dataset exceeds probe)" do
    mount = build_mount(:crm)
    scope = seed(mount)

    # Non-vacuity control: the dataset genuinely exceeds the probe size, so an UNbounded
    # read here WOULD over-return — the bound is real, not vacuous.
    all = Ash.read!(Samen.WebTest.Crm.Person, scope: scope)
    assert length(all) == @dataset
    assert @dataset > @probe_size

    assert :ok =
             Reads.bounded!(&bounded_reads/3, mount, scope, page_size: @probe_size)
  end

  test "RED PATH (RP-G1-5): an UNBOUNDED reads fn makes bounded! RAISE, not silently pass" do
    mount = build_mount(:crm)
    scope = seed(mount)

    # Prove the sabotage genuinely leaks the full set (so the raise is over a real leak).
    leaked = unbounded_reads(mount, scope, %Samen.Web.ListState{page_size: @probe_size})
    assert length(leaked.items) == @dataset

    err =
      assert_raise UnboundedReadError, fn ->
        Reads.bounded!(&unbounded_reads/3, mount, scope, page_size: @probe_size)
      end

    assert err.message =~ "UNBOUNDED READ"
  end

  test "RED PATH: a reads fn that returns a bare list (not a %Page{}) is REJECTED" do
    mount = build_mount(:crm)
    scope = seed(mount)

    assert_raise UnboundedReadError, ~r/did not return a %Samen.Web.Page/, fn ->
      Reads.bounded!(&not_a_page_reads/3, mount, scope, page_size: @probe_size)
    end
  end

  test "ANTI-TAUTOLOGY: the lint is not a no-op — the SAME probe green-lights bounded and red-lights unbounded" do
    mount = build_mount(:crm)
    scope = seed(mount)

    # If bounded!/4 were a no-op (always :ok — the tautology), the unbounded fn below
    # would ALSO return :ok and this assertion would fail. The lint must DISCRIMINATE.
    assert :ok = Reads.bounded!(&bounded_reads/3, mount, scope, page_size: @probe_size)

    assert_raise UnboundedReadError, fn ->
      Reads.bounded!(&unbounded_reads/3, mount, scope, page_size: @probe_size)
    end
  end

  test "the ListFixture reads (the inherited convention) is bounded by construction" do
    mount = build_mount(:crm)
    scope = seed(mount)

    # The exact reads fn the A2 fixture LiveView adopts — proves the SHIPPED convention
    # passes the lint, not just a bespoke test fn.
    assert :ok =
             Reads.bounded!(
               &Samen.WebTest.ListFixture.Reads.contacts/3,
               mount,
               scope,
               page_size: @probe_size
             )
  end
end
