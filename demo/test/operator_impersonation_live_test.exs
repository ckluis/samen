defmodule Demo.OperatorImpersonationLiveTest do
  @moduledoc """
  T4.1 clause (e): the LiveView slice proving the impersonating operator sees the
  tenant's REAL data shape with `••••` PII.

  Renders `DemoWeb.OperatorImpersonationLive` against a real impersonation session over
  a real tenant org with real (vaulted) contacts, and asserts the rendered HTML:
    * contains the tenant's real non-PII data (display_name);
    * renders `••••` for every vaulted PII field;
    * never leaks the plaintext value or the vault token;
    * shows the tenant-visible accountability line (reason/expiry).

  Red path: a view mounted with an EXPIRED / never-opened session renders the
  access-denied state and NO tenant data.
  """
  use Demo.DataCase, async: false

  alias Samen.Impersonation
  alias Samen.OperatorPlane.Actor

  defp mk_org(name) do
    {:ok, org} =
      Demo.Identity.Org
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

    org
  end

  defp mk_contact(org_id, display_name, email) do
    {:ok, c} =
      Demo.Crm.Contact
      |> Ash.Changeset.for_create(:create, %{
        display_name: display_name,
        org_id: org_id,
        full_name: %{first: display_name, last: "Person"},
        emails: [email],
        dob: ~D[1985-03-03]
      })
      |> Ash.create(authorize?: false)

    c
  end

  defp render_live(socket) do
    socket.assigns
    |> Map.put(:__changed__, %{})
    |> DemoWeb.OperatorImpersonationLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp empty_socket, do: %Phoenix.LiveView.Socket{}

  test "renders the tenant's real data shape with •••• PII" do
    org = mk_org("Acme")
    _c1 = mk_contact(org.id, "Alice", "alice@acme.com")
    _c2 = mk_contact(org.id, "Bob", "bob@acme.com")

    op = Actor.new("op-live-1", :operator_support)
    {:ok, _} = Impersonation.open(op, org.id, "reviewing their onboarding")

    socket = DemoWeb.OperatorImpersonationLive.load(empty_socket(), op.id, org.id)
    html = render_live(socket)

    # Real non-PII data shape is present (both contacts).
    assert html =~ "Alice"
    assert html =~ "Bob"

    # Vaulted PII is masked — •••• appears, plaintext does NOT.
    assert html =~ "••••"
    refute html =~ "alice@acme.com"
    refute html =~ "bob@acme.com"
    refute html =~ "vt_"

    # Accountability line: reason is shown (bounded, no PII).
    assert html =~ "reviewing their onboarding"
    assert html =~ "PII is masked"
  end

  test "RED PATH: an expired / never-opened session renders access-denied and NO data" do
    org = mk_org("Acme")
    _c = mk_contact(org.id, "Secret", "secret@acme.com")

    op = Actor.new("op-live-2", :operator_support)
    # NO session opened → the scope build fails closed.

    socket = DemoWeb.OperatorImpersonationLive.load(empty_socket(), op.id, org.id)
    html = render_live(socket)

    assert html =~ "access denied"
    refute html =~ "Secret"
    refute html =~ "secret@acme.com"
    # No contact rows rendered.
    refute html =~ "contact-row"
  end

  # H2 (phase-6 SEC fix round, R3) — this slice carried an unrouted COPY of the
  # remediated defect: a `mount/3` deriving the acting operator from
  # `params["operator_id"] || session["operator_id"]` (params beating the session). It is
  # gone, not fixed: demo is API-only (no endpoint, no live socket, no live route) and
  # depends on samen_core only, so it cannot reach the framework gate that makes a routed
  # mount safe. Pin BOTH halves so the copy cannot silently return.
  test "H2/R3: this slice exports NO mount/3 — a client-param identity path cannot return here" do
    Code.ensure_loaded!(DemoWeb.OperatorImpersonationLive)

    refute function_exported?(DemoWeb.OperatorImpersonationLive, :mount, 3),
           "a routed mount/3 must not exist on this proof-only slice — a host that wants a " <>
             "real console uses the framework path (assign_identity + gate_socket), not this module"

    # POSITIVE CONTROL (anti-tautology): the proof surface it DOES export is still there,
    # so the assertion above is about the mount specifically, not a deleted module.
    assert function_exported?(DemoWeb.OperatorImpersonationLive, :load, 3)
    assert function_exported?(DemoWeb.OperatorImpersonationLive, :render, 1)
  end

  test "H2/R3: load/3 fails CLOSED on a nil operator/org instead of raising out of the kernel" do
    org = mk_org("Acme")
    _c = mk_contact(org.id, "Secret", "secret@acme.com")

    for {op_id, org_id} <- [{nil, org.id}, {"op-live-3", nil}, {nil, nil}] do
      socket = DemoWeb.OperatorImpersonationLive.load(empty_socket(), op_id, org_id)

      assert socket.assigns.session_inactive
      assert socket.assigns.contacts == []
      refute render_live(socket) =~ "secret@acme.com"
    end
  end
end
