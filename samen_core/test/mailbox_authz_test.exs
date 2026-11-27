defmodule Samen.MailboxAuthzTest do
  @moduledoc """
  authz-6 review, SHOULD-FIX 3 (+ the suspected reveal finding): the Mailbox scope's tenant-actor surface.

  `Connection` and `MailMessage` are written ONLY by `Samen.Mailbox.Sync` (`authorize?: false`): no person, role or
  surface creates, edits or deletes a mailbox row. Their policies used to be `OrgScope` for every action type, so any
  tenant actor (a viewer included) could write them. Now no actor may; the sync path is the `authorize?: false` call.
  Reads stay org-scoped and open to every role.

  `reveal_connection` / `reveal_mail_message` took the actor to check the grant for from a CALLER-SUPPLIED
  `actor_id` argument and were `authorize_if(always())`: a caller could name an operator who holds a grant and ride
  it. The grant is now checked for the actor that RUNS the action.
  """
  use ExUnit.Case, async: false

  alias SamenCore.Support.MailboxFixture.{Connection, MailMessage}
  alias SamenCore.TestRepo

  defmodule OperatorOneGrant do
    @moduledoc false
    # The grant model, reduced to its question: is THIS actor `operator-1`?
    @behaviour Samen.Reveal.Grant

    @impl true
    def granted?(%Samen.Reveal.Context{actor: %{id: id}}), do: id == "operator-1"
    def granted?(%Samen.Reveal.Context{actor: id}) when is_binary(id), do: id == "operator-1"
    def granted?(_), do: false
  end

  setup do
    Samen.TestSandbox.shared!(TestRepo)
    prev = Application.get_env(:samen_core, :reveal_grant)
    Application.put_env(:samen_core, :reveal_grant, OperatorOneGrant)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :reveal_grant, prev),
        else: Application.delete_env(:samen_core, :reveal_grant)
    end)

    :ok
  end

  defp scope(org_id, role, id \\ nil) do
    %Samen.Scope{actor: %{id: id || "u:#{role}:#{org_id}", org_id: org_id, role: role, kind: :tenant, plane: :tenant}}
  end

  @roles [:viewer, :member, :admin, :owner]

  # The sync path's own writes: system context, `authorize?: false`.
  defp connection!(org) do
    Connection
    |> Ash.Changeset.for_create(:create, %{org_id: org, user_id: Ash.UUID.generate(), provider: "fake", address: "rep@ourco.test", status: :connected}, authorize?: false)
    |> Ash.create!()
  end

  defp message!(org, connection) do
    MailMessage
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        direction: :inbound,
        external_id: "m-#{Ash.UUID.generate()}",
        subject_key: "crm.person",
        subject_id: Ash.UUID.generate(),
        connection_id: connection.id,
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:second),
        subject: "Hello",
        body: "Body",
        counterparty_address: "c@example.com"
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  describe "no tenant actor writes a mailbox row" do
    test "a tenant actor of ANY role cannot create, update or destroy a Connection; the system path can" do
      org = Ash.UUID.generate()
      row = connection!(org)

      for role <- @roles do
        s = scope(org, role)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Connection
                 |> Ash.Changeset.for_create(:create, %{org_id: org, user_id: Ash.UUID.generate(), provider: "fake", address: "x@ourco.test", status: :connected}, scope: s)
                 |> Ash.create(),
               "#{role} created a connection"

        assert {:error, %Ash.Error.Forbidden{}} =
                 row |> Ash.Changeset.for_update(:update, %{status: :disconnected}, scope: s) |> Ash.update(),
               "#{role} updated a connection"

        assert {:error, %Ash.Error.Forbidden{}} = row |> Ash.Changeset.for_destroy(:destroy, %{}, scope: s) |> Ash.destroy(),
               "#{role} destroyed a connection"
      end

      assert [%{status: :connected}] = Connection |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.id == row.id))

      # positive controls: reads are org-scoped and open to every role; the sync path's own `authorize?: false` writes work
      for role <- @roles, do: assert([_] = Ash.read!(Connection, scope: scope(org, role)))
      assert [] = Ash.read!(Connection, scope: scope(Ash.UUID.generate(), :owner))
      assert {:ok, %{status: :disconnected}} = row |> Ash.Changeset.for_update(:update, %{status: :disconnected}, authorize?: false) |> Ash.update()
    end

    test "a tenant actor of ANY role cannot create, update or destroy a MailMessage; the system path can" do
      org = Ash.UUID.generate()
      connection = connection!(org)
      row = message!(org, connection)

      for role <- @roles do
        s = scope(org, role)

        assert {:error, %Ash.Error.Forbidden{}} =
                 MailMessage
                 |> Ash.Changeset.for_create(
                   :create,
                   %{org_id: org, direction: :inbound, external_id: "x-#{role}", subject_key: "crm.person", subject_id: Ash.UUID.generate(), occurred_at: DateTime.utc_now() |> DateTime.truncate(:second), subject: "S", body: "B", counterparty_address: "c@example.com"},
                   scope: s
                 )
                 |> Ash.create(),
               "#{role} created a message"

        assert {:error, %Ash.Error.Forbidden{}} =
                 row |> Ash.Changeset.for_update(:update, %{subject_key: "forged"}, scope: s) |> Ash.update(),
               "#{role} updated a message"

        assert {:error, %Ash.Error.Forbidden{}} = row |> Ash.Changeset.for_destroy(:destroy, %{}, scope: s) |> Ash.destroy(),
               "#{role} destroyed a message"
      end

      assert [%{subject_key: "crm.person"}] = MailMessage |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.id == row.id))

      for role <- @roles, do: assert([_] = Ash.read!(MailMessage, scope: scope(org, role)))
      assert {:ok, %{subject_key: "forged"}} = row |> Ash.Changeset.for_update(:update, %{subject_key: "forged"}, authorize?: false) |> Ash.update()
    end
  end

  describe "a reveal action checks the grant of the actor that runs it" do
    defp run_reveal(resource, action, args, actor_scope) do
      resource
      |> Ash.ActionInput.for_action(action, args, scope: actor_scope)
      |> Ash.run_action()
    end

    defp assert_rides_nothing(resource, action) do
      org = Ash.UUID.generate()
      subject = Ash.UUID.generate()

      # RED before the fix: the grant was checked for the NAMED actor, whoever asked
      for role <- @roles do
        result = run_reveal(resource, action, %{actor_id: "operator-1", subject_id: subject}, scope(org, role))
        refute match?({:ok, %{status: "granted"}}, result), "#{role} rode operator-1's grant through #{action}: #{inspect(result)}"
      end

      # and an actor with no grant of its own gets nothing when it names nobody
      assert {:error, _} = run_reveal(resource, action, %{subject_id: subject}, scope(org, :owner))

      # positive control: the actor that HOLDS the grant is granted, asking as itself
      assert {:ok, %{status: "granted", subject_id: ^subject}} =
               run_reveal(resource, action, %{subject_id: subject}, scope(org, :member, "operator-1"))
    end

    test "reveal_connection: naming operator-1 in the arguments rides nothing; operator-1 itself is granted" do
      assert_rides_nothing(Connection, :reveal_connection)
    end

    test "reveal_mail_message: naming operator-1 in the arguments rides nothing; operator-1 itself is granted" do
      assert_rides_nothing(MailMessage, :reveal_mail_message)
    end
  end
end
