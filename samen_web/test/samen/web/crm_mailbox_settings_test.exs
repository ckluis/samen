defmodule Samen.Web.CRMMailboxSettingsTest do
  @moduledoc """
  T74 (spec §I1) — the CRM MAILBOX settings surface (`/crm/mailbox`): the connect UI
  seam and, above all, its **HONEST EMPTY STATE**.

  The fail-honest assert this file exists for: with NO mailbox provider wired (the CI
  default and the state of every un-adopted host), the page says *"Mailbox sync is not
  configured"* and offers NO connect affordance. It does NOT render an empty inbox, a
  "0 synced" tile, or fabricated connection rows — "unconfigured" and "connected but
  quiet" are different facts and the surface never blurs them. The three states are
  proven MUTUALLY EXCLUSIVE (each state's copy is absent from the other two), so a
  regression that collapses them cannot pass.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Mailbox
  alias Samen.Mailbox.{Config, FakeProvider}
  alias Samen.Web.CRM.MailboxLive

  @not_configured "Mailbox sync is not configured."
  @none_connected "No mailbox connected yet."
  @mailbox_address "rep@ourco.test"

  setup do
    previous = Application.get_env(:samen_core, :mailbox_provider)
    Application.delete_env(:samen_core, :mailbox_provider)
    FakeProvider.reset()

    on_exit(fn ->
      FakeProvider.reset()

      case previous do
        nil -> Application.delete_env(:samen_core, :mailbox_provider)
        value -> Application.put_env(:samen_core, :mailbox_provider, value)
      end
    end)

    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id}
  end

  defp wire_provider! do
    FakeProvider.set_capabilities([:inbound_sync, :outbound_send])
    Application.put_env(:samen_core, :mailbox_provider, {FakeProvider, %{configured: true}})
  end

  defp connect!(org_id) do
    cfg = %Config{
      org_id: org_id,
      repo: Samen.WebTest.Repo,
      provider: FakeProvider,
      provider_config: %{configured: true},
      connection_resource: Samen.WebTest.Mailbox.Connection,
      message_resource: Samen.WebTest.Mailbox.MailMessage
    }

    {:ok, connection} =
      Mailbox.connect(%{user_id: Ash.UUID.generate(), address: @mailbox_address}, cfg)

    connection
  end

  defp render(org_id, mount_opts) do
    render_live(MailboxLive, build_mount(:crm, mount_opts), [org_id])
  end

  # ==========================================================================
  # State 1 — UNCONFIGURED: the honest empty state (the fail-honest assert)
  # ==========================================================================

  test "UNCONFIGURED: the page says so, offers NO connect affordance, and fabricates NO data",
       %{org_id: org_id} do
    refute Mailbox.provider_configured?()

    html = render(org_id, plane: :tenant)

    assert html =~ @not_configured
    assert html =~ "mailbox-not-configured"
    assert html =~ "mailbox-honesty-note"
    # NO connect affordance — the seam is not one click away when nothing is wired.
    refute html =~ ~s(id="mailbox-connect-button")
    # NOT conflated with "connected but empty".
    refute html =~ @none_connected
    refute html =~ "mailbox-row"
  end

  test "UNCONFIGURED even when connection ROWS exist — the provider is the source of truth",
       %{org_id: org_id} do
    # A row left behind by an earlier, since-removed provider must NOT make the page
    # claim sync works. The predicate is the adapter, never the presence of data.
    wire_provider!()
    connect!(org_id)
    Application.delete_env(:samen_core, :mailbox_provider)

    html = render(org_id, plane: :tenant)

    assert html =~ @not_configured
    refute html =~ ~s(id="mailbox-connect-button")
  end

  # ==========================================================================
  # State 2 — CONFIGURED, nothing connected: THIS is where connect is offered
  # ==========================================================================

  test "CONFIGURED + nothing connected: the connect affordance appears, with different copy",
       %{org_id: org_id} do
    wire_provider!()
    assert Mailbox.provider_configured?()

    html = render(org_id, plane: :tenant)

    assert html =~ @none_connected
    assert html =~ ~s(id="mailbox-connect-button")
    # The unconfigured copy is GONE — the two states are mutually exclusive.
    refute html =~ @not_configured
    refute html =~ "mailbox-row"
  end

  test "OPERATOR plane: no connect affordance (an operator does not connect a tenant's mailbox)",
       %{org_id: org_id} do
    wire_provider!()

    html = render(org_id, plane: :operator, target_org_id: org_id)

    assert html =~ @none_connected
    refute html =~ ~s(id="mailbox-connect-button")
  end

  # ==========================================================================
  # State 3 — CONNECTED: real rows, 🔒 address masked per plane
  # ==========================================================================

  test "CONNECTED: the row renders with the mailbox address CLEAR on the tenant plane", %{
    org_id: org_id
  } do
    wire_provider!()
    connection = connect!(org_id)

    html = render(org_id, plane: :tenant)

    assert html =~ "mailbox-#{connection.id}"
    assert html =~ @mailbox_address
    assert html =~ "connected"
    refute html =~ "vt_"
    # Neither empty state is shown when a mailbox really is connected.
    refute html =~ @not_configured
    refute html =~ @none_connected
  end

  # L4 (Phase-6 T85 gate dogfood) — the address cell uses the theme var every other
  # bold/primary-value cell in the kit uses (`var(--ink)`, `samen_ui.css`'s `:root`
  # token), not a hardcoded literal that can't adapt if a dark palette overrides it.
  test "CONNECTED: the address cell renders via the var(--ink) theme token, no hardcoded literal",
       %{org_id: org_id} do
    wire_provider!()
    _connection = connect!(org_id)

    html = render(org_id, plane: :tenant)

    assert html =~ ~s|class="mailbox-address" style="font-weight:500;color:var(--ink)"|
    refute html =~ "#3a3b45"
  end

  test "CONNECTED: the OPERATOR plane masks the mailbox address •••• (no plaintext, no vt_ token)",
       %{org_id: org_id} do
    wire_provider!()
    connection = connect!(org_id)

    html = render(org_id, plane: :operator, target_org_id: org_id)

    # Non-vacuous: the same row is rendered…
    assert html =~ "mailbox-#{connection.id}"
    assert html =~ "••••"
    # …with the 🔒 address absent.
    refute html =~ @mailbox_address
    refute html =~ "vt_"
  end

  # ==========================================================================
  # Cross-org: the settings read is ORG-SCOPED (MED-2)
  # ==========================================================================

  test "CROSS-ORG: another tenant's mailbox connections NEVER appear in this org's settings read",
       %{org_id: org_a} do
    wire_provider!()
    connection_a = connect!(org_a)

    org_b = Ash.UUID.generate()
    connection_b = connect!(org_b)

    mount = build_mount(:crm, plane: :tenant)

    ids_a =
      mount
      |> Samen.Web.CRM.Reads.mailbox_connections(Samen.Web.Mount.scope(mount, org_a))
      |> Enum.map(& &1.id)

    ids_b =
      mount
      |> Samen.Web.CRM.Reads.mailbox_connections(Samen.Web.Mount.scope(mount, org_b))
      |> Enum.map(& &1.id)

    # Non-vacuous: each org DOES see its own connection (positive control)…
    assert connection_a.id in ids_a
    assert connection_b.id in ids_b
    # …and never the other's. A settings page listing every tenant's mailboxes is
    # exactly the regression this pins.
    refute connection_b.id in ids_a
    refute connection_a.id in ids_b

    # The rendered page carries the same boundary.
    html = render(org_a, plane: :tenant)
    assert html =~ "mailbox-#{connection_a.id}"
    refute html =~ "mailbox-#{connection_b.id}"
  end

  # ==========================================================================
  # The connect affordance answers HONESTLY (LOW-3)
  # ==========================================================================

  test "the Connect affordance ANSWERS instead of silently doing nothing", %{org_id: org_id} do
    wire_provider!()

    mount = build_mount(:crm, plane: :tenant)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> MailboxLive.load(org_id)

    # Before the click there is no notice (non-vacuous).
    refute render_html(MailboxLive, socket.assigns) =~ "mailbox-connect-notice"

    {:noreply, clicked} = MailboxLive.handle_event("connect", %{}, socket)
    html = render_html(MailboxLive, clicked.assigns)

    assert html =~ "mailbox-connect-notice"
    # …and the answer is the HONEST one: the host owns the handshake, not this surface.
    assert html =~ "Samen.Mailbox.connect/2"
    assert html =~ "docs/guides/mailbox-seam.md"
    # It does not claim a connection was made.
    refute html =~ "mailbox-row"
  end

  # ==========================================================================
  # Scope-absence: a host with no Mailbox scope mounted gets the honest state too
  # ==========================================================================

  test "a mount whose host has NOT mounted the Mailbox scope reads [] — never a fake row", %{
    org_id: org_id
  } do
    # A host root with no sibling `Mailbox` domain at all: the resource derivation
    # returns nil and both reads are honestly empty (never a fabricated row).
    bare = Samen.Web.Mount.new(:crm, NoSuchHost.Crm, Samen.WebTest.Repo, plane: Samen.Web.Plane.tenant())

    assert Samen.Web.CRM.Reads.mailbox_message_resource(bare) == nil
    assert Samen.Web.CRM.Reads.mailbox_connection_resource(bare) == nil
    assert Samen.Web.CRM.Reads.mailbox_connections(bare, Samen.Web.Mount.scope(bare, org_id)) == []

    assert Samen.Web.CRM.Reads.mail_for_person(
             bare,
             Samen.Web.Mount.scope(bare, org_id),
             Ash.UUID.generate()
           ) == []
  end
end
