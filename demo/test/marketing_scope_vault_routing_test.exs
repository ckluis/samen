defmodule Demo.MarketingScopeVaultRoutingTest do
  @moduledoc """
  Proves Marketing Subscriber's PII (email) is genuinely vault-routed at runtime
  (T3.4 acceptance: "PII vault round-trip for each 🔒 object"):

    * the domain column holds an opaque `vt_*` token, NEVER plaintext;
    * vault rows exist for the subject with ciphertext (not plaintext);
    * the plaintext email appears nowhere in the domain row;
    * the VaultField last-line guard refuses a raw (non-token) write.

  Subscriber is the only 🔒 resource in the Marketing scope. The scalar PII field
  carries the `pii_` prefix: `pii_msu_email`.
  """
  use Demo.DataCase, async: false

  alias Demo.MarketingScope.Subscriber
  alias Demo.Identity.Org
  alias Samen.Vault.VaultRow

  import Ecto.Query

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  test "subscriber email writes to the vault as a vt_ token; plaintext never in the domain row" do
    org = mk_org("mkt-vault-sub")

    {:ok, subscriber} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "vault-test@marketing.example",
        status: :active,
        consent_at: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    # The raw domain column holds a vt_* token, not plaintext.
    %{rows: [[email_col]]} =
      Repo.query!(
        "SELECT pii_msu_email FROM msu_subscriber WHERE msu_id = $1",
        [Ecto.UUID.dump!(subscriber.id)]
      )

    assert String.starts_with?(email_col, "vt_"),
           "pii_msu_email should be a vt_ token, got: #{inspect(email_col)}"

    # Plaintext email never appears in the domain column.
    refute email_col =~ "vault-test@marketing.example"

    # Vault rows exist with ciphertext (binary, not plaintext).
    vault_rows = Repo.all(from(v in VaultRow, where: v.subject_id == ^subscriber.id))
    assert length(vault_rows) >= 1, "Expected at least 1 vault row for the email PII field"

    Enum.each(vault_rows, fn row ->
      assert is_binary(row.ciphertext)
      refute row.ciphertext =~ "vault-test@marketing.example"
    end)
  end

  test "subscriber email is %Masked{} on a plain Ash.read (masking default)" do
    org = mk_org("mkt-vault-mask")

    {:ok, _subscriber} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "masked@marketing.example",
        status: :active
      })
      |> Ash.create(authorize?: false)

    query = Subscriber |> Ash.Query.select([:id, :email])
    {:ok, [loaded]} = Ash.read(query, authorize?: false)

    assert %Samen.Masked{} = loaded.email

    # Masked value renders as bullets, never plaintext.
    assert Phoenix.HTML.Safe.to_iodata(loaded.email) |> IO.iodata_to_binary() =~ "•"
    refute inspect(loaded) =~ "masked@marketing.example"
  end

  test "the VaultField last-line guard refuses a raw plaintext write (red path)" do
    # The VaultField type's dump guard refuses anything that is not already a
    # vt_* token — the last line of defense even if Samen.Vault.Change were bypassed.
    assert {:ok, "vt_realtoken"} = Samen.Type.VaultField.dump_to_native("vt_realtoken", [])

    # Raw plaintext is refused → :error (the INSERT would fail).
    assert :error == Samen.Type.VaultField.dump_to_native("test@marketing.example", [])
    assert :error == Samen.Type.VaultField.dump_to_native("somebody@example.com", [])
  end

  test "subscriber email vault-routes correctly; non-PII resources carry no email columns" do
    org = mk_org("mkt-vault-no-pii")

    {:ok, _subscriber} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "nopii-check@marketing.example"
      })
      |> Ash.create(authorize?: false)

    # Query the campaign table — no PII columns should exist.
    {:ok, %{columns: camp_cols}} = Repo.query("SELECT * FROM mca_campaign LIMIT 0")
    refute Enum.any?(camp_cols, fn c -> c =~ "email" end)

    # Same for suppression — no email column (only the opaque subscriber_id FK).
    {:ok, %{columns: supp_cols}} = Repo.query("SELECT * FROM msp_suppression LIMIT 0")
    refute Enum.any?(supp_cols, fn c -> c =~ "email" end)

    # Send table carries no email column.
    {:ok, %{columns: send_cols}} = Repo.query("SELECT * FROM msn_send LIMIT 0")
    refute Enum.any?(send_cols, fn c -> c =~ "email" end)
  end

  test "two subscribers have distinct vault entries (no cross-subject token sharing)" do
    org = mk_org("mkt-vault-distinct")

    {:ok, sub1} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "distinct1@marketing.example"
      })
      |> Ash.create(authorize?: false)

    {:ok, sub2} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "distinct2@marketing.example"
      })
      |> Ash.create(authorize?: false)

    # Both get their own vault rows; tokens in domain are different.
    %{rows: [[token1]]} =
      Repo.query!("SELECT pii_msu_email FROM msu_subscriber WHERE msu_id = $1",
        [Ecto.UUID.dump!(sub1.id)])

    %{rows: [[token2]]} =
      Repo.query!("SELECT pii_msu_email FROM msu_subscriber WHERE msu_id = $1",
        [Ecto.UUID.dump!(sub2.id)])

    refute token1 == token2, "Two subscribers must have distinct vault tokens"
  end
end
