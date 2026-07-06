defmodule Demo.IdentityVaultRoutingTest do
  @moduledoc """
  Proves Identity's PII (user 🔒 full_name/emails, invitation 🔒 email) is genuinely
  vault-routed at RUNTIME (T3.1 acceptance: "user/invitation PII vaulted"):

    * the domain column holds an opaque `vt_*` token, NEVER plaintext;
    * a vault row exists for the subject with ciphertext (not plaintext);
    * the plaintext never appears in the domain row;
    * a red path: an un-vaulted (raw) PII write would be refused by the
      `Samen.Type.VaultField` last-line guard.
  """
  use Demo.DataCase, async: false

  alias Demo.Identity.{Org, User, Invitation}
  alias Samen.Vault.VaultRow

  import Ecto.Query

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  test "user full_name/emails write to the vault as vt_ tokens; plaintext never in the domain row" do
    org = mk_org("vault-user")

    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "vaulted",
        org_id: org.id,
        full_name: %{first: "Alice", last: "Anders"},
        emails: ["alice@secret.example"]
      })
      |> Ash.create(authorize?: false)

    # The raw domain columns hold vt_* tokens, not plaintext.
    %{rows: [[full_name_col, emails_col]]} =
      Repo.query!(
        "SELECT usr_full_name, usr_emails FROM usr_user WHERE usr_id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    assert String.starts_with?(full_name_col, "vt_")
    assert String.starts_with?(emails_col, "vt_")
    refute full_name_col =~ "Alice"
    refute emails_col =~ "alice@secret.example"

    # A vault row exists for the subject, carrying ciphertext (binary), not plaintext.
    vault_rows = Repo.all(from(v in VaultRow, where: v.subject_id == ^user.id))
    assert length(vault_rows) >= 2

    Enum.each(vault_rows, fn row ->
      assert is_binary(row.ciphertext)
      refute row.ciphertext =~ "Alice"
      refute row.ciphertext =~ "alice@secret.example"
    end)

    # The plaintext appears NOWHERE in the whole usr_user row.
    %{rows: [row_values]} =
      Repo.query!("SELECT * FROM usr_user WHERE usr_id = $1", [Ecto.UUID.dump!(user.id)])

    row_text = row_values |> Enum.map(&inspect/1) |> Enum.join(" ")
    refute row_text =~ "Alice"
    refute row_text =~ "alice@secret.example"
  end

  test "invitation email writes to the vault as a vt_ token (invitation🔒 routing)" do
    org = mk_org("vault-invite")

    {:ok, invite} =
      Invitation
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        role: :member,
        email: ["newhire@secret.example"]
      })
      |> Ash.create(authorize?: false)

    %{rows: [[email_col]]} =
      Repo.query!("SELECT inv_email FROM inv_invitation WHERE inv_id = $1", [
        Ecto.UUID.dump!(invite.id)
      ])

    assert String.starts_with?(email_col, "vt_")
    refute email_col =~ "newhire@secret.example"

    vault_rows = Repo.all(from(v in VaultRow, where: v.subject_id == ^invite.id))
    assert length(vault_rows) >= 1
    assert Enum.all?(vault_rows, fn r -> is_binary(r.ciphertext) end)
  end

  test "the VaultField last-line guard refuses a raw (non-token) plaintext write (red path)" do
    # Even if a bug bypassed Samen.Vault.Change, the VaultField type's dump guard
    # refuses to persist anything that is not already a vt_* token. We prove the
    # guard by calling dump_to_native/2 directly with a plaintext value.
    assert {:ok, "vt_realtoken"} = Samen.Type.VaultField.dump_to_native("vt_realtoken", [])

    # A raw plaintext (not a token) is refused → :error (the insert would fail).
    assert :error == Samen.Type.VaultField.dump_to_native("alice@secret.example", [])
    assert :error == Samen.Type.VaultField.dump_to_native("Alice Anders", [])
  end
end
