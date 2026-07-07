defmodule Demo.ApiTwoKeyClassesTest do
  @moduledoc """
  T3.11 — the TWO KEY CLASSES (doc §external-surface "two key classes, not one").
  Same policy stack, two actors:

    * a **tenant** key is org-bound and acts as the tenant over its OWN org's data. It
      reads its own org's PII in CLEAR per its own RBAC, with NO operator reveal grant
      (the reveal seam is operator-scoped; it does not sit between a tenant and its own
      records). A cross-org request is DENIED (org-scope FilterCheck → zero rows).

    * an **operator** / cross-tenant key is masked by default: a vaulted field is
      ABSENT unless a live reveal grant covers the subject. With a grant it reads
      plaintext.

  Red paths here: (1) tenant key cross-org request returns no foreign rows; (2)
  operator key sees vaulted PII absent WITHOUT a grant, plaintext ONLY WITH a live
  grant; (3) an api_key's scopes can never out-reach its actor.

  Anti-tautology: the tenant positive path asserts plaintext IS present; the operator
  with-grant path asserts plaintext IS present — so "absent"/"denied" are real.
  """
  use Demo.ApiCase, async: false

  # An approving grant checker — the operator-plane "live grant" positive control.
  defmodule ApproveAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: true
  end

  setup do
    # Baseline: no approving grant (the demo config wires Samen.Reveal.Grants, which
    # denies with no live grant row). Snapshot + restore so the with-grant test's
    # override never bleeds into another test.
    prev = Application.get_env(:samen_core, :reveal_grant)
    on_exit(fn -> restore(prev) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:samen_core, :reveal_grant)
  defp restore(v), do: Application.put_env(:samen_core, :reveal_grant, v)

  # =========================================================================
  # Tenant key — owns its org's PII in clear; cross-org denied.
  # =========================================================================

  describe "tenant key" do
    test "reads its OWN org's PII in CLEAR — no reveal grant involved" do
      org = mk_org("Acme")

      _c =
        mk_contact(org.id, %{
          display_name: "Alice",
          full_name: %{first: "Alice", last: "Owner"},
          emails: ["alice@acme.com"]
        })

      {raw, _key} = mk_api_key(org.id, plane: :tenant)

      conn = api_get("/contacts", raw)
      assert conn.status == 200
      %{"data" => [record | _]} = json(conn)
      attrs = record["attributes"]

      # The tenant owns its customers' PII → plaintext, NOT `••••`, NOT absent.
      refute attrs["emails"] == Samen.Masked.mask()
      assert attrs["emails"] =~ "alice@acme.com"
      assert Map.has_key?(attrs, "full_name")
      assert attrs["full_name"] =~ "Alice"
    end

    test "cross-org request is DENIED — a tenant key sees zero of another org's rows" do
      org_a = mk_org("OrgA")
      org_b = mk_org("OrgB")
      _ca = mk_contact(org_a.id, %{display_name: "A-Contact"})
      cb = mk_contact(org_b.id, %{display_name: "B-Contact"})

      # A tenant key bound to org A.
      {raw_a, _} = mk_api_key(org_a.id, plane: :tenant)

      # Index: org A's key sees only org A's contacts.
      conn = api_get("/contacts", raw_a)
      assert conn.status == 200
      %{"data" => data} = json(conn)
      names = Enum.map(data, & &1["attributes"]["display_name"])
      assert "A-Contact" in names
      refute "B-Contact" in names

      # Direct GET of org B's contact by id → not found (filtered out, not forbidden).
      conn_b = api_get("/contacts/#{cb.id}", raw_a)
      assert conn_b.status in [404, 403],
             "tenant key reached a foreign org's row (status #{conn_b.status})"

      refute conn_b.resp_body =~ "B-Contact"
    end
  end

  # =========================================================================
  # Operator key — masked/absent by default; plaintext only under a live grant.
  # =========================================================================

  describe "operator key" do
    test "vaulted PII is ABSENT without a reveal grant (masked by default)" do
      # Default grant model: deny (no live grant row).
      restore(Samen.Reveal.Grants)

      org = mk_org("Acme")

      _c =
        mk_contact(org.id, %{
          display_name: "Bob",
          full_name: %{first: "Bob", last: "Subject"},
          emails: ["bob@acme.com"]
        })

      {raw, _key} = mk_api_key(org.id, plane: :operator)

      conn = api_get("/contacts", raw)
      assert conn.status == 200
      %{"data" => [record | _]} = json(conn)
      attrs = record["attributes"]

      # Non-PII fields still present (the record is visible; only PII is withheld).
      assert Map.has_key?(attrs, "display_name")

      # Vaulted fields ABSENT (the doc: "on the operator plane a vaulted field is
      # absent unless a reveal grant covers it"). Not `••••`, not plaintext — gone.
      refute Map.has_key?(attrs, "full_name"),
             "operator key saw a vaulted field with no grant"

      refute Map.has_key?(attrs, "emails"),
             "operator key saw a vaulted field with no grant"

      # And the plaintext value never appears anywhere in the body.
      refute conn.resp_body =~ "bob@acme.com"
    end

    test "vaulted PII is PLAINTEXT with a live T1.6 reveal grant (request → approve)" do
      # The REAL T1.6 grant model — not a stub. A distinct-party-approved, unexpired
      # grant for (operator-actor, subject) makes the operator read plaintext.
      restore(Samen.Reveal.Grants)

      org = mk_org("Acme")

      contact =
        mk_contact(org.id, %{
          display_name: "Dave",
          full_name: %{first: "Dave", last: "RealGrant"},
          emails: ["dave@acme.com"]
        })

      # The operator key's actor id is its minter user's id — mint the key first so we
      # know the requestor id the grant must bind to.
      {raw, key} = mk_api_key(org.id, plane: :operator)
      key = Ash.load!(key, [membership: [:user_id]], authorize?: false)
      requestor_id = key.membership.user_id

      # A live grant: requestor = the operator actor, subject = the contact, approved
      # by a DISTINCT party, unexpired.
      {:ok, req} =
        Samen.Reveal.Grants.request(%{
          subject_id: contact.id,
          requestor_id: requestor_id,
          reason: "api integration test"
        })

      {:ok, _grant} =
        Samen.Reveal.Grants.approve(req, %{granted_by: "distinct-approver", window_minutes: 60})

      conn = api_get("/contacts", raw)
      assert conn.status == 200
      %{"data" => [record | _]} = json(conn)
      attrs = record["attributes"]

      assert Map.has_key?(attrs, "emails"), "live grant did not surface the vaulted field"
      assert attrs["emails"] =~ "dave@acme.com"
    end

    test "vaulted PII is PLAINTEXT with an approving grant stub (control)" do
      # A live, approving operator grant.
      Application.put_env(:samen_core, :reveal_grant, ApproveAll)

      org = mk_org("Acme")

      _c =
        mk_contact(org.id, %{
          display_name: "Carol",
          full_name: %{first: "Carol", last: "Granted"},
          emails: ["carol@acme.com"]
        })

      {raw, _key} = mk_api_key(org.id, plane: :operator)

      conn = api_get("/contacts", raw)
      assert conn.status == 200
      %{"data" => [record | _]} = json(conn)
      attrs = record["attributes"]

      # WITH a grant, the operator reads plaintext — proving the absence above was the
      # grant gate, not a blanket strip.
      assert Map.has_key?(attrs, "emails")
      assert attrs["emails"] =~ "carol@acme.com"
    end
  end

  # =========================================================================
  # api_key scopes can never out-reach the actor (doc §external-surface).
  # =========================================================================

  describe "api_key cannot out-reach its actor" do
    test "a viewer-minted key with a declared write scope is still read-only" do
      # The mechanism the API relies on: a key's effective authority is the
      # intersection of its declared scopes AND the minter's role ceiling.
      viewer_key = %{
        org_id: "org-1",
        plane: :tenant,
        scopes: %{crm: [:read, :write]},
        minter_role: :viewer
      }

      # Declares write, but the minter is a viewer → no write reach.
      refute Samen.Scope.ApiKey.authorized?(viewer_key, :write, :crm, "org-1")
      # Read is within a viewer's ceiling → allowed.
      assert Samen.Scope.ApiKey.authorized?(viewer_key, :read, :crm, "org-1")
    end

    test "a key cannot reach a family it did not declare, nor another org" do
      key = %{
        org_id: "org-1",
        plane: :tenant,
        scopes: %{crm: [:read]},
        minter_role: :admin
      }

      # Declared family only.
      assert Samen.Scope.ApiKey.authorized?(key, :read, :crm, "org-1")
      refute Samen.Scope.ApiKey.authorized?(key, :read, :billing, "org-1")
      # Never another org.
      refute Samen.Scope.ApiKey.authorized?(key, :read, :crm, "org-2")
    end
  end
end
