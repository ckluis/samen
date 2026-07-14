defmodule Samen.Web.OperatorFlagAdminTest do
  @moduledoc """
  WS-B B6 UNIT 1 (operator plane) — `Samen.Web.Operator.FlagAdminLive` at
  `/operator/flags` (ADR-020; design G6 §3.5; AC-G6-7), over the operator org's OWN
  `FeatureFlag` rows (the PLATFORM flags) in the host's Primitives namespace, wired
  via the `:flags_namespace` mount label:

    * **THE KILL SWITCH (RP-F4 at the UI)** — a visually distinct, confirm-gated
      control. Flipping it round-trips through `Cache.invalidate/1` (the B5
      write-through hop): warm the cache with a LONG TTL so ONLY invalidation can
      refresh, kill through the UI event, and the NEXT `evaluate/2` is OFF
      (`:kill_switch`). SABOTAGE TWIN: the same DB flip WITHOUT the UI path leaves
      the warm cache ON — proving the UI's invalidate is load-bearing, not a
      re-read coincidence (the exact B5 kill-switch test pattern).
    * **Ramp + targeting over tenant cohorts** — rollout_pct + the rule editor
      through the kernel action; the PII-keyed rule refusal surfaces friendly here
      too (RP-F3 is plane-independent).
    * **Per-org evaluated state** — the debugging table renders one cache-FREE
      decision per tenant account (bounded cohort read).
    * **Per-plane visibility** — the operator page shows ONLY the operator org's
      platform flags; a tenant org's flags never render (no cross-plane leak; the
      kernel `OrgScope` is the mechanism). Without a `flags_namespace` label the
      page renders an honest empty card. An impersonation-plane mount renders no
      write affordance and the kernel refuses the plain member-scope write.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.FeatureFlags
  alias Samen.FeatureFlags.Cache
  alias Samen.FeatureFlags.Decision
  alias Samen.Web.Flags.Reads
  alias Samen.Web.Mount
  alias Samen.Web.Operator.FlagAdminLive
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.Primitives.FeatureFlag

  setup do
    Cache.invalidate_all()
    on_exit(fn -> Cache.invalidate_all() end)
    :ok
  end

  # -- harness -------------------------------------------------------------------

  defp operator_mount(operator_org_id, opts \\ []) do
    labels =
      Keyword.get(opts, :labels, %{})
      |> Map.put_new(:flags_namespace, Samen.WebTest.Primitives)

    build_operator_mount(operator_org_id, labels: labels)
  end

  defp mount_socket(mount) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> FlagAdminLive.load()
  end

  defp html(socket), do: render_html(FlagAdminLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = FlagAdminLive.handle_event(name, params, socket)
    socket
  end

  defp seed_operator_org do
    org =
      Op.Org
      |> Ash.Changeset.for_create(:create, %{name: "Samen SaaS, Inc.", plan: "operator"}, authorize?: false)
      |> Ash.create!()

    org
    |> Ash.Changeset.for_update(:update, %{org_id: org.id}, authorize?: false)
    |> Ash.update!()
  end

  defp seed_account(operator_org_id, name, plan) do
    Op.Org
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: operator_org_id, name: name, slug: Ash.UUID.generate(), plan: plan},
      authorize?: false
    )
    |> Ash.create!()
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

  # The REAL cached-evaluation path over the test host's flag rows — the same
  # flag_module seam the B5 AC-G6-6 test uses. LONG TTL so ONLY an explicit
  # invalidation can refresh (models the write-through hop being load-bearing).
  defp eval_opts, do: [flag_module: FeatureFlag, ttl_ms: 3_600_000]

  # ---------------------------------------------------------------------------
  # The platform flag list + the visually distinct, confirm-gated kill switch
  # ---------------------------------------------------------------------------

  test "platform flags render with a visually distinct, confirm-gated kill switch on live flags; killed flags offer re-enable" do
    op_org = seed_operator_org()
    live = seed_flag(op_org.id, name: "platform.live_flag")
    _dead = seed_flag(op_org.id, name: "platform.dead_flag", enabled: false)

    socket = mount_socket(operator_mount(op_org.id))
    rendered = html(socket)

    assert rendered =~ "platform.live_flag"
    assert rendered =~ "platform.dead_flag"

    # The kill switch: its own distinct wrapper + danger styling + the data-confirm
    # interlock naming the blast radius — never one accidental click away.
    assert rendered =~ ~s(class="kill-switch")
    assert rendered =~ "Kill switch"
    assert rendered =~ ~s(phx-click="kill_flag")
    assert rendered =~ ~s(phx-value-id="#{live.id}")
    assert rendered =~ "KILL this flag? Every evaluation, for every org, returns OFF"
    assert rendered =~ ~s(class="btn danger")

    # The killed flag reads honestly and offers re-enable, not a second kill.
    assert rendered =~ "killed / off"
    assert rendered =~ ~s(phx-click="enable_flag")
  end

  # ---------------------------------------------------------------------------
  # RP-F4 at the UI — the kill switch ROUND-TRIPS through Cache.invalidate
  # ---------------------------------------------------------------------------

  test "KILL SWITCH ROUND-TRIP: the UI kill writes enabled=false AND invalidates the cache — the next evaluate/2 is OFF" do
    op_org = seed_operator_org()
    flag = seed_flag(op_org.id, name: "incident.lever", rollout_pct: 100)

    # Warm the REAL cache through the DB-backed flag_module path: the flag is ON.
    assert FeatureFlags.evaluate("incident.lever", op_org.id, eval_opts()).on

    # The operator flips the kill switch through the confirm-gated UI event.
    socket = mount_socket(operator_mount(op_org.id))
    socket = event(socket, "kill_flag", %{"id" => flag.id})
    assert socket.assigns.flag_error == nil

    # The write persisted through the kernel action…
    refute raw_flag(flag.id).enabled
    # …and ROUND-TRIPPED through Cache.invalidate/1: despite the hour-long TTL, the
    # next evaluate reloads and short-circuits OFF (reason: :kill_switch).
    assert %Decision{on: false, reason: :kill_switch} =
             FeatureFlags.evaluate("incident.lever", op_org.id, eval_opts())

    # The page renders the killed state.
    assert html(socket) =~ "killed / off"
  end

  test "SABOTAGE TWIN: the same DB flip WITHOUT the UI path is NOT seen through the warm cache — proving the UI's invalidate is load-bearing" do
    op_org = seed_operator_org()
    flag = seed_flag(op_org.id, name: "incident.stale", rollout_pct: 100)

    # Warm the cache: ON, hour-long TTL — only an explicit invalidation can refresh.
    assert FeatureFlags.evaluate("incident.stale", op_org.id, eval_opts()).on

    # Flip enabled=false DIRECTLY in the DB — the UI (and its write-through
    # invalidate) is bypassed, exactly the sabotage of the mechanism under test.
    flag
    |> Ash.Changeset.for_update(:update, %{enabled: false}, authorize?: false)
    |> Ash.update!()

    # The warm cache still serves ON. If this were OFF, the round-trip test above
    # would be a tautology (any evaluate would re-read the DB regardless).
    assert FeatureFlags.evaluate("incident.stale", op_org.id, eval_opts()).on,
           "without the UI's Cache.invalidate the stale ON must persist — the invalidate is the mechanism"

    # The write-through hop is exactly what closes it.
    Cache.invalidate("incident.stale")

    assert %Decision{on: false, reason: :kill_switch} =
             FeatureFlags.evaluate("incident.stale", op_org.id, eval_opts())
  end

  # ---------------------------------------------------------------------------
  # B9 carry B6-N2 — Re-enable is IDEMPOTENT (interlock symmetry with kill)
  # ---------------------------------------------------------------------------

  test "RED-PATH (B6-N2): a rapid double-click on Re-enable after a kill leaves the flag ENABLED — never toggled back off; double-kill stays killed" do
    op_org = seed_operator_org()
    flag = seed_flag(op_org.id, name: "incident.recover")

    socket = mount_socket(operator_mount(op_org.id))
    socket = event(socket, "kill_flag", %{"id" => flag.id})
    refute raw_flag(flag.id).enabled

    # The rapid double-click: two enable_flag events in one breath. The OLD raw
    # toggle flipped the second click back to disabled — the exact carried defect.
    socket = event(socket, "enable_flag", %{"id" => flag.id})
    assert raw_flag(flag.id).enabled

    socket = event(socket, "enable_flag", %{"id" => flag.id})
    assert socket.assigns.flag_error == nil

    assert raw_flag(flag.id).enabled,
           "the second click of a Re-enable double-click flipped the flag back off — enable must be idempotent (B6-N2)"

    # The interlock symmetry: kill was already idempotent; pin it so the pair
    # can never diverge again.
    socket = event(socket, "kill_flag", %{"id" => flag.id})
    socket = event(socket, "kill_flag", %{"id" => flag.id})
    assert socket.assigns.flag_error == nil
    refute raw_flag(flag.id).enabled
  end

  # ---------------------------------------------------------------------------
  # B9 carry B6-N1 — the PERMANENT foreign-id regression probe (the B6 gate's
  # adversarial probes, folded into the suite): every mutating path driven with a
  # FOREIGN org's flag id answers "Flag not found." and mutates NOTHING —
  # insurance against a refactor sourcing org_id from event params instead of
  # socket.assigns.
  # ---------------------------------------------------------------------------

  test "FOREIGN-ID REGRESSION (B6-N1): toggle / kill / ramp / rules driven with another org's flag id — 'Flag not found.', ZERO mutation" do
    op_org = seed_operator_org()
    foreign_org_id = Ash.UUID.generate()

    foreign =
      seed_flag(foreign_org_id,
        name: "foreign.crown_jewel",
        enabled: true,
        rollout_pct: 77,
        target_rules: [%{"attribute" => "plan", "op" => "eq", "values" => ["pro"], "then" => "on"}]
      )

    mount = operator_mount(op_org.id)
    socket = mount_socket(mount)
    flags_mount = %{mount | namespace: Samen.WebTest.Primitives, scope_kind: :flags}
    admin_scope = Reads.write_scope(mount, op_org.id)

    # The Reads mutators (what save_ramp / add_rule / remove_rule ride) — the
    # kernel OrgScope makes the foreign row invisible to the elevated ADMIN scope.
    assert {:error, "Flag not found."} = Reads.toggle_flag(flags_mount, admin_scope, foreign.id)
    assert {:error, "Flag not found."} = Reads.set_rollout(flags_mount, admin_scope, foreign.id, 0)
    assert {:error, "Flag not found."} = Reads.put_rules(flags_mount, admin_scope, foreign.id, [])

    # The UI events, foreign id in the event PARAMS (the refactor this insures
    # against would trust exactly these params).
    killed = event(socket, "kill_flag", %{"id" => foreign.id})
    assert killed.assigns.flag_error == "Flag not found."

    enabled = event(socket, "enable_flag", %{"id" => foreign.id})
    assert enabled.assigns.flag_error == "Flag not found."

    # edit_flag with a foreign id opens NO modal — so the modal-scoped mutators
    # (save_ramp / add_rule) have no foreign flag to write through.
    edited = event(socket, "edit_flag", %{"id" => foreign.id})
    assert edited.assigns.edit_flag == nil

    # ZERO MUTATION: the foreign flag is exactly as seeded.
    after_probe = raw_flag(foreign.id)
    assert after_probe.enabled == true
    assert after_probe.rollout_pct == 77
    assert [%{"attribute" => "plan"}] = after_probe.target_rules

    # POSITIVE CONTROL (anti-tautology): the SAME calls against the operator's OWN
    # flag id succeed — the refusal above is the org boundary, not a broken path.
    own = seed_flag(op_org.id, name: "platform.own_flag", rollout_pct: 10)
    assert {:ok, _} = Reads.set_rollout(flags_mount, admin_scope, own.id, 55)
    assert raw_flag(own.id).rollout_pct == 55
  end

  # ---------------------------------------------------------------------------
  # Ramp + targeting + per-org evaluated state (the debugging modal)
  # ---------------------------------------------------------------------------

  test "ramp persists through the kernel action; the modal shows per-tenant-org evaluated state over the bounded cohort" do
    op_org = seed_operator_org()
    pro = seed_account(op_org.id, "Pro Freight Co", "pro")
    starter = seed_account(op_org.id, "Starter Haulers", "starter")

    flag =
      seed_flag(op_org.id,
        name: "platform.targeted",
        rollout_pct: 0,
        target_rules: [%{"attribute" => "plan", "op" => "eq", "values" => ["pro"], "then" => "on"}]
      )

    socket = mount_socket(operator_mount(op_org.id)) |> event("edit_flag", %{"id" => flag.id})
    rendered = html(socket)

    # The ramp form + the rules table render in the modal.
    assert rendered =~ ~s(id="ramp-form")
    assert rendered =~ ~s(id="flag-rules")
    assert rendered =~ ~s(class="rule-attribute")

    # Per-org evaluated state: the pro-plan account is targeted ON, the starter
    # account (rollout 0, no match) is OFF — decided per cohort row, cache-free.
    assert rendered =~ ~s(id="per-org-state")
    assert rendered =~ ~s(id="cohort-#{pro.id}")
    assert rendered =~ ~s(id="cohort-#{starter.id}")
    assert rendered =~ "targeted"
    assert rendered =~ "rollout_out"

    # The ramp write goes through the kernel action.
    _socket = event(socket, "save_ramp", %{"ramp" => %{"rollout_pct" => "40"}})
    assert raw_flag(flag.id).rollout_pct == 40
  end

  test "RED PATH: the operator rule editor cannot submit a PII-keyed rule either (kernel refusal, surfaced friendly)" do
    op_org = seed_operator_org()
    flag = seed_flag(op_org.id, name: "platform.rules", target_rules: [])

    socket = mount_socket(operator_mount(op_org.id)) |> event("edit_flag", %{"id" => flag.id})

    socket =
      event(socket, "add_rule", %{
        "rule" => %{"attribute" => "email", "op" => "eq", "values" => "vip@example.com", "then" => "on"}
      })

    rendered = html(socket)
    assert rendered =~ ~s(id="rule-error")
    assert rendered =~ "refused"
    assert raw_flag(flag.id).target_rules == []

    # Anti-tautology twin: the governed cohort key persists through the same path.
    _socket =
      event(socket, "add_rule", %{
        "rule" => %{"attribute" => "tier", "op" => "eq", "values" => "gold", "then" => "allow"}
      })

    assert [%{"attribute" => "tier"}] = raw_flag(flag.id).target_rules
  end

  # ---------------------------------------------------------------------------
  # Per-plane visibility — platform flags only; no cross-plane leak
  # ---------------------------------------------------------------------------

  test "VISIBILITY: the operator sees ONLY the operator org's platform flags — a tenant org's flags never render (and vice versa)" do
    op_org = seed_operator_org()
    tenant_org_id = Ash.UUID.generate()
    seed_flag(op_org.id, name: "platform.operator_flag")
    seed_flag(tenant_org_id, name: "tenant.private_flag")

    # Operator plane: platform flags only.
    rendered = html(mount_socket(operator_mount(op_org.id)))
    assert rendered =~ "platform.operator_flag"
    refute rendered =~ "tenant.private_flag"

    # Tenant plane (the same rows, the other plane): own flags only — no leak of
    # the platform flag into the tenant's settings surface.
    tenant_socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, build_mount(:flags))
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> Samen.Web.Flags.SettingsLive.load(tenant_org_id)

    tenant_rendered = render_html(Samen.Web.Flags.SettingsLive, tenant_socket.assigns)
    assert tenant_rendered =~ "tenant.private_flag"
    refute tenant_rendered =~ "platform.operator_flag"
  end

  test "without a flags_namespace label the page renders the honest wiring empty state (no flags, no crash)" do
    op_org = seed_operator_org()
    mount = build_operator_mount(op_org.id)

    rendered = html(mount_socket(mount))
    assert rendered =~ "flags-ns-empty"
    assert rendered =~ "No flags namespace wired."
    refute rendered =~ "kill-switch"
  end

  test "IMPERSONATION plane: no write affordance in the DOM; the kernel refuses the plain member-scope write" do
    op_org = seed_operator_org()
    flag = seed_flag(op_org.id, name: "platform.posture")

    mount =
      Samen.Web.Mount.new(
        :operator,
        Op,
        Samen.WebTest.Repo,
        plane: Samen.Web.Plane.operator("op-1", op_org.id, "test-session"),
        labels: %{operator_org_id: op_org.id, flags_namespace: Samen.WebTest.Primitives}
      )

    socket = mount_socket(mount)
    rendered = html(socket)

    # Rows render (non-PII config rows); no kill/edit affordance on this plane.
    assert rendered =~ "platform.posture"
    refute rendered =~ ~s(phx-click="kill_flag")
    refute rendered =~ ~s(phx-click="edit_flag")
    refute rendered =~ "data-confirm"

    # Posture-refused event; the flag is untouched.
    socket = event(socket, "kill_flag", %{"id" => flag.id})
    assert socket.assigns.flag_error == "Read-only on this plane."
    assert raw_flag(flag.id).enabled

    # Kernel enforcement (AC-G6-7): the plain, un-elevated member scope is refused
    # by RoleAtLeast(:admin) — the read-only posture is kernel-backed, not UI-only.
    flags_mount = %{mount | namespace: Samen.WebTest.Primitives, scope_kind: :flags}
    assert {:error, _} = Reads.toggle_flag(flags_mount, Mount.scope(mount, op_org.id), flag.id)
    assert raw_flag(flag.id).enabled
  end
end
