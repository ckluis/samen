defmodule Samen.Webhook.DeliverEndpointsTest.Row do
  @moduledoc """
  A REAL Ecto schema over a TEMP table, so the lookup's query is executed by Postgres (a stub repo that
  returned canned rows ignored the query: removing the org filter or the archive filter went unnoticed).
  Shaped like a generated `Webhook` endpoint: `org_id`, `status`, `event_types`, `archived_at`.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "deliver_ep_rows" do
    field(:org_id, :binary_id)
    field(:status, :string)
    field(:event_types, {:array, :string}, default: [])
    field(:archived_at, :utc_datetime)
  end
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
    # EVERY env key these tests touch is captured and restored (an earlier version deleted
    # `:verify_repo` and never put it back, so later modules that fall back to it saw `nil`).
    @env_keys [:webhook_endpoint_module, :webhook_repo, :verify_repo]

    setup do
      prev = Map.new(@env_keys, &{&1, Application.fetch_env(:samen_core, &1)})

      on_exit(fn ->
        for {key, saved} <- prev do
          case saved do
            {:ok, value} -> Application.put_env(:samen_core, key, value)
            :error -> Application.delete_env(:samen_core, key)
          end
        end
      end)

      :ok
    end

    test "unconfigured is an error, never a silent {:ok, 0}" do
      Application.delete_env(:samen_core, :webhook_endpoint_module)
      Application.delete_env(:samen_core, :webhook_repo)
      Application.delete_env(:samen_core, :verify_repo)

      assert {:error, :not_configured} =
               Webhook.deliver("invoice.created", FakeResource, @record, multi: Ecto.Multi.new())
    end

    test "a failing lookup is an error, not {:ok, 0}" do
      Application.put_env(:samen_core, :webhook_endpoint_module, FakeResource)
      Application.put_env(:samen_core, :webhook_repo, Samen.Webhook.NoSuchRepo)

      assert {:error, :endpoint_lookup_failed} =
               Webhook.deliver("invoice.created", FakeResource, @record, multi: Ecto.Multi.new())
    end
  end

  describe "default endpoint source, read from the real repo" do
    alias Samen.Webhook.DeliverEndpointsTest.Row

    @repo SamenCore.TestRepo
    @other_org "00000000-0000-0000-0000-0000000000bb"

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)

      @repo.query!("""
      CREATE TEMP TABLE deliver_ep_rows (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        org_id uuid, status text, event_types text[] DEFAULT '{}', archived_at timestamptz
      ) ON COMMIT DROP
      """)

      prev = Map.new([:webhook_endpoint_module, :webhook_repo, :verify_repo], &{&1, Application.fetch_env(:samen_core, &1)})

      on_exit(fn ->
        for {key, saved} <- prev do
          case saved do
            {:ok, value} -> Application.put_env(:samen_core, key, value)
            :error -> Application.delete_env(:samen_core, key)
          end
        end
      end)

      Application.put_env(:samen_core, :webhook_endpoint_module, Row)
      Application.put_env(:samen_core, :webhook_repo, @repo)
      :ok
    end

    defp insert!(attrs), do: @repo.insert!(struct!(Row, Map.merge(%{org_id: @org, status: "active", event_types: []}, attrs)))

    defp deliver, do: Webhook.deliver("invoice.created", FakeResource, @record, multi: Ecto.Multi.new())

    test "the org's active, subscribed, unarchived endpoint receives; paused and unsubscribed ones do not" do
      insert!(%{})
      insert!(%{status: "paused"})
      insert!(%{event_types: ["x"]})

      assert {:ok, 1, %Ecto.Multi{}} = deliver()
    end

    test "RED: another org's active endpoint is never read (the org filter)" do
      insert!(%{org_id: @other_org})

      # positive control: the same row in THIS org is delivered to
      assert {:ok, 0, %Ecto.Multi{}} = deliver()
      insert!(%{})
      assert {:ok, 1, %Ecto.Multi{}} = deliver()
    end

    test "RED: an ARCHIVED endpoint is never delivered to, even though its status is still active (the archive filter)" do
      insert!(%{archived_at: ~U[2026-01-01 00:00:00Z]})

      assert {:ok, 0, %Ecto.Multi{}} = deliver()

      # positive control: the same row, restored, is delivered to
      @repo.query!("UPDATE deliver_ep_rows SET archived_at = NULL")
      assert {:ok, 1, %Ecto.Multi{}} = deliver()
    end
  end
end
