defmodule Demo.SupportScopeVaultRoutingTest do
  @moduledoc """
  Proves Support scope PII (message body🔒 and agent name/email🔒) is genuinely
  vault-routed at runtime (T3.6 acceptance: "PII vault round-trip for each 🔒 object"):

    * the domain column holds an opaque `vt_*` token, NEVER plaintext;
    * vault rows exist for the subject with ciphertext (not plaintext);
    * the plaintext value appears nowhere in the domain row;
    * the VaultField last-line guard refuses a raw (non-token) write;
    * %Masked{} is the default read value.

  Two 🔒 resources:
    * Message   — body (scalar, `pii_smg_body`): free-text, vaulted as a single blob.
    * Agent     — full_name (composite, `sag_full_name`), email (scalar, `pii_sag_email`).
  """
  use Demo.DataCase, async: false

  alias Demo.SupportScope.{Ticket, Conversation, Message, Agent}
  alias Demo.Identity.{Org}
  alias Samen.Vault.VaultRow

  import Ecto.Query

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_ticket(org_id) do
    {:ok, t} =
      Ticket
      |> Ash.Changeset.for_create(:create, %{subject: "vault-test", org_id: org_id})
      |> Ash.create(authorize?: false)

    t
  end

  defp mk_conversation(org_id, ticket_id) do
    {:ok, c} =
      Conversation
      |> Ash.Changeset.for_create(:create, %{
        channel: :email,
        status: :open,
        org_id: org_id,
        ticket_id: ticket_id
      })
      |> Ash.create(authorize?: false)

    c
  end

  # ===========================================================================
  # Message — body (pii_smg_body)
  # ===========================================================================

  test "message body writes to vault as a vt_ token; plaintext never in the domain row" do
    org = mk_org("vault-msg-body")
    ticket = mk_ticket(org.id)
    convo = mk_conversation(org.id, ticket.id)
    plaintext_body = "Hello, I am having trouble with order #12345. Please help ASAP."

    {:ok, message} =
      Message
      |> Ash.Changeset.for_create(:create, %{
        body: plaintext_body,
        sender_type: :customer,
        message_type: :reply,
        org_id: org.id,
        conversation_id: convo.id
      })
      |> Ash.create(authorize?: false)

    # The raw domain column holds a vt_* token, not plaintext.
    %{rows: [[body_col]]} =
      Repo.query!(
        "SELECT pii_smg_body FROM smg_message WHERE smg_id = $1",
        [Ecto.UUID.dump!(message.id)]
      )

    assert String.starts_with?(body_col, "vt_"),
           "pii_smg_body should be a vt_ token, got: #{inspect(body_col)}"

    # Plaintext never in domain column.
    refute body_col =~ plaintext_body
    refute body_col =~ "order #12345"

    # Vault rows exist with ciphertext (binary, not plaintext).
    vault_rows = Repo.all(from(v in VaultRow, where: v.subject_id == ^message.id))
    assert length(vault_rows) >= 1

    Enum.each(vault_rows, fn row ->
      assert is_binary(row.ciphertext)
      refute row.ciphertext =~ plaintext_body
    end)
  end

  test "message body is %Masked{} on a plain Ash.read (mask-by-default)" do
    org = mk_org("vault-msg-mask")
    ticket = mk_ticket(org.id)
    convo = mk_conversation(org.id, ticket.id)

    {:ok, _message} =
      Message
      |> Ash.Changeset.for_create(:create, %{
        body: "Sensitive message content.",
        sender_type: :customer,
        org_id: org.id,
        conversation_id: convo.id
      })
      |> Ash.create(authorize?: false)

    query = Message |> Ash.Query.select([:id, :body])
    {:ok, [loaded]} = Ash.read(query, authorize?: false)

    assert %Samen.Masked{} = loaded.body
    assert Phoenix.HTML.Safe.to_iodata(loaded.body) |> IO.iodata_to_binary() =~ "•"
    refute inspect(loaded) =~ "Sensitive message content"
  end

  test "two messages have distinct vault entries (no cross-subject token sharing)" do
    org = mk_org("vault-msg-distinct")
    ticket = mk_ticket(org.id)
    convo = mk_conversation(org.id, ticket.id)

    {:ok, m1} =
      Message
      |> Ash.Changeset.for_create(:create, %{
        body: "First message body.",
        sender_type: :customer,
        org_id: org.id,
        conversation_id: convo.id
      })
      |> Ash.create(authorize?: false)

    {:ok, m2} =
      Message
      |> Ash.Changeset.for_create(:create, %{
        body: "Second distinct message body.",
        sender_type: :agent,
        org_id: org.id,
        conversation_id: convo.id
      })
      |> Ash.create(authorize?: false)

    %{rows: [[token1]]} =
      Repo.query!("SELECT pii_smg_body FROM smg_message WHERE smg_id = $1",
        [Ecto.UUID.dump!(m1.id)])

    %{rows: [[token2]]} =
      Repo.query!("SELECT pii_smg_body FROM smg_message WHERE smg_id = $1",
        [Ecto.UUID.dump!(m2.id)])

    refute token1 == token2, "Two messages must have distinct vault tokens"
  end

  # ===========================================================================
  # Agent — full_name (composite, sag_full_name) + email (scalar, pii_sag_email)
  # ===========================================================================

  test "agent email writes to vault as a vt_ token; plaintext never in the domain row" do
    org = mk_org("vault-agent-email")
    plaintext_email = "agent-vault-#{:rand.uniform(999_999)}@support.example"

    {:ok, agent} =
      Agent
      |> Ash.Changeset.for_create(:create, %{
        handle: "agent-#{:rand.uniform(999_999)}",
        full_name: %Samen.Type.FullName{first: "Alice", last: "Agent"},
        email: plaintext_email,
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    %{rows: [[email_col]]} =
      Repo.query!(
        "SELECT pii_sag_email FROM sag_agent WHERE sag_id = $1",
        [Ecto.UUID.dump!(agent.id)]
      )

    assert String.starts_with?(email_col, "vt_"),
           "pii_sag_email should be a vt_ token, got: #{inspect(email_col)}"

    refute email_col =~ plaintext_email
  end

  test "agent full_name writes to vault as a vt_ token (composite PII, no pii_ prefix)" do
    org = mk_org("vault-agent-name")

    {:ok, agent} =
      Agent
      |> Ash.Changeset.for_create(:create, %{
        handle: "agent-name-#{:rand.uniform(999_999)}",
        full_name: %Samen.Type.FullName{first: "Bob", last: "Builder"},
        email: "bob-#{:rand.uniform(999_999)}@support.example",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    # Composite PII: column is sag_full_name (no pii_ prefix — composite types route by vault name).
    %{rows: [[name_col]]} =
      Repo.query!(
        "SELECT sag_full_name FROM sag_agent WHERE sag_id = $1",
        [Ecto.UUID.dump!(agent.id)]
      )

    assert String.starts_with?(name_col, "vt_"),
           "sag_full_name should be a vt_ token, got: #{inspect(name_col)}"

    refute name_col =~ "Bob"
    refute name_col =~ "Builder"
  end

  test "agent full_name and email are %Masked{} on a plain Ash.read" do
    org = mk_org("vault-agent-mask")

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:create, %{
        handle: "masked-agent-#{:rand.uniform(999_999)}",
        full_name: %Samen.Type.FullName{first: "Carol", last: "Hidden"},
        email: "carol-#{:rand.uniform(999_999)}@example.com",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    query = Agent |> Ash.Query.select([:id, :full_name, :email])
    {:ok, [loaded]} = Ash.read(query, authorize?: false)

    assert %Samen.Masked{} = loaded.full_name
    assert %Samen.Masked{} = loaded.email
    refute inspect(loaded) =~ "Carol"
  end

  test "the VaultField last-line guard refuses a raw plaintext write (red path)" do
    assert {:ok, "vt_realtoken"} = Samen.Type.VaultField.dump_to_native("vt_realtoken", [])

    assert :error == Samen.Type.VaultField.dump_to_native("plaintext body content", [])
    assert :error == Samen.Type.VaultField.dump_to_native("somebody@example.com", [])
  end

  # ===========================================================================
  # F3.1 de-vault backstop: the vault_declared_parity verifier fails closed when
  # a free-text 🔒 field (message.body) is de-vaulted — the pii_smg_body column
  # stays in the DB while the resource drops the route. This is the exact gap the
  # C4 pii_classify heuristic misses ("body" is not a PII name-token). The
  # authoritative red path for the actual de-vault edit is this file's other
  # tests + the verifier; here we prove the verifier catches the DB⇄route mismatch.
  # ===========================================================================

  alias Mix.Tasks.Samen.Verify.VaultDeclaredParity, as: VaultParity

  defp support_routed do
    domains = Application.get_env(:demo, :ash_domains, [])
    resources = Samen.Catalog.resource_modules(domains)
    VaultParity.routed_vault_columns(resources)
  end

  test "vault_declared_parity is GREEN while message.body IS vault-routed (control)" do
    violations = VaultParity.check(Demo.Repo, support_routed())

    body_vs = Enum.filter(violations, &(&1 =~ "pii_smg_body"))

    assert body_vs == [],
           "pii_smg_body must not be flagged while it is routed, got: #{inspect(body_vs)}"
  end

  test "de-vaulting message.body (drop route, keep pii_smg_body column) is CAUGHT (red path)" do
    # Model the de-vault: the resource dropped the `pii_attribute :body` route (so
    # {smg_message, pii_smg_body} leaves the routed set) while the migration left
    # the pii_smg_body column in the DB. The verifier reads the DB truth and must
    # fail closed on the leftover, unrouted pii_ column.
    routed_without_body = MapSet.delete(support_routed(), {"smg_message", "pii_smg_body"})

    violations = VaultParity.check(Demo.Repo, routed_without_body)

    assert Enum.any?(violations, fn v ->
             v =~ "smg_message.pii_smg_body" and v =~ "de-vaulted PII column"
           end),
           "de-vaulting message.body must be caught by vault_declared_parity, got: #{inspect(violations)}"
  end

  test "non-PII resources (ticket, conversation, macro, csat) carry no email or body vault columns" do
    # The ticket table should have no pii_ column.
    {:ok, %{columns: tkt_cols}} = Repo.query("SELECT * FROM stk_ticket LIMIT 0")
    refute Enum.any?(tkt_cols, fn c -> String.starts_with?(c, "pii_") end)

    # The macro table should have no pii_ column.
    {:ok, %{columns: mac_cols}} = Repo.query("SELECT * FROM smc_macro LIMIT 0")
    refute Enum.any?(mac_cols, fn c -> String.starts_with?(c, "pii_") end)

    # The csat table should have no pii_ column.
    {:ok, %{columns: csat_cols}} = Repo.query("SELECT * FROM scs_csat LIMIT 0")
    refute Enum.any?(csat_cols, fn c -> String.starts_with?(c, "pii_") end)
  end
end
