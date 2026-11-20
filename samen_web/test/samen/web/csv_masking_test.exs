defmodule Samen.Web.CsvMaskingTest do
  @moduledoc """
  WS-E E3.2 — THE EXPORT MASK-BY-OMISSION RED-PATH (ADR-028; AC-G15-2,
  NON-NEGOTIABLE; RP-CSV-1). Export is the highest-risk WS-E masking surface: a
  CSV leaves the app, so a cell that leaks what the UI masks is an exfiltration
  channel. The invariant proven here: **the CSV cell and the pixel show the SAME
  value on the same plane.**

  Consumer of `Samen.MaskingCase` (E2i.1) — the same green/red/sabotage discipline
  as the file-preview and notifications masking tests:

    * **GREEN** — tenant own-org export carries the vaulted composite in the CLEAR.
    * **RED** — operator (impersonation) export cell is exactly `••••`: never the
      plaintext, never a `vt_*` vault token — and EQUAL to the UI value (the
      resolver output stringified), byte-for-byte.
    * **SABOTAGE twins** — (1) plane flip: the SAME rows exported on the tenant
      plane go clear (the resolver is the gate — sabotaging `Csv`'s actor to the
      tenant plane is the committed RP-CSV-1 patch and FAILS the red test);
      (2) leak scan refutability: a modeled raw-row export (the at-rest vault
      token serialized without resolution) IS caught by the same `vt_` scan.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Factory
  alias Samen.Masked
  alias Samen.Web.Csv
  alias Samen.Web.Plane

  alias Samen.WebTest.Crm.Person

  @secret_first "VaultedCsvFirst"
  @secret_last "Csv-Export-Secret"

  defp tenant_scope(org_id), do: Plane.scope(Plane.tenant(), org_id)

  defp operator_scope(org_id),
    do: Plane.scope(Plane.operator("op-1", org_id, "csv-mask-session"), org_id)

  defp seed_secret_person!(org_id) do
    Factory.create!(
      Person,
      Map.merge(Factory.person(@secret_first, @secret_last), %{
        display_name: "Public Display",
        org_id: org_id
      }),
      tenant_scope(org_id)
    )
  end

  defp export!(scope) do
    {:ok, csv} =
      Csv.export(Person, scope, repo: Samen.WebTest.Repo, columns: [:display_name, :full_name])

    csv
  end

  defp full_name_cell(csv) do
    [header | rows] = Csv.parse(csv)
    idx = Enum.find_index(header, &(&1 == "full_name"))
    assert idx, "full_name column missing from export header"
    [row] = rows
    Enum.at(row, idx)
  end

  describe "import cannot plant a vault token (token-binding T-W1)" do
    test "a vt_<hex> cell naming ANOTHER org's live token imports as plaintext: a NEW token, the literal string back, the foreign row untouched" do
      victim_org = Ash.UUID.generate()
      attacker_org = Ash.UUID.generate()
      victim = seed_secret_person!(victim_org)

      victim_masked = read_full_name!(victim.id)
      victim_token = victim_masked.token
      assert Samen.Vault.token?(victim_token)

      csv = "display_name,full_name\nPlanted,#{victim_token}\n"

      assert {:ok, %Csv.Report{created: 1, errors: []}} =
               Csv.import(Person, tenant_scope(attacker_org), csv: csv)

      [planted] =
        Person |> Ash.Query.filter(org_id == ^attacker_org) |> Ash.read!(authorize?: false)

      planted_masked = read_full_name!(planted.id)

      # a NEW token, not the victim's
      refute planted_masked.token == victim_token
      assert Samen.Vault.token?(planted_masked.token)

      # tenant resolution of the planted record returns the literal cell, never the victim's PII
      resolved =
        resolve_on_plane(%{planted | full_name: planted_masked}, Person, :tenant, repo: Samen.WebTest.Repo)

      refute inspect(resolved.full_name) =~ @secret_first
      refute to_string(resolved.full_name) =~ @secret_last

      assert {:ok, revealed} = Samen.Vault.reveal(planted_masked, Samen.WebTest.Repo)
      assert revealed =~ victim_token
      refute revealed =~ @secret_first

      # the foreign row is untouched and still reveals the victim's own value
      assert {:ok, victim_plain} = Samen.Vault.reveal(victim_masked, Samen.WebTest.Repo)
      assert victim_plain =~ @secret_first
    end

    test "CONTROL: an ordinary plaintext cell still imports and vaults" do
      org_id = Ash.UUID.generate()
      csv = "display_name,full_name\nOrdinary,Plain Name\n"

      assert {:ok, %Csv.Report{created: 1, errors: []}} =
               Csv.import(Person, tenant_scope(org_id), csv: csv)

      [p] = Person |> Ash.Query.filter(org_id == ^org_id) |> Ash.read!(authorize?: false)
      m = read_full_name!(p.id)
      assert Samen.Vault.token?(m.token)
      assert {:ok, plain} = Samen.Vault.reveal(m, Samen.WebTest.Repo)
      assert plain =~ "Plain Name"
    end
  end

  defp read_full_name!(id) do
    Person
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:full_name])
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:full_name)
  end

  describe "export masking per plane (AC-G15-2)" do
    test "GREEN: tenant own-org export carries the vaulted composite in the CLEAR" do
      org_id = Ash.UUID.generate()
      seed_secret_person!(org_id)

      csv = export!(tenant_scope(org_id))

      assert csv =~ @secret_first
      assert csv =~ @secret_last
      refute csv =~ "vt_"
      # Non-PII columns ride along unmasked on every plane.
      assert csv =~ "Public Display"
    end

    test "RED: operator export cell is •••• — NEVER plaintext, NEVER a vt_ token (RP-CSV-1)" do
      org_id = Ash.UUID.generate()
      seed_secret_person!(org_id)

      csv = export!(operator_scope(org_id))

      # The whole-document scan: mask present, both plaintext halves ABSENT,
      # no vault token anywhere. Sabotaging Csv's plane resolution (the committed
      # RP-CSV-1 patch) leaks the plaintext and FAILS here.
      assert_masked_dom!(csv, [@secret_first, @secret_last])

      # The exact cell is the mask — not a JSON blob wrapping it, not a token.
      assert full_name_cell(csv) == Samen.MaskingCase.mask()

      # Non-PII cells are untouched: masking is per-field, not per-file.
      assert csv =~ "Public Display"
    end

    test "the CSV cell EQUALS the UI value on the operator plane (the same-pixel rule)" do
      org_id = Ash.UUID.generate()
      person = seed_secret_person!(org_id)

      # The UI value: the record resolved through the SAME seam every LiveView
      # renders through, on the operator plane, stringified as the DOM would.
      at_rest =
        Person
        |> Ash.Query.filter(id == ^person.id)
        |> Ash.Query.ensure_selected([:full_name])
        |> Ash.read_one!(authorize?: false)

      ui_value =
        at_rest
        |> resolve_on_plane(Person, :operator, repo: Samen.WebTest.Repo)
        |> Map.get(:full_name)

      assert_plane_masked!(ui_value)

      csv = export!(operator_scope(org_id))
      assert full_name_cell(csv) == to_string(ui_value)
    end

    test "ANTI-TAUTOLOGY: the SAME rows exported on the tenant plane go CLEAR (plane flip)" do
      org_id = Ash.UUID.generate()
      seed_secret_person!(org_id)

      # As-designed: operator masked.
      operator_csv = export!(operator_scope(org_id))
      assert_masked_dom!(operator_csv, [@secret_first])

      # SABOTAGE (plane flip): the only difference is the scope's plane — the
      # export goes clear, proving the mask is the resolver's per-plane decision,
      # not a serialize-everything-as-•••• blanket.
      tenant_csv = export!(tenant_scope(org_id))
      assert tenant_csv =~ @secret_first
      refute tenant_csv =~ Samen.MaskingCase.mask()
    end

    test "ANTI-TAUTOLOGY: a modeled raw-row export IS caught by the vt_ leak scan" do
      org_id = Ash.UUID.generate()
      person = seed_secret_person!(org_id)

      # A broken export that serializes the AT-REST row without resolution would
      # write the vault token into the cell. Model exactly that leak and prove
      # the scan the RED test relies on (refute csv =~ "vt_") is refutable.
      at_rest =
        Person
        |> Ash.Query.filter(id == ^person.id)
        |> Ash.Query.ensure_selected([:full_name])
        |> Ash.read_one!(authorize?: false)

      assert %Masked{token: "vt_" <> _ = token} = at_rest.full_name

      leaked_csv = Csv.serialize([["full_name"], [token]])
      assert_leak_detected!(leaked_csv, "vt_")
    end
  end
end
