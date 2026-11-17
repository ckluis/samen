defmodule Samen.HonestKernelReadsCTest do
  @moduledoc """
  Honest reads, kernel phase C: a failed lookup is never "no endpoint" (drop) or "nothing to do" (acknowledge).
  Each RED case fails the real call and asserts the honest tagged answer plus the by-name report; each is paired with a
  positive control through the same seam so it cannot be a tautology.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.Webhook.{DeliveryWorker, IngestWorker}
  alias SamenCore.TestRepo, as: Repo

  setup do
    Samen.TestSandbox.shared!(Repo)
    :ok
  end

  defmodule DownRepo do
    def get_by(_module, _clauses), do: raise(DBConnection.ConnectionError, "connection not available")
  end

  defmodule EmptyRepo do
    def get_by(_module, _clauses), do: nil
  end

  describe "Webhook.DeliveryWorker — a failed endpoint lookup is not 'the endpoint was deleted'" do
    defp delivery_args(repo),
      do: %{
        "endpoint_id" => Ecto.UUID.generate(),
        "idempotency_key" => Ecto.UUID.generate(),
        "event_type" => "invoice.created",
        "body" => ~s({"event":"invoice.created"}),
        "org_id" => Ecto.UUID.generate(),
        "repo" => inspect(repo)
      }

    test "RED: the lookup fails -> a retried, reported error, never a permanent discard" do
      log =
        capture_log(fn ->
          assert {:error, :endpoint_unavailable} =
                   DeliveryWorker.perform(%Oban.Job{args: delivery_args(DownRepo)})
        end)

      assert log =~ "read=webhook_delivery_load_endpoint"
      assert log =~ "cause=DBConnection.ConnectionError"
    end

    test "POSITIVE CONTROL: a lookup that answers 'no such row' is still the permanent discard" do
      assert {:discard, "webhook endpoint not found: " <> _} =
               DeliveryWorker.perform(%Oban.Job{args: delivery_args(EmptyRepo)})
    end
  end

  describe "Webhook.IngestWorker — an unresolvable repo is not 'nothing to do'" do
    test "RED: an event id with no repo is a retried, reported error, not an acknowledged (stranded) envelope" do
      previous = Application.get_env(:samen_core, Samen.Webhook)
      Application.delete_env(:samen_core, Samen.Webhook)
      on_exit(fn -> if previous, do: Application.put_env(:samen_core, Samen.Webhook, previous) end)

      log =
        capture_log(fn ->
          assert {:error, :repo_unavailable} = IngestWorker.perform(%Oban.Job{args: %{"event_id" => "whk_1"}})
        end)

      assert log =~ "read=webhook_ingest_repo"
    end

    test "POSITIVE CONTROL: with a repo, a row that is gone is still acknowledged; no id is still a no-op" do
      args = %{"event_id" => Ecto.UUID.generate(), "repo" => inspect(Repo)}
      assert :ok = IngestWorker.perform(%Oban.Job{args: args})
      assert :ok = IngestWorker.perform(%Oban.Job{args: %{"repo" => inspect(Repo)}})
    end
  end

  describe "Replay.Player.load — a failed read is not 'no such replay'" do
    defp tenant(org), do: %Samen.Scope{actor: %{org_id: org, plane: :tenant, role: :admin}}

    test "RED: a read that fails is {:error, :unavailable}, reported by name (it answered :not_found)" do
      broken = %Samen.Scope{actor: :not_an_actor}

      log =
        capture_log(fn ->
          assert {:error, :unavailable} = Samen.Replay.Player.load(broken, Ecto.UUID.generate())
        end)

      assert log =~ "read=replay_player_load"
    end

    test "POSITIVE CONTROL: an absent id and a malformed id are still :not_found" do
      assert {:error, :not_found} = Samen.Replay.Player.load(tenant(Ecto.UUID.generate()), Ecto.UUID.generate())
      assert {:error, :not_found} = Samen.Replay.Player.load(tenant(Ecto.UUID.generate()), "not-a-uuid")
    end
  end

  describe "Observability.ParamFilter — a filter that fails is [FILTERED] and on record" do
    test "RED: a filter that raises filters the whole value, and says so by name; no param value reaches the log" do
      log =
        capture_log(fn ->
          wrapped = fn _event, _measurements, metadata, _config -> send(self(), {:printed, metadata}) end

          Application.put_env(:phoenix, :filter_parameters, {:keep, ["id" | "improper"]})

          try do
            Samen.Observability.ParamFilter.handle_event(
              [:phoenix, :endpoint, :stop],
              %{},
              %{params: %{"secret" => "jane.doe@example.com"}},
              {wrapped, nil}
            )
          after
            Application.delete_env(:phoenix, :filter_parameters)
          end
        end)

      assert_received {:printed, %{params: "[FILTERED]"}}
      assert log =~ "read=param_filter"
      refute log =~ "jane.doe@example.com"
    end

    test "POSITIVE CONTROL: a well-formed keep-list filters per key and reports nothing" do
      log =
        capture_log(fn ->
          assert %{"id" => "7", "secret" => "[FILTERED]"} =
                   Samen.Observability.ParamFilter.filter_values(%{"id" => "7", "secret" => "x"}, {:keep, ["id"]})
        end)

      refute log =~ "param_filter"
    end
  end
end
