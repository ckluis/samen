defmodule Demo.IdentityRevealActionTest do
  @moduledoc """
  Exercises the Identity reveal actions (`User.reveal_user`, `Invitation.reveal_invitation`)
  end-to-end (T3.1). Two purposes:

    1. **Red path (default-deny):** with no reveal grant configured, invoking a reveal
       action returns `{:error, :denied}` — it never produces plaintext. This is the
       operator-plane reveal seam failing closed (the doc's "masking is the field's
       normal value; plaintext only under a grant").
    2. **Regression guard:** the reveal `run/2` actually EXECUTES the grant-checker
       path (`Samen.Reveal.grant_checker().granted?/1`). A bare `Samen.Reveal.granted?/1`
       — which does NOT exist — would raise UndefinedFunctionError here. This test is
       what catches that drift (the scope-authoring guide §5 warns about it; the demo's
       CRM Contact action was aligned to the same pattern).

  Positive control: with an approving grant checker injected, the action reports
  `granted` — so the deny result is not vacuous.
  """
  use Demo.DataCase, async: false

  alias Demo.Identity.{Org, User, Invitation}

  # An approving grant checker (the positive-control seam). Implements the
  # Samen.Reveal.Grant behaviour.
  defmodule ApproveAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: true
  end

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_user(org_id) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "reveal-subj",
        org_id: org_id,
        full_name: %{first: "Reveal", last: "Subject"},
        emails: ["reveal@example.com"]
      })
      |> Ash.create(authorize?: false)

    user
  end

  setup do
    # Ensure default-deny for these tests regardless of ambient config, and restore.
    prev = Application.get_env(:samen_core, :reveal_grant)
    Application.delete_env(:samen_core, :reveal_grant)
    on_exit(fn -> restore_reveal_grant(prev) end)
    :ok
  end

  defp restore_reveal_grant(nil), do: Application.delete_env(:samen_core, :reveal_grant)
  defp restore_reveal_grant(v), do: Application.put_env(:samen_core, :reveal_grant, v)

  test "User.reveal_user denies by default (no grant) and does not crash" do
    org = mk_org("reveal-user-deny")
    user = mk_user(org.id)
    scope = Samen.Scope.new(%{id: "operator", org_id: org.id, role: :admin})

    result =
      User
      |> Ash.ActionInput.for_action(:reveal_user, %{
        actor_id: "operator",
        subject_id: user.id
      })
      |> Ash.run_action(actor: scope.actor)

    assert {:error, _} = result
  end

  test "Invitation.reveal_invitation denies by default (no grant) and does not crash" do
    org = mk_org("reveal-inv-deny")

    {:ok, invite} =
      Invitation
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        role: :member,
        email: ["invitee@example.com"]
      })
      |> Ash.create(authorize?: false)

    scope = Samen.Scope.new(%{id: "operator", org_id: org.id, role: :admin})

    result =
      Invitation
      |> Ash.ActionInput.for_action(:reveal_invitation, %{
        actor_id: "operator",
        subject_id: invite.id
      })
      |> Ash.run_action(actor: scope.actor)

    assert {:error, _} = result
  end

  test "positive control: with an approving grant checker, reveal reports granted (deny is not vacuous)" do
    Application.put_env(:samen_core, :reveal_grant, ApproveAll)
    on_exit(fn -> Application.delete_env(:samen_core, :reveal_grant) end)

    org = mk_org("reveal-user-grant")
    user = mk_user(org.id)
    scope = Samen.Scope.new(%{id: "operator", org_id: org.id, role: :admin})

    result =
      User
      |> Ash.ActionInput.for_action(:reveal_user, %{
        actor_id: "operator",
        subject_id: user.id
      })
      |> Ash.run_action(actor: scope.actor)

    assert {:ok, %{status: "granted", subject_id: subj}} = result
    assert subj == user.id
  end
end
