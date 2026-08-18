defmodule Samen.Delivery.EmailHardeningT111Test do
  @moduledoc """
  T111 — the persona-11 email-pipeline hardening gate. Three defects, one fix
  surface (`Samen.Delivery.AuthMailer` / `Samen.Delivery.Rendering` / the email
  templates), each with a sabotage-refutable regression proof (positive control
  per the `Samen.RedPath` house discipline):

    * **F3 (XSS)** — every recipient/tenant-derived interpolation in the digest
      template AND the generic fallback is HTML-escaped through the sanctioned
      `Phoenix.HTML.Safe` seam (`Rendering.html_safe/1`, the SAME protocol
      `%Samen.Masked{}` implements): a `<script>`-bearing `display_name` renders
      ESCAPED/inert, never executable markup. Refutable — the pre-fix raw
      interpolation shape would leave the raw `<script>` in the body.
    * **F1 (empty auth content)** — `AuthMailer.dispatch/2` now renders real
      content (subject + text/html body + the actionable `/verify|/reset|/invite`
      link) for all three auth contexts. Refutable via a tokenless-dispatch
      negative control that carries NO content (the pre-fix shape).
    * **F3 masking cross-check** — `html_safe/1` renders a `%Samen.Masked{}` as
      `••••`, never a `vt_` token, never double-escaped (the vt_/•••• discipline
      is unregressed by the escaping change).

  The F2 (invite-dispatch fail-honesty) regression lives in samen_web's
  `Samen.Web.Auth.InvitationTest` (it needs the REAL `Invite.create/3` path with
  a full resource `mods` map — only wired in the samen_web test host).
  """
  use ExUnit.Case, async: false

  alias Samen.Delivery.AuthMailer
  alias Samen.Delivery.Lifecycle.EmailWorker
  alias Samen.Delivery.Rendering
  alias Samen.Masked
  alias Samen.Notifications.Digest
  alias SamenCore.Support.NotificationFixture.{Notification, NotificationPreference}
  alias SamenCore.Support.RevealDomain.RevealPerson
  alias SamenCore.TestRepo

  @repo TestRepo
  @resource RevealPerson

  # The persona-11 injection payload: HTML-meaningful chars + a live <script>.
  @injection_name "O'Brien <script>alert(document.domain)</script>"

  # A vault stub — the escaping is what's under test here, not the decrypt; on the
  # send plane the tenant owns its own address, so this resolves plaintext.
  defmodule OkVault do
    def reveal(_masked, _repo, _opts \\ []), do: {:ok, "obrien-SENTINEL@customer.test"}
  end

  # Captures the exact delivery config (subject/text_body/html_body) the send path
  # built — the SAME methodology persona-11's scratch harness used.
  defmodule CapturingAdapter do
    use Samen.Delivery.Provider
    @impl true
    def configured?(_config), do: true
    @impl true
    def deliver(message, config) do
      send(self(), {:t111_captured, message, config})
      {:ok, %{provider_message_id: "captured-#{message.send_id}"}}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})

    prev_provider = Application.get_env(:samen_core, :delivery_provider)
    prev_email = Application.get_env(:samen_core, EmailWorker)
    prev_env = Application.get_env(:samen_core, :delivery_env)

    # Force the per-worker fallback adapter to be the one that runs (no provider
    # selection override).
    Application.delete_env(:samen_core, :delivery_provider)

    on_exit(fn ->
      restore(:delivery_provider, prev_provider)
      restore(EmailWorker, prev_email)
      restore(:delivery_env, prev_env)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, val), do: Application.put_env(:samen_core, key, val)

  defp create_notification(org, recipient, event_type) do
    Notification
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      recipient_id: recipient,
      event_type: event_type,
      channel: :email,
      status: :pending
    })
    |> Ash.create!(authorize?: false)
  end

  # ==========================================================================
  # F3 — XSS: recipient/tenant-derived fields render ESCAPED in HTML bodies
  # ==========================================================================

  describe "F3 (XSS): recipient/tenant-derived fields are HTML-escaped in every email HTML body" do
    test "the REAL digest path (Digest.run/2) escapes a <script>-bearing display_name" do
      org = Ash.UUID.generate()
      rec = Ash.UUID.generate()
      create_notification(org, rec, "invoice.created")

      loader = fn _org_id, recipient_id ->
        {:ok,
         %{
           struct:
             struct(@resource, %{
               id: recipient_id,
               display_name: @injection_name,
               emails: Masked.new("vt_t111_injection_token", :emails)
             }),
           resource: @resource
         }}
      end

      opts = [
        notification_module: Notification,
        preference_module: NotificationPreference,
        repo: @repo,
        recipient_loader: loader,
        env: :prod,
        fallback_adapter: CapturingAdapter,
        render_opts: [repo: :unused, vault: OkVault]
      ]

      results = Digest.run(~U[2026-07-27 09:00:00Z], opts)
      assert Enum.any?(results, &match?({:sent, ^org, ^rec, _}, &1))

      assert_receive {:t111_captured, _message, config}, 1_000
      html = config.html_body

      # The executable markup is GONE; the entity-encoded form is present instead.
      refute html =~ "<script>alert(document.domain)</script>"
      assert html =~ "&lt;script&gt;alert(document.domain)&lt;/script&gt;"
      # The apostrophe is escaped too (HTML-meaningful character coverage).
      assert html =~ "&#39;"

      # The TEXT body is plain text (not HTML) — it legitimately keeps the raw
      # name; escaping there would corrupt a real plain-text name.
      assert config.text_body =~ @injection_name
    end

    test "the generic fallback (Rendering.default_template/1) escapes HTML-meaningful characters" do
      {_subject, text_body, html_body} =
        Rendering.default_template(%{to: "obrien-SENTINEL@customer.test", name: @injection_name})

      refute html_body =~ "<script>alert(document.domain)</script>"
      assert html_body =~ "&lt;script&gt;alert(document.domain)&lt;/script&gt;"
      assert html_body =~ "&#39;"
      # Plain-text body keeps the raw name by design.
      assert text_body =~ @injection_name
    end

    test "masking preserved: html_safe/1 renders a %Masked{} as ••••, never a vt_ token, never double-escaped" do
      masked = Masked.new("vt_super_secret_token", :emails)

      assert Rendering.html_safe(masked) == Masked.mask()
      refute Rendering.html_safe(masked) =~ "vt_"
      refute Rendering.html_safe(masked) =~ "&amp;"
    end
  end

  # ==========================================================================
  # F1 — auth emails carry real content with the correct actionable link
  # ==========================================================================

  describe "F1: AuthMailer renders real content with the correct route link" do
    setup do
      Application.put_env(:samen_core, EmailWorker, adapter: CapturingAdapter, adapter_config: %{})
      Application.put_env(:samen_core, :delivery_env, :prod)
      :ok
    end

    test "each auth context renders a non-empty subject + text + html body with the correct link" do
      base = "https://app.example.test"

      cases = [
        {:email_verify, "/verify/", :credential_id, "cred-verify-1"},
        {:password_reset, "/reset/", :credential_id, "cred-reset-1"},
        {:invite, "/invite/", :invitation_id, "inv-1"}
      ]

      for {context, segment, id_key, id} <- cases do
        token = "tok_#{context}_abcDEF123-_"

        opts = [{id_key, id}, {:org_id, "org-1"}, {:raw_token, token}, {:base_url, base}]
        assert {:ok, _receipt} = AuthMailer.dispatch(context, opts)

        assert_receive {:t111_captured, _message, config}, 1_000

        link = "#{base}#{segment}#{token}"

        assert is_binary(config.subject) and config.subject != ""
        assert is_binary(config.text_body) and config.text_body != ""
        assert is_binary(config.html_body) and config.html_body != ""

        # The actionable link points at the correct T110 route, in BOTH bodies.
        assert config.text_body =~ link
        assert config.html_body =~ ~s(href="#{link}")
      end
    end

    test "NEGATIVE CONTROL: a tokenless dispatch carries NO content (the pre-fix shape) — proves the content assertion is refutable" do
      assert {:ok, _receipt} = AuthMailer.dispatch(:email_verify, credential_id: "cred-x", org_id: "org-1")

      assert_receive {:t111_captured, _message, config}, 1_000

      refute Map.has_key?(config, :subject)
      refute Map.has_key?(config, :text_body)
      refute Map.has_key?(config, :html_body)
    end
  end
end
