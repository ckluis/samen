defmodule Demo.PrimitivesNotificationRecipientScopeTest do
  @moduledoc """
  A notification and a notification preference belong to their RECIPIENT. Before, both resources were
  `OrgScope` only: a viewer could create, update or destroy any recipient's notification, any member
  could read every notification of the organisation, and any member could write another user's
  `NotificationPreference` (switching their alerts off).

  Now: a recipient reads and marks only their own (plus the rows the engine addresses to the
  organisation, for a member); no actor creates a notification (the engine does, with
  `authorize?: false`); only the recipient or an admin destroys one; nobody edits another
  recipient's notification or preference.
  """
  use Demo.DataCase, async: false

  require Ash.Query

  alias Demo.PrimitivesScope.{Notification, NotificationPreference}
  alias Demo.Identity.{Org, User}

  defp mk_org do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: "rs-#{:rand.uniform(999_999)}"}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_user(org_id, role) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "rs-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "R", last: "S"},
        emails: ["rs#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    {user, Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})}
  end

  defp mk_notification(org_id, recipient_id) do
    {:ok, n} =
      Notification
      |> Ash.Changeset.for_create(:create, %{
        recipient_id: recipient_id,
        channel: :in_app,
        event_type: "invoice.created",
        rendered_body: "Dear someone",
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    n
  end

  defp mk_pref(org_id, recipient_id) do
    {:ok, p} =
      NotificationPreference
      |> Ash.Changeset.for_create(:create, %{
        recipient_id: recipient_id,
        event_type: "invoice.created",
        in_app_enabled: true,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    p
  end

  defp ids(actor, resource) do
    {:ok, rows} = Ash.read(Ash.Query.select(resource, [:id]), actor: actor)
    MapSet.new(rows, & &1.id)
  end

  defp mark_read(n, actor) do
    n
    |> Ash.Changeset.for_update(:update, %{read_at: DateTime.utc_now(), status: :read}, actor: actor)
    |> Ash.update(actor: actor)
  end

  setup do
    org = mk_org()
    {alice, alice_scope} = mk_user(org.id, :member)
    {bob, bob_scope} = mk_user(org.id, :member)
    {_v, viewer_scope} = mk_user(org.id, :viewer)
    {_a, admin_scope} = mk_user(org.id, :admin)
    %{org: org, alice: alice, bob: bob, a: alice_scope.actor, b: bob_scope.actor, viewer: viewer_scope.actor, admin: admin_scope.actor}
  end

  describe "Notification reads" do
    test "RED: a member reads only their own notifications; POSITIVE: they do read their own",
         %{org: org, alice: alice, bob: bob, a: a} do
      mine = mk_notification(org.id, alice.id)
      theirs = mk_notification(org.id, bob.id)

      seen = ids(a, Notification)
      assert mine.id in seen
      refute theirs.id in seen
    end

    test "an organisation-addressed notification is visible to a member, not to a viewer",
         %{org: org, a: a, viewer: viewer} do
      org_row = mk_notification(org.id, org.id)
      assert org_row.id in ids(a, Notification)
      refute org_row.id in ids(viewer, Notification)
    end

    test "an admin does not read another user's notification", %{org: org, bob: bob, admin: admin} do
      theirs = mk_notification(org.id, bob.id)
      refute theirs.id in ids(admin, Notification)
    end

    test "the operator plane reads the org's notifications (masked by the resolver)", %{org: org, bob: bob} do
      theirs = mk_notification(org.id, bob.id)
      operator = %{id: "operator:ops", org_id: org.id, role: :member, kind: :operator, plane: :operator}
      assert theirs.id in ids(operator, Notification)
    end
  end

  describe "Notification writes" do
    test "RED: no actor creates a notification (viewer, member, admin)", %{org: org, bob: bob, viewer: viewer, a: a, admin: admin} do
      for actor <- [viewer, a, admin] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Notification
                 |> Ash.Changeset.for_create(
                   :create,
                   %{recipient_id: bob.id, channel: :in_app, event_type: "x.y", org_id: org.id},
                   actor: actor
                 )
                 |> Ash.create(actor: actor)
      end
    end

    test "RED: nobody updates another recipient's notification; POSITIVE: the recipient marks their own",
         %{org: org, alice: alice, bob: bob, a: a, viewer: viewer, admin: admin} do
      theirs = mk_notification(org.id, bob.id)

      for actor <- [a, viewer, admin] do
        assert {:error, %Ash.Error.Forbidden{}} = mark_read(theirs, actor)
      end

      assert Ash.get!(Notification, theirs.id, authorize?: false).read_at == nil

      mine = mk_notification(org.id, alice.id)
      assert {:ok, marked} = mark_read(mine, a)
      assert marked.status == :read
    end

    test "an update cannot rewrite the recipient, the body or the channel", %{org: org, alice: alice, bob: bob, a: a} do
      mine = mk_notification(org.id, alice.id)

      for input <- [%{recipient_id: bob.id}, %{rendered_body: "forged"}, %{channel: :email}] do
        assert {:error, %Ash.Error.Invalid{}} =
                 mine |> Ash.Changeset.for_update(:update, input, actor: a) |> Ash.update(actor: a)
      end
    end

    test "RED: destroy is the recipient's or an admin's; a viewer or another member cannot",
         %{org: org, alice: alice, bob: bob, a: a, viewer: viewer, admin: admin} do
      theirs = mk_notification(org.id, bob.id)

      for actor <- [a, viewer] do
        assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(theirs, actor: actor)
      end

      assert Ash.get!(Notification, theirs.id, authorize?: false)

      assert :ok = Ash.destroy(mk_notification(org.id, alice.id), actor: a)
      assert :ok = Ash.destroy(theirs, actor: admin)
    end
  end

  describe "NotificationPreference" do
    test "RED: a member cannot create a preference for another user", %{org: org, bob: bob, a: a} do
      assert {:error, %Ash.Error.Forbidden{}} =
               NotificationPreference
               |> Ash.Changeset.for_create(
                 :create,
                 %{recipient_id: bob.id, event_type: "invoice.created", in_app_enabled: false, org_id: org.id},
                 actor: a
               )
               |> Ash.create(actor: a)

      assert Ash.read!(Ash.Query.filter(NotificationPreference, recipient_id == ^bob.id), authorize?: false) == []
    end

    test "RED: nobody updates or destroys another user's preference, an admin included",
         %{org: org, bob: bob, a: a, admin: admin} do
      pref = mk_pref(org.id, bob.id)

      for actor <- [a, admin] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 pref |> Ash.Changeset.for_update(:update, %{in_app_enabled: false}, actor: actor) |> Ash.update(actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(pref, actor: actor)
      end

      assert Ash.get!(NotificationPreference, pref.id, authorize?: false).in_app_enabled == true
    end

    test "RED: an update cannot repoint the user's own row at another recipient", %{org: org, alice: alice, bob: bob, a: a} do
      pref = mk_pref(org.id, alice.id)

      assert {:error, %Ash.Error.Invalid{}} =
               pref |> Ash.Changeset.for_update(:update, %{recipient_id: bob.id}, actor: a) |> Ash.update(actor: a)
    end

    test "POSITIVE: a user creates, reads, updates and destroys their own", %{org: org, alice: alice, a: a} do
      assert {:ok, pref} =
               NotificationPreference
               |> Ash.Changeset.for_create(
                 :create,
                 %{recipient_id: alice.id, event_type: "invoice.created", in_app_enabled: false, org_id: org.id},
                 actor: a
               )
               |> Ash.create(actor: a)

      assert pref.id in ids(a, NotificationPreference)

      assert {:ok, on} =
               pref |> Ash.Changeset.for_update(:update, %{in_app_enabled: true}, actor: a) |> Ash.update(actor: a)

      assert on.in_app_enabled
      assert :ok = Ash.destroy(on, actor: a)
    end
  end
end
