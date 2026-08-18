defmodule Samen.CalendarScopeTest do
  @moduledoc """
  The Calendar scope (F2, T44) — Event/Meeting + recurrence + the substrate
  side of ICS export, mounted via `test/support/calendar_fixture.ex`.

  Every red-path pairs denial with a positive control (anti-tautology, the
  `Samen.RedPath` / masking-watch-list house style — CLAUDE.md):

    * c1 CRUD via governed actions + org-scoped reads (cross-org RED / own-org
      CONTROL, org-less fail-closed — mirrors `Samen.WorkScopeTest` c1, since
      this fixture uses a bare `org_id` UUID, not a real `Identity.Org`);
    * c2 archive/restore (ADR-040 §5.9): hide-on-archive / show-via-`:archived`
      / return-on-restore, double-archive/-restore idempotent;
    * c3 recurrence expansion (`Samen.Scopes.Calendar.Recurrence`) is bounded
      and deterministic over a window — daily/weekly/monthly/yearly, count-
      and until-bounded, and the hard safety cap on an unbounded-looking
      window (done-criterion 1: no infinite expansion);
    * c4 INV-1 — `attendees` masks by default (green/red/sabotage three-proof,
      `Samen.MaskingCase`): tenant plane clear, operator-without-grant plane
      `%Samen.Masked{}` (never plaintext, never a `vt_*` token), and the leak
      scan is refutable (anti-tautology);
    * c5 vault routing: `attendees` lands a `vt_*` token in the raw domain
      row, plaintext nowhere, ciphertext (never plaintext) in `pii_vault`;
    * c6 an ARCHIVED Event keeps its vault token and still masks per plane
      (soft-delete does not disturb INV-1 — mirrors `Samen.SoftDeleteTest`);
    * c7 catalog registration — `mix samen.verify.catalog_parity` is green.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  import Samen.MaskingCase,
    only: [resolve_on_plane: 4, assert_plane_masked!: 2, assert_leak_detected!: 2, mask: 0]

  alias Samen.Archival
  alias Samen.Scopes.Calendar.Recurrence
  alias SamenCore.Support.CalendarFixture.Event

  @repo SamenCore.TestRepo

  # No-grant vault stub: even wired to a vault, the operator-without-grant plane
  # must mask. Proves the mask is the plane/grant gate, independent of decrypt
  # availability (mirrors Samen.SoftDeleteTest's DenyAll).
  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  @secret_addr "vaulted.attendee@sample.invalid"

  defp new_event(scope, org, attrs \\ %{}) do
    Event
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org, starts_at: ~U[2026-03-01 09:00:00.000000Z]}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  # pii_attribute fields are NOT select-by-default (mirrors every other 🔒
  # field in this codebase — e.g. `Ash.Query.ensure_selected([:full_name])`
  # in `Samen.SoftDeleteTest`/`Samen.Web.CsvMaskingTest`); a fresh read that
  # needs `attendees` must select it explicitly.
  defp with_attendees_loaded(%Event{id: id}, scope) do
    Event
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:attendees])
    |> Ash.read_one!(scope: scope)
  end

  defp with_attendee(attrs \\ %{}) do
    Map.put(attrs, :attendees, [%{label: "primary", address: @secret_addr}])
  end

  defp event_ids(scope), do: Event |> Ash.read!(scope: scope) |> Enum.map(& &1.id) |> MapSet.new()

  defp archived_events(scope), do: Event |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)

  defp archived_event_ids(scope),
    do: archived_events(scope) |> Enum.map(& &1.id) |> MapSet.new()

  # ── c1: CRUD via governed actions + org-scoped reads ─────────────────────────

  describe "c1 — CRUD via governed actions; org-scoped reads" do
    test "create/read/update/destroy(=archive) an Event", %{org: org, scope: scope} do
      e = new_event(scope, org, %{title: "Kickoff", kind: :meeting})
      assert e.kind == :meeting
      assert e.title == "Kickoff"

      [read] = Event |> Ash.read!(scope: scope)
      assert read.id == e.id

      updated =
        e
        |> Ash.Changeset.for_update(:update, %{location: "Room 4"}, scope: scope)
        |> Ash.update!()

      assert updated.location == "Room 4"

      :ok = Ash.destroy!(e, scope: scope)
      assert Event |> Ash.read!(scope: scope) == []
    end

    test "an actor never reads another org's Events (RED); reads its own org's (CONTROL)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      event_a = new_event(scope_a, org_a, %{title: "A"})
      _event_b = new_event(scope_b, org_b, %{title: "B"})

      seen = Event |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)

      assert event_a.id in seen
      assert length(seen) == 1
    end

    test "an org-less actor sees zero Events (fail closed)", %{org: org, scope: scope} do
      _e = new_event(scope, org, %{title: "hidden"})

      orgless = %Samen.Scope{actor: %{id: "nobody", org_id: nil, role: :member}}

      case Ash.read(Event, scope: orgless) do
        {:ok, seen} -> assert seen == []
        {:error, %Ash.Error.Forbidden{}} -> assert true
      end
    end

    test "kind defaults to :event; :meeting is a legal value", %{org: org, scope: scope} do
      e = new_event(scope, org)
      assert e.kind == :event

      m = new_event(scope, org, %{kind: :meeting})
      assert m.kind == :meeting
    end
  end

  # ── c2: archive/restore ────────────────────────────────────────────────────

  describe "c2 — archive/restore (ADR-040 §5.9)" do
    test "archive hides it (RED), :archived shows it (CONTROL), restore returns it (ASSERT)",
         %{org: org, scope: scope} do
      e = new_event(scope, org)
      {:ok, _} = Archival.archive(e, scope: scope)

      refute MapSet.member?(event_ids(scope), e.id)
      assert MapSet.member?(archived_event_ids(scope), e.id)

      restored = archived_events(scope) |> hd()
      {:ok, _} = Archival.restore(restored, scope: scope)
      assert MapSet.member?(event_ids(scope), e.id)
    end

    test "double-archive is an idempotent no-op (archived_at does not move)",
         %{org: org, scope: scope} do
      e = new_event(scope, org)
      {:ok, once} = Archival.archive(e, scope: scope)
      {:ok, twice} = Archival.archive(once, scope: scope)
      assert once.archived_at == twice.archived_at
    end
  end

  # ── c3: recurrence expansion (bounded, deterministic) ─────────────────────

  describe "c3 — recurrence expansion is bounded and deterministic" do
    test "a non-recurring Event yields exactly its own instant, once, iff in-window",
         %{org: org, scope: scope} do
      e = new_event(scope, org)

      occ =
        Recurrence.expand(
          e.starts_at,
          e.recurrence,
          ~U[2026-01-01 00:00:00.000000Z],
          ~U[2026-12-31 00:00:00.000000Z]
        )

      assert occ == [e.starts_at]
    end

    test "a weekly rule expands to the exact bounded count over a window", %{org: org, scope: scope} do
      {:ok, rule} = Recurrence.cast_rule(%{"freq" => "weekly", "interval" => 1})
      e = new_event(scope, org, %{recurrence: rule})

      window_to = DateTime.add(e.starts_at, 5 * 7 * 86_400, :second)
      occ = Recurrence.expand(e.starts_at, e.recurrence, e.starts_at, window_to)

      assert length(occ) == 6
      assert occ == Enum.sort(occ, DateTime)
      assert Enum.uniq(occ) == occ
    end

    test "a monthly rule clamps day-of-month across shorter months (no invalid dates)",
         %{org: org, scope: scope} do
      e = new_event(scope, org, %{starts_at: ~U[2026-01-31 10:00:00.000000Z]})
      {:ok, rule} = Recurrence.cast_rule(%{freq: :monthly, interval: 1})

      occ =
        Recurrence.expand(e.starts_at, rule, e.starts_at, ~U[2026-05-01 00:00:00.000000Z])

      dates = Enum.map(occ, &DateTime.to_date/1)
      assert dates == [~D[2026-01-31], ~D[2026-02-28], ~D[2026-03-31], ~D[2026-04-30]]
    end

    test "a :count-bounded rule stops at exactly count occurrences regardless of window" do
      s = ~U[2026-01-01 09:00:00.000000Z]
      {:ok, rule} = Recurrence.cast_rule(%{freq: :daily, count: 3})

      occ = Recurrence.expand(s, rule, s, DateTime.add(s, 3650 * 86_400, :second))
      assert length(occ) == 3
    end

    test "an :until-bounded rule stops at the until instant" do
      s = ~U[2026-01-01 09:00:00.000000Z]
      until = DateTime.add(s, 2 * 86_400, :second)
      {:ok, rule} = Recurrence.cast_rule(%{freq: :daily, until: until})

      occ = Recurrence.expand(s, rule, s, DateTime.add(s, 3650 * 86_400, :second))
      assert length(occ) == 3
      assert Enum.all?(occ, &(DateTime.compare(&1, until) != :gt))
    end

    test "a rule with NEITHER :count NOR :until over an effectively-unbounded window is " <>
           "capped by the hard safety limit (done-criterion 1: no infinite expansion)" do
      s = ~U[2026-01-01 00:00:00.000000Z]
      far_future = DateTime.add(s, 100 * 365 * 86_400, :second)
      {:ok, rule} = Recurrence.cast_rule(%{freq: :daily})

      occ = Recurrence.expand(s, rule, s, far_future)
      assert length(occ) == 366
    end

    test "cast_rule/1 rejects an unknown :freq (RED) and accepts every supported one (CONTROL)" do
      assert {:error, {:invalid_freq, :bogus}} = Recurrence.cast_rule(%{freq: :bogus})

      Enum.each(Recurrence.freqs(), fn freq ->
        assert {:ok, %{freq: ^freq}} = Recurrence.cast_rule(%{freq: freq})
      end)
    end

    test "expansion is a pure function: the SAME inputs always produce the SAME occurrences " <>
           "(determinism — the DST-safety property under test)" do
      s = ~U[2026-03-01 09:00:00.000000Z]
      {:ok, rule} = Recurrence.cast_rule(%{freq: :daily, count: 30})
      window_to = DateTime.add(s, 60 * 86_400, :second)

      run1 = Recurrence.expand(s, rule, s, window_to)
      run2 = Recurrence.expand(s, rule, s, window_to)
      assert run1 == run2

      # Every occurrence is EXACTLY interval*86_400 seconds apart on the UTC
      # calendar — no drift, no seasonal branch (see Recurrence moduledoc).
      diffs =
        run1
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> DateTime.diff(b, a, :second) end)

      assert Enum.uniq(diffs) == [86_400]
    end

    test "write-time guard: an invalid recurrence rule is refused at create (RED); a valid " <>
           "one is accepted (CONTROL)", %{org: org, scope: scope} do
      result =
        Event
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, starts_at: ~U[2026-01-01 09:00:00.000000Z], recurrence: %{freq: :bogus}},
          scope: scope
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result

      valid = new_event(scope, org, %{recurrence: %{freq: :daily, interval: 2}})
      assert {:ok, %{freq: :daily, interval: 2}} = Recurrence.cast_rule(valid.recurrence)
    end
  end

  # ── c4: INV-1 — attendees masks by default (three-proof) ──────────────────

  describe "c4 — INV-1: attendees masks by default (green/red/sabotage three-proof)" do
    test "GREEN: tenant plane resolves attendees CLEAR", %{org: org, scope: scope} do
      e = new_event(scope, org, with_attendee()) |> with_attendees_loaded(scope)

      resolved =
        e
        |> resolve_on_plane(Event, :tenant, repo: @repo)
        |> Map.get(:attendees)

      # Composite PII fields resolve to the raw revealed plaintext (the vault's
      # `reveal/3` return, JSON-decodable back to the entries list) — never a
      # %Masked{} on the tenant's own-org plane, and the address is genuinely
      # readable (not just "not masked").
      refute match?(%Samen.Masked{}, resolved)
      assert resolved =~ @secret_addr
      assert [%{"address" => @secret_addr}] = Jason.decode!(resolved)
    end

    test "RED: operator-without-grant plane resolves attendees to %Masked{} — never plaintext, " <>
           "never a vt_ token", %{org: org, scope: scope} do
      e = new_event(scope, org, with_attendee()) |> with_attendees_loaded(scope)

      masked = resolve_on_plane(e, Event, :operator, repo: @repo, grant: DenyAll).attendees
      assert_plane_masked!(masked, nil)
      refute to_string(masked) =~ @secret_addr
      refute to_string(masked) =~ "vt_"
    end

    test "ANTI-TAUTOLOGY: plane flip — the SAME row resolves clear on tenant, masked on operator",
         %{org: org, scope: scope} do
      e = new_event(scope, org, with_attendee()) |> with_attendees_loaded(scope)

      tenant_val = resolve_on_plane(e, Event, :tenant, repo: @repo).attendees
      operator_val = resolve_on_plane(e, Event, :operator, repo: @repo, grant: DenyAll).attendees

      refute match?(%Samen.Masked{}, tenant_val)
      assert match?(%Samen.Masked{}, operator_val)
      assert to_string(operator_val) == mask()
    end

    test "ANTI-TAUTOLOGY: the leak scan is refutable — a modeled plaintext render IS caught",
         %{org: org, scope: scope} do
      e = new_event(scope, org, with_attendee()) |> with_attendees_loaded(scope)

      # A broken render that serialized the raw at-rest value would leak the
      # attendee address into the DOM/CSV/ICS surface. Model exactly that and
      # prove `refute ... =~ @secret_addr` above is not vacuously true.
      leaked = "<div>attendees: #{@secret_addr}</div>"
      assert_leak_detected!(leaked, @secret_addr)

      # Sanity: the real record still masks (the scan is refutable, not broken).
      masked = resolve_on_plane(e, Event, :operator, repo: @repo, grant: DenyAll).attendees
      assert_plane_masked!(masked, nil)
    end
  end

  # ── c5: vault routing ───────────────────────────────────────────────────────

  describe "c5 — vault routing: attendees writes a vt_ token; plaintext never in the domain row" do
    test "raw-row + pii_vault proof", %{org: org, scope: scope} do
      e = new_event(scope, org, with_attendee())

      Samen.RedPath.assert_vault_routed!(@repo, Event, e.id, [:attendees], [@secret_addr])
    end

    test "the VaultField last-line guard refuses a raw plaintext write (red path)" do
      assert {:ok, "vt_realtoken"} = Samen.Type.VaultField.dump_to_native("vt_realtoken", [])
      assert :error == Samen.Type.VaultField.dump_to_native(@secret_addr, [])
    end
  end

  # ── c6: an archived Event keeps its vault token and still masks per plane ──

  describe "c6 — archiving does not disturb INV-1 (trash, not erasure)" do
    test "archived Event: vt_ token at rest, masks on operator plane (RED), clears on tenant (CONTROL)",
         %{org: org, scope: scope} do
      e = new_event(scope, org, with_attendee())
      {:ok, _} = Archival.archive(e, scope: scope)

      archived =
        Event
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.ensure_selected([:attendees])
        |> Ash.read!(scope: scope)
        |> hd()

      %{rows: [[stored]]} =
        @repo.query!("SELECT sce_attendees FROM sce_event WHERE sce_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      masked = resolve_on_plane(archived, Event, :operator, repo: @repo, grant: DenyAll).attendees
      assert_plane_masked!(masked, nil)
      refute to_string(masked) =~ @secret_addr

      tenant_val = resolve_on_plane(archived, Event, :tenant, repo: @repo).attendees
      refute match?(%Samen.Masked{}, tenant_val)
    end
  end

  # ── c7: catalog registration ────────────────────────────────────────────────

  describe "c7 — catalog registration (mix samen.verify.catalog_parity is green)" do
    test "the Calendar fixture's table/columns are fully catalogued (no violations)" do
      violations =
        Mix.Tasks.Samen.Verify.CatalogParity.check(@repo)
        |> Enum.filter(&(&1 =~ "sce_event"))

      assert violations == [],
             "expected no catalog_parity violations for the Calendar fixture table, got: " <>
               inspect(violations)
    end
  end
end
