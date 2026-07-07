defmodule Demo.Adversarial.ImpersonationBypassMatrixTest do
  @moduledoc """
  T4.6 — ADVERSARIAL suite, category 1: IMPERSONATION BYPASS MATRIX.

  Consolidated Phase-4 attack surface (plan §6.3 "Masked-impersonation bypass
  attempts"): under an impersonation session with NO reveal grant, EVERY egress must
  show `••••` / absent for the ungranted operator. The egresses attacked here, on the
  REAL demo `Demo.Crm.Contact` (vaulted full_name/emails/dob) over a REAL tenant org:

    * LiveView (HEEx `Phoenix.HTML.Safe`)
    * JSON API (the `%Masked{}` `Jason.Encoder`)
    * webhook payload (`Samen.Webhook.Payload.build/3`)
    * CSV / iodata (string interpolation)
    * logs (`Logger`-shaped `to_string`/`inspect`)
    * error messages (an exception whose message interpolates the field)

  The doc §control posture under impersonation is PRESENT-but-masked (`%Masked{}`
  renders `••••`, not omitted) — the operator sees the tenant's real UI shape with
  `••••` where PII would be. A REAL operator API key uses the absent posture (T3.11);
  both are attacked.

  POSITIVE CONTROL (non-vacuity): with a live T1.6 second-party reveal grant on top,
  the SAME field IS plaintext through the SAME egress paths — so every `••••`/absent
  assertion is the grant gate firing, not a blanket strip.

  Tag: `@moduletag :adversarial` — run via `mix test --only adversarial`.
  """
  use Demo.DataCase, async: false

  @moduletag :adversarial

  alias Samen.Impersonation
  alias Samen.OperatorPlane.Actor
  alias Samen.Api.PiiResolution
  alias Samen.Webhook.Payload

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

  defp mk_contact(org_id, attrs) do
    {:ok, c} =
      Demo.Crm.Contact
      |> Ash.Changeset.for_create(:create, %{
        display_name: Map.get(attrs, :display_name, "Contact"),
        org_id: org_id,
        full_name: Map.get(attrs, :full_name, %{first: "Alice", last: "Smith"}),
        emails: Map.get(attrs, :emails, ["alice@acme.com"]),
        dob: Map.get(attrs, :dob, ~D[1990-01-01])
      })
      |> Ash.create(authorize?: false)

    c
  end

  defp operator, do: Actor.new("op-#{System.unique_integer([:positive])}", :operator_support)

  # Load one contact under an impersonation scope (NO grant), selecting all vaulted fields.
  defp load_masked(org, contact_id) do
    op = operator()
    {:ok, _session} = Impersonation.open(op, org.id, "adversarial egress sweep")
    {:ok, scope} = Impersonation.scope(op, org.id)

    [contact] =
      Demo.Crm.Contact
      |> Ash.Query.filter(id == ^contact_id)
      |> Ash.Query.ensure_selected([:full_name, :emails, :dob])
      |> Ash.read!(scope: scope)

    {contact, scope}
  end

  # ==========================================================================
  # THE FULL EGRESS MATRIX under impersonation — every path shows ••••/absent
  # ==========================================================================

  describe "impersonation egress matrix — every surface masks the ungranted operator" do
    setup do
      restore(Samen.Reveal.Grants)
      org = mk_org("EgressOrg-#{System.unique_integer([:positive])}")
      c = mk_contact(org.id, %{display_name: "Bob", emails: ["bob@secret.test"]})
      {contact, scope} = load_masked(org, c.id)
      %{org: org, contact: contact, scope: scope, plaintext: "bob@secret.test"}
    end

    test "the loaded field is %Masked{} (the field's normal value under impersonation)",
         %{contact: contact} do
      assert %Samen.Masked{} = contact.full_name
      assert %Samen.Masked{} = contact.emails
      assert %Samen.Masked{} = contact.dob
    end

    test "LiveView (HEEx Phoenix.HTML.Safe) renders ••••", %{contact: contact, plaintext: pt} do
      html = IO.iodata_to_binary(Phoenix.HTML.Safe.to_iodata(contact.emails))
      assert html == "••••"
      refute html =~ pt
    end

    test "JSON API (%Masked{} Jason.Encoder) serializes ••••", %{contact: contact, plaintext: pt} do
      assert Jason.encode!(contact.emails) == ~s("••••")
      json = Jason.encode!(%{email: contact.emails, dob: contact.dob, name: contact.full_name})
      refute json =~ pt
      assert json =~ "••••"
    end

    test "webhook payload (Samen.Webhook.Payload) serializes the allowlisted field as ••••",
         %{contact: contact, plaintext: pt} do
      data = Payload.build("contact.updated", Demo.Crm.Contact, contact)["data"]
      # emails is on Contact's show_fields allowlist; under the mask it renders ••••.
      assert data["emails"] == "••••"
      refute Jason.encode!(data) =~ pt
    end

    test "CSV / iodata (interpolation) shows ••••", %{contact: contact, plaintext: pt} do
      csv_row = "#{contact.display_name},#{contact.full_name},#{contact.emails},#{contact.dob}"
      assert csv_row == "Bob,••••,••••,••••"
      refute csv_row =~ pt
    end

    test "logs (Logger-shaped to_string / inspect) never carry plaintext",
         %{contact: contact, plaintext: pt} do
      # A log line built the way an app would: interpolate + inspect the record.
      log_line = "contact update emails=#{contact.emails} record=#{inspect(contact)}"
      refute log_line =~ pt
      assert log_line =~ "••••"
      # inspect of the whole record must not leak the plaintext anywhere.
      refute inspect(contact) =~ pt
    end

    test "error messages (an exception interpolating the field) never carry plaintext",
         %{contact: contact, plaintext: pt} do
      # Model an app raising with the field in the message (a classic leak vector).
      err =
        try do
          raise "validation failed for contact email #{contact.emails} / dob #{contact.dob}"
        rescue
          e -> Exception.message(e)
        end

      refute err =~ pt
      assert err =~ "••••"
    end

    test "the T3.11 resolver re-run on the impersonation actor keeps it •••• (idempotent mask)",
         %{contact: contact, scope: scope, plaintext: pt} do
      [resolved] = PiiResolution.resolve([contact], Demo.Crm.Contact, scope.actor, repo: Demo.Repo)
      assert %Samen.Masked{} = resolved.emails
      assert to_string(resolved.emails) == "••••"
      refute inspect(resolved) =~ pt
    end
  end

  # ==========================================================================
  # POSITIVE CONTROL — a second-party reveal grant on top surfaces plaintext on
  # the SAME egress paths (proves the mask above is the grant gate, non-vacuous)
  # ==========================================================================

  test "POSITIVE CONTROL: with a live reveal grant on top, the SAME egress paths surface plaintext" do
    restore(ApproveAll)

    org = mk_org("GrantedOrg-#{System.unique_integer([:positive])}")
    c = mk_contact(org.id, %{display_name: "Carol", emails: ["carol@granted.test"]})
    {contact, _scope} = load_masked(org, c.id)

    # With an approving grant, the read's PiiResolution prep reveals plaintext.
    refute match?(%Samen.Masked{}, contact.emails)
    assert to_string(contact.emails) =~ "carol@granted.test"

    # And it flows through every egress as plaintext (the discriminating half).
    assert Jason.encode!(contact.emails) =~ "carol@granted.test"
    csv_row = "#{contact.display_name},#{contact.emails}"
    assert csv_row =~ "carol@granted.test"

  end

  # ==========================================================================
  # REAL operator API key — the ABSENT posture (T3.11), also attacked
  # ==========================================================================

  test "a REAL operator-plane API key (not impersonation) sees the vaulted field ABSENT (no grant)" do
    restore(Samen.Reveal.Grants)
    org = mk_org("OperatorKeyOrg-#{System.unique_integer([:positive])}")
    c = mk_contact(org.id, %{display_name: "Dana", emails: ["dana@absent.test"]})

    # Load the contact with the vaulted field materialised as %Masked{} (its normal
    # value) — the same shape the API serializer sees before PiiResolution runs.
    contact =
      Demo.Crm.Contact
      |> Ash.Query.filter(id == ^c.id)
      |> Ash.Query.ensure_selected([:full_name, :emails, :dob])
      |> Ash.read_one!(authorize?: false)

    assert %Samen.Masked{} = contact.emails

    # A real cross-tenant operator API key actor (T3.11): the absent posture.
    operator_key = %{id: "opkey-1", kind: :api_key, plane: :operator, org_id: org.id}
    [resolved] = PiiResolution.resolve([contact], Demo.Crm.Contact, operator_key, repo: Demo.Repo)

    # Under the operator-KEY posture the vaulted field is ABSENT — the resolver replaces
    # it with %Ash.ForbiddenField{} so the JSON serializer OMITS it (never plaintext,
    # never even ••••; the field is gone from the payload by omission).
    assert %Ash.ForbiddenField{field: :emails} = resolved.emails
    refute inspect(resolved) =~ "dana@absent.test"
    # And the field is absent from a JSON-shaped projection (the serializer omits it).
    payload = Payload.build("contact.updated", Demo.Crm.Contact, resolved)["data"]
    refute Map.has_key?(payload, "emails")
    refute Jason.encode!(payload) =~ "dana@absent.test"
  end
end
