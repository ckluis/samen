defmodule Samen.Replay.CaptureTest do
  @moduledoc """
  ADR-052 §2.2 (P2) — capture end to end in the kernel: a recording "LiveView" process (a real
  process, the shape `Samen.Web.Replay.Recorder` drives) writes sanitized frames into the ETS
  buffer, LiveView's own `[:phoenix, :live_view, :handle_event, :start]` telemetry records its
  events, the monitor sees the process exit and persists the session in Postgres — and the RAW
  rows are scanned for the seeded plaintext.

  Red paths: R5 (persisted JSONB carries no plaintext of a vault-routed attribute; the vault
  fields are Refs), R7 (a typed event value is shape only), R11 (capture is off unless the
  org's flag is on), R12 (retention prunes past TTL — the replay spec is in the sweep), plus
  the caps (truncate, never crash), the interaction rule, the bounded exit reason, the
  persist-time validator, and the never-crash properties of the handler and buffer.
  """
  use ExUnit.Case, async: false

  alias Samen.FeatureFlags.Cache
  alias Samen.Replay
  alias Samen.Replay.{Buffer, Capture, Monitor, Sanitizer}
  alias SamenCore.Support.Clinical.Patient
  alias SamenCore.Support.ReplayView

  @repo SamenCore.TestRepo
  @first "Grace"
  @last "Hopper"
  @mrn "MRN-SECRET-42"
  @title "Rear Admiral"
  @typed_email "typed.secret@example.com"
  @typed_name "Ada Lovelace"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    Cache.invalidate_all()
    prev_specs = Application.get_env(:samen_core, :retention_specs)

    on_exit(fn ->
      Cache.invalidate_all()
      Replay.erase_runtime_config()
      Capture.detach()

      case prev_specs do
        nil -> Application.delete_env(:samen_core, :retention_specs)
        v -> Application.put_env(:samen_core, :retention_specs, v)
      end
    end)

    %{org: Ash.UUID.generate(), other_org: Ash.UUID.generate()}
  end

  # The flag engine's loader seam: `samen.replay` is ON for exactly `on_orgs` (an `org_id`
  # allow rule over a 0% rollout — the per-org opt-in shape).
  defp flag_opts(on_orgs) do
    config = %{
      enabled: true,
      rollout_pct: 0,
      stage: :ga,
      variants: %{},
      target_rules: [
        %{"attribute" => "org_id", "op" => "in", "values" => on_orgs, "then" => "allow"}
      ]
    }

    [loader: fn "samen.replay" -> {:ok, config} end]
  end

  defp start_capture!(on_orgs, extra \\ []) do
    start_supervised!({Replay.Supervisor, Keyword.merge([flag_opts: flag_opts(on_orgs)], extra)})
    :ok
  end

  defp tenant_patient!(org) do
    p =
      Patient
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        full_name: %{first: @first, last: @last},
        mrn: @mrn,
        dob: ~D[1906-12-09],
        job_title: @title,
        consent_on_file: true
      })
      |> Ash.create!()

    [read] =
      Patient
      |> Ash.Query.filter_input(%{id: p.id})
      |> Ash.Query.select(Patient |> Ash.Resource.Info.attribute_names() |> Enum.to_list())
      |> Ash.read!()
      |> Samen.Api.PiiResolution.resolve(Patient, %{plane: :tenant, org_id: org}, repo: @repo)

    read
  end

  # Run `fun` inside a fresh "LiveView" process that opens a capture session, wait for it to
  # exit and for the monitor to finish persisting.
  defp run_lv(org, fun, exit_how \\ :normal) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        opened = Capture.open(%{org_id: org, view: ReplayView, principal: Ash.UUID.generate()})
        # Make sure the monitor has processed the watch before this process can exit.
        _ = :sys.get_state(Monitor)
        send(parent, {:opened, opened})
        fun.()

        case exit_how do
          :normal -> :ok
          :crash -> raise "boom #{@typed_name}"
        end
      end)

    assert_receive {:opened, opened}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    :ok = Monitor.flush()
    opened
  end

  defp lv_event(event, params) do
    :telemetry.execute(
      [:phoenix, :live_view, :handle_event, :start],
      %{system_time: System.system_time()},
      %{socket: %{view: ReplayView, assigns: %{}}, event: event, params: params}
    )
  end

  defp raw_rows do
    %{rows: frames} =
      @repo.query!("SELECT rpf_kind, rpf_payload::text FROM replay_frame ORDER BY rpf_seq")

    %{rows: sessions} = @repo.query!("SELECT row_to_json(s)::text FROM replay_session s")
    {frames, sessions}
  end

  defp all_text({frames, sessions}),
    do:
      Enum.map_join(frames, "\n", fn [k, p] -> "#{k} #{p}" end) <>
        Enum.join(List.flatten(sessions), "\n")

  describe "R5 — a captured tenant session over a real vault-routed resource stores no plaintext" do
    test "raw JSONB carries Refs for the vault fields and none of the seeded plaintext", ctx do
      start_capture!([ctx.org])
      patient = tenant_patient!(ctx.org)

      # Positive control: the assigns the LiveView holds DO carry tenant-plane plaintext.
      assert patient.mrn == @mrn
      assert inspect(patient.full_name) =~ @first

      assert {:ok, _id} =
               run_lv(ctx.org, fn ->
                 Capture.record(:mount, %{
                   view: "SamenCore.Support.ReplayView",
                   assigns:
                     Sanitizer.assigns(
                       %{patient: patient, rows: [patient], page_title: "Patients"},
                       keep: [:page_title]
                     )
                 })

                 lv_event("validate", %{
                   "patient" => %{"email" => @typed_email, "full_name" => @typed_name}
                 })

                 Capture.record(:render, %{
                   assigns: Sanitizer.assigns(%{patient: patient}, only: [:patient])
                 })
               end)

      {frames, _sessions} = rows = raw_rows()
      text = all_text(rows)

      # Positive control: the session persisted, with the frames we expect.
      assert Enum.map(frames, &hd/1) == ["mount", "event", "render", "exit"]
      assert text =~ ~s("$ref")
      assert text =~ ~s("attribute": "mrn")
      assert text =~ ~s("attribute": "full_name")
      assert text =~ patient.id
      assert text =~ ~s("Patients")

      for secret <- [
            @first,
            @last,
            @mrn,
            "1906-12-09",
            @title,
            @typed_email,
            "typed.secret",
            "Lovelace"
          ] do
        refute text =~ secret, "plaintext #{inspect(secret)} reached the replay tables"
      end

      refute text =~ "vt_", "a vault token reached the replay tables"
    end
  end

  describe "R7 — events record shape, not content" do
    test "an event's typed values are shape only; a declared keep-list key keeps its label",
         ctx do
      start_capture!([ctx.org])

      run_lv(ctx.org, fn ->
        lv_event("sort", %{"field" => "inserted_at", "q" => "Grace"})
        lv_event("validate", %{"q" => "Grace", "email" => @typed_email})
        lv_event("zz_unhandled_#{System.unique_integer([:positive])}", %{"x" => "Grace"})
        # ADR-052 §2.2.1 gate fix: client-chosen, label-shaped strings — a sort value outside
        # the declared set, and a key no server code knows — never reach the row.
        lv_event("sort", %{"field" => "Sortvaluesecret", "Paramkeysecret" => 1})
      end)

      {frames, _} = raw_rows()
      events = for [k, p] <- frames, k == "event", do: Jason.decode!(p)
      assert [sort, validate, other, client] = events
      assert client["event"] == "sort"
      [field | _] = client["params"]["$shape"]["fields"] |> Enum.sort_by(& &1["key"], :desc)
      assert field["key"] == "field"
      refute Map.has_key?(field, "value")
      assert sort["event"] == "sort"
      assert validate["event"] == "validate"
      assert other["event"] == "other"

      sort_fields = Map.new(sort["params"]["$shape"]["fields"], &{&1["key"], &1})
      assert sort_fields["field"]["value"] == "inserted_at"
      refute Map.has_key?(sort_fields["q"], "value")

      validate_fields = Map.new(validate["params"]["$shape"]["fields"], &{&1["key"], &1})

      assert validate_fields["email"] == %{
               "key" => "email",
               "type" => "string",
               "length" => 24,
               "class" => "email"
             }

      text = all_text(raw_rows())
      refute text =~ "Grace"
      refute text =~ "typed.secret"
      refute text =~ "Sortvaluesecret"
      refute text =~ "Paramkeysecret"
    end
  end

  describe "R11 — capture is off unless the org's flag is on" do
    test "decide/1 is :on only for an opted-in org; an unknown flag is :off", ctx do
      cfg = Replay.config!(flag_opts: flag_opts([ctx.org]))
      assert Replay.decide(ctx.org, cfg) == :on
      assert Replay.decide(ctx.other_org, cfg) == :off
      assert Replay.decide(nil, cfg) == :off

      Cache.invalidate_all()
      unknown = Replay.config!(flag_opts: [loader: fn _ -> {:ok, nil} end])
      assert Replay.decide(ctx.org, unknown) == :off

      Cache.invalidate_all()

      killed =
        Replay.config!(
          flag_opts: [loader: fn _ -> {:ok, %{enabled: false, rollout_pct: 100}} end]
        )

      assert Replay.decide(ctx.org, killed) == :off
    end

    test "a sample rate of 0 captures nothing even for an opted-in org", ctx do
      cfg = Replay.config!(flag_opts: flag_opts([ctx.org]), sample_rate: 0.0)
      assert Replay.decide(ctx.org, cfg) == :off
    end

    test "no capture plane → not running, open refuses, no handler attached", ctx do
      refute Replay.running?()
      assert Capture.open(%{org_id: ctx.org, view: ReplayView}) == :error

      refute Enum.any?(
               :telemetry.list_handlers([:phoenix, :live_view, :handle_event, :start]),
               &(&1.id == Capture.handler_id())
             )
    end

    test "Observability.child_specs/2: replay off is a no-op child list; on adds ONE supervisor" do
      base = Samen.Observability.child_specs(:samen_core)
      assert Samen.Observability.child_specs(:samen_core, replay: false) == base
      refute Enum.any?(base, &match?({Replay.Supervisor, _}, &1))

      on = Samen.Observability.child_specs(:samen_core, replay: true)
      assert on -- base == [{Replay.Supervisor, []}]
    end

    test "fail-honest: a retention window above the max refuses to build" do
      assert_raise ArgumentError, ~r/retention_days/, fn ->
        Samen.Observability.child_specs(:samen_core,
          replay: [retention_days: Replay.max_retention_days() + 1]
        )
      end

      assert_raise ArgumentError, fn -> Replay.config!(retention_days: 0) end
      assert_raise ArgumentError, fn -> Replay.config!(sample_rate: 2) end
      assert_raise ArgumentError, fn -> Replay.config!(max_frames: 0) end
    end
  end

  describe "R12 — retention prunes replays past TTL" do
    test "the installed replay spec deletes sessions + frames older than the window, keeps fresh ones",
         ctx do
      start_capture!([ctx.org], retention_days: 14)
      run_lv(ctx.org, fn -> lv_event("save", %{}) end)
      run_lv(ctx.org, fn -> lv_event("save", %{}) end)

      %{rows: [[old_id], [fresh_id]]} =
        @repo.query!("SELECT rps_id::text FROM replay_session ORDER BY rps_started_at")

      # Age ONE session (and its frames) past the 14-day window.
      @repo.query!(
        "UPDATE replay_session SET rps_inserted_at = now() - interval '15 days' WHERE rps_id::text = $1",
        [old_id]
      )

      @repo.query!(
        "UPDATE replay_frame SET rpf_inserted_at = now() - interval '15 days' WHERE rpf_session_id::text = $1",
        [old_id]
      )

      specs = Application.get_env(:samen_core, :retention_specs, [])

      assert Enum.any?(
               specs,
               &(Samen.Retention.Spec.normalize(&1).resource == Samen.Replay.Session)
             )

      # Positive control: both sessions exist before the sweep.
      assert %{rows: [[2]]} = @repo.query!("SELECT count(*) FROM replay_session")

      Samen.Retention.sweep(specs)

      assert %{rows: [[^fresh_id]]} = @repo.query!("SELECT rps_id::text FROM replay_session")

      assert %{rows: [[0]]} =
               @repo.query!("SELECT count(*) FROM replay_frame WHERE rpf_session_id::text = $1", [
                 old_id
               ])

      assert %{rows: [[n]]} =
               @repo.query!("SELECT count(*) FROM replay_frame WHERE rpf_session_id::text = $1", [
                 fresh_id
               ])

      assert n > 0
    end

    test "the spec defaults to 14 days and refuses a host entry above the max" do
      assert [%{ttl_seconds: ttl} | _] = Replay.retention_specs()
      assert ttl == 14 * 86_400

      Application.put_env(:samen_core, :retention_specs, [
        %{resource: Samen.Replay.Session, ttl_seconds: 365 * 86_400, action: :delete}
      ])

      assert_raise ArgumentError, ~r/bounded/, fn -> Replay.install_retention_specs() end
    end
  end

  describe "persist rules + caps" do
    test "a session with no user interaction is discarded", ctx do
      start_capture!([ctx.org])
      run_lv(ctx.org, fn -> Capture.record(:render, %{assigns: %{n: 1}}) end)
      assert %{rows: [[0]]} = @repo.query!("SELECT count(*) FROM replay_session")
    end

    test "max_frames truncates with ONE marker; the LiveView never sees an error", ctx do
      start_capture!([ctx.org], max_frames: 3)

      run_lv(ctx.org, fn ->
        for i <- 1..10,
            do: assert(Capture.record(:render, %{assigns: %{n: i}}) in [:ok, :truncated])

        lv_event("save", %{})
      end)

      {frames, _} = raw_rows()
      kinds = Enum.map(frames, &hd/1)
      assert kinds == ["render", "render", "render", "truncated", "exit"]

      assert %{rows: [[true, 1]]} =
               @repo.query!("SELECT rps_truncated, rps_interaction_count FROM replay_session")
    end

    test "max_bytes truncates too", ctx do
      start_capture!([ctx.org], max_bytes: 300)

      run_lv(ctx.org, fn ->
        lv_event("save", %{})
        for _ <- 1..20, do: Capture.record(:render, %{assigns: %{rows: Enum.to_list(1..40)}})
      end)

      {frames, _} = raw_rows()
      assert Enum.count(frames, &(hd(&1) == "truncated")) == 1
      assert Enum.any?(frames, fn [k, p] -> k == "truncated" and p =~ "max_bytes" end)
    end

    @tag :capture_log
    test "a crashing LiveView persists with the bounded :crash reason, never the exit term",
         ctx do
      start_capture!([ctx.org])
      run_lv(ctx.org, fn -> lv_event("save", %{}) end, :crash)

      {frames, sessions} = raw_rows()
      assert [["exit", exit_payload]] = Enum.filter(frames, &(hd(&1) == "exit"))
      assert Jason.decode!(exit_payload) == %{"reason" => "crash"}
      refute all_text({frames, sessions}) =~ "Lovelace"
      assert %{rows: [["crash"]]} = @repo.query!("SELECT rps_exit_reason FROM replay_session")
    end

    test "a frame that fails the schema is refused and counted, never stored", ctx do
      start_capture!([ctx.org])

      run_lv(ctx.org, fn ->
        lv_event("save", %{})
        # A sanitizer bug modelled: a raw string in a render payload.
        Capture.record(:render, %{assigns: %{leak: @typed_name}})
      end)

      refute all_text(raw_rows()) =~ "Lovelace"
      assert %{rows: [[1]]} = @repo.query!("SELECT rps_rejected_count FROM replay_session")
    end

    test "the session actor is stored only as the HMAC pseudonym", ctx do
      start_capture!([ctx.org])
      principal = Ash.UUID.generate()
      {:ok, _} = Samen.Kms.adapter().generate_subject_key(principal)
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Capture.open(%{org_id: ctx.org, view: ReplayView, principal: principal})
          _ = :sys.get_state(Monitor)
          lv_event("save", %{})
          send(parent, :done)
        end)

      assert_receive :done
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      Monitor.flush()

      {:ok, expected} = Samen.WideEvent.for_subject(principal)
      assert %{rows: [[^expected]]} = @repo.query!("SELECT rps_actor_ref FROM replay_session")
      refute all_text(raw_rows()) =~ principal
    end
  end

  describe "never crashes or slows the LiveView" do
    test "the event handler survives garbage metadata and stays attached", ctx do
      start_capture!([ctx.org])
      # This process records, so garbage metadata reaches the capture path (and raises in it).
      assert {:ok, _} = Capture.open(%{org_id: ctx.org, view: ReplayView})

      for meta <- [
            %{socket: nil, event: 1, params: :x},
            %{socket: %{view: 42}, event: "e", params: [1]},
            %{component: nil, event: "e", params: %{}}
          ] do
        :telemetry.execute([:phoenix, :live_view, :handle_event, :start], %{}, meta)
        :telemetry.execute([:phoenix, :live_component, :handle_event, :start], %{}, meta)
      end

      assert Enum.any?(
               :telemetry.list_handlers([:phoenix, :live_view, :handle_event, :start]),
               &(&1.id == Capture.handler_id())
             )

      assert Enum.any?(
               :telemetry.list_handlers([:phoenix, :live_component, :handle_event, :start]),
               &(&1.id == Capture.handler_id())
             )
    end

    test "buffer + capture calls with no table return :error, never raise" do
      refute Buffer.table_exists?()
      assert Buffer.record(self(), :render, %{}) == :error
      assert Buffer.session(self()) == :error
      assert Buffer.take("nope") == :error
      assert Capture.record(:render, %{}) == :error
    end

    test "an unrecorded LiveView's event costs one lookup and records nothing", ctx do
      start_capture!([ctx.org])
      lv_event("save", %{"email" => @typed_email})
      assert Buffer.session(self()) == :error
    end
  end

  describe "keep-list declarations" do
    test "declarations accumulate into one __samen_replay__/0" do
      assert Replay.keep(SamenCore.Support.ReplayMixinView) == %{
               assigns: [:tab],
               params: %{"paginate" => ["dir", "page"]},
               url_params: []
             }

      assert Replay.keep(ReplayView).assigns == [:page_title]
      assert Replay.keep(URI) == %{assigns: [], params: %{}, url_params: []}
    end

    test "event labels: own literal, else a DECLARED key, else other — never the client string" do
      assert Replay.event_label(ReplayView, "save") == "save"
      assert Replay.event_label(SamenCore.Support.ReplayMixinView, "paginate") == "paginate"
      assert Replay.event_label(ReplayView, "ada@example.com") == "other"
      assert Replay.event_label(ReplayView, 42) == "other"
    end
  end
end
