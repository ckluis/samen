defmodule Samen.Web.Auth.OnboardingTest do
  @moduledoc """
  T08 — A8 onboarding-wizard scaffold (ADR-035 §5 A8; spec §WS-A A8). Proves,
  against the samen_web test host's Operator Identity mount:

    1. A fresh org's wizard is OFFERED (`Onboarding.needed?/3` true,
       `WizardLive` renders the step-1 org-naming form); completing step 1
       writes `Org.name`; the invite step creates a REAL pending
       `Invitation` row through T05's confirmed `Samen.Identity.Invite` flow
       (via `Samen.Web.Settings.Invitations` — reused, never reinvented);
       after `"finish"` the wizard is NOT shown again — a LATER, independent
       load renders the "already set up" card, never the step forms (both
       halves asserted — anti-tautology).
    2. The plan-selection step renders the fail-honest empty state (EXACT
       copy asserted) with no `:plan_labels` hook wired — no fabricated plan
       list, ever (INV-4 spirit); POSITIVE CONTROL: wiring a `:plan_labels`
       MFA renders REAL choices and a selection writes `Org.plan`; a forged
       plan key is refused.
    3. Every step is skippable — skipping org/plan/invite advances without
       writing, and `"finish"` still completes the wizard.
    4. `samen_onboarding_routes` mounts `/onboarding` in a real
       `Phoenix.Router` (the macro-compiles-or-fails proof, the
       `Samen.Web.RouterTest` precedent).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Identity.Register
  alias Samen.Web.Mount
  alias Samen.Web.Onboarding
  alias Samen.Web.Onboarding.WizardLive
  alias Samen.WebTest.Operator.AuthToken
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Invitation
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.Org
  alias Samen.WebTest.Operator.User

  # A real host router mounting `/onboarding` via the macro — if the macro is
  # broken, THIS MODULE FAILS TO COMPILE (the `Samen.Web.RouterTest` proof).
  defmodule HostRouter do
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    scope "/" do
      samen_onboarding_routes(Samen.WebTest.Operator, repo: Samen.WebTest.Repo)
    end
  end

  # The stub `:plan_labels` MFA — a host's WS-B hookup point, once billing
  # exists. Arity 1: the hook is called with `org_id` appended.
  def stub_plans(_org_id), do: [%{key: "starter", label: "Starter"}, %{key: "growth", label: "Growth"}]

  # See invitation_test.exs — `Samen.Delivery.AuthMailer` resolves its env the
  # SAME way `Samen.Delivery.Lifecycle.EmailWorker` does; set it explicitly so
  # the invite step's real send (through the fail-honest Delivery chokepoint)
  # captures via `LocalSink` in this suite instead of `:adapter_unconfigured`.
  setup do
    prev = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :delivery_env, prev),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    :ok
  end

  defp register_mods,
    do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Repo}

  defp unique_email, do: "onboard-#{System.unique_integer([:positive])}@example.test"

  defp register! do
    attrs = %{
      org_name: "Onboard Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: unique_email(),
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())
    result
  end

  defp owner_scope(result) do
    %Samen.Scope{
      actor: %{id: result.user.id, org_id: result.org.id, role: :owner, verified?: true, kind: :tenant, plane: :tenant}
    }
  end

  defp plan_mount, do: Mount.new(:settings, Samen.WebTest.Operator, Repo, labels: %{plan_labels: {__MODULE__, :stub_plans, []}})

  defp mount_socket(mount, org_id, user_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:samen_session, %{})
    |> WizardLive.load(org_id, user_id)
  end

  defp mount_socket(org_id, user_id), do: mount_socket(build_mount(:settings), org_id, user_id)

  defp html(socket), do: render_html(WizardLive, socket.assigns)

  defp event(socket, name, params \\ %{}) do
    {:noreply, socket} = WizardLive.handle_event(name, params, socket)
    socket
  end

  # T110 — Skip is no longer a `phx-click` event; it is a plain GET
  # `<.link patch>` to the next step (works no-JS, F2). Navigating there advances
  # the step via `handle_params/3`'s `&step=` reading and WRITES NOTHING — this
  # helper drives that same step-navigation the Skip link performs.
  defp goto(socket, step) when is_atom(step) do
    params = %{"step" => Atom.to_string(step), "org" => socket.assigns.org_id, "user" => socket.assigns.user_id}
    {:noreply, socket} = WizardLive.handle_params(params, "http://localhost/onboarding", socket)
    socket
  end

  defp reread_org(id) do
    Org
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :name, :plan, :onboarded_at])
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # ===========================================================================
  # 1. Engine unit — Samen.Web.Onboarding
  # ===========================================================================

  describe "Samen.Web.Onboarding engine" do
    test "needed?/3: TRUE for a fresh org, FALSE once complete!/3 runs (anti-tautology)" do
      reg = register!()
      mount = build_mount(:settings)
      scope = owner_scope(reg)

      assert Onboarding.needed?(mount, scope, reg.org.id)

      assert {:ok, _org} = Onboarding.complete!(mount, scope, reg.org.id)

      refute Onboarding.needed?(mount, scope, reg.org.id)
      refute is_nil(reread_org(reg.org.id).onboarded_at)
    end

    test "RED PATH: needed?/3 is false for a nil org id (no crash)" do
      refute Onboarding.needed?(build_mount(:settings), %{}, nil)
    end

    test "name_org/4 writes Org.name" do
      reg = register!()
      mount = build_mount(:settings)
      scope = owner_scope(reg)

      assert {:ok, org} = Onboarding.name_org(mount, scope, reg.org.id, "Renamed Co")
      assert org.name == "Renamed Co"
      assert reread_org(reg.org.id).name == "Renamed Co"
    end

    test "GREEN (fail-honest default): plan_choices/2 is :not_configured with no :plan_labels hook wired" do
      mount = build_mount(:settings)
      assert Onboarding.plan_choices(mount, Ash.UUID.generate()) == :not_configured
    end

    test "POSITIVE CONTROL: plan_choices/2 returns real choices once :plan_labels IS wired" do
      assert {:ok, choices} = Onboarding.plan_choices(plan_mount(), Ash.UUID.generate())
      assert choices == [%{key: "starter", label: "Starter"}, %{key: "growth", label: "Growth"}]
    end

    test "RED: select_plan/4 refuses a plan key that is not currently offered (never an actor-forged value)" do
      reg = register!()
      scope = owner_scope(reg)

      assert {:error, :invalid_plan} = Onboarding.select_plan(build_mount(:settings), scope, reg.org.id, "forged-plan")
      assert reread_org(reg.org.id).plan == "free"
    end

    test "RED: select_plan/4 refuses ANY key when the hook is unconfigured" do
      reg = register!()
      scope = owner_scope(reg)

      assert {:error, :invalid_plan} = Onboarding.select_plan(build_mount(:settings), scope, reg.org.id, "starter")
    end

    test "POSITIVE CONTROL: select_plan/4 writes Org.plan when the key IS offered" do
      reg = register!()
      scope = owner_scope(reg)

      assert {:ok, org} = Onboarding.select_plan(plan_mount(), scope, reg.org.id, "growth")
      assert org.plan == "growth"
      assert reread_org(reg.org.id).plan == "growth"
    end
  end

  # ===========================================================================
  # 2. WizardLive — step 1: org naming
  # ===========================================================================

  describe "WizardLive — org-naming step" do
    test "a fresh org's wizard renders step 1 (org naming), pre-filled with the current name" do
      reg = register!()
      socket = mount_socket(reg.org.id, reg.user.id)

      refute socket.assigns.complete?
      html = html(socket)
      assert html =~ ~s(id="onboarding-wizard")
      assert html =~ ~s(id="onboarding-step-org")
      assert html =~ ~s(id="onboarding-org-form")
      assert html =~ reg.org.name
    end

    test "submitting step 1 writes Org.name and advances to step 2 (plan)" do
      reg = register!()
      socket = mount_socket(reg.org.id, reg.user.id) |> event("name_org", %{"org" => %{"name" => "New Name"}})

      assert socket.assigns.step == :plan
      assert reread_org(reg.org.id).name == "New Name"
      html = html(socket)
      assert html =~ ~s(id="onboarding-step-plan")
      refute html =~ ~s(id="onboarding-step-org")
    end

    test "SKIP: skipping step 1 advances to step 2 WITHOUT writing" do
      reg = register!()
      socket = mount_socket(reg.org.id, reg.user.id) |> goto(:plan)

      assert socket.assigns.step == :plan
      assert reread_org(reg.org.id).name == reg.org.name
    end
  end

  # ===========================================================================
  # 3. WizardLive — step 2: plan selection (the WS-B hook, INV-4)
  # ===========================================================================

  describe "WizardLive — plan-selection step" do
    test "GREEN (fail-honest default): the exact empty-state copy renders, no fake plan list" do
      reg = register!()
      socket = mount_socket(reg.org.id, reg.user.id) |> goto(:plan)

      html = html(socket)
      assert html =~ ~s(id="onboarding-plan-empty")
      assert html =~ Onboarding.no_plans_copy()
      refute html =~ ~s(id="onboarding-plan-form")
    end

    test "POSITIVE CONTROL: a wired :plan_labels hook renders REAL choices, not the empty state" do
      reg = register!()
      socket = mount_socket(plan_mount(), reg.org.id, reg.user.id) |> goto(:plan)

      html = html(socket)
      assert html =~ ~s(id="onboarding-plan-form")
      assert html =~ ~s(id="onboarding-plan-starter")
      assert html =~ ~s(id="onboarding-plan-growth")
      assert html =~ "Starter"
      refute html =~ ~s(id="onboarding-plan-empty")
    end

    test "selecting a plan writes Org.plan and advances to step 3 (invite)" do
      reg = register!()

      socket =
        mount_socket(plan_mount(), reg.org.id, reg.user.id)
        |> goto(:plan)
        |> event("select_plan", %{"plan" => %{"key" => "growth"}})

      assert socket.assigns.step == :invite
      assert reread_org(reg.org.id).plan == "growth"
    end

    test "SKIP: skipping plan selection advances without writing" do
      reg = register!()

      socket =
        mount_socket(reg.org.id, reg.user.id)
        |> goto(:plan)
        |> goto(:invite)

      assert socket.assigns.step == :invite
      assert reread_org(reg.org.id).plan == "free"
    end
  end

  # ===========================================================================
  # 4. WizardLive — step 3: teammate invite (T05's Invite flow, reused)
  # ===========================================================================

  describe "WizardLive — teammate-invite step" do
    test "submitting the invite form creates a REAL pending Invitation row (T05's Samen.Identity.Invite)" do
      reg = register!()
      email = unique_email()

      socket =
        mount_socket(reg.org.id, reg.user.id)
        |> goto(:plan)
        |> goto(:invite)
        |> event("invite", %{"invitation" => %{"email" => email, "role" => "member"}})

      refute socket.assigns.invite_error
      assert html(socket) =~ ~s(id="onboarding-invite-sent")

      invitations =
        Invitation
        |> Ash.Query.filter(org_id == ^reg.org.id)
        |> Ash.read!(authorize?: false)

      assert [invitation] = invitations
      assert invitation.status == "pending"
      assert invitation.role == :member
    end

    test "SKIP: clicking finish without inviting anyone still completes the wizard" do
      reg = register!()

      socket =
        mount_socket(reg.org.id, reg.user.id)
        |> goto(:plan)
        |> goto(:invite)
        |> event("finish")

      assert socket.assigns.complete?

      invitations =
        Invitation
        |> Ash.Query.filter(org_id == ^reg.org.id)
        |> Ash.read!(authorize?: false)

      assert invitations == []
    end
  end

  # ===========================================================================
  # 5. Completion — never re-traps (anti-tautology, both halves asserted)
  # ===========================================================================

  describe "WizardLive — completion never re-traps" do
    test "GREEN: a fresh org's wizard renders the step forms, not the already-done card" do
      reg = register!()
      html = html(mount_socket(reg.org.id, reg.user.id))

      assert html =~ ~s(id="onboarding-wizard")
      refute html =~ ~s(id="onboarding-already-done")
    end

    test "finishing completes the wizard; a LATER, INDEPENDENT load renders already-done, never the step forms" do
      reg = register!()

      socket =
        mount_socket(reg.org.id, reg.user.id)
        |> goto(:plan)
        |> goto(:invite)
        |> event("finish")

      html_now = html(socket)
      assert html_now =~ ~s(id="onboarding-already-done")
      refute html_now =~ ~s(id="onboarding-wizard")

      # A brand-new socket (no in-memory wizard step survives) re-derives the
      # SAME answer from the server truth (`Org.onboarded_at`), not from
      # anything carried on the LiveView process.
      later_html = html(mount_socket(reg.org.id, reg.user.id))
      assert later_html =~ ~s(id="onboarding-already-done")
      refute later_html =~ ~s(id="onboarding-wizard")
    end
  end

  # ===========================================================================
  # 6. RED PATH — no org resolved
  # ===========================================================================

  describe "RED PATH — no org resolved" do
    test "a nil org id renders the seed-state card, never a crash, never the wizard" do
      html = html(mount_socket(nil, nil))

      refute html =~ ~s(id="onboarding-wizard")
      refute html =~ ~s(id="onboarding-already-done")
      assert html =~ ~s(id="no-org")
    end
  end

  # ===========================================================================
  # 7. The samen_onboarding_routes macro
  # ===========================================================================

  describe "the samen_onboarding_routes macro" do
    test "compiles and mounts GET /onboarding -> Samen.Web.Onboarding.WizardLive" do
      paths = HostRouter.__routes__() |> Enum.map(& &1.path)
      assert "/onboarding" in paths
    end
  end
end
