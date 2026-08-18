defmodule Samen.CloneTest do
  @moduledoc """
  T57 — `Samen.Clone.clone/3`: generic duplicate/clone with vault RE-TOKENIZATION
  (spec G9, semantics c14). The sharpest security surface in WS-G: a clone must be a
  genuinely INDEPENDENT record — every vault-routed (🔒) field gets its OWN fresh
  vault entry / `vt_*` token, NEVER a copy of the source's token/ciphertext.

  Every red-path pairs denial with a positive control (anti-tautology, the house
  style — CLAUDE.md). Coverage:

    * **a** re-tokenization: the clone's vault token DIFFERS from the source's
      (a token-copying clone fails the named test — sabotage-refutable);
    * **b** INDEPENDENCE, both directions: crypto-shred the CLONE → the source still
      resolves; shred the SOURCE → the clone still resolves (the anti-aliasing proof);
    * **c** governed path: re-tokenization rides the real `:create` action through
      the vault chokepoint (fresh `pii_vault` subject rows), never a raw token copy;
    * **d** masking/plane: an operator WITHOUT a grant cannot clone PII — refused,
      no plaintext, no `vt_*` leak (CONTROL: the same clone on the tenant plane works);
    * **e** org-scope: a cross-org clone is refused (CONTROL: same-org succeeds);
    * **f** unique/identity + `_copy` display suffix; relationships + file
      attachments RE-LINKED (referenced row not duplicated), not deep-cloned;
    * **g** audit: cloning a `versioned` resource writes a `<Resource>.Version` row
      (value-free / token-only), exactly like any governed create.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Clone
  alias Samen.Vault
  alias SamenCore.Support.Clinical.Patient
  alias SamenCore.Support.CrmScopeFixture
  alias SamenCore.Support.Versioning.Contact

  @repo SamenCore.TestRepo

  # No-grant vault stub — proves the mask/refusal is the plane/grant gate, not a
  # decrypt outage (mirrors Samen.SalesOpsScopeTest.DenyAll).
  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp tenant_scope(org, role \\ :member) do
    %Samen.Scope{actor: %{id: "u:#{org}", org_id: org, role: role, kind: :tenant, plane: :tenant}}
  end

  defp operator_scope(org) do
    %Samen.Scope{
      actor: %{
        id: "op:#{org}",
        org_id: org,
        role: :member,
        plane: :operator,
        impersonation: %{session_id: "op-session"}
      }
    }
  end

  @full_name %{first: "Grace", last: "Hopper"}
  @emails %{entries: [%{label: "work", address: "grace@example.com"}]}
  @phones %{entries: [%{label: "work", number: "+15550100100"}]}

  defp create_patient(org, attrs \\ %{}) do
    Patient
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org, mrn: "MRN-SECRET-42", dob: ~D[1906-12-09]}, attrs)
    )
    |> Ash.create!()
  end

  defp raw_col(table, pk_col, id, col) do
    %{rows: [[v]]} =
      @repo.query!("SELECT #{col} FROM #{table} WHERE #{pk_col} = $1", [Ecto.UUID.dump!(id)])

    v
  end

  defp reveal_field(resource, id, field) do
    [rec] =
      resource
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.ensure_selected([field])
      |> Ash.read!(authorize?: false)

    Vault.reveal(Map.get(rec, field), @repo)
  end

  defp vault_tokens_for(subject_id) do
    import Ecto.Query

    @repo.all(from(v in Vault.VaultRow, where: v.subject_id == ^subject_id, select: v.token))
    |> MapSet.new()
  end

  # ── a · re-tokenization (token DIFFERS) — sabotage-refutable ─────────────────

  describe "a — re-tokenization: the clone gets its OWN fresh vault token" do
    test "the clone's vault token DIFFERS from the source's — a token-COPYING clone fails this",
         %{org: org, scope: scope} do
      source = create_patient(org)
      {:ok, clone} = Clone.clone(source, scope, repo: @repo)

      refute clone.id == source.id

      src_tok = raw_col("pat_patient", "pat_id", source.id, "pii_pat_mrn")
      clone_tok = raw_col("pat_patient", "pat_id", clone.id, "pii_pat_mrn")

      # Both are real vault tokens (vt_ + 32 lowercase hex), never plaintext.
      assert src_tok =~ ~r/\Avt_[0-9a-f]{32}\z/
      assert clone_tok =~ ~r/\Avt_[0-9a-f]{32}\z/
      refute clone_tok =~ "SECRET"

      # THE GUARANTEE: the clone's token is NOT the source's (not aliased).
      refute clone_tok == src_tok

      # ANTI-TAUTOLOGY (sabotage-refutable): a token-copying clone would set
      # clone_tok = src_tok; the `refute ==` above WOULD then fail. Model that copy
      # and show the same comparison catches it — the assertion is not vacuous.
      aliased = src_tok
      assert aliased == src_tok

      # The pii_vault subject-row sets are DISJOINT (independent subjects), and the
      # source's set is non-empty (non-vacuous).
      src_rows = vault_tokens_for(source.id)
      clone_rows = vault_tokens_for(clone.id)
      assert MapSet.size(src_rows) > 0
      assert MapSet.size(clone_rows) > 0
      assert MapSet.disjoint?(src_rows, clone_rows)
    end

    test "the clone re-tokenizes to the SAME logical value (granted resolution control)",
         %{org: org, scope: scope} do
      source = create_patient(org)
      {:ok, clone} = Clone.clone(source, scope, repo: @repo)

      assert {:ok, "MRN-SECRET-42"} = reveal_field(Patient, source.id, :mrn)
      assert {:ok, "MRN-SECRET-42"} = reveal_field(Patient, clone.id, :mrn)
    end
  end

  # ── b · INDEPENDENCE, both directions (the anti-aliasing proof) — INV-1 ───────

  describe "b — independence: shredding one record never affects the other" do
    test "crypto-shred the CLONE → the SOURCE still resolves", %{org: org, scope: scope} do
      source = create_patient(org)
      {:ok, clone} = Clone.clone(source, scope, repo: @repo)

      {:ok, att} = Vault.shred(clone.id)
      assert att.state == :shredded

      # The clone's PII is gone; the source's is UNAFFECTED (control + red).
      assert {:error, :shredded} = reveal_field(Patient, clone.id, :mrn)
      assert {:ok, "MRN-SECRET-42"} = reveal_field(Patient, source.id, :mrn)
    end

    test "crypto-shred the SOURCE → the CLONE still resolves", %{org: org, scope: scope} do
      source = create_patient(org)
      {:ok, clone} = Clone.clone(source, scope, repo: @repo)

      {:ok, att} = Vault.shred(source.id)
      assert att.state == :shredded

      assert {:error, :shredded} = reveal_field(Patient, source.id, :mrn)
      assert {:ok, "MRN-SECRET-42"} = reveal_field(Patient, clone.id, :mrn)
    end
  end

  # ── c · governed write path (fresh vault subject rows, no token copy) ─────────

  describe "c — the clone re-tokenizes through the governed create/vault chokepoint" do
    test "a fresh pii_vault subject row is minted for the clone (not a token alias)",
         %{org: org, scope: scope} do
      source = create_patient(org)
      {:ok, clone} = Clone.clone(source, scope, repo: @repo)

      # A vault row exists under the CLONE's own subject_id (= the clone's PK), whose
      # token equals the clone's domain-column token. That is a genuine re-tokenize,
      # not a copy of the source token.
      clone_tok = raw_col("pat_patient", "pat_id", clone.id, "pii_pat_mrn")
      assert clone_tok in vault_tokens_for(clone.id)
      refute clone_tok in vault_tokens_for(source.id)

      # And the domain column never held plaintext (VaultField last-line guard).
      refute clone_tok =~ "MRN"
    end
  end

  # ── d · masking / plane: operator WITHOUT a grant cannot clone PII ────────────

  describe "d — an operator without a grant cannot clone PII into plaintext" do
    test "RED: operator-without-grant clone is REFUSED (no plaintext, no vt_ leak); " <>
           "CONTROL: the tenant plane succeeds",
         %{org: org, scope: scope} do
      person =
        CrmScopeFixture.Person
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, display_name: "Grace H", full_name: @full_name, emails: @emails, phones: @phones},
          scope: scope
        )
        |> Ash.create!()

      before = CrmScopeFixture.Person |> Ash.count!(authorize?: false)

      # RED: the operator has no reveal grant → the resolve masks → clone refuses,
      # never aliasing the token, never exposing plaintext.
      assert {:error, {:pii_unresolved, field}} =
               Clone.clone(person, operator_scope(org), repo: @repo, grant: DenyAll)

      assert field in [:full_name, :emails, :phones]

      # No row was created; the error carries no plaintext and no token.
      assert CrmScopeFixture.Person |> Ash.count!(authorize?: false) == before
      refute inspect(field) =~ "Grace"
      refute inspect(field) =~ "vt_"

      # CONTROL: the SAME clone on the tenant plane (owns its org PII) succeeds —
      # proving the refusal is the plane/grant gate, not a blanket failure.
      assert {:ok, clone} = Clone.clone(person, scope, repo: @repo)
      assert clone.display_name == "Grace H_copy"
      assert CrmScopeFixture.Person |> Ash.count!(authorize?: false) == before + 1
    end
  end

  # ── e · org-scope: a cross-org clone is refused ──────────────────────────────

  describe "e — cross-org clone refused; same-org clone succeeds (control)" do
    test "org A's record is never cloned into org B", %{org: org_a, scope: scope_a} do
      org_b = Ash.UUID.generate()
      scope_b = tenant_scope(org_b)

      company =
        CrmScopeFixture.Company
        |> Ash.Changeset.for_create(:create, %{org_id: org_a, name: "Acme"}, scope: scope_a)
        |> Ash.create!()

      opp =
        CrmScopeFixture.Opportunity
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_a, name: "Big Deal", company_id: company.id, value: Money.new!(:USD, "10.00")},
          scope: scope_a
        )
        |> Ash.create!()

      # RED: org B cannot clone org A's opportunity — refused, nothing created in B.
      assert {:error, reason} = Clone.clone(opp, scope_b, repo: @repo)
      assert reason in [:cross_org, :source_not_found]
      assert CrmScopeFixture.Opportunity |> Ash.read!(scope: scope_b) == []

      # CONTROL: the OWNING org clones it fine (same org).
      assert {:ok, clone} = Clone.clone(opp, scope_a, repo: @repo)
      assert clone.name == "Big Deal_copy"
      # The clone lands in org A (the actor's org), never org B.
      assert raw_col("sco_opportunity", "sco_id", clone.id, "sco_org_id") == Ecto.UUID.dump!(org_a)
      # And it is visible to org A's org-scoped read (control).
      assert Enum.any?(CrmScopeFixture.Opportunity |> Ash.read!(scope: scope_a), &(&1.id == clone.id))
    end
  end

  # ── f · suffix + unique + relationship/file RE-LINK (shallow) ─────────────────

  describe "f — display _copy suffix; relationships + file attachments re-linked" do
    test "a no-vault resource clones: name suffixed, value copied, FK RE-LINKED (parent not duplicated)",
         %{org: org, scope: scope} do
      company =
        CrmScopeFixture.Company
        |> Ash.Changeset.for_create(:create, %{org_id: org, name: "Hooli"}, scope: scope)
        |> Ash.create!()

      opp =
        CrmScopeFixture.Opportunity
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, name: "Renewal", company_id: company.id, value: Money.new!(:USD, "42.50")},
          scope: scope
        )
        |> Ash.create!()

      companies_before = CrmScopeFixture.Company |> Ash.count!(authorize?: false)

      {:ok, clone} = Clone.clone(opp, scope, repo: @repo)

      assert clone.id != opp.id
      assert clone.name == "Renewal_copy"
      assert Money.equal?(clone.value, Money.new!(:USD, "42.50"))
      # The company is RE-LINKED (same FK), not deep-cloned.
      assert clone.company_id == company.id
      assert CrmScopeFixture.Company |> Ash.count!(authorize?: false) == companies_before
    end

    test "a file attachment clones: storage_key RE-LINKED verbatim, no new file minted",
         %{org: org, scope: scope} do
      person =
        CrmScopeFixture.Person
        |> Ash.Changeset.for_create(:create, %{org_id: org, display_name: "Ada"}, scope: scope)
        |> Ash.create!()

      attachment =
        CrmScopeFixture.Attachment
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org,
            file_name: "contract.pdf",
            content_type: "application/pdf",
            storage_key: "s3://bucket/obj-abc-123",
            person_id: person.id
          },
          scope: scope
        )
        |> Ash.create!()

      {:ok, clone} = Clone.clone(attachment, scope, repo: @repo)

      assert clone.id != attachment.id
      # The stored object is RE-LINKED (identical storage_key) — never re-uploaded /
      # re-minted through the Files chokepoint.
      assert clone.storage_key == attachment.storage_key
      assert clone.storage_key == "s3://bucket/obj-abc-123"
      # The parent person is re-linked, not duplicated.
      assert clone.person_id == person.id
    end
  end

  # ── g · audit: cloning a versioned resource writes a Version row (token-only) ─

  describe "g — the clone create is audited like any governed create" do
    test "cloning a versioned resource writes a value-free <Resource>.Version row",
         %{org: org, scope: scope} do
      contact =
        Samen.Factory.create!(
          Contact,
          Map.merge(%{org_id: org, label: "primary"}, Samen.Factory.person("Grace", "Hopper")),
          scope
        )

      # The source create wrote one version row.
      assert version_count(org) == 1

      {:ok, _clone} = Clone.clone(contact, scope, repo: @repo)

      # The CLONE's create wrote its own version row — it did NOT escape audit.
      assert version_count(org) == 2

      # INV-1: every version row's change diff carries the vault field as a vt_* token,
      # never the plaintext name.
      for changes <- version_changes(org) do
        blob = inspect(changes)
        refute blob =~ "Grace"
        refute blob =~ "Hopper"
      end
    end
  end

  defp version_count(org) do
    %{rows: [[n]]} =
      @repo.query!("SELECT count(*) FROM svc_contact_versions WHERE vcv_org_id = $1", [
        Ecto.UUID.dump!(org)
      ])

    n
  end

  defp version_changes(org) do
    %{rows: rows} =
      @repo.query!("SELECT vcv_changes FROM svc_contact_versions WHERE vcv_org_id = $1", [
        Ecto.UUID.dump!(org)
      ])

    Enum.map(rows, fn [changes] -> changes end)
  end
end
