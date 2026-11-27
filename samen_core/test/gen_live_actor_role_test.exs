defmodule Samen.Gen.LiveActorRoleTest do
  @moduledoc """
  A generated `--live` screen acts with the signed-in person's RESOLVED membership role
  (ADR-045 §4.4 residual): through `Samen.Web.TenantActor.access/4` — never a hard-coded role, never the
  old `membership_role/3` that fell back to `:member` for "no membership". The generated app is compiled
  and exercised by `priv/gen_post_probe.exs`; this pins the template text of all three screens.
  """
  use ExUnit.Case, async: true

  @templates [:resource_index_live, :resource_show_live, :resource_form_live]

  defp source(name), do: apply(Samen.Gen.PostTemplates, name, [])

  for name <- @templates do
    test "#{name}: the role comes from the shared resolver and a refusal carries no role" do
      src = source(unquote(name))

      assert src =~ "Samen.Web.TenantActor.access(@samen_authn_mount"
      assert src =~ "{:refused, _state} -> nil"
      assert src =~ ~s(id="actor-denied")
      assert src =~ ~s(id="actor-unavailable")
      assert src =~ "samen_principal_ref: Samen.Web.Settings.Reads.principal_ref("
    end

    test "#{name}: no hard-coded or defaulted role survives" do
      src = source(unquote(name))

      refute src =~ "membership_role"
      refute src =~ "role: :member"
      refute src =~ "role: :admin"
      # the dev convenience is named ONCE, as the disarmed argument of the resolver
      assert length(Regex.scan(~r/:admin\)/, src)) == 1
    end
  end

  # authz-6 review 2, X1: an OPEN generated screen must not keep the role it resolved at its last navigation. Its forms
  # are built at load with that moment's role, and a `save_new` / `save` submits them, so the role is resolved again
  # before EVERY event (the shared `TenantActor.attach_once/4` lifecycle seam), the forms are rebuilt when it changed,
  # and a refusal halts the event and loads nothing.
  for name <- @templates do
    test "#{name}: the role is resolved again before every event through the shared lifecycle guard" do
      src = source(unquote(name))

      assert src =~
               "Samen.Web.TenantActor.attach_once(socket, :samen_gen_actor_guard, :handle_event, &__MODULE__.recheck_event/3)"

      assert src =~ "def recheck_event(_event, _params, %{assigns: %{access: :ok, org_id: org_id}} = socket)"
      assert src =~ "access(org_id, socket.assigns[:samen_principal_ref])"
      # the same role passes the event on; a refusal HALTS it
      assert src =~ "if role == socket.assigns[:acting_role], do: {:cont, socket}, else: {:cont, load("
      assert src =~ "{:halt, load("
      # the role a page acts with is remembered at load, and a refusal forgets it
      assert src =~ "acting_role: role"
      assert src =~ "acting_role: nil"
    end

    test "#{name}: the guard is attached before the first load and runs before the screen's own handle_event" do
      src = source(unquote(name))

      {attach, _} = :binary.match(src, ":samen_gen_actor_guard")
      {first_load, _} = :binary.match(src, "{:ok, load(")
      assert attach < first_load
    end
  end

  test "the emitted smoke test drives an ARMED open screen: a demoted admin's save and a suspended member's are refused" do
    src = apply(Samen.Gen.PostTemplates, :resource_live_smoke_test, [])

    assert src =~ "an open FORM: an admin demoted to viewer while it is open is refused, with no navigation"
    assert src =~ "an open FORM: a suspended member's save is halted and the screen is the refused state"
    assert src =~ "an open INDEX: a demoted admin's save_new is refused"
    # the positive control rides with them, and every event goes through the screen's lifecycle hooks first
    assert src =~ "an admin who is still an admin saves and navigates"
    assert src =~ "Phoenix.LiveView.Lifecycle.handle_event(name, params, socket)"
  end

  test "the generated form screen attaches the shared actor guard, so an open form is not saved with the old role" do
    src = source(:resource_form_live)

    assert src =~
             "Samen.Web.TenantActor.attach_once(socket, :samen_gen_actor_guard, :handle_event, &__MODULE__.recheck_event/3)"
  end
end
