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

    test "handle_event/4 returns :ok for ANY input — the guard, not the caller, absorbs a raise" do
      # :telemetry only ever passes maps, but the callback's contract is total: a shape that
      # makes the builder raise (here a nil metadata — Map.get/2 raises BadMapError) must be
      # absorbed, because a raise would detach the handler.
      for event <- LiveTelemetry.events() do
        assert :ok = LiveTelemetry.handle_event(event, %{duration: 1}, nil, %{})
      end

      assert :ok = LiveTelemetry.handle_event([:phoenix, :endpoint, :stop], nil, nil, nil)
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

  describe "request_id — only a server-generated id reaches the event (ADR-052 §2.1.2 item 1)" do
    # `Plug.RequestId.generate/0`, byte for byte (samen_core has no Plug dependency; the
    # samen_web e2e test drives the real plug).
    defp plug_generated_id do
      Base.url_encode64(<<
        System.system_time(:nanosecond)::64,
        :erlang.phash2({node(), self()}, 16_777_216)::24,
        :erlang.unique_integer()::32
      >>)
    end

    defp with_request_id(id, fun) do
      Logger.metadata(request_id: id)

      try do
        fun.()
      after
        Logger.metadata(request_id: nil)
      end
    end

    defp request_event(id, req_headers) do
      with_request_id(id, fn ->
        :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1}, %{
          conn: %{method: "GET", status: 200, req_headers: req_headers, assigns: %{}}
        })

        one_event!()
      end)
    end

    test "POSITIVE CONTROL: a server-generated id is kept verbatim (it IS the response header)" do
      id = plug_generated_id()
      assert request_event(id, [{"accept", "text/html"}]).request_id == id

      with_request_id(id, fn ->
        lv(:handle_event, :stop, %{socket: socket(LiveEventsFixture), event: "save"})
        assert one_event!().request_id == id
      end)
    end

    test "a client-chosen x-request-id never reaches the event — a bounded substitute does" do
      client = "alice@example.com-ticket-4711"
      ev = request_event(client, [{"x-request-id", client}])

      refute ev.request_id == client
      refute inspect(ev) =~ "alice"
      assert ev.request_id =~ ~r/\Asub_[A-Za-z0-9_-]{16}\z/

      # Still correlatable across the events that carry the same client id on this node …
      assert request_event(client, [{"x-request-id", client}]).request_id == ev.request_id
      # … and distinct from another client id.
      refute request_event(client <> "x", [{"x-request-id", client <> "x"}]).request_id ==
               ev.request_id
    end

    test "a client id in the server's exact shape is still the client's when the client sent it" do
      # A replayed / forged id that even carries this process's hash: the conn proves the
      # client sent it, under whatever header name.
      forged = plug_generated_id()
      assert request_event(forged, [{"x-correlation-id", forged}]).request_id =~ ~r/\Asub_/
    end

    test "a 20-char base64 id the client chose (no conn in hand) is substituted" do
      for id <- ["AliceAndersSmith1234", "alice-anders-1234567"] do
        with_request_id(id, fn ->
          lv(:handle_event, :stop, %{socket: socket(LiveEventsFixture), event: "save"})
          ev = one_event!()
          assert ev.request_id =~ ~r/\Asub_/
          refute inspect(ev) =~ "lice"
        end)
      end
    end

    test "an id Plug generated in ANOTHER process is substituted (provenance, not just shape)" do
      other = Task.async(fn -> plug_generated_id() end) |> Task.await()

      with_request_id(other, fn ->
        lv(:mount, :stop, %{socket: socket(LiveEventsFixture)})
        assert one_event!().request_id =~ ~r/\Asub_/
      end)
    end
  end

  describe "hot path: each value is validated ONCE (ADR-052 §2.1.2 item 4)" do
    # Runs `fun` in a fresh process traced by an isolated trace session (no global tracer is
    # touched) and counts its calls to the id-shape heuristic.
    defp count_shape_checks(fun) do
      session = :trace.session_create(:samen_live_telemetry_validation_count, self(), [])

      try do
        :trace.function(session, {Samen.PiiValueShape, :pii_shaped_id?, 1}, true, [:local])
        test_pid = self()

        {pid, ref} =
          spawn_monitor(fn ->
            receive do: (:go -> fun.())
            send(test_pid, :ran)
          end)

        :trace.process(session, pid, true, [:call])
        send(pid, :go)
        assert_receive :ran, 1000
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
        drain_calls(0)
      after
        :trace.session_destroy(session)
      end
    end

    defp drain_calls(n) do
      receive do
        {:trace, _pid, :call, {Samen.PiiValueShape, :pii_shaped_id?, _}} -> drain_calls(n + 1)
      after
        100 -> n
      end
    end

    test "one handle_event callback runs the id-shape check once per id/token field" do
      org = Ecto.UUID.generate()

      calls =
        count_shape_checks(fn ->
          # Generated in the emitting process, as Plug.RequestId does.
          id =
            Base.url_encode64(<<1::64, :erlang.phash2({node(), self()}, 16_777_216)::24, 2::32>>)

          Logger.metadata(request_id: id)

          lv(:handle_event, :stop, %{
            socket: socket(LiveEventsFixture, %{org_id: org}),
            event: "save"
          })
        end)

      ev = one_event!()
      # view + tenant_id + request_id are the opaque ids present (no principal, no span).
      assert Map.take(ev, [:view, :tenant_id, :request_id]) |> map_size() == 3
      # One check per field, plus one per enum atom of the open `:action` / `:event` labels.
      assert calls == 3 + 2, "expected one shape check per value, got #{calls}"
    end

    test "best_effort drops ONLY the failing value; strict :build still refuses the event" do
      fields = %{action: :live_view, callback: :mount, tenant_id: "Alice Anders", duration_ms: 1}

      assert :ok = WideEvent.emit(fields, :best_effort)
      ev = one_event!()
      assert ev.callback == :mount
      refute Map.has_key?(ev, :tenant_id)

      assert {:error, _} = WideEvent.emit(fields, :build)
      refute_receive {:wide_event, _}, 100

      assert {:error, _} = WideEvent.emit(%{action: :live_view, bogus: 1}, :best_effort)
      assert {:error, _} = WideEvent.emit(%{action: :"alice@example.com"}, :best_effort)
      refute_receive {:wide_event, _}, 100
    end
  end
end
