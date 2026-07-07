defmodule Demo.ImpersonationEgressTest do
  @moduledoc """
  T4.1 end-to-end on the demo dogfood: masked impersonation over a REAL tenant org.

  Proves, against a running Postgres + the real `Demo.Crm.Contact` (vaulted
  full_name/emails/dob):

    * (b) the impersonation scope reads the TARGET org's REAL rows with `••••` PII —
      the tenant's own org-scope + policies apply unchanged, and no reveal grant means
      every vaulted field is `%Masked{}`;
    * (e) the LiveView slice renders the tenant's real data shape with `••••`;
    * (c) a tenant-plane query lists the impersonation against their org (who, when,
      reason, expiry);
    * PII stays masked through the egress matrix (LiveView / JSON / CSV) under
      impersonation — reusing the T3.11 resolver + the `%Masked{}` serialization paths.

  Red paths:
    * an impersonating operator invoking `:reveal` WITHOUT a separate second-party
      grant DENIES;
    * an expired session denies mid-flight (rebuild the scope → session_inactive);
    * cross-org: impersonating org A never sees org B's rows.

  Anti-tautology on the mask: a control asserts that WITH a live T1.6 reveal grant on
  top, the SAME field IS plaintext — so the mask/absence is the grant gate, not a
  blanket strip.
  """
  use Demo.DataCase, async: false

  alias Samen.Impersonation
  alias Samen.OperatorPlane.Actor
  alias Samen.Api.PiiResolution

  require Ash.Query

  # An approving grant checker — the "reveal opened on top" positive control.
  defmodule ApproveAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: true
  end

  setup do
    prev = Application.get_env(:samen_core, :reveal_grant)
    on_exit(fn -> restore(prev) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:samen_core, :reveal_grant)
  defp restore(v), do: Application.put_env(:samen_core, :reveal_grant, v)

  defp mk_org(name) do
    {:ok, org} =
      Demo.Identity.Org
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

    org
  end

  defp mk_contact(org_id, attrs \\ %{}) do
    {:ok, c} =
      Demo.Crm.Contact
      |> Ash.Changeset.for_create(:create, %{
        display_name: Map.get(attrs, :display_name, "Contact"),
        org_id: org_id,
        full_name: Map.get(attrs, :full_name, %{first: "Alice", last: "Smith"}),
        emails: Map.get(attrs, :emails, ["alice@example.com"]),
        dob: Map.get(attrs, :dob, ~D[1990-01-01])
      })
      |> Ash.create(authorize?: false)

    c
  end

  defp operator, do: Actor.new("op-#{System.unique_integer([:positive])}", :operator_support)

  # =========================================================================
  # (b) impersonation reads the tenant's REAL rows with •••• PII
  # =========================================================================

  test "an impersonating operator sees the tenant's REAL contacts with masked PII" do
    org = mk_org("Acme")
    _c = mk_contact(org.id, %{display_name: "Alice", emails: ["alice@acme.com"]})

    op = operator()
    {:ok, _session} = Impersonation.open(op, org.id, "customer reported a billing error")
    {:ok, scope} = Impersonation.scope(op, org.id)

    contacts =
      Demo.Crm.Contact
      |> Ash.Query.filter(org_id == ^org.id)
      |> Ash.Query.ensure_selected([:full_name, :emails, :dob])
      |> Ash.read!(scope: scope)

    assert [contact | _] = contacts
    # The REAL data SHAPE is present (display_name is a non-PII field).
    assert contact.display_name == "Alice"

    # Every vaulted field is %Masked{} — NO reveal grant, so ••••. The plaintext value
    # is nowhere in the loaded record.
    assert %Samen.Masked{} = contact.full_name
    assert %Samen.Masked{} = contact.emails
    assert %Samen.Masked{} = contact.dob
    assert to_string(contact.emails) == "••••"
    refute inspect(contact) =~ "alice@acme.com"
  end

  test "cross-org: impersonating org A never sees org B's rows (tenant policy unchanged)" do
    org_a = mk_org("OrgA")
    org_b = mk_org("OrgB")
    _a = mk_contact(org_a.id, %{display_name: "A-Contact"})
    _b = mk_contact(org_b.id, %{display_name: "B-Contact"})

    op = operator()
    {:ok, _} = Impersonation.open(op, org_a.id, "support")
    {:ok, scope} = Impersonation.scope(op, org_a.id)

    # The org-scope FilterCheck narrows to org A even if the operator tries org B's id.
    names =
      Demo.Crm.Contact
      |> Ash.read!(scope: scope)
      |> Enum.map(& &1.display_name)

    assert "A-Contact" in names
    refute "B-Contact" in names
  end

  # =========================================================================
  # PII masked through the EGRESS MATRIX under impersonation (LiveView/JSON/CSV)
  # =========================================================================

  test "egress matrix: masked PII stays •••• / absent through LiveView, JSON, CSV under impersonation" do
    org = mk_org("Acme")
    c = mk_contact(org.id, %{display_name: "Bob", emails: ["bob@acme.com"]})

    op = operator()
    {:ok, _} = Impersonation.open(op, org.id, "support")
    {:ok, scope} = Impersonation.scope(op, org.id)

    [contact] =
      Demo.Crm.Contact
      |> Ash.Query.filter(id == ^c.id)
      |> Ash.Query.ensure_selected([:full_name, :emails, :dob])
      |> Ash.read!(scope: scope)

    # Under impersonation (doc §control: "personal data renders •••• by default") the
    # vaulted field is PRESENT-but-masked (`%Masked{}`), not omitted — the operator
    # sees the tenant's real UI with •••• where PII would be.
    assert %Samen.Masked{} = contact.emails

    # --- LiveView (HEEx) egress ---
    assert IO.iodata_to_binary(Phoenix.HTML.Safe.to_iodata(contact.emails)) == "••••"

    # --- JSON egress (the %Masked{} Jason.Encoder path) ---
    assert Jason.encode!(contact.emails) == ~s("••••")

    # --- CSV / iodata egress (interpolation into a CSV row) ---
    csv_row = "#{contact.display_name},#{contact.full_name},#{contact.emails},#{contact.dob}"
    assert csv_row == "Bob,••••,••••,••••"
    refute csv_row =~ "bob@acme.com"

    # --- Re-running the T3.11 resolver on the impersonation actor keeps it •••• ---
    [resolved] = PiiResolution.resolve([contact], Demo.Crm.Contact, scope.actor, repo: Demo.Repo)
    assert %Samen.Masked{} = resolved.emails
    assert to_string(resolved.emails) == "••••"
  end

  # =========================================================================
  # ANTI-TAUTOLOGY on the mask: with a live T1.6 reveal grant ON TOP, plaintext appears
  # =========================================================================

  test "ANTI-TAUTOLOGY: a second-party reveal grant on top of impersonation surfaces plaintext" do
    restore(ApproveAll)

    org = mk_org("Acme")
    c = mk_contact(org.id, %{display_name: "Carol", emails: ["carol@acme.com"]})

    op = operator()
    {:ok, _} = Impersonation.open(op, org.id, "billing")
    {:ok, scope} = Impersonation.scope(op, org.id)

    [contact] =
      Demo.Crm.Contact
      |> Ash.Query.filter(id == ^c.id)
      |> Ash.Query.ensure_selected([:full_name, :emails, :dob])
      |> Ash.read!(scope: scope)

    # WITH an approving grant (the separate reveal path opened on top), the read
    # produces plaintext — proving the mask above was the grant gate firing, not a
    # blanket strip. The read's own PiiResolution prep already revealed it.
    refute match?(%Samen.Masked{}, contact.emails)
    assert to_string(contact.emails) =~ "carol@acme.com"
  end

  # =========================================================================
  # RED PATH: impersonating operator invoking :reveal WITHOUT a grant DENIES
  # =========================================================================

  test "RED PATH: :reveal without a separate second-party grant DENIES under impersonation" do
    # The real T1.6 grant model (denies with no live grant row).
    restore(Samen.Reveal.Grants)

    org = mk_org("Acme")
    c = mk_contact(org.id, %{display_name: "Dana", emails: ["dana@acme.com"]})

    op = operator()
    {:ok, _} = Impersonation.open(op, org.id, "support")

    masked = Samen.Masked.new("vt_reveal_token", :emails)

    # An impersonating operator (its actor id) invoking the reveal seam WITHOUT having
    # opened a separate reveal request/approval → DENIED, never touches the vault.
    assert {:error, :denied} =
             Samen.Reveal.reveal(op.id, masked, :reveal_contact, Demo.Crm.Contact,
               repo: Demo.Repo,
               subject_id: c.id
             )
  end

  # =========================================================================
  # RED PATH: expired session denies mid-flight (per-request scope rebuild)
  # =========================================================================

  test "RED PATH: an expired session denies mid-flight — the scope rebuild fails closed" do
    org = mk_org("Acme")
    _c = mk_contact(org.id)

    op = operator()
    {:ok, session} = Impersonation.open(op, org.id, "quick", window_minutes: 1)

    # BEFORE expiry (anti-tautology positive control): the scope builds.
    before = DateTime.add(session.expires_at, -30, :second)
    assert {:ok, _scope} = Impersonation.scope(op, org.id, now: before)

    # AFTER expiry: rebuilding the scope (per request) fails closed — with only the
    # clock moved. The session row still exists (deny-on-read, not deny-on-cleanup).
    after_exp = DateTime.add(session.expires_at, 1, :second)
    assert {:error, :session_inactive} = Impersonation.scope(op, org.id, now: after_exp)
  end

  # =========================================================================
  # (c) tenant-visible: a tenant can list the impersonations against their org
  # =========================================================================

  test "(c) a tenant can see who impersonated their org, when, and why" do
    org = mk_org("Acme")
    op = operator()
    {:ok, session} = Impersonation.open(op, org.id, "customer #1234 reported a billing error")

    entries = Impersonation.list_for_org(org.id)
    assert [entry] = entries
    assert entry.operator_id == op.id
    assert entry.reason == "customer #1234 reported a billing error"
    assert entry.session_id == session.id
    assert %DateTime{} = entry.opened_at
    assert %DateTime{} = entry.expires_at
    assert entry.active? == true

    # No PII in the tenant-visible record — only bounded operator id + reason + times.
    refute inspect(entry) =~ ~r/@/
  end

  test "(c) list_for_scope: a tenant sees only THEIR org's impersonations; an impersonated scope is refused" do
    org = mk_org("Acme")
    other = mk_org("Other")
    op = operator()
    {:ok, _} = Impersonation.open(op, org.id, "our support")
    {:ok, _} = Impersonation.open(op, other.id, "their support")

    # A real tenant member scope for org — sees only org's impersonation.
    tenant_scope = Samen.Scope.new(%{id: "tenant-user", org_id: org.id, role: :admin})
    assert {:ok, [entry]} = Impersonation.list_for_scope(tenant_scope)
    assert entry.reason == "our support"

    # The impersonating operator's OWN scope may NOT read the tenant ledger this way.
    {:ok, imp_scope} = Impersonation.scope(op, org.id)
    assert {:error, :no_org} = Impersonation.list_for_scope(imp_scope)
  end

  # =========================================================================
  # (d) every open/close/expiry writes a token-only aud_event row
  # =========================================================================

  test "(d) open + close write token-only aud_event rows (tokens only)" do
    org = mk_org("Acme")
    op = operator()
    {:ok, session} = Impersonation.open(op, org.id, "support call")
    {:ok, _} = Impersonation.close(session.id)

    events = Samen.AuditEvent.for_subject(Demo.Repo, org.id)
    lifecycles = Enum.map(events, & &1.detail)
    assert Enum.any?(lifecycles, &(&1 =~ "event=open"))
    assert Enum.any?(lifecycles, &(&1 =~ "event=close"))

    # Tokens only: subject = the org UUID, actor = the operator id, no plaintext PII.
    for ev <- events do
      assert ev.event_type == "impersonation"
      assert ev.subject_id == org.id
      refute ev.detail =~ ~r/@/
    end
  end
end
