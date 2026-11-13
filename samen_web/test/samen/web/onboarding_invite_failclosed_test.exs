defmodule Samen.Web.OnboardingInviteFailClosedTest do
  @moduledoc """
  The onboarding wizard's invite step must derive the inviter's `verified?` the way its twins
  (`Settings.InvitationsLive`, `Onboarding.WizardController`) do: an unresolvable principal on an
  ARMED host is UNVERIFIED (the ADR-035 §5 A2 capability gate refuses the invite), never an
  elevated default. Positive control: the same call on a DISARMED host is still accepted.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Mount
  alias Samen.Web.Onboarding.WizardLive
  alias Samen.WebTest.Operator.{Membership, User}
  alias Samen.WebTest.SecurityHost

  setup do
    previous = Application.fetch_env(SecurityHost.otp_app(), :auth_required?)
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    # The send goes through the fail-honest Delivery chokepoint: the test LocalSink captures it, so
    # the ONLY thing that can refuse the invite here is the capability gate under test.
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev_delivery,
        do: Application.put_env(:samen_core, :delivery_env, prev_delivery),
        else: Application.delete_env(:samen_core, :delivery_env)

      case previous do
        {:ok, value} -> Application.put_env(SecurityHost.otp_app(), :auth_required?, value)
        :error -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
      end
    end)

    org_id = Ash.UUID.generate()

    user =
      User
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, handle: "wiz-admin", full_name: %Samen.Type.FullName{first: "Wiz", last: "Admin"}})
      |> Ash.create!(authorize?: false)

    Membership
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: :admin})
    |> Ash.create!(authorize?: false)

    %{org_id: org_id, user_id: user.id}
  end

  defp mount do
    Mount.new(:settings, Samen.WebTest.Operator, Samen.WebTest.Repo,
      labels: %{
        otp_app: SecurityHost.otp_app(),
        authn: {:app_env, SecurityHost.otp_app(), :auth_required?},
        authorized_orgs: {SecurityHost, :authorized_org_ids, []}
      }
    )
  end

  defp invite(ctx, session) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(
        samen_mount: mount(),
        org_id: ctx.org_id,
        user_id: ctx.user_id,
        samen_session: session,
        invite_error: nil,
        invited_raw_token: nil
      )

    {:noreply, socket} =
      WizardLive.handle_event("invite", %{"invitation" => %{"email" => "new-hire@example.com", "role" => "member"}}, socket)

    socket
  end

  test "armed host + unresolvable principal: the invite is refused (fail CLOSED)", ctx do
    SecurityHost.arm!()
    assert Samen.Web.CurrentOrg.tenant_gate_armed?(mount())

    socket = invite(ctx, %{})

    assert socket.assigns.invited_raw_token == nil
    assert socket.assigns.invite_error =~ "refused"
  end

  test "armed host + a session that makes the principal lookup RAISE: still refused", ctx do
    SecurityHost.arm!()

    socket = invite(ctx, :not_a_session_map)

    assert socket.assigns.invited_raw_token == nil
    assert socket.assigns.invite_error =~ "refused"
  end

  test "POSITIVE CONTROL: the same invite on a DISARMED host (dev posture) is accepted", ctx do
    SecurityHost.disarm!()
    refute Samen.Web.CurrentOrg.tenant_gate_armed?(mount())

    socket = invite(ctx, %{})

    assert is_binary(socket.assigns.invited_raw_token)
    assert socket.assigns.invite_error == nil
  end
end
