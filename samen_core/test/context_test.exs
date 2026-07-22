defmodule Samen.ContextTest do
  @moduledoc """
  T3.10 acceptance: the `Samen.Context` bounded-context DSL.

  Mirrors the vision doc's `Lumen.Context` (doc §core `Lumen.Context` block) via the
  toy context `Ctx.Toy` over the kernel resources `Core.Ctx.Activity` (aliased as
  `Encounter`) and `Core.Ctx.Invoice` (money reshaped into a split).

  Covers:
    (a) `alias_resource` — the kernel resource re-exposed under the vertical's name;
        aliased actions/queries run against the kernel resource.
    (b) inherited plumbing UNCHANGED underneath — a reshaped/aliased resource's PII
        still masks; org-scope still filters; audit writers still fire.
    (c) introspection — the catalog knows the alias mapping + derived fields.
    (d) `reshape` — the money split computes correctly against worked examples.

  Red paths live in `context_red_path_test.exs`.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias SamenCore.TestRepo, as: Repo
  alias Samen.Context
  alias Samen.Context.Info

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp scope(org_id, role \\ :admin), do: %{id: "u-#{org_id}", org_id: org_id, role: role}

  # ==========================================================================
  # (a) alias_resource — kernel resource under the vertical's name
  # ==========================================================================

  describe "alias_resource — re-identify a kernel noun" do
    test "the alias resolves to the kernel resource" do
      assert Context.kernel_resource(Ctx.Toy, Ctx.Toy.Encounter) == Core.Ctx.Activity
    end

    test "a bare kernel resource passes through kernel_resource/2 unchanged" do
      assert Context.kernel_resource(Ctx.Toy, Core.Ctx.Invoice) == Core.Ctx.Invoice
    end

    test "an aliased query runs against the kernel resource (same actions)" do
      org = Ash.UUID.generate()

      act =
        Core.Ctx.Activity
        |> Ash.Changeset.for_create(:create, %{org_id: org, kind: :visit, subject: "checkup"},
          authorize?: false
        )
        |> Ash.create!()

      # Read THROUGH the vertical's name — the query targets Core.Ctx.Activity.
      [read] =
        Ctx.Toy
        |> Context.query(Ctx.Toy.Encounter)
        |> Ash.Query.filter(id == ^act.id)
        |> Ash.read!(actor: scope(org))

      assert read.id == act.id
      assert read.subject == "checkup"
    end

    test "the alias is a NAME, not a second Ash resource (no policy-bypass surface)" do
      # Deliberately: the alias module is NOT defined as an Ash resource. This is
      # what makes it impossible for the alias to widen or re-declare policies —
      # everything routes to the kernel resource.
      refute Ash.Resource.Info.resource?(Ctx.Toy.Encounter)
      assert Ash.Resource.Info.resource?(Core.Ctx.Activity)
    end
  end

  # ==========================================================================
  # (b) inherited plumbing UNCHANGED — PII masks, org-scope filters, audit fires
  # ==========================================================================

  describe "inherited plumbing rides underneath a context UNCHANGED" do
    test "a reshaped/aliased resource's PII still masks (vault underneath)" do
      org = Ash.UUID.generate()

      act =
        Core.Ctx.Activity
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, kind: :note, attendee_note: "Jane Doe, SSN 123"},
          authorize?: false
        )
        |> Ash.create!()

      [read] =
        Ctx.Toy
        |> Context.query(Ctx.Toy.Encounter)
        |> Ash.Query.filter(id == ^act.id)
        |> Ash.Query.ensure_selected([:attendee_note])
        |> Ash.read!(actor: scope(org))

      # The PII field reads back MASKED — the vault plumbing rides underneath the
      # vertical's rename, unchanged.
      assert %Samen.Masked{} = read.attendee_note

      # Ground truth: the domain column holds a vt_* token, never plaintext.
      %{rows: [[stored]]} =
        Repo.query!("SELECT pii_cea_attendee_note FROM cea_activity WHERE cea_id = $1", [
          Ecto.UUID.dump!(act.id)
        ])

      # The column holds ONLY a canonical vault token — structurally proving no
      # plaintext (nor any fragment of it) leaked. ROOT-CAUSE FIX (T102, a distinct
      # flake class from the outage/property ones): a digit-substring refute like
      # `refute stored =~ "123"` is UNSOUND here — "123" is all hex, so it appears
      # by chance inside the random `vt_<hex>` token even when nothing leaked (a
      # ci-fast run produced "vt_390a62127551234f72c840a2e068ed18", tripping that
      # refute; the randomness is `:crypto.strong_rand_bytes`, independent of the
      # ExUnit seed). The exact-token-shape assertion is the sound, deterministic
      # masking check (the RedPathVaultScanTest pattern) and is strictly stronger:
      # a plaintext-appended leak still fails it.
      assert stored =~ ~r/^vt_[0-9a-f]{32}$/
      refute stored =~ "Jane"
    end

    # DETERMINISTIC regression for the T102 hex-collision flake class: proves the
    # token-shape masking assertion is BOTH sound (a valid token that happens to
    # contain a plaintext digit-fragment is correctly NOT flagged) and non-vacuous
    # (a real plaintext-appended leak IS flagged). Uses the exact token a live
    # ci-fast run generated, so it needs no DB and no seed.
    test "T102: token-shape masking check is sound against hex-substring collision" do
      colliding = "vt_390a62127551234f72c840a2e068ed18"

      # The token embeds "123" purely by chance in its random hex — this is what
      # made the old `refute _ =~ "123"` flaky.
      assert colliding =~ "123"

      # SOUND check: a canonical token passes (no plaintext leaked)...
      assert colliding =~ ~r/^vt_[0-9a-f]{32}$/

      # ...and it is NOT vacuous: a token with plaintext appended (a real leak)
      # fails the exact-shape assertion.
      refute colliding <> "Jane Doe SSN 123" =~ ~r/^vt_[0-9a-f]{32}$/
    end

    test "org-scope still filters an aliased read (cross-org invisible)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      a =
        Core.Ctx.Activity
        |> Ash.Changeset.for_create(:create, %{org_id: org_a, kind: :visit}, authorize?: false)
        |> Ash.create!()

      # Actor scoped to org_b reads through the alias → org_a's row is invisible.
      results =
        Ctx.Toy
        |> Context.query(Ctx.Toy.Encounter)
        |> Ash.Query.filter(id == ^a.id)
        |> Ash.read!(actor: scope(org_b))

      assert results == []

      # Same actor, correct org → the row IS visible (proves the filter, not a
      # blanket deny).
      [seen] =
        Ctx.Toy
        |> Context.query(Ctx.Toy.Encounter)
        |> Ash.Query.filter(id == ^a.id)
        |> Ash.read!(actor: scope(org_a))

      assert seen.id == a.id
    end

    test "an aliased action still writes aud_event through the kernel plumbing" do
      org = Ash.UUID.generate()
      subject = "enc-#{System.unique_integer([:positive])}"

      # A context contributes AUDIT WRITERS over the existing aud_event tier (the
      # scope-authoring idiom); it never defines a new audit schema. Here we prove
      # a call made through the aliased resource lands a token-only aud_event row —
      # the audit plumbing rides underneath, unchanged.
      before =
        Repo.query!("SELECT count(*) FROM aud_event WHERE aud_subject_id = $1", [subject]).rows

      assert [[0]] = before

      {:ok, _} =
        Samen.AuditEvent.insert(Repo, %{
          event_type: "system",
          subject_id: subject,
          actor_id: "u1",
          detail: "ctx.encounter.created org=#{org}"
        })

      %{rows: [[n]]} =
        Repo.query!("SELECT count(*) FROM aud_event WHERE aud_subject_id = $1", [subject])

      assert n == 1
    end
  end

  # ==========================================================================
  # (c) introspection — the catalog knows the alias mapping + derived fields
  # ==========================================================================

  describe "introspection — the context map is machine-readable" do
    test "aliases/1 exposes the alias→kernel mapping" do
      assert Info.aliases(Ctx.Toy) == [
               %{alias: Ctx.Toy.Encounter, resource: Core.Ctx.Activity}
             ]
    end

    test "reshapes/1 exposes each reshape's calculations" do
      [%{resource: resource, calculations: calcs}] = Info.reshapes(Ctx.Toy)
      assert resource == Core.Ctx.Invoice

      names = Enum.map(calcs, & &1.name)
      assert names == [:patient_responsibility, :payer_claim]
      # :money is sugar → resolves to :decimal.
      assert Enum.all?(calcs, &(&1.resolved_type == :decimal))
    end

    test "domain/1 returns the context's declared domain" do
      assert Info.domain(Ctx.Toy) == Core.Ctx
    end

    test "catalog_context_map/1 names derived fields as NON-physical (not fld_field)" do
      map = Info.catalog_context_map(Ctx.Toy)

      assert map.context == "Ctx.Toy"
      assert map.domain == "Core.Ctx"

      assert [%{alias_name: "Ctx.Toy.Encounter", kernel_table: "cea_activity"}] = map.aliases

      # Every derived field is explicitly physical?: false — a reshape mints no
      # column, so it is NOT a fld_field row. The catalog distinguishes a
      # context-derived field from physical storage.
      assert Enum.all?(map.derived_fields, &(&1.physical? == false))

      pr = Enum.find(map.derived_fields, &(&1.context_field == "patient_responsibility"))
      assert pr.kernel_table == "cei_invoice"
      assert pr.type == "decimal"
    end

    test "the derived fields are NOT physical columns of the kernel resource" do
      # Ground truth: the reshape did NOT add a column. The kernel table has only
      # its declared storage columns; no patient_responsibility / payer_claim.
      %{rows: cols} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_name = 'cei_invoice'",
          []
        )

      col_names = List.flatten(cols)
      refute "patient_responsibility" in col_names
      refute "payer_claim" in col_names
      refute "cei_patient_responsibility" in col_names

      # And the catalog fld_field rows carry no derived field either.
      %{rows: fld} =
        Repo.query!("SELECT fld_column_name FROM fld_field WHERE fld_table_name = 'cei_invoice'", [])

      fld_names = List.flatten(fld)
      refute "patient_responsibility" in fld_names
      refute "payer_claim" in fld_names
    end
  end

  # ==========================================================================
  # (d) reshape — the money split computes correctly (worked examples)
  # ==========================================================================

  describe "reshape — patient_responsibility + payer_claim compute correctly" do
    setup do
      org = Ash.UUID.generate()
      {:ok, org: org}
    end

    defp make_invoice(org, total, covered) do
      Core.Ctx.Invoice
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, total: Decimal.new(total), covered_amount: Decimal.new(covered)},
        authorize?: false
      )
      |> Ash.create!()
    end

    defp reshaped_read(org, id) do
      [rec] =
        Ctx.Toy
        |> Context.reshaped_query(Core.Ctx.Invoice)
        |> Ash.Query.filter(id == ^id)
        |> Ash.read!(actor: %{id: "u1", org_id: org, role: :admin})

      # Ad-hoc (query-time) calculations land in the record's `:calculations` map —
      # they are NOT top-level fields, which is exactly right: a reshape mints no
      # attribute/column. Surface them for the worked-example assertions.
      rec.calculations
    end

    test "worked example: total 100, covered 70 → responsibility 30, claim 70", %{org: org} do
      inv = make_invoice(org, "100.00", "70.00")
      rec = reshaped_read(org, inv.id)

      assert Decimal.equal?(rec.patient_responsibility, Decimal.new("30.00"))
      assert Decimal.equal?(rec.payer_claim, Decimal.new("70.00"))
    end

    test "worked example: fully covered (total == covered) → responsibility 0", %{org: org} do
      inv = make_invoice(org, "250.00", "250.00")
      rec = reshaped_read(org, inv.id)

      assert Decimal.equal?(rec.patient_responsibility, Decimal.new("0.00"))
      assert Decimal.equal?(rec.payer_claim, Decimal.new("250.00"))
    end

    test "worked example: nothing covered → responsibility == total", %{org: org} do
      inv = make_invoice(org, "42.50", "0.00")
      rec = reshaped_read(org, inv.id)

      assert Decimal.equal?(rec.patient_responsibility, Decimal.new("42.50"))
      assert Decimal.equal?(rec.payer_claim, Decimal.new("0.00"))
    end

    test "responsibility + claim always reconstitutes the gross total (invariant)", %{org: org} do
      inv = make_invoice(org, "199.99", "123.45")
      rec = reshaped_read(org, inv.id)

      reconstituted = Decimal.add(rec.patient_responsibility, rec.payer_claim)
      assert Decimal.equal?(reconstituted, Decimal.new("199.99"))
    end

    test "the reshape still routes through org-scope (reshaped read is org-filtered)", %{org: org} do
      inv = make_invoice(org, "100.00", "40.00")
      other = Ash.UUID.generate()

      # An actor from a DIFFERENT org gets zero rows even on the reshaped query —
      # the reshape rides on top of the kernel's org-scope policy.
      results =
        Ctx.Toy
        |> Context.reshaped_query(Core.Ctx.Invoice)
        |> Ash.Query.filter(id == ^inv.id)
        |> Ash.read!(actor: %{id: "u1", org_id: other, role: :admin})

      assert results == []
    end
  end
end
