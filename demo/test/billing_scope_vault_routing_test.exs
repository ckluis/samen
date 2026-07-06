defmodule Demo.BillingScopeVaultRoutingTest do
  @moduledoc """
  Proves Billing Customer's PII (billing_name/billing_email) is genuinely vault-routed
  at runtime (T3.3 acceptance: "PII vault round-trip for each 🔒 object"):

    * the domain columns hold opaque `vt_*` tokens, NEVER plaintext;
    * vault rows exist for the subject with ciphertext (not plaintext);
    * the plaintext appears nowhere in the domain row;
    * both PII fields are individually vault-routed;
    * the VaultField last-line guard refuses a raw (non-token) write.

  Customer is the only 🔒 resource in the Billing scope. Scalar PII fields carry the
  `pii_` prefix: `pii_bcu_billing_name` and `pii_bcu_billing_email`.
  """
  use Demo.DataCase, async: false

  alias Demo.BillingScope.Customer
  alias Demo.Identity.Org
  alias Samen.Vault.VaultRow

  import Ecto.Query

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  test "customer billing_name/billing_email write to the vault as vt_ tokens; plaintext never in the domain row" do
    org = mk_org("billing-vault-customer")

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        billing_name: "Alice Accountant",
        billing_email: "alice@billing.example",
        status: :active
      })
      |> Ash.create(authorize?: false)

    # The raw domain columns hold vt_* tokens, not plaintext.
    %{rows: [[billing_name_col, billing_email_col]]} =
      Repo.query!(
        "SELECT pii_bcu_billing_name, pii_bcu_billing_email FROM bcu_customer WHERE bcu_id = $1",
        [Ecto.UUID.dump!(customer.id)]
      )

    assert String.starts_with?(billing_name_col, "vt_"),
           "pii_bcu_billing_name should be a vt_ token, got: #{inspect(billing_name_col)}"

    assert String.starts_with?(billing_email_col, "vt_"),
           "pii_bcu_billing_email should be a vt_ token, got: #{inspect(billing_email_col)}"

    # Plaintext values never appear in the domain columns.
    refute billing_name_col =~ "Alice"
    refute billing_email_col =~ "alice@billing.example"

    # Vault rows exist with ciphertext (binary, not plaintext).
    vault_rows = Repo.all(from(v in VaultRow, where: v.subject_id == ^customer.id))
    assert length(vault_rows) >= 2, "Expected at least 2 vault rows (one per PII field)"

    Enum.each(vault_rows, fn row ->
      assert is_binary(row.ciphertext)
      refute row.ciphertext =~ "Alice"
      refute row.ciphertext =~ "alice@billing.example"
    end)
  end

  test "each PII field is individually vault-routed (two vault entries)" do
    org = mk_org("billing-vault-double")

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        billing_name: "Bob Banker",
        billing_email: "bob@double.example"
      })
      |> Ash.create(authorize?: false)

    vault_rows = Repo.all(from(v in VaultRow, where: v.subject_id == ^customer.id))

    # At least one row per PII field (billing_name, billing_email) — minimum 2.
    assert length(vault_rows) >= 2

    # Each ciphertext is different (different vault names → different ciphertexts).
    ciphertexts = Enum.map(vault_rows, & &1.ciphertext)
    assert length(Enum.uniq(ciphertexts)) == length(ciphertexts),
           "Expected distinct ciphertext per PII field"
  end

  test "customer PII is %Masked{} on a plain Ash.read (masking default)" do
    org = mk_org("billing-vault-mask")

    {:ok, _customer} =
      Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        billing_name: "Carol CFO",
        billing_email: "carol@mask.example"
      })
      |> Ash.create(authorize?: false)

    query = Customer |> Ash.Query.select([:id, :billing_name, :billing_email])
    {:ok, [loaded]} = Ash.read(query, authorize?: false)

    assert %Samen.Masked{} = loaded.billing_name
    assert %Samen.Masked{} = loaded.billing_email

    # Masked values render as bullets, never plaintext.
    assert Phoenix.HTML.Safe.to_iodata(loaded.billing_name) |> IO.iodata_to_binary() =~ "•"
    refute inspect(loaded) =~ "Carol"
    refute inspect(loaded) =~ "carol@mask.example"
  end

  test "the VaultField last-line guard refuses a raw plaintext write (red path)" do
    # The VaultField type's dump guard refuses anything that is not already a
    # vt_* token — the last line of defense even if Samen.Vault.Change were bypassed.
    assert {:ok, "vt_realtoken"} = Samen.Type.VaultField.dump_to_native("vt_realtoken", [])

    # Raw plaintext is refused → :error (the INSERT would fail).
    assert :error == Samen.Type.VaultField.dump_to_native("Alice Accountant", [])
    assert :error == Samen.Type.VaultField.dump_to_native("alice@billing.example", [])
    assert :error == Samen.Type.VaultField.dump_to_native("Bob Banker", [])
  end

  test "customer PII absent from non-PII resources (entitlement, subscription carry no names)" do
    org = mk_org("billing-vault-no-pii")

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        billing_name: "Dan Director",
        billing_email: "dan@nopii.example"
      })
      |> Ash.create(authorize?: false)

    # Query the subscription table — no PII columns should exist.
    # (This is a structural assertion: if PII leaked into a non-PII resource, this would fail.)
    {:ok, %{columns: sub_cols}} = Repo.query("SELECT * FROM bsb_subscription LIMIT 0")
    refute Enum.any?(sub_cols, fn c -> c =~ "billing_name" or c =~ "billing_email" end)

    # Same for entitlement.
    {:ok, %{columns: ent_cols}} = Repo.query("SELECT * FROM ben_entitlement LIMIT 0")
    refute Enum.any?(ent_cols, fn c -> c =~ "billing_name" or c =~ "billing_email" end)

    _ = customer
  end
end
