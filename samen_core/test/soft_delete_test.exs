defmodule Samen.SoftDeleteTest do
  @moduledoc """
  E6 soft-delete substrate (ADR-040 §5, T36) — proven on two pilots via the
  `archivable true` convention (do NOT sweep the §5.9 roster — that is T37):

    * `Widget` — plain resource with a partial unique index (`WHERE arv_archived_at
      IS NULL`);
    * `Person` — vaulted (🔒) resource folding `Core.Person`.

  Every red-path pairs denial with a positive control (anti-tautology, the
  `Samen.RedPath` / masking-watch-list house style):

    * c1 archive hides from default reads/list/search (RED) + `:archived` read shows
      it (CONTROL) + restore returns it (ASSERT);
    * c3 archived rows stay org-scoped (RED cross-org + CONTROL same-org) and
      mask-safe on every plane (two-plane masking on the vaulted pilot);
    * c4 double-archive / double-restore are idempotent no-ops (no timestamp move, no
      duplicate audit);
    * §5.3 restore-conflict is a fail-honest `{:error, :restore_conflict}` (RED) with a
      no-conflict restore CONTROL;
    * §5.1 `:destroy_permanently` is the untouched terminal path; the default `:destroy`
      is now soft (archives);
    * c4 archive/restore emit `record_archived` / `record_restored` governance audit.

  E6 is implemented ON **ash_archival** (ADR-037 §5.3 ADOPT; dep-add owned by T36 per
  §7.4): ash_archival supplies `archived_at`, the `is_nil(archived_at)` default read filter
  (FilterArchived), the soft-destroy rewrite, and `archive_related` cascade. Samen adds only
  the glue ash_archival lacks — the audited `:archive`, `:restore` (+ `:restore_conflict`
  mapping), the trash-only `:archived` read, `<abbrev>_archived_at` prefixing, and masking.

  The sabotage (`scripts/sabotages/31-e6-soft-delete-default-filter-drop.patch`) widens the
  `:archived`-only `exclude_read_actions` to also exclude the primary `:read` from
  ash_archival's FilterArchived — archived rows then LEAK into default reads and the two
  named tests below MUST fail (the filter application is load-bearing, ADR-037 §5.3 / §5.5).
  """
  use ExUnit.Case, async: false

  import Samen.MaskingCase,
    only: [resolve_on_plane: 4, assert_plane_masked!: 1, assert_leak_detected!: 2]

  alias Samen.Archival
  alias SamenCore.Support.Archivable.{Person, Widget}

  @repo SamenCore.TestRepo

  # No-grant vault stub: even wired to a vault, the operator-without-grant plane must
  # mask. Proves the mask is the plane/grant gate, independent of decrypt availability.
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

  defp new_widget(scope, org, code, name \\ "W") do
    Widget
    |> Ash.Changeset.for_create(:create, %{org_id: org, code: code, name: name}, scope: scope)
    |> Ash.create!()
  end

  defp live_ids(scope) do
    Widget |> Ash.read!(scope: scope) |> Enum.map(& &1.id) |> MapSet.new()
  end

  defp archived_widgets(scope) do
    Widget |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)
  end

  defp archived_ids(scope), do: archived_widgets(scope) |> Enum.map(& &1.id) |> MapSet.new()

  # The :archived read record for `id` (archived_at loaded — the realistic record a
  # trash view / retention sweep re-archives or restores).
  defp archived_widget(scope, id), do: archived_widgets(scope) |> Enum.find(&(&1.id == id))

  defp aud_count(event_type, id) do
    %{rows: [[n]]} =
      @repo.query!(
        "SELECT count(*) FROM aud_event WHERE aud_event_type = $1 AND aud_subject_id = $2",
        [event_type, to_string(id)]
      )

    n
  end

  # ── c1: archive hides / :archived shows / restore returns ────────────────────

  describe "c1 — default reads exclude archived; :archived includes; restore returns" do
    test "archive removes from default read (RED), :archived shows it (CONTROL), restore returns it (ASSERT)",
         %{org: org, scope: scope} do
      w = new_widget(scope, org, "c1")
      assert MapSet.member?(live_ids(scope), w.id)

      {:ok, _} = Archival.archive(w, scope: scope)

      # RED: gone from default reads / list / search (search reads the primary read).
      refute MapSet.member?(live_ids(scope), w.id)
      # CONTROL: the :archived include-read still sees it — HIDDEN, not gone.
      assert MapSet.member?(archived_ids(scope), w.id)

      # ASSERT: restore returns it to default reads.
      {:ok, _} = Archival.restore(archived_widget(scope, w.id), scope: scope)
      assert MapSet.member?(live_ids(scope), w.id)
      refute MapSet.member?(archived_ids(scope), w.id)
    end

    test "the DEFAULT destroy is now SOFT — a plain Ash.destroy archives, never deletes (ADR §5.2)",
         %{org: org, scope: scope} do
      w = new_widget(scope, org, "soft")

      :ok = Ash.destroy!(w, scope: scope)

      # RED: hidden from default reads.
      refute MapSet.member?(live_ids(scope), w.id)
      # CONTROL: still present via :archived — archived, not terminally deleted.
      assert MapSet.member?(archived_ids(scope), w.id)
    end
  end

  # ── §5.1: the terminal hard-delete path stays distinct + unchanged ───────────

  describe "§5.1 — :destroy_permanently is the untouched terminal path" do
    test "destroy_permanently REALLY deletes (gone even from :archived); soft archive does NOT",
         %{org: org, scope: scope} do
      hard = new_widget(scope, org, "hard")
      soft = new_widget(scope, org, "keep")

      # CONTROL: a soft archive leaves the row in the table (visible via :archived).
      {:ok, _} = Archival.archive(soft, scope: scope)
      assert MapSet.member?(archived_ids(scope), soft.id)

      # RED-for-terminal: destroy_permanently removes the row entirely.
      :ok = Ash.destroy!(hard, action: :destroy_permanently, scope: scope)
      refute MapSet.member?(archived_ids(scope), hard.id)

      %{rows: [[n]]} =
        @repo.query!("SELECT count(*) FROM arv_widget WHERE arv_id = $1", [
          Ecto.UUID.dump!(hard.id)
        ])

      assert n == 0
    end
  end

  # ── c4: idempotence ──────────────────────────────────────────────────────────

  describe "c4 — double-archive / double-restore are idempotent no-ops" do
    test "double-archive does not move archived_at and writes no second audit event",
         %{org: org, scope: scope} do
      w = new_widget(scope, org, "idem")

      {:ok, _} = Archival.archive(w, scope: scope)
      ts1 = archived_widget(scope, w.id).archived_at
      assert %DateTime{} = ts1
      assert aud_count("record_archived", w.id) == 1

      # Re-archive the (loaded) archived record — a no-op.
      {:ok, _} = Archival.archive(archived_widget(scope, w.id), scope: scope)
      assert archived_widget(scope, w.id).archived_at == ts1
      assert aud_count("record_archived", w.id) == 1
      assert Enum.count(archived_widgets(scope), &(&1.id == w.id)) == 1
    end

    test "double-restore on a live row is a no-op (no audit)", %{org: org, scope: scope} do
      w = new_widget(scope, org, "idem2")
      {:ok, _} = Archival.archive(w, scope: scope)

      {:ok, _} = Archival.restore(archived_widget(scope, w.id), scope: scope)
      assert MapSet.member?(live_ids(scope), w.id)
      assert aud_count("record_restored", w.id) == 1

      # Restore an already-live record — no-op, no second audit.
      [live] = Widget |> Ash.read!(scope: scope) |> Enum.filter(&(&1.id == w.id))
      {:ok, _} = Archival.restore(live, scope: scope)
      assert aud_count("record_restored", w.id) == 1
    end
  end

  # ── §5.3: restore-conflict on the partial unique index ───────────────────────

  describe "§5.3 — restore is honest about a partial-index conflict" do
    test "restore into an occupied live slot fails :restore_conflict (RED); a free slot restores (CONTROL)",
         %{org: org, scope: scope} do
      # RED: A archived, B claims the freed (org, code) slot, A cannot restore.
      a = new_widget(scope, org, "dup")
      {:ok, _} = Archival.archive(a, scope: scope)
      _b = new_widget(scope, org, "dup")
      assert {:error, :restore_conflict} = Archival.restore(archived_widget(scope, a.id), scope: scope)

      # CONTROL: no live claimant on the slot → restore succeeds. Proves the conflict
      # above is the index firing, not a blanket refusal.
      c = new_widget(scope, org, "free")
      {:ok, _} = Archival.archive(c, scope: scope)
      assert {:ok, _} = Archival.restore(archived_widget(scope, c.id), scope: scope)
      assert MapSet.member?(live_ids(scope), c.id)
    end
  end

  # ── c3: org-scope holds on archived rows ─────────────────────────────────────

  describe "c3 — archived rows stay org-scoped (the include-read does not bypass OrgScope)" do
    test "the :archived read for org A never returns org B's archived row (RED), only A's (CONTROL)",
         %{org: org_a, scope: scope_a} do
      org_b = Ash.UUID.generate()
      scope_b = tenant_scope(org_b)

      a = new_widget(scope_a, org_a, "A")
      b = new_widget(scope_b, org_b, "B")
      {:ok, _} = Archival.archive(a, scope: scope_a)
      {:ok, _} = Archival.archive(b, scope: scope_b)

      a_view = archived_ids(scope_a)
      # CONTROL: A sees its own archived row.
      assert MapSet.member?(a_view, a.id)
      # RED: A never sees org B's archived row through the include-read.
      refute MapSet.member?(a_view, b.id)
    end
  end

  # ── c3 / INV-1: masking holds on an archived vaulted row ─────────────────────

  describe "c3 / INV-1 — an archived vaulted row still masks per plane, restore never leaks" do
    test "archived Person keeps its vault token at rest and masks on the operator plane (RED) / clears on tenant (CONTROL)",
         %{org: org, scope: scope} do
      attrs =
        Map.merge(
          %{org_id: org, job_title: "Ops"},
          Samen.Factory.person("Ada", "Lovelace", email: "ada.lovelace@sample.invalid")
        )

      person = Samen.Factory.create!(Person, attrs, scope)
      {:ok, _} = Archival.archive(person, scope: scope)

      archived =
        Person
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.ensure_selected([:emails])
        |> Ash.read!(scope: scope)
        |> hd()

      # INV-1 at rest: the vault column holds a vt_* token even while archived — the
      # archived row is trash, not erasure; tokens stay vaulted (§5.1).
      %{rows: [[stored]]} =
        @repo.query!("SELECT avf_emails FROM avf_person WHERE avf_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      # RED (INV-1): operator plane WITHOUT a grant resolves the archived row's field to
      # %Masked{} — never plaintext, never the vt_ token, on any egress (DOM/CSV/API).
      masked = resolve_on_plane(archived, Person, :operator, grant: DenyAll).emails
      assert_plane_masked!(masked)
      assert to_string(masked) == "••••"
      refute to_string(masked) =~ "vt_"
      refute to_string(masked) =~ "ada.lovelace"

      # CONTROL / anti-tautology (Samen.MaskingCase.assert_leak_detected!): the substring
      # scan the RED relies on IS refutable — a modeled plaintext render is detected. So
      # "never plaintext" above is a real guarantee, not a vacuous assertion; a leak on an
      # archived row would be caught by the same watch-list scan.
      assert_leak_detected!("<td>ada.lovelace@sample.invalid</td>", "ada.lovelace")

      # Restore does not leak: an operator (no-grant) read of the restored row still masks.
      {:ok, _} = Archival.restore(archived, scope: scope)

      live =
        Person
        |> Ash.Query.ensure_selected([:emails])
        |> Ash.read!(scope: scope)
        |> hd()

      assert_plane_masked!(resolve_on_plane(live, Person, :operator, grant: DenyAll).emails)
    end
  end

  # ── c4: archive/restore are audited ──────────────────────────────────────────

  describe "c4 — archive/restore emit governance audit events" do
    test "archive writes record_archived, restore writes record_restored (id/enum-only detail)",
         %{org: org, scope: scope} do
      w = new_widget(scope, org, "aud")

      assert aud_count("record_archived", w.id) == 0
      {:ok, _} = Archival.archive(w, scope: scope)
      assert aud_count("record_archived", w.id) == 1

      {:ok, _} = Archival.restore(archived_widget(scope, w.id), scope: scope)
      assert aud_count("record_restored", w.id) == 1
    end
  end

  # ── introspection: the adopt-me convention is queryable (T37 fixture) ─────────

  describe "introspection — Samen.Info.archivable?/1 (T37 catalog probe surface)" do
    test "archivable pilots report true; a non-archivable resource reports false" do
      assert Samen.Info.archivable?(Widget)
      assert Samen.Info.archivable?(Person)
      refute Samen.Info.archivable?(SamenCore.Support.Crm.Company)
    end
  end
end
