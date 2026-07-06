defmodule Demo.CrmScopeVaultRoutingTest do
  @moduledoc """
  Proves CRM Person's PII (full_name/emails/phones via `Samen.Fragments.CorePerson`)
  is genuinely vault-routed at runtime (T3.2 acceptance: "PII vault round-trip for
  each 🔒 object"):

    * the domain column holds an opaque `vt_*` token, NEVER plaintext;
    * a vault row exists for the subject with ciphertext (not plaintext);
    * the plaintext appears nowhere in the domain row;
    * all three composite fields (full_name, emails, phones) are each vault-routed;
    * a red path: the VaultField last-line guard refuses a raw (non-token) write.

  This is the **canonical vault case** from the vision doc (§core "The proof —
  one base, many shapes"): `per_full_name`, `per_emails`, `per_phones` are
  composite PII columns carrying `vt_*` tokens after a create.
  """
  use Demo.DataCase, async: false

  alias Demo.CrmScope.Person
  alias Demo.Identity.Org
  alias Samen.Vault.VaultRow

  import Ecto.Query

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  test "person full_name/emails/phones write to the vault as vt_ tokens; plaintext never in the domain row" do
    org = mk_org("crm-vault-person")

    {:ok, person} =
      Person
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        display_name: "Alice",
        full_name: %{first: "Alice", last: "Anders"},
        emails: ["alice@crmsecret.example"],
        phones: ["+15559876543"]
      })
      |> Ash.create(authorize?: false)

    # The raw domain columns hold vt_* tokens, not plaintext.
    %{rows: [[full_name_col, emails_col, phones_col]]} =
      Repo.query!(
        "SELECT per_full_name, per_emails, per_phones FROM per_person WHERE per_id = $1",
        [Ecto.UUID.dump!(person.id)]
      )

    assert String.starts_with?(full_name_col, "vt_"),
           "per_full_name should be a vt_ token, got: #{inspect(full_name_col)}"

    assert String.starts_with?(emails_col, "vt_"),
           "per_emails should be a vt_ token, got: #{inspect(emails_col)}"

    assert String.starts_with?(phones_col, "vt_"),
           "per_phones should be a vt_ token, got: #{inspect(phones_col)}"

    # Plaintext values never appear in the domain columns.
    refute full_name_col =~ "Alice"
    refute emails_col =~ "alice@crmsecret.example"
    refute phones_col =~ "+15559876543"

    # Vault rows exist with ciphertext (binary, not plaintext).
    vault_rows = Repo.all(from(v in VaultRow, where: v.subject_id == ^person.id))
    assert length(vault_rows) >= 3, "Expected at least 3 vault rows (one per PII field)"

    Enum.each(vault_rows, fn row ->
      assert is_binary(row.ciphertext)
      refute row.ciphertext =~ "Alice"
      refute row.ciphertext =~ "alice@crmsecret.example"
      refute row.ciphertext =~ "+15559876543"
    end)

    # PII plaintext appears NOWHERE in the PII columns (vt_* tokens confirmed above).
    # The full_name/emails/phones token columns must NOT contain plaintext names or
    # contact data. (per_display_name is a non-PII plain column and may contain
    # the display name — that is correct and expected behavior.)
    refute full_name_col =~ "Alice"
    refute full_name_col =~ "Anders"
    refute emails_col =~ "alice"
    refute phones_col =~ "5559876543"
  end

  test "each composite PII field is individually vault-routed (three vault entries)" do
    org = mk_org("crm-vault-triple")

    {:ok, person} =
      Person
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        display_name: "Bob",
        full_name: %{first: "Bob", last: "Builder"},
        emails: ["bob@triple.example"],
        phones: ["+15551112222"]
      })
      |> Ash.create(authorize?: false)

    vault_rows = Repo.all(from(v in VaultRow, where: v.subject_id == ^person.id))

    # One row per PII field (full_name, emails, phones) — at minimum 3.
    assert length(vault_rows) >= 3

    # Each ciphertext is different (different vault names → different ciphertexts
    # under the per-subject key).
    ciphertexts = Enum.map(vault_rows, & &1.ciphertext)
    assert length(Enum.uniq(ciphertexts)) == length(ciphertexts),
           "Expected distinct ciphertext per PII field"
  end

  test "person PII is %Masked{} on a plain Ash.read (masking default)" do
    org = mk_org("crm-vault-mask")

    {:ok, _person} =
      Person
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        display_name: "Carol",
        full_name: %{first: "Carol", last: "Cipher"},
        emails: ["carol@mask.example"],
        phones: ["+15550000001"]
      })
      |> Ash.create(authorize?: false)

    query = Person |> Ash.Query.select([:id, :full_name, :emails, :phones])
    {:ok, [loaded]} = Ash.read(query, authorize?: false)

    assert %Samen.Masked{} = loaded.full_name
    assert %Samen.Masked{} = loaded.emails
    assert %Samen.Masked{} = loaded.phones

    # Masked values render as bullets, never plaintext.
    assert Phoenix.HTML.Safe.to_iodata(loaded.full_name) |> IO.iodata_to_binary() =~ "•"
    refute inspect(loaded) =~ "Carol"
  end

  test "the VaultField last-line guard refuses a raw plaintext write (red path)" do
    # The VaultField type's dump guard refuses anything that is not already a
    # vt_* token — the last line of defense even if Samen.Vault.Change were bypassed.
    assert {:ok, "vt_realtoken"} = Samen.Type.VaultField.dump_to_native("vt_realtoken", [])

    # Raw plaintext is refused → :error (the INSERT would fail).
    assert :error == Samen.Type.VaultField.dump_to_native("alice@crmsecret.example", [])
    assert :error == Samen.Type.VaultField.dump_to_native("Alice Anders", [])
    assert :error == Samen.Type.VaultField.dump_to_native("+15559876543", [])
  end
end
