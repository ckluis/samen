defmodule Samen.Observability.LiveTelemetryTest do
  @moduledoc """
  ADR-052 §2.1 (P1 item 1) — the LiveView + request wide events, and red path **R2**.

  Driven with the EXACT telemetry event names and metadata keys Phoenix / LiveView emit
  (`socket`, `event`, `params`, `component`, `conn`); the samen_web end-to-end test
  (`samen_web/test/samen/web/live_wide_events_e2e_test.exs`) proves the same handler against a
  real mounted LiveView.

    * exactly ONE `Samen.WideEvent` per callback / request, carrying only bounded values;
    * R2 — a client-sent event string NEVER becomes an atom: an unknown event is `:other` and
      the atom table is untouched; a statically handled literal maps to its own atom (the
      positive control);
    * params, session, URI and assigns other than the org id / principal never reach the event;
    * the actor is the HMAC pseudonym (`for_subject/2`), never the raw principal;
    * a malformed metadata map does NOT detach the handler (`:telemetry` detaches a raising
      handler — the positive control proves that detection is real).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.Observability
  alias Samen.Observability.{LiveEvents, LiveTelemetry}
  alias Samen.WideEvent
  alias SamenCore.Support.{LiveEventsDeclared, LiveEventsFixture}

  @collector {__MODULE__, :collector}

  setup do
    LiveTelemetry.detach()
    :ok = LiveTelemetry.attach(kms: Samen.Kms.InMemory)

    test_pid = self()

    :ok =
      :telemetry.attach(
        @collector,
        WideEvent.telemetry_event(),
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:wide_event, Map.merge(metadata, measurements)})
        end,
        nil
      )

    on_exit(fn ->
      LiveTelemetry.detach()
      :telemetry.detach(@collector)
    end)

    :ok
  end

  defp socket(view, assigns \\ %{}), do: %{view: view, assigns: assigns}

  defp lv(callback, kind, metadata, duration \\ 2_000_000) do
    :telemetry.execute([:phoenix, :live_view, callback, kind], %{duration: duration}, metadata)
  end

  defp one_event! do
    assert_receive {:wide_event, ev}, 1000
    refute_receive {:wide_event, _}, 100
    ev
  end

  describe "one bounded wide event per LiveView callback" do
    test "mount / handle_params / handle_event each emit exactly one event" do
      org = Ecto.UUID.generate()

      lv(:mount, :stop, %{
        socket: socket(LiveEventsFixture, %{org_id: org}),
        params: %{},
        session: %{}
      })

      ev = one_event!()
      assert ev.action == :live_view
      assert ev.callback == :mount
      assert ev.outcome == :ok
      assert ev.view == "SamenCore.Support.LiveEventsFixture"
      assert ev.tenant_id == org
      assert is_number(ev.duration_ms)
      refute Map.has_key?(ev, :event)

      lv(:handle_params, :stop, %{
        socket: socket(LiveEventsFixture),
        params: %{},
        uri: "http://x/y"
      })

      assert one_event!().callback == :handle_params

      lv(:handle_event, :stop, %{socket: socket(LiveEventsFixture), event: "save", params: %{}})
      ev = one_event!()
      assert ev.callback == :handle_event
      assert ev.event == :save
    end

    test "params, session, uri and other assigns never reach the event" do
      secret = "Alice Anders alice@example.com"

      lv(:handle_event, :stop, %{
        socket: socket(LiveEventsFixture, %{org_id: Ecto.UUID.generate(), note: secret}),
        event: "save",
        params: %{"email" => secret, "id" => "1"},
        session: %{"user" => secret},
        uri: "http://x/contacts?email=#{secret}"
      })

      ev = one_event!()
      refute inspect(ev) =~ "alice"
      refute inspect(ev) =~ "Anders"
      # Every field is a declared schema field.
      assert ev |> Map.keys() |> Enum.all?(&MapSet.member?(WideEvent.Schema.field_names(), &1))
    end

    test "an exception emits ONE event with outcome :exception and never the reason" do
      lv(:handle_event, :exception, %{
        socket: socket(LiveEventsFixture),
        event: "save",
        kind: :error,
        reason: %RuntimeError{message: "bad email alice@example.com"},
        stacktrace: []
      })

      ev = one_event!()
      assert ev.outcome == :exception
      refute inspect(ev) =~ "alice"
    end

    test "a non-UUID org id is dropped (a bounded id or nothing), the event still emits" do
      lv(:mount, :stop, %{socket: socket(LiveEventsFixture, %{org_id: "alice@example.com"})})
      ev = one_event!()
      refute Map.has_key?(ev, :tenant_id)
      assert ev.callback == :mount
    end

    test "a live_component handle_event resolves against the COMPONENT's own literals" do
      :telemetry.execute(
        [:phoenix, :live_component, :handle_event, :stop],
        %{duration: 1_000},
        %{
          socket: socket(Elixir.Unrelated.View),
          component: LiveEventsFixture,
          event: "sort",
          params: %{}
        }
      )

      ev = one_event!()
      assert ev.action == :live_component
      assert ev.callback == :component_event
      assert ev.event == :sort
      assert ev.view == "SamenCore.Support.LiveEventsFixture"
    end
  end

  describe "R2 — a client-sent event string never becomes an atom" do
    test "an unknown event is :other and NO atom is created for it" do
      unknown = "zz_r2_client_event_#{System.unique_integer([:positive])}"

      lv(:handle_event, :stop, %{socket: socket(LiveEventsFixture), event: unknown, params: %{}})

      assert one_event!().event == :other

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end

    test "POSITIVE CONTROL: the view's own static literals resolve to their atoms" do
      assert LiveEvents.resolve(LiveEventsFixture, "save") == :save
      # `"sort" = event` heads count as literals too.
      assert LiveEvents.resolve(LiveEventsFixture, "sort") == :sort
    end

    test "prefix patterns, catch-alls, PII-shaped literals and non-strings are :other" do
      assert LiveEvents.resolve(LiveEventsFixture, "row:42") == :other
      assert LiveEvents.resolve(LiveEventsFixture, "alice@example.com") == :other
      assert LiveEvents.resolve(LiveEventsFixture, :save) == :other
      assert LiveEvents.resolve(LiveEventsFixture, nil) == :other
      assert LiveEvents.resolve(nil, "save") == :other
      assert LiveEvents.events(LiveEventsFixture) == %{"save" => :save, "sort" => :sort}
    end

    test "an event another module handles is still :other for this view" do
      assert LiveEvents.resolve(LiveEventsDeclared, "save") == :other
    end

    test "an explicit __samen_live_events__/0 declaration is honoured (label-shaped only)" do
      assert LiveEvents.events(LiveEventsDeclared) == %{"approve" => :approve}
    end
  end

  describe "the actor is the HMAC pseudonym, never the principal" do
    setup do
      prev = Application.get_env(:samen_core, :kms_adapter)
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.InMemory)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:samen_core, :kms_adapter, prev),
          else: Application.delete_env(:samen_core, :kms_adapter)
      end)

      :ok
    end

    test "actor_id == for_subject(principal); the raw principal is absent" do
      principal = Ecto.UUID.generate()
      Samen.Kms.InMemory.generate_subject_key(principal)
      {:ok, expected} = WideEvent.for_subject(principal, Samen.Kms.InMemory)

      # Run in a fresh process: the pseudonym is memoized per process.
      Task.async(fn ->
        lv(:mount, :stop, %{
          socket: socket(LiveEventsFixture, %{samen_tenant_principal: principal})
        })
      end)
      |> Task.await()

      ev = one_event!()
      assert ev.actor_id == expected
      refute inspect(ev) =~ principal
    end

    test "a principal with no live key emits the event WITHOUT an actor_id" do
      Task.async(fn ->
        lv(:mount, :stop, %{
          socket:
            socket(LiveEventsFixture, %{
              samen_tenant_principal: "no-key-#{System.unique_integer()}"
            })
        })
      end)
      |> Task.await()

      ev = one_event!()
      refute Map.has_key?(ev, :actor_id)
    end
  end

  describe "the endpoint request event" do
    test "one event with method + status, never the path or query string" do
      org = Ecto.UUID.generate()

      :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 5_000}, %{
        conn: %{
          method: "POST",
          status: 201,
          request_path: "/contacts/alice@example.com",
          query_string: "email=alice@example.com",
          params: %{"email" => "alice@example.com"},
          assigns: %{org_id: org}
        },
        options: []
      })

      ev = one_event!()
      assert ev.action == :http_request
      assert ev.callback == :request
      assert ev.method == :post
      assert ev.status == 201
      assert ev.tenant_id == org
      refute inspect(ev) =~ "alice"
    end

    test "an unknown method is :other" do
      :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1}, %{
        conn: %{method: "BREW", status: 418}
      })

      assert one_event!().method == :other
    end
  end

  describe "the handler can never crash its caller (telemetry would detach it)" do
    defp attached? do
      Enum.any?(
        :telemetry.list_handlers([:phoenix, :live_view, :handle_event, :stop]),
        &(&1.id == LiveTelemetry.handler_id())
      )
    end

    test "malformed metadata maps do not detach the handler" do
      assert attached?()

      lv(:handle_event, :stop, %{socket: "not a socket", event: 123})
      lv(:handle_event, :stop, %{})
      lv(:mount, :exception, %{socket: %{view: "str", assigns: :nope}}, "not a duration")

      :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: :x}, %{conn: :not_a_conn})

      assert attached?(), "a malformed metadata map detached the LiveView wide-event handler"

      # And it still works afterwards.
      lv(:handle_event, :stop, %{socket: socket(LiveEventsFixture), event: "save"})
      assert_receive {:wide_event, %{event: :save}}, 1000
    end

    test "POSITIVE CONTROL: a handler that raises IS detached by :telemetry" do
      id = {__MODULE__, :raiser}
      :ok = :telemetry.attach(id, [:samen_test, :raise], fn _, _, _, _ -> raise "boom" end, nil)
      capture_log(fn -> :telemetry.execute([:samen_test, :raise], %{}, %{}) end)
      refute Enum.any?(:telemetry.list_handlers([:samen_test, :raise]), &(&1.id == id))
    end
  end

  describe "wired by Samen.Observability.child_specs/2, ON by default" do
    test "default includes the request-events child; request_events: false opts out" do
      ids = fn specs -> for %{id: id} <- specs, do: id end

      assert {Observability, :request_events, :lt_app} in ids.(Observability.child_specs(:lt_app))

      refute {Observability, :request_events, :lt_app} in ids.(
               Observability.child_specs(:lt_app, request_events: false)
             )
    end

    test "starting the child attaches the handler (restart-safe)" do
      LiveTelemetry.detach()

      %{start: {m, f, a}} =
        Enum.find(Observability.child_specs(:lt_app), &match?(%{id: {_, :request_events, _}}, &1))

      assert :ignore = apply(m, f, a)
      assert :ignore = apply(m, f, a)

      assert Enum.any?(
               :telemetry.list_handlers([:phoenix, :endpoint, :stop]),
               &(&1.id == LiveTelemetry.handler_id())
             )
    end
  end
end
