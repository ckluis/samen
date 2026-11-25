defmodule Samen.Webhook.DeliverStubRepo do
  @moduledoc false
  def all(_query), do: Process.get(:deliver_rows, [])
end

defmodule Samen.Webhook.DeliverEndpointsTest.Res do
  @moduledoc false
  use Ash.Resource, domain: nil, validate_domain_inclusion?: false

  attributes do
    uuid_primary_key(:id, writable?: true, public?: true)
    attribute(:display_name, :string, public?: true)
  end

  actions do
    defaults([:read])
  end
end

defmodule Samen.Webhook.DeliverEndpointsTest do
  @moduledoc """
  `Samen.Webhook.deliver/4` with a NON-EMPTY endpoint list used to raise `FunctionClauseError`
  (the reducer matched `{{endpoint, idx}, _}` against `{endpoint, idx}`), and with `:multi` it
  threw the enqueued multi away while still counting the job. The default (no `:endpoints`) path
  answered `{:ok, 0}` without looking anywhere.
  """
  use ExUnit.Case, async: false

  alias Samen.Webhook
  alias Samen.Webhook.DeliverEndpointsTest.Res, as: FakeResource

  @org "00000000-0000-0000-0000-0000000000aa"
  @record %{id: "r1", org_id: @org}

  defp ep(id, extra \\ %{}), do: Map.merge(%{id: id, status: :active, event_types: []}, extra)

  describe "explicit endpoints" do
    test "a non-empty endpoint list does not crash and enqueues one job per matching endpoint" do
      endpoints = [
        ep("e1"),
        ep("e2", %{event_types: ["invoice.created"]}),
        ep("e3", %{event_types: ["other.event"]}),
        ep("e4", %{status: :paused})
      ]

      assert {:ok, 2, %Ecto.Multi{} = multi} =
               Webhook.deliver("invoice.created", FakeResource, @record,
                 endpoints: endpoints,
                 multi: Ecto.Multi.new()
               )

      # the RETURNED multi carries the jobs (a discarded multi would be a counted-but-lost delivery)
      assert [:webhook_delivery_0, :webhook_delivery_1] == Enum.map(Ecto.Multi.to_list(multi), &elem(&1, 0))
    end

    test "positive control: no matching endpoint is {:ok, 0}" do
      assert {:ok, 0, %Ecto.Multi{}} =
               Webhook.deliver("invoice.created", FakeResource, @record,
                 endpoints: [ep("e4", %{status: :paused})],
                 multi: Ecto.Multi.new()
               )
    end
  end

  describe "default endpoint source" do
    setup do
      prev = {Application.get_env(:samen_core, :webhook_endpoint_module), Application.get_env(:samen_core, :webhook_repo)}

      on_exit(fn ->
        restore(:webhook_endpoint_module, elem(prev, 0))
        restore(:webhook_repo, elem(prev, 1))
      end)
    end

    defp restore(k, nil), do: Application.delete_env(:samen_core, k)
    defp restore(k, v), do: Application.put_env(:samen_core, k, v)

    test "unconfigured is an error, never a silent {:ok, 0}" do
      Application.delete_env(:samen_core, :webhook_endpoint_module)
      Application.delete_env(:samen_core, :webhook_repo)
      Application.delete_env(:samen_core, :verify_repo)

      assert {:error, :not_configured} =
               Webhook.deliver("invoice.created", FakeResource, @record, multi: Ecto.Multi.new())
    end

    test "configured: the org's active, subscribed endpoints are read from the endpoint module" do
      Application.put_env(:samen_core, :webhook_endpoint_module, FakeResource)
      Application.put_env(:samen_core, :webhook_repo, Samen.Webhook.DeliverStubRepo)

      Process.put(:deliver_rows, [
        ep("e1", %{status: "active"}),
        ep("e2", %{status: "paused"}),
        ep("e3", %{event_types: ["x"]})
      ])

      assert {:ok, 1, %Ecto.Multi{}} =
               Webhook.deliver("invoice.created", FakeResource, @record, multi: Ecto.Multi.new())
    end

    test "a failing lookup is an error, not {:ok, 0}" do
      Application.put_env(:samen_core, :webhook_endpoint_module, FakeResource)
      Application.put_env(:samen_core, :webhook_repo, Samen.Webhook.NoSuchRepo)

      assert {:error, :endpoint_lookup_failed} =
               Webhook.deliver("invoice.created", FakeResource, @record, multi: Ecto.Multi.new())
    end
  end
end
