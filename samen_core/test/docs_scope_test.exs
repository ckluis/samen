defmodule Samen.DocsScopeTest do
  @moduledoc """
  The Docs scope (F3, T45) — Doc + Note, attachable via the generic object-ref
  anchor + PII-classified-routes-to-vault, mounted via
  `test/support/docs_fixture.ex`.

  Every red-path pairs denial with a positive control (anti-tautology, the
  `Samen.RedPath` / masking-watch-list house style — CLAUDE.md):

    * c1 CRUD via governed actions + org-scoped reads (cross-org RED / own-org
      CONTROL, org-less fail-closed — mirrors `Samen.CalendarScopeTest` c1) for
      BOTH `Doc` and `Note`;
    * c2 archive/restore (ADR-040 §5.9): hide-on-archive / show-via-`:archived`
      / return-on-restore, double-archive idempotent;
    * c3 distinct-from-CMS probe (spec F3): `Doc`/`Note` own tables, never
      `cpg_page`/`cpt_post` (no shared storage with CMS `Page`/`Post`);
    * c4 INV-1 — `secure_body` masks by default (green/red/sabotage
      three-proof, `Samen.MaskingCase`): tenant plane clear, operator-without-
      grant plane `%Samen.Masked{}` (never plaintext, never a `vt_*` token),
      leak scan refutable (anti-tautology);
    * c5 vault routing: `secure_body` lands a `vt_*` token in the raw domain
      row, plaintext nowhere, ciphertext in `pii_vault`;
    * c6 an ARCHIVED Doc/Note keeps its vault token and still masks per plane;
    * c7 catalog registration — `mix samen.verify.catalog_parity` is green;
    * c8 the F3 Unit 6 free-text write chokepoint (`Samen.Pii.FreeTextScan`):
      a bare email/SSN/phone-shaped `body` value is REFUSED at the write path
      (RED, DB unchanged), ordinary prose is accepted (CONTROL) — this is the
      "vaulted when PII-classified" mechanism's plain-path belt: an obviously
      PII-shaped value can never land in the unvaulted `body` column, forcing
      the caller to the vaulted `secure_body` path instead.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  import Samen.MaskingCase,
    only: [resolve_on_plane: 4, assert_plane_masked!: 2, assert_leak_detected!: 2, mask: 0]

  alias Samen.Archival
  alias SamenCore.Support.DocsFixture.{Doc, Note}

  @repo SamenCore.TestRepo

  # No-grant vault stub: even wired to a vault, the operator-without-grant plane
  # must mask. Proves the mask is the plane/grant gate, independent of decrypt
  # availability (mirrors Samen.CalendarScopeTest's DenyAll).
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

  @secret_body "vaulted.subject@sample.invalid"

  defp new_doc(scope, org, attrs \\ %{}) do
    Doc
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org, title: "Doc"}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  defp new_note(scope, org, attrs \\ %{}) do
    Note
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org}, attrs), scope: scope)
    |> Ash.create!()
  end

  # secure_body is NOT select-by-default — a fresh read that needs it must
  # select it explicitly (mirrors every other 🔒 field, e.g.
  # Samen.CalendarScopeTest.with_attendees_loaded/2).
  defp with_secure_body_loaded(%{id: id}, resource, scope) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:secure_body])
    |> Ash.read_one!(scope: scope)
  end

  defp doc_ids(scope), do: Doc |> Ash.read!(scope: scope) |> Enum.map(& &1.id) |> MapSet.new()
  defp note_ids(scope), do: Note |> Ash.read!(scope: scope) |> Enum.map(& &1.id) |> MapSet.new()

  defp archived_docs(scope), do: Doc |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)
  defp archived_notes(scope), do: Note |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)

  # ── c1: CRUD via governed actions; org-scoped reads ───────────────────────

  describe "c1 — CRUD via governed actions; org-scoped reads" do
    test "create/read/update/destroy(=archive) a Doc", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{title: "Runbook", body: "How to deploy."})
      assert d.title == "Runbook"
      assert d.body == "How to deploy."

      [read] = Doc |> Ash.read!(scope: scope)
      assert read.id == d.id

      updated = d |> Ash.Changeset.for_update(:update, %{title: "Runbook v2"}, scope: scope) |> Ash.update!()
      assert updated.title == "Runbook v2"

      :ok = Ash.destroy!(d, scope: scope)
      assert Doc |> Ash.read!(scope: scope) == []
    end

    test "create/read/update/destroy(=archive) a Note", %{org: org, scope: scope} do
      n = new_note(scope, org, %{body: "Called re: renewal."})
      assert n.body == "Called re: renewal."

      [read] = Note |> Ash.read!(scope: scope)
      assert read.id == n.id

      updated = n |> Ash.Changeset.for_update(:update, %{body: "Updated note."}, scope: scope) |> Ash.update!()
      assert updated.body == "Updated note."

      :ok = Ash.destroy!(n, scope: scope)
      assert Note |> Ash.read!(scope: scope) == []
    end

    test "an actor never reads another org's Docs/Notes (RED); reads its own org's (CONTROL)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      doc_a = new_doc(scope_a, org_a, %{title: "A"})
      _doc_b = new_doc(scope_b, org_b, %{title: "B"})
      note_a = new_note(scope_a, org_a)
      _note_b = new_note(scope_b, org_b)

      seen_docs = Doc |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)
      seen_notes = Note |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)

      assert doc_a.id in seen_docs and length(seen_docs) == 1
      assert note_a.id in seen_notes and length(seen_notes) == 1
    end

    test "an org-less actor sees zero Docs/Notes (fail closed)", %{org: org, scope: scope} do
      _d = new_doc(scope, org, %{title: "hidden"})
      _n = new_note(scope, org)

      orgless = %Samen.Scope{actor: %{id: "nobody", org_id: nil, role: :member}}

      case Ash.read(Doc, scope: orgless) do
        {:ok, seen} -> assert seen == []
        {:error, %Ash.Error.Forbidden{}} -> assert true
      end

      case Ash.read(Note, scope: orgless) do
        {:ok, seen} -> assert seen == []
        {:error, %Ash.Error.Forbidden{}} -> assert true
      end
    end

    test "the object-ref anchor (subject_key/subject_id) is a plain scalar pair, storable and readable",
         %{org: org, scope: scope} do
      target_id = Ash.UUID.generate()
      d = new_doc(scope, org, %{title: "Attached", subject_key: "crm.person", subject_id: target_id})
      assert d.subject_key == "crm.person"
      assert d.subject_id == target_id

      n = new_note(scope, org, %{subject_key: "work.task", subject_id: target_id})
      assert n.subject_key == "work.task"
      assert n.subject_id == target_id
    end
  end

  # ── c2: archive/restore ────────────────────────────────────────────────────

  describe "c2 — archive/restore (ADR-040 §5.9)" do
    test "Doc: archive hides it (RED), :archived shows it (CONTROL), restore returns it (ASSERT)",
         %{org: org, scope: scope} do
      d = new_doc(scope, org)
      {:ok, _} = Archival.archive(d, scope: scope)

      refute MapSet.member?(doc_ids(scope), d.id)
      assert Enum.any?(archived_docs(scope), &(&1.id == d.id))

      restored = archived_docs(scope) |> Enum.find(&(&1.id == d.id))
      {:ok, _} = Archival.restore(restored, scope: scope)
      assert MapSet.member?(doc_ids(scope), d.id)
    end

    test "Note: archive hides it (RED), :archived shows it (CONTROL), restore returns it (ASSERT)",
         %{org: org, scope: scope} do
      n = new_note(scope, org)
      {:ok, _} = Archival.archive(n, scope: scope)

      refute MapSet.member?(note_ids(scope), n.id)
      assert Enum.any?(archived_notes(scope), &(&1.id == n.id))

      restored = archived_notes(scope) |> Enum.find(&(&1.id == n.id))
      {:ok, _} = Archival.restore(restored, scope: scope)
      assert MapSet.member?(note_ids(scope), n.id)
    end

    test "double-archive is an idempotent no-op (archived_at does not move)", %{org: org, scope: scope} do
      d = new_doc(scope, org)
      {:ok, once} = Archival.archive(d, scope: scope)
      {:ok, twice} = Archival.archive(once, scope: scope)
      assert once.archived_at == twice.archived_at
    end
  end

  # ── c3: distinct-from-CMS probe (spec F3) ──────────────────────────────────

  describe "c3 — distinct from CMS Page/Post (no shared table)" do
    test "Doc/Note own tables, never cpg_page/cpt_post; distinct from each other" do
      doc_table = AshPostgres.DataLayer.Info.table(Doc)
      note_table = AshPostgres.DataLayer.Info.table(Note)

      refute doc_table in ["cpg_page", "cpt_post"]
      refute note_table in ["cpg_page", "cpt_post"]
      assert doc_table != note_table
      assert doc_table == "sdd_doc"
      assert note_table == "sdn_note"
    end
  end

  # ── c4: INV-1 — secure_body masks by default (three-proof) ────────────────

  describe "c4 — INV-1: secure_body masks by default (green/red/sabotage three-proof)" do
    test "GREEN: tenant plane resolves Doc.secure_body CLEAR", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body}) |> with_secure_body_loaded(Doc, scope)

      resolved = d |> resolve_on_plane(Doc, :tenant, repo: @repo) |> Map.get(:secure_body)

      refute match?(%Samen.Masked{}, resolved)
      assert resolved == @secret_body
    end

    test "RED: operator-without-grant plane resolves Doc.secure_body to %Masked{} — never " <>
           "plaintext, never a vt_ token", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body}) |> with_secure_body_loaded(Doc, scope)

      masked = resolve_on_plane(d, Doc, :operator, repo: @repo, grant: DenyAll).secure_body
      assert_plane_masked!(masked, nil)
      refute to_string(masked) =~ @secret_body
      refute to_string(masked) =~ "vt_"
    end

    test "GREEN/RED: Note.secure_body masks identically to Doc.secure_body", %{org: org, scope: scope} do
      n = new_note(scope, org, %{secure_body: @secret_body}) |> with_secure_body_loaded(Note, scope)

      tenant_val = n |> resolve_on_plane(Note, :tenant, repo: @repo) |> Map.get(:secure_body)
      operator_val = resolve_on_plane(n, Note, :operator, repo: @repo, grant: DenyAll).secure_body

      assert tenant_val == @secret_body
      assert_plane_masked!(operator_val, nil)
      refute to_string(operator_val) =~ @secret_body
    end

    test "ANTI-TAUTOLOGY: plane flip — the SAME row resolves clear on tenant, masked on operator",
         %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body}) |> with_secure_body_loaded(Doc, scope)

      tenant_val = resolve_on_plane(d, Doc, :tenant, repo: @repo).secure_body
      operator_val = resolve_on_plane(d, Doc, :operator, repo: @repo, grant: DenyAll).secure_body

      refute match?(%Samen.Masked{}, tenant_val)
      assert match?(%Samen.Masked{}, operator_val)
      assert to_string(operator_val) == mask()
    end

    test "ANTI-TAUTOLOGY: the leak scan is refutable — a modeled plaintext render IS caught",
         %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body}) |> with_secure_body_loaded(Doc, scope)

      leaked = "<div>secure_body: #{@secret_body}</div>"
      assert_leak_detected!(leaked, @secret_body)

      masked = resolve_on_plane(d, Doc, :operator, repo: @repo, grant: DenyAll).secure_body
      assert_plane_masked!(masked, nil)
    end
  end

  # ── c5: vault routing ───────────────────────────────────────────────────────

  describe "c5 — vault routing: secure_body writes a vt_ token; plaintext never in the domain row" do
    test "Doc raw-row + pii_vault proof", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body})
      Samen.RedPath.assert_vault_routed!(@repo, Doc, d.id, [:secure_body], [@secret_body])
    end

    test "Note raw-row + pii_vault proof", %{org: org, scope: scope} do
      n = new_note(scope, org, %{secure_body: @secret_body})
      Samen.RedPath.assert_vault_routed!(@repo, Note, n.id, [:secure_body], [@secret_body])
    end

    test "the VaultField last-line guard refuses a raw plaintext write (red path)" do
      assert {:ok, "vt_realtoken"} = Samen.Type.VaultField.dump_to_native("vt_realtoken", [])
      assert :error == Samen.Type.VaultField.dump_to_native(@secret_body, [])
    end
  end

  # ── c6: an archived Doc/Note keeps its vault token and still masks per plane ─

  describe "c6 — archiving does not disturb INV-1 (trash, not erasure)" do
    test "archived Doc: vt_ token at rest, masks on operator plane (RED), clears on tenant (CONTROL)",
         %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body})
      {:ok, _} = Archival.archive(d, scope: scope)

      archived =
        Doc
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.filter(id == ^d.id)
        |> Ash.Query.ensure_selected([:secure_body])
        |> Ash.read!(scope: scope)
        |> hd()

      %{rows: [[stored]]} =
        @repo.query!("SELECT pii_sdd_secure_body FROM sdd_doc WHERE sdd_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      masked = resolve_on_plane(archived, Doc, :operator, repo: @repo, grant: DenyAll).secure_body
      assert_plane_masked!(masked, nil)
      refute to_string(masked) =~ @secret_body

      tenant_val = resolve_on_plane(archived, Doc, :tenant, repo: @repo).secure_body
      refute match?(%Samen.Masked{}, tenant_val)
    end
  end

  # ── c7: catalog registration ────────────────────────────────────────────────

  describe "c7 — catalog registration (mix samen.verify.catalog_parity is green)" do
    test "the Docs fixture's tables/columns are fully catalogued (no violations)" do
      violations =
        Mix.Tasks.Samen.Verify.CatalogParity.check(@repo)
        |> Enum.filter(&(&1 =~ "sdd_doc" or &1 =~ "sdn_note"))

      assert violations == [],
             "expected no catalog_parity violations for the Docs fixture tables, got: " <>
               inspect(violations)
    end
  end

  # ── c8: F3 Unit 6 free-text write chokepoint on the plain `body` path ────────

  describe "c8 — Samen.Pii.FreeTextScan refuses a bare PII-shaped body (RED); ordinary prose " <>
             "is accepted (CONTROL)" do
    test "RED: a bare email-shaped body is refused at create; DB unchanged", %{org: org, scope: scope} do
      result =
        Doc
        |> Ash.Changeset.for_create(:create, %{org_id: org, title: "x", body: @secret_body}, scope: scope)
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result
      assert Doc |> Ash.read!(scope: scope) == []
    end

    test "RED: a bare phone-shaped body is refused on Note; DB unchanged", %{org: org, scope: scope} do
      result =
        Note
        |> Ash.Changeset.for_create(:create, %{org_id: org, body: "800-555-1234"}, scope: scope)
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result
      assert Note |> Ash.read!(scope: scope) == []
    end

    test "CONTROL: ordinary prose is accepted in body (anti-tautology — the scan is not " <>
           "blanket-refusing everything)", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{body: "Renewal call scheduled for next week."})
      assert d.body == "Renewal call scheduled for next week."

      n = new_note(scope, org, %{body: "Follow up after the demo."})
      assert n.body == "Follow up after the demo."
    end

    test "CONTROL: a PII-classified value is accepted via the vaulted secure_body path " <>
           "(the caller's declared-classification route)", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body})
      assert d.id
    end
  end
end
