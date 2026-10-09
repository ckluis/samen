defmodule Samen.Replay.PlayerTest do
  @moduledoc """
  ADR-052 §2.3 (P3) — the replay PLAYER kernel: decode stored frames safely, resolve every
  reference at view time on the VIEWER's plane (`Samen.Replay.Resolver`), and audit an open.

  Frames are recorded for real (`Samen.Replay.Capture` + the monitor persisting to Postgres)
  over two real vault-routed resources: `Patient` (mrn/dob/full_name vaulted, no reveal
  action) and the automation `Subject` (email vaulted, a declared `reveal :reveal_subject`, reads
  `Samen.Policy.OrgScope`d).

  Red paths: R8 (operator without a grant → masked, with a grant → clear, after shred →
  `:shredded`; resolution on the viewer's plane, never cached), R10 (one token-only
  `replay.viewed` row per audit call), plus decode safety (`:code_changed`, no atom created)
  and the code-drift marker.
  """
  use ExUnit.Case, async: false

  require Record

  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias Samen.FeatureFlags.Cache
  alias Samen.Replay
  alias Samen.Replay.{Capture, Decoder, Monitor, Placeholder, Player, Resolver, Sanitizer}
  alias SamenCore.Support.Clinical.Patient
  alias SamenCore.Support.ReplayView
  alias SamenCore.Support.AutomationFixture.Subject

  @repo SamenCore.TestRepo
  @first "Grace"
  @last "Hopper"
  @mrn "MRN-SECRET-42"
  @email "reveal.secret@example.com"

  defmodule AllowGrant do
    @moduledoc false
    def granted?(_ctx), do: true
  end

  defmodule DenyGrant do
    @moduledoc false
    def granted?(_ctx), do: false
  end

  # A grant checker whose answer a test flips mid-playback (deny-on-read).
  defmodule SwitchGrant do
    @moduledoc false
    def granted?(_ctx), do: :persistent_term.get({__MODULE__, :on}, false) === true
    def set(on), do: :persistent_term.put({__MODULE__, :on}, on)
  end

  # A KMS whose attestation is unreachable.
  defmodule AttestDownKms do
    @moduledoc false
    def attest(_subject), do: raise("kms unreachable")
  end

  defmodule FakeView do
    @moduledoc false
    def render(_assigns), do: "fake"
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    Cache.invalidate_all()

    on_exit(fn ->
      Cache.invalidate_all()
      Replay.erase_runtime_config()
      Capture.detach()
      SwitchGrant.set(false)
    end)

    org = Ash.UUID.generate()
    patient = patient!(org)
    person = reveal_person!(org)
    start_capture!([org])
    replay_id = record!(org, patient, person)

    %{org: org, patient: patient, person: person, replay_id: replay_id}
  end

  # -- fixtures -------------------------------------------------------------------

  defp start_capture!(orgs) do
    config = %{
      enabled: true,
      rollout_pct: 0,
      stage: :ga,
      variants: %{},
      target_rules: [%{"attribute" => "org_id", "op" => "in", "values" => orgs, "then" => "allow"}]
    }

    start_supervised!(
      {Replay.Supervisor, [flag_opts: [loader: fn "samen.replay" -> {:ok, config} end]]}
    )

    :ok
  end

  defp patient!(org) do
    p =
      Patient
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        full_name: %{first: @first, last: @last},
        mrn: @mrn,
        dob: ~D[1906-12-09],
        consent_on_file: true
      })
      |> Ash.create!()

    tenant_read(Patient, p.id, org)
  end

  defp reveal_person!(org) do
    p =
      Subject
      |> Ash.Changeset.for_create(:create, %{org_id: org, title: "replay subject", email: @email})
      |> Ash.create!(authorize?: false)

    tenant_read(Subject, p.id, org)
  end

  # What a tenant LiveView holds: the record resolved CLEAR on the tenant plane.
  defp tenant_read(resource, id, org) do
    [read] =
      resource
      |> Ash.Query.filter_input(%{id: id})
      |> Ash.Query.select(resource |> Ash.Resource.Info.attribute_names() |> Enum.to_list())
      |> Ash.read!(authorize?: false)
      |> Samen.Api.PiiResolution.resolve(resource, %{plane: :tenant, org_id: org}, repo: @repo)

    read
  end

  # A recorded session: mount (both records) → an event → a render (the patient again).
  defp record!(org, patient, person) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, id} = Capture.open(%{org_id: org, view: ReplayView, principal: Ash.UUID.generate()})
        _ = :sys.get_state(Monitor)
        send(parent, {:opened, id})

        Capture.record(:mount, %{
          view: "SamenCore.Support.ReplayView",
          assigns:
            Sanitizer.assigns(%{patient: patient, person: person, page_title: "Patients"},
              keep: [:page_title]
            )
        })

        :telemetry.execute(
          [:phoenix, :live_view, :handle_event, :start],
          %{system_time: System.system_time()},
          %{socket: %{view: ReplayView, assigns: %{}}, event: "save", params: %{"q" => @first}}
        )

        Capture.record(:render, %{assigns: Sanitizer.assigns(%{count: 3}, only: [:count])})
      end)

    assert_receive {:opened, _}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    :ok = Monitor.flush()

    %{rows: [[id]]} =
      @repo.query!("SELECT rps_id::text FROM replay_session WHERE rps_org_id = $1", [
        Ecto.UUID.dump!(org)
      ])

    id
  end

  defp tenant_scope(org), do: %Samen.Scope{actor: %{org_id: org, plane: :tenant, role: :admin}}

  defp operator_scope(org) do
    %Samen.Scope{
      actor: %{
        id: Ash.UUID.generate(),
        org_id: org,
        role: :member,
        plane: :operator,
        impersonation: %{session_id: Ash.UUID.generate()}
      }
    }
  end

  defp mount_assigns(ctx, scope) do
    {:ok, %{frames: frames}} = Player.load(scope, ctx.replay_id)
    Player.assigns_at(frames, 0)
  end

  defp outcomes(refs), do: Map.new(refs, &{{&1.resource, &1.attribute}, &1.outcome})

  # -- R8: the viewer's plane --------------------------------------------------------

  describe "R8 — every reference resolves on the VIEWER's plane, now" do
    test "GREEN tenant admin: the CURRENT values, clear", ctx do
      scope = tenant_scope(ctx.org)
      %{value: v, refs: refs} = Resolver.resolve(mount_assigns(ctx, scope), scope)

      assert %Patient{} = v.patient
      assert v.patient.mrn == @mrn
      assert inspect(v.patient.full_name) =~ @first
      assert inspect(v.person.email) =~ @email
      assert outcomes(refs)[{"Patient", "mrn"}] == :clear
      assert outcomes(refs)[{"Subject", "email"}] == :clear
      # Kept / dropped context: the declared keep-list string, the unknown scope dropped.
      assert v.page_title == "Patients"
    end

    test "RED operator without a grant: •••• placeholders — never plaintext, never a vt_ token",
         ctx do
      scope = operator_scope(ctx.org)
      %{value: v, refs: refs} = Resolver.resolve(mount_assigns(ctx, scope), scope, grant: DenyGrant)

      assert v.patient.mrn == Placeholder.new(:masked)
      assert v.person.email == Placeholder.new(:masked)
      assert to_string(v.patient.mrn) == "••••"
      assert outcomes(refs)[{"Patient", "mrn"}] == :masked

      text = inspect(v, limit: :infinity, printable_limit: :infinity)

      for secret <- [@first, @last, @mrn, @email, "1906-12-09"],
          do: refute(text =~ secret, "plaintext #{secret} resolved for an ungranted operator")

      refute text =~ "vt_"
    end

    test "GREEN operator WITH a live grant: plaintext through the vault chokepoint (reveal action required)",
         ctx do
      scope = operator_scope(ctx.org)
      %{value: v, refs: refs} = Resolver.resolve(mount_assigns(ctx, scope), scope, grant: AllowGrant)

      assert inspect(v.person.email) =~ @email
      assert outcomes(refs)[{"Subject", "email"}] == :clear
      # Patient declares no reveal action: a grant can never unmask it (the PiiResolution rule).
      assert outcomes(refs)[{"Patient", "mrn"}] == :masked
    end

    test "the SAME recording resolves per viewer — the recording actor's (tenant) plane is never used",
         ctx do
      tenant = tenant_scope(ctx.org)
      operator = operator_scope(ctx.org)
      assigns = mount_assigns(ctx, tenant)

      assert Resolver.resolve(assigns, tenant).value.patient.mrn == @mrn

      assert Resolver.resolve(assigns, operator, grant: DenyGrant).value.patient.mrn ==
               Placeholder.new(:masked)
    end

    test "deny-on-read: a grant that lapses between two batches takes effect on the next one",
         ctx do
      scope = operator_scope(ctx.org)
      assigns = mount_assigns(ctx, scope)

      SwitchGrant.set(true)
      assert inspect(Resolver.resolve(assigns, scope, grant: SwitchGrant).value.person.email) =~ @email

      SwitchGrant.set(false)
      second = Resolver.resolve(assigns, scope, grant: SwitchGrant)
      assert second.value.person.email == Placeholder.new(:masked)
      refute inspect(second) =~ @email
    end

    test "after a crypto-shred of the subject every reference to it is :shredded", ctx do
      scope = tenant_scope(ctx.org)
      assigns = mount_assigns(ctx, scope)
      # Positive control: clear before.
      assert Resolver.resolve(assigns, scope).value.patient.mrn == @mrn

      {:ok, _} = Samen.Vault.shred(ctx.patient.id)
      %{value: v, refs: refs} = Resolver.resolve(assigns, scope)

      assert v.patient.mrn == Placeholder.new(:shredded)
      assert to_string(v.patient.mrn) == "[erased]"
      assert outcomes(refs)[{"Patient", "mrn"}] == :shredded
      refute inspect(v, limit: :infinity) =~ @mrn
      # The other subject is untouched.
      assert outcomes(refs)[{"Subject", "email"}] == :clear
    end

    test "a viewer scope that names no org resolves nothing (fail closed, even on the tenant plane)",
         ctx do
      assigns = mount_assigns(ctx, tenant_scope(ctx.org))
      %{value: v, refs: refs} = Resolver.resolve(assigns, %Samen.Scope{actor: %{plane: :tenant}})

      assert v.patient.mrn == Placeholder.new(:gone)
      assert Enum.all?(refs, &(&1.outcome == :gone))
      refute inspect(v, limit: :infinity) =~ @mrn
    end

    test "a KMS that cannot attest never claims :shredded — the value stays ••••", ctx do
      scope = operator_scope(ctx.org)
      assigns = mount_assigns(ctx, scope)
      Application.put_env(:samen_core, :kms_adapter, AttestDownKms)

      %{value: v, refs: refs} = Resolver.resolve(assigns, scope, grant: DenyGrant)
      assert v.patient.mrn == Placeholder.new(:masked)
      assert outcomes(refs)[{"Patient", "mrn"}] == :masked
    after
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    end

    test "a deleted record is :gone", ctx do
      scope = tenant_scope(ctx.org)
      assigns = mount_assigns(ctx, scope)
      Ash.destroy!(ctx.patient)

      %{value: v, refs: refs} = Resolver.resolve(assigns, scope)
      assert v.patient.mrn == Placeholder.new(:gone)
      assert outcomes(refs)[{"Patient", "mrn"}] == :gone
    end

    test "references are read under the viewer's org scope: another org's viewer gets :gone, never a value",
         ctx do
      assigns = mount_assigns(ctx, tenant_scope(ctx.org))
      %{value: v, refs: refs} = Resolver.resolve(assigns, tenant_scope(Ash.UUID.generate()))

      # Subject is OrgScope'd: a viewer of another org cannot read it — indistinguishable from deleted.
      assert v.person.email == Placeholder.new(:gone)
      assert outcomes(refs)[{"Subject", "email"}] == :gone
      refute inspect(v, limit: :infinity) =~ @email
      # Patient declares NO org policy: the resolver's own org check still refuses the row.
      assert v.patient.mrn == Placeholder.new(:gone)
      refute inspect(v, limit: :infinity) =~ @mrn
    end

    test "a reference the current code no longer routes through the vault is :code_changed" do
      scope = tenant_scope(Ash.UUID.generate())

      tree = %{
        a: %Samen.Replay.Ref{resource: "SamenCore.Support.Clinical.Patient", pk: Ash.UUID.generate(), attribute: "consent_on_file"},
        b: %Samen.Replay.Ref{resource: "No.Such.ModuleXyzzy", pk: Ash.UUID.generate(), attribute: "mrn"}
      }

      %{value: v, refs: refs} = Resolver.resolve(tree, scope)
      assert v.a == Placeholder.new(:code_changed)
      assert v.b == Placeholder.new(:code_changed)
      assert Enum.all?(refs, &(&1.outcome == :code_changed))
    end
  end

  describe "R8 — an operator-plane resolution is traced like any reveal" do
    setup do
      :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
      on_exit(fn -> :otel_simple_processor.set_exporter(:otel_exporter_pid, :undefined) end)
      :ok
    end

    defp reveal_spans(acc \\ []) do
      receive do
        {:span, s} -> reveal_spans([s | acc])
      after
        200 -> acc |> Enum.reverse() |> Enum.filter(&(span(&1, :name) == Samen.Reveal.span_name()))
      end
    end

    test "one allow-listed reveal span per referenced record on the operator plane; none on the tenant plane",
         ctx do
      assigns = mount_assigns(ctx, tenant_scope(ctx.org))
      _ = reveal_spans()

      %{value: v} = Resolver.resolve(assigns, tenant_scope(ctx.org))
      assert v.patient.mrn == @mrn
      assert reveal_spans() == []

      %{value: v} = Resolver.resolve(assigns, operator_scope(ctx.org), grant: AllowGrant)
      assert inspect(v.person.email) =~ @email
      spans = reveal_spans()
      assert length(spans) == 2

      for s <- spans do
        attrs = s |> span(:attributes) |> :otel_attributes.map()
        assert Map.keys(attrs) -- [:subject_id, :grant_id, :reason] == []
        assert attrs.subject_id in [ctx.patient.id, ctx.person.id]
        refute inspect(attrs) =~ @email
        refute inspect(attrs) =~ @mrn
      end
    end
  end

  # -- decode safety --------------------------------------------------------------

  describe "decode safety" do
    test "unknown modules, atoms and markers become :code_changed — no atom is created" do
      name = "zz_replay_unknown_#{System.unique_integer([:positive])}"

      decoded =
        Decoder.tree(%{
          "a" => %{"$atom" => %{"value" => name}},
          "b" => %{"$record" => %{"resource" => "Zz.Nope#{System.unique_integer([:positive])}", "pk" => nil, "fields" => %{}}},
          "c" => %{"$whatever" => %{"x" => 1}},
          "d" => "a bare stored string",
          name => 1
        })

      assert decoded.a == Placeholder.new(:code_changed)
      assert decoded.c == Placeholder.new(:code_changed)
      assert decoded.d == Placeholder.new(:redacted)
      # The unknown KEY is dropped, not created.
      assert map_size(decoded) == 4
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

      %{value: v} = Resolver.resolve(decoded, tenant_scope(Ash.UUID.generate()))
      assert v.b == Placeholder.new(:code_changed)
    end

    test "a dropped struct renders as its module's DEFAULT struct (code, never data) — never a scope, a resource or a non-struct" do
      dropped = fn name -> %Samen.Replay.Dropped{kind: :struct, struct: name} end

      tree = %{
        uri: dropped.("URI"),
        scope: dropped.("Samen.Scope"),
        resource: dropped.("SamenCore.Support.Clinical.Patient"),
        module: dropped.("Enum"),
        actor: %Samen.Replay.Dropped{kind: :actor}
      }

      %{value: v} = Resolver.resolve(tree, tenant_scope(Ash.UUID.generate()))
      assert v.uri == %URI{}
      assert v.scope == nil
      assert v.resource == nil
      assert v.module == nil
      assert v.actor == nil
    end

    test "a stored $record rebuilds only what the recorder writes; a {:safe, _} tuple never becomes markup" do
      # ADR-052 P3 gate: a row written past RowGuard (raw SQL) named `Range` (a template loops
      # over it without end) or a LiveView `Rendered`/`Comprehension` (renders raw) and the
      # resolver minted it. Only an Ash resource or a sanitizer walk-list struct is rebuilt.
      prev = Application.get_env(:samen_core, Samen.Replay)
      Application.put_env(:samen_core, Samen.Replay, Keyword.put(prev || [], :walk_structs, [URI]))

      on_exit(fn ->
        if prev,
          do: Application.put_env(:samen_core, Samen.Replay, prev),
          else: Application.delete_env(:samen_core, Samen.Replay)
      end)

      record = fn name, fields -> %Samen.Replay.Record{resource: name, pk: nil, fields: fields} end
      raw = "<meta http-equiv=refresh content=0;url=https://x.example/>"

      tree = %{
        range: record.("Range", %{first: 1, last: 1_000_000_000_000, step: 1}),
        map_set: record.("MapSet", %{}),
        walked: record.("URI", %{port: 1}),
        resource: record.("SamenCore.Support.Clinical.Patient", %{}),
        raw: {:safe, %Samen.Replay.Kept{value: raw}},
        pair: {:ok, 1}
      }

      %{value: v} = Resolver.resolve(tree, tenant_scope(Ash.UUID.generate()))
      assert v.range == Placeholder.new(:code_changed)
      assert v.map_set == Placeholder.new(:code_changed)
      assert %Placeholder{kind: :redacted} = v.raw
      refute inspect(v) =~ "meta http-equiv"
      # Positive controls: what the recorder DOES write still rebuilds; other tuples pass.
      assert %URI{port: 1} = v.walked
      assert %Patient{} = v.resource
      assert v.pair == {:ok, 1}
    end

    test "a stored frame that fails the frame schema decodes as ONE :invalid frame, nothing in it" do
      bad = %{seq: 4, at_ms: 10, kind: :render, payload: %{"assigns" => %{"x" => "free text"}}}
      assert %{kind: :invalid, payload: %{}} = Decoder.frame(bad)

      good = %{seq: 4, at_ms: 10, kind: :render, payload: %{"assigns" => %{"count" => 3}}}
      assert %{kind: :render, payload: %{assigns: %{count: 3}}} = Decoder.frame(good)
    end

    test "placeholders render safely through every protocol and never raise" do
      for kind <- Placeholder.kinds() do
        p = Placeholder.new(kind, 7)
        assert is_binary(to_string(p))
        assert is_binary(Jason.encode!(p))
        assert p |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary() |> is_binary()
      end

      assert to_string(Placeholder.new(:redacted, 12)) == "▒▒▒ (12)"
      assert to_string(Placeholder.new(:masked)) == "••••"
      assert Placeholder.new(:not_a_kind).kind == :code_changed
    end
  end

  # -- the player kernel ---------------------------------------------------------------

  describe "load / list / timeline / drift" do
    test "load and list read under the viewer's scope: another org sees nothing", ctx do
      assert {:ok, %{session: s, frames: frames}} = Player.load(tenant_scope(ctx.org), ctx.replay_id)
      assert s.id == ctx.replay_id
      assert Enum.map(frames, & &1.kind) == [:mount, :event, :render, :exit]
      assert [%{id: id, view_short: "ReplayView"}] = Player.list(tenant_scope(ctx.org))
      assert id == ctx.replay_id

      other = tenant_scope(Ash.UUID.generate())
      assert Player.load(other, ctx.replay_id) == {:error, :not_found}
      assert Player.list(other) == []
      assert Player.load(tenant_scope(ctx.org), "not-a-uuid") == {:error, :not_found}
    end

    test "assigns_at folds the mount assigns with each later render's changed assigns", ctx do
      {:ok, %{frames: frames}} = Player.load(tenant_scope(ctx.org), ctx.replay_id)
      refute Map.has_key?(Player.assigns_at(frames, 0), :count)
      at_render = Player.assigns_at(frames, 2)
      assert at_render.count == 3
      assert %Samen.Replay.Record{} = at_render.patient
    end

    test "the timeline labels frames from bounded values and marks gaps", ctx do
      {:ok, %{frames: frames}} = Player.load(tenant_scope(ctx.org), ctx.replay_id)
      labels = for %{type: :frame, label: l} <- Player.timeline(frames), do: l
      assert labels == ["mount ReplayView", "event save", "render (1 changed)", "exit normal"]
      refute Enum.join(labels) =~ @first

      gapped = [
        %{seq: 1, at_ms: 0, kind: :mount, payload: %{}},
        %{seq: 4, at_ms: 10, kind: :render, payload: %{}},
        %{seq: 5, at_ms: 9_000, kind: :exit, payload: %{}}
      ]

      assert [
               %{type: :frame},
               %{type: :gap, reason: :missing_frames, n: 2},
               %{type: :frame},
               %{type: :gap, reason: :idle, n: 8},
               %{type: :frame}
             ] = Player.timeline(gapped)
    end

    test "the code-drift marker compares the stored MD5 with the loaded module" do
      view = "Samen.Replay.PlayerTest.FakeView"
      assert Player.drift(%{view: view, view_md5: Capture.md5(FakeView)}) == :same
      assert Player.drift(%{view: view, view_md5: String.duplicate("0", 32)}) == :changed
      assert Player.drift(%{view: view, view_md5: nil}) == :changed
      assert Player.drift(%{view: "Zz.Gone#{System.unique_integer([:positive])}", view_md5: nil}) == :missing
      # A module that is not a view (no render/1) cannot be replayed.
      assert Player.drift(%{view: "SamenCore.Support.ReplayView", view_md5: nil}) == :missing
    end
  end

  # -- R10: the audit row ---------------------------------------------------------------

  describe "R10 — one token-only replay.viewed row per audit call" do
    test "the row carries ids and a bounded detail only", ctx do
      count = fn ->
        %{rows: [[n]]} =
          @repo.query!("SELECT count(*) FROM aud_event WHERE aud_event_type = 'replay.viewed'")

        n
      end

      before = count.()
      op = Ash.UUID.generate()
      session = Ash.UUID.generate()

      assert {:ok, %{aud_event: aud}} =
               Player.audit_viewed(%{
                 replay_id: ctx.replay_id,
                 org_id: ctx.org,
                 viewer_id: op,
                 plane: :operator,
                 impersonation_session_id: session
               })

      assert count.() == before + 1
      assert aud.subject_id == ctx.replay_id
      assert aud.actor_id == op
      assert aud.correlation_id == session
      assert aud.detail == "event=replay.viewed plane=operator"

      assert Player.audit_viewed(%{replay_id: ctx.replay_id, org_id: ctx.org, viewer_id: op, plane: :root}) ==
               {:error, :invalid_viewer}

      assert count.() == before + 1
    end
  end
end
