defmodule Samen.Web.FlagsSettingsCrudTest do
  @moduledoc """
  WS-B B6 UNIT 1 (tenant plane) — `Samen.Web.Flags.SettingsLive` on the A2 kit
  contract (`ListLive` + `list_view` + `simple_form`/`modal`), over the org's OWN
  `FeatureFlag` rows (`Samen.WebTest.Primitives.FeatureFlag`, non-PII Tier-0 config;
  ADR-020; design G6 §3.5):

    * **Toggle + ramp (AC-G6-7)** — the enable/disable toggle and the rollout ramp
      go through the sanctioned kernel `:update` action (`OrgScope` + `RoleAtLeast
      :admin` via the plane-preserving `write_scope/2`), asserted against raw DB.
    * **RULE-REFUSAL RED PATH (RP-F3 / AC-G6-4 at the UI)** — the targeting-rule
      editor CANNOT submit a PII-keyed rule: an `email`-keyed rule is refused by the
      kernel `NonPiiTargeting` validation INSIDE the action, surfaces as a friendly
      inline error, and persists NOTHING. Anti-tautology twin: the SAME form path
      with a governed key (`plan`) persists — the refusal is the validation, not a
      broken form.
    * **Per-plane visibility** — a tenant sees ONLY its own org's flags (kernel
      `OrgScope`); another org's flags never render. The operator/impersonation
      plane renders NO write affordance (posture) and the kernel refuses a plain
      member-scope write (enforcement — not UI-only).
    * **Bounded read** — `flags_page/3` passes `Samen.Web.Reads.bounded!/4`
      non-vacuously and keyset pagination walks the set.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Flags.Reads
  alias Samen.Web.Flags.SettingsLive
  alias Samen.Web.Mount
  alias Samen.Web.Reads, as: WebReads
  alias Samen.WebTest.Primitives.FeatureFlag

  # -- harness -------------------------------------------------------------------

  defp mount_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:flags, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> SettingsLive.load(org_id)
  end

  defp html(socket), do: render_html(SettingsLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = SettingsLive.handle_event(name, params, socket)
    socket
  end

  defp seed_flag(org_id, attrs) do
    FeatureFlag
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org_id, enabled: true, rollout_pct: 100}, Map.new(attrs)),
      authorize?: false
    )
    |> Ash.create!()
  end

  defp raw_flag(id), do: Ash.get!(FeatureFlag, id, authorize?: false)

  # ---------------------------------------------------------------------------
  # Toggle — the sanctioned enable/disable through the kernel update action
  # ---------------------------------------------------------------------------

  test "the flag list renders the org's flags; toggle flips enabled through the sanctioned update and refreshes" do
    org_id = Ash.UUID.generate()
    flag = seed_flag(org_id, name: "checkout.v2", description: "New checkout")

    socket = mount_socket(org_id)
    rendered = html(socket)
    assert rendered =~ "checkout.v2"
    assert rendered =~ ~s(phx-click="toggle_flag")
    # Evaluated state renders the bounded decision (enabled @ 100% → ON, :default).
    assert rendered =~ "flag-decision"
    assert rendered =~ ~s(class="flag-reason)
    assert rendered =~ "default"

    socket = event(socket, "toggle_flag", %{"id" => flag.id})
    refute raw_flag(flag.id).enabled
    rendered = html(socket)
    assert rendered =~ "disabled"
    # A killed/disabled flag previews OFF with the kill_switch reason.
    assert rendered =~ "kill_switch"

    _socket = event(socket, "toggle_flag", %{"id" => flag.id})
    assert raw_flag(flag.id).enabled
  end

  # ---------------------------------------------------------------------------
  # Percentage ramp — the kit modal form → kernel update
  # ---------------------------------------------------------------------------

  test "Ramp & rules opens the kit modal; save_ramp persists a clamped rollout_pct through the kernel action" do
    org_id = Ash.UUID.generate()
    flag = seed_flag(org_id, name: "search.rerank", rollout_pct: 100)

    socket = mount_socket(org_id) |> event("edit_flag", %{"id" => flag.id})
    rendered = html(socket)
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(id="ramp-form")
    assert rendered =~ ~s(name="ramp[rollout_pct]")

    socket = event(socket, "save_ramp", %{"ramp" => %{"rollout_pct" => "25"}})
    assert raw_flag(flag.id).rollout_pct == 25
    assert html(socket) =~ "25%"

    # Hostile ramp values are clamped by the write path, never persisted raw.
    _socket = event(socket, "save_ramp", %{"ramp" => %{"rollout_pct" => "900"}})
    assert raw_flag(flag.id).rollout_pct == 100
  end

  # ---------------------------------------------------------------------------
  # RED PATH (RP-F3 at the UI) — the editor cannot submit a PII-keyed rule
  # ---------------------------------------------------------------------------

  test "RED PATH: an email-keyed targeting rule is REFUSED with a friendly inline error and persists NOTHING; the same form path persists a governed key" do
    org_id = Ash.UUID.generate()
    flag = seed_flag(org_id, name: "billing.pdf", target_rules: [])

    socket = mount_socket(org_id) |> event("edit_flag", %{"id" => flag.id})

    # The PII-keyed submit: kernel NonPiiTargeting refuses INSIDE the update action.
    socket =
      event(socket, "add_rule", %{
        "rule" => %{"attribute" => "email", "op" => "eq", "values" => "vip@example.com", "then" => "on"}
      })

    rendered = html(socket)
    assert rendered =~ ~s(id="rule-error")
    assert rendered =~ "refused"
    assert rendered =~ "non-PII"
    assert raw_flag(flag.id).target_rules == [], "the refused rule must not persist"

    # Default-deny belt: an arbitrary uncleared key is refused too.
    socket =
      event(socket, "add_rule", %{
        "rule" => %{"attribute" => "favorite_color", "op" => "eq", "values" => "red", "then" => "on"}
      })

    assert html(socket) =~ ~s(id="rule-error")
    assert raw_flag(flag.id).target_rules == []

    # ANTI-TAUTOLOGY TWIN: the SAME form path with a governed non-PII key persists —
    # the refusal above is the validation, not a broken form.
    socket =
      event(socket, "add_rule", %{
        "rule" => %{"attribute" => "plan", "op" => "in", "values" => "pro, enterprise", "then" => "on"}
      })

    refute html(socket) =~ ~s(id="rule-error")

    assert [%{"attribute" => "plan", "op" => "in", "values" => ["pro", "enterprise"], "then" => "on"}] =
             raw_flag(flag.id).target_rules

    # And the editor removes it again through the same kernel action.
    socket = event(socket, "remove_rule", %{"index" => "0"})
    assert raw_flag(flag.id).target_rules == []
    assert html(socket) =~ ~s(id="rule-form")
  end

  # ---------------------------------------------------------------------------
  # Per-plane visibility — tenant sees OWN flags only (kernel OrgScope)
  # ---------------------------------------------------------------------------

  test "VISIBILITY: a tenant sees only its own org's flags — another org's flags never render" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    seed_flag(org_a, name: "org-a.only_flag")
    seed_flag(org_b, name: "org-b.secret_flag")

    rendered = html(mount_socket(org_a))
    assert rendered =~ "org-a.only_flag"
    refute rendered =~ "org-b.secret_flag"

    rendered_b = html(mount_socket(org_b))
    assert rendered_b =~ "org-b.secret_flag"
    refute rendered_b =~ "org-a.only_flag"
  end

  # ---------------------------------------------------------------------------
  # Operator/impersonation plane — read-only posture + KERNEL enforcement
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: no write affordance in the DOM; the kernel refuses a plain member-scope write regardless of UI" do
    org_id = Ash.UUID.generate()
    flag = seed_flag(org_id, name: "ops.visible_flag")

    socket = mount_socket(org_id, plane: :operator, target_org_id: org_id)
    rendered = html(socket)

    # Rows render (flags are non-PII config); write affordances do not.
    assert rendered =~ "ops.visible_flag"
    refute rendered =~ ~s(phx-click="toggle_flag")
    refute rendered =~ ~s(phx-click="edit_flag")

    # A mutating event on this plane is posture-refused (no elevation is built)…
    socket = event(socket, "toggle_flag", %{"id" => flag.id})
    assert socket.assigns.flag_error == "Read-only on this plane."
    assert raw_flag(flag.id).enabled

    # …and ENFORCEMENT is the kernel's, not the UI's: a direct write with the plain
    # (un-elevated, role: :member) scope is refused by RoleAtLeast(:admin).
    mount = build_mount(:flags, plane: :operator, target_org_id: org_id)
    assert {:error, _msg} = Reads.toggle_flag(mount, Mount.scope(mount, org_id), flag.id)
    assert raw_flag(flag.id).enabled, "the kernel policy must refuse the un-elevated write"
  end

  # ---------------------------------------------------------------------------
  # Bounded read + pagination (the A3 per-surface probe)
  # ---------------------------------------------------------------------------

  test "flags_page/3 is BOUNDED (bounded!/4 passes non-vacuously) and keyset pagination walks the set" do
    org_id = Ash.UUID.generate()

    for i <- 1..12 do
      seed_flag(org_id, name: "flag-#{String.pad_leading(to_string(i), 2, "0")}")
    end

    mount = build_mount(:flags)
    scope = Mount.scope(mount, org_id)

    assert :ok == WebReads.bounded!(&Reads.flags_page/3, mount, scope, page_size: 10)

    socket = mount_socket(org_id)
    assert length(socket.assigns.page.items) == 12

    state = %{socket.assigns.list_state | page_size: 10}
    page = Reads.flags_page(mount, scope, state)
    assert length(page.items) == 10
    assert page.has_more

    next = Reads.flags_page(mount, scope, %{state | cursor: page.next_cursor})
    assert length(next.items) == 2
    refute next.has_more
  end

  test "zero rows render the kit-default empty_state" do
    socket = mount_socket(Ash.UUID.generate())
    assert socket.assigns.page.items == []
    assert html(socket) =~ "empty-state"
  end
end
