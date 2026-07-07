defmodule Demo.PrimitivesScopeVaultRoutingTest do
  @moduledoc """
  Proves Primitives scope PII (notification🔒 rendered_body and webhook🔒
  signing_secret) is genuinely vault-routed at runtime (T3.7 acceptance:
  "PII vault round-trip for each 🔒 object"):

    * the domain column holds an opaque `vt_*` token, NEVER plaintext;
    * vault rows exist for the subject with ciphertext (not plaintext);
    * the plaintext value appears nowhere in the domain row;
    * the VaultField last-line guard refuses a raw (non-token) write;
    * %Masked{} is the default read value.

  Two 🔒 resources:
    * Notification — rendered_body (scalar, pii_pnt_rendered_body): vaulted body.
    * Webhook       — signing_secret (scalar, pii_pwh_signing_secret): vaulted credential.
  """
  use Demo.DataCase, async: false

  alias Demo.PrimitivesScope.{Notification, Webhook}
  alias Demo.Identity.Org
  alias Samen.Vault.VaultRow

  import Ecto.Query

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  # ===========================================================================
  # Notification — rendered_body (pii_pnt_rendered_body)
  # ===========================================================================

  test "notification rendered_body writes to vault as a vt_ token; plaintext never in domain row" do
    org = mk_org("vault-ntf-body")
    plaintext_body = "Dear Alice Smith, your invoice #INV-#{:rand.uniform(9999)} is ready."

    {:ok, notification} =
      Notification
      |> Ash.Changeset.for_create(:create, %{
        recipient_id: Ash.UUID.generate(),
        channel: :email,
        event_type: "invoice.created",
        status: :sent,
        rendered_body: plaintext_body,
        sent_at: DateTime.utc_now(),
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    # The raw domain column holds a vt_* token, not plaintext.
    %{rows: [[body_col]]} =
      Repo.query!(
        "SELECT pii_pnt_rendered_body FROM pnt_notification WHERE pnt_id = $1",
        [Ecto.UUID.dump!(notification.id)]
      )

    assert String.starts_with?(body_col, "vt_"),
           "pii_pnt_rendered_body should be a vt_ token, got: #{inspect(body_col)}"

    # Plaintext never in domain column.
    refute body_col =~ plaintext_body
    refute body_col =~ "Alice Smith"
    refute body_col =~ "INV-"

    # Vault rows exist with ciphertext (binary, not plaintext).
    vault_rows = Repo.all(from(v in VaultRow, where: v.subject_id == ^notification.id))
    assert length(vault_rows) >= 1

    Enum.each(vault_rows, fn row ->
      assert is_binary(row.ciphertext)
      refute row.ciphertext =~ plaintext_body
    end)
  end

  test "notification rendered_body is %Masked{} on a plain Ash.read (mask-by-default)" do
    org = mk_org("vault-ntf-mask")

    {:ok, _notification} =
      Notification
      |> Ash.Changeset.for_create(:create, %{
        recipient_id: Ash.UUID.generate(),
        channel: :email,
        event_type: "invoice.created",
        status: :sent,
        rendered_body: "Confidential notification with personal details.",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    query = Notification |> Ash.Query.select([:id, :rendered_body])
    {:ok, [loaded]} = Ash.read(query, authorize?: false)

    assert %Samen.Masked{} = loaded.rendered_body
    assert Phoenix.HTML.Safe.to_iodata(loaded.rendered_body) |> IO.iodata_to_binary() =~ "•"
    refute inspect(loaded) =~ "Confidential notification"
  end

  test "two notifications have distinct vault entries (no cross-subject token sharing)" do
    org = mk_org("vault-ntf-distinct")

    {:ok, n1} =
      Notification
      |> Ash.Changeset.for_create(:create, %{
        recipient_id: Ash.UUID.generate(),
        channel: :email,
        event_type: "event.a",
        status: :sent,
        rendered_body: "First notification body.",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    {:ok, n2} =
      Notification
      |> Ash.Changeset.for_create(:create, %{
        recipient_id: Ash.UUID.generate(),
        channel: :sms,
        event_type: "event.b",
        status: :sent,
        rendered_body: "Second distinct notification body.",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    %{rows: [[token1]]} =
      Repo.query!("SELECT pii_pnt_rendered_body FROM pnt_notification WHERE pnt_id = $1",
        [Ecto.UUID.dump!(n1.id)])

    %{rows: [[token2]]} =
      Repo.query!("SELECT pii_pnt_rendered_body FROM pnt_notification WHERE pnt_id = $1",
        [Ecto.UUID.dump!(n2.id)])

    refute token1 == token2, "Two notifications must have distinct vault tokens"
  end

  # ===========================================================================
  # Webhook — signing_secret (pii_pwh_signing_secret)
  # ===========================================================================

  test "webhook signing_secret writes to vault as a vt_ token; plaintext never in domain row" do
    org = mk_org("vault-pwh-secret")
    plaintext_secret = "whsec-#{Ash.UUID.generate()}-super-secret-value"

    {:ok, webhook} =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook/vault-test",
        label: "Vault test webhook",
        event_types: ["invoice.created"],
        status: :active,
        signing_secret: plaintext_secret,
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    # The raw domain column holds a vt_* token, not plaintext.
    %{rows: [[secret_col]]} =
      Repo.query!(
        "SELECT pii_pwh_signing_secret FROM pwh_webhook WHERE pwh_id = $1",
        [Ecto.UUID.dump!(webhook.id)]
      )

    assert String.starts_with?(secret_col, "vt_"),
           "pii_pwh_signing_secret should be a vt_ token, got: #{inspect(secret_col)}"

    # Plaintext never in domain column.
    refute secret_col =~ plaintext_secret
    refute secret_col =~ "whsec-"
    refute secret_col =~ "super-secret-value"

    # Vault rows exist with ciphertext.
    vault_rows = Repo.all(from(v in VaultRow, where: v.subject_id == ^webhook.id))
    assert length(vault_rows) >= 1

    Enum.each(vault_rows, fn row ->
      assert is_binary(row.ciphertext)
      refute row.ciphertext =~ plaintext_secret
    end)
  end

  test "webhook signing_secret is %Masked{} on a plain Ash.read (mask-by-default)" do
    org = mk_org("vault-pwh-mask")

    {:ok, _webhook} =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook/mask-test",
        event_types: ["test"],
        signing_secret: "masked-secret-#{Ash.UUID.generate()}",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    query = Webhook |> Ash.Query.select([:id, :signing_secret])
    {:ok, [loaded]} = Ash.read(query, authorize?: false)

    assert %Samen.Masked{} = loaded.signing_secret
    assert Phoenix.HTML.Safe.to_iodata(loaded.signing_secret) |> IO.iodata_to_binary() =~ "•"
    refute inspect(loaded) =~ "masked-secret-"
  end

  test "two webhooks have distinct vault entries for signing_secret" do
    org = mk_org("vault-pwh-distinct")

    {:ok, w1} =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook/w1",
        event_types: ["event.a"],
        signing_secret: "secret-w1-#{Ash.UUID.generate()}",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    {:ok, w2} =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook/w2",
        event_types: ["event.b"],
        signing_secret: "secret-w2-#{Ash.UUID.generate()}",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    %{rows: [[token1]]} =
      Repo.query!("SELECT pii_pwh_signing_secret FROM pwh_webhook WHERE pwh_id = $1",
        [Ecto.UUID.dump!(w1.id)])

    %{rows: [[token2]]} =
      Repo.query!("SELECT pii_pwh_signing_secret FROM pwh_webhook WHERE pwh_id = $1",
        [Ecto.UUID.dump!(w2.id)])

    refute token1 == token2, "Two webhooks must have distinct signing secret vault tokens"
  end

  # ===========================================================================
  # Reveal action — grant-checker denial by default
  # ===========================================================================

  test "reveal_notification action denies without a grant (default deny)" do
    org = mk_org("reveal-ntf-deny")

    {:ok, notification} =
      Notification
      |> Ash.Changeset.for_create(:create, %{
        recipient_id: Ash.UUID.generate(),
        channel: :email,
        event_type: "test",
        rendered_body: "Reveal-denied body content.",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    result =
      Notification
      |> Ash.ActionInput.for_action(:reveal_notification, %{
        actor_id: Ash.UUID.generate(),
        subject_id: notification.id
      })
      |> Ash.run_action(authorize?: false)

    assert {:error, _} = result
    # Ash wraps the :denied atom in Ash.Error.Unknown; either form is fail-closed.
    case result do
      {:error, :denied} -> :ok
      {:error, %Ash.Error.Unknown{}} -> :ok
      {:error, other} -> assert inspect(other) =~ "denied"
    end
  end

  test "reveal_webhook action denies without a grant (default deny)" do
    org = mk_org("reveal-pwh-deny")

    {:ok, webhook} =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook/reveal-test",
        event_types: ["test"],
        signing_secret: "deny-test-secret",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    result =
      Webhook
      |> Ash.ActionInput.for_action(:reveal_webhook, %{
        actor_id: Ash.UUID.generate(),
        subject_id: webhook.id
      })
      |> Ash.run_action(authorize?: false)

    assert {:error, _} = result
    case result do
      {:error, :denied} -> :ok
      {:error, %Ash.Error.Unknown{}} -> :ok
      {:error, other} -> assert inspect(other) =~ "denied"
    end
  end

  # ===========================================================================
  # Non-PII resources carry no pii_ columns
  # ===========================================================================

  test "non-PII resources (file, search_index, feature_flag) carry no pii_ columns" do
    {:ok, %{columns: file_cols}} = Repo.query("SELECT * FROM pfl_file LIMIT 0")
    refute Enum.any?(file_cols, fn c -> String.starts_with?(c, "pii_") end)

    {:ok, %{columns: search_cols}} = Repo.query("SELECT * FROM psh_search_index LIMIT 0")
    refute Enum.any?(search_cols, fn c -> String.starts_with?(c, "pii_") end)

    {:ok, %{columns: ff_cols}} = Repo.query("SELECT * FROM pff_feature_flag LIMIT 0")
    refute Enum.any?(ff_cols, fn c -> String.starts_with?(c, "pii_") end)
  end

  # ===========================================================================
  # VaultField last-line guard
  # ===========================================================================

  test "VaultField last-line guard refuses raw plaintext write for notification (red path)" do
    # The guard that protects notification rendered_body and webhook signing_secret.
    assert {:ok, "vt_realtoken"} = Samen.Type.VaultField.dump_to_native("vt_realtoken", [])

    # Raw plaintext must be rejected.
    assert :error == Samen.Type.VaultField.dump_to_native("Dear Alice, your invoice is ready.", [])
    assert :error == Samen.Type.VaultField.dump_to_native("whsec-plaintext-secret", [])
  end

  # ===========================================================================
  # F3.1 de-vault backstop: vault_declared_parity fails closed when a free-text
  # 🔒 field (webhook.signing_secret / notification.rendered_body) is de-vaulted
  # — the pii_ column stays in the DB while the resource drops the vault route.
  # Neither "signing_secret" nor "rendered_body" is a C4 pii_classify name-token,
  # so this verifier (DB-truth parity) is the fail-closed gate for these fields.
  # ===========================================================================

  alias Mix.Tasks.Samen.Verify.VaultDeclaredParity, as: VaultParity

  defp primitives_routed do
    domains = Application.get_env(:demo, :ash_domains, [])
    resources = Samen.Catalog.resource_modules(domains)
    VaultParity.routed_vault_columns(resources)
  end

  test "vault_declared_parity is GREEN while signing_secret + rendered_body ARE routed (control)" do
    violations = VaultParity.check(Demo.Repo, primitives_routed())

    flagged =
      Enum.filter(violations, fn v ->
        v =~ "pii_pwh_signing_secret" or v =~ "pii_pnt_rendered_body"
      end)

    assert flagged == [],
           "vaulted free-text fields must not be flagged while routed, got: #{inspect(flagged)}"
  end

  test "de-vaulting webhook.signing_secret (drop route, keep column) is CAUGHT (red path)" do
    routed_without_secret =
      MapSet.delete(primitives_routed(), {"pwh_webhook", "pii_pwh_signing_secret"})

    violations = VaultParity.check(Demo.Repo, routed_without_secret)

    assert Enum.any?(violations, fn v ->
             v =~ "pwh_webhook.pii_pwh_signing_secret" and v =~ "de-vaulted PII column"
           end),
           "de-vaulting signing_secret must be caught, got: #{inspect(violations)}"
  end

  test "de-vaulting notification.rendered_body (drop route, keep column) is CAUGHT (red path)" do
    routed_without_body =
      MapSet.delete(primitives_routed(), {"pnt_notification", "pii_pnt_rendered_body"})

    violations = VaultParity.check(Demo.Repo, routed_without_body)

    assert Enum.any?(violations, fn v ->
             v =~ "pnt_notification.pii_pnt_rendered_body" and v =~ "de-vaulted PII column"
           end),
           "de-vaulting rendered_body must be caught, got: #{inspect(violations)}"
  end
end
