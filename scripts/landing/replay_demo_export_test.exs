# Landing-page replay demo exporter — ADR-052 session replay (`Samen.Replay`, on main since PR #83).
#
# Records ONE real session through the real P2 recorder over the real
# `Samen.Web.CRM.ContactsLive` (fictional Blue Ridge contacts, `.example` addresses), then plays
# it back through the real `Samen.Web.Replay.PlayerLive` for four viewers and writes
# `replay_demo.json` (+ one srcdoc per viewer for inspection). Everything runs inside the
# samen_web SQL sandbox, so every row it writes is rolled back when the test ends; the KMS key
# dir is samen_web's per-run temp dir.
#
# Regenerate (from the repo root):
#
#     cp scripts/landing/replay_demo_export_test.exs samen_web/test/landing_replay_demo_export_test.exs
#     (cd samen_web && LANDING_EXPORT_OUT=/tmp/replay-demo mix test test/landing_replay_demo_export_test.exs)
#     rm samen_web/test/landing_replay_demo_export_test.exs
#     python3 -I scripts/landing/replay_demo_section.py /tmp/replay-demo/replay_demo.json /tmp/replay-demo index.html
#
# The last step lays out index.html's #replay section and splices it in place (see that script's
# header for where its two outputs go). Ids and millisecond timestamps differ on every run; the rest should not.
#
# The JSON holds, per frame: the bounded timeline label, the VERBATIM `rpf_payload` text exactly
# as Postgres returns it, and the player's output (reference outcomes + the rendered contact
# cells) for operator-no-grant / operator-with-grant / tenant-admin / after-shred; the
# `replay.viewed` aud_event rows; and the CONTRAST — the same session's changed assigns and
# event params BEFORE sanitization (what a replay that stores values would have kept).
defmodule Samen.Web.LandingReplayDemoExportTest do
  use Samen.WebTest.DataCase, async: false

  alias Phoenix.LiveView.Lifecycle
  alias Samen.FeatureFlags.Cache
  alias Samen.Replay
  alias Samen.Replay.{Capture, Monitor}
  alias Samen.Reveal.Grants
  alias Samen.Web.CRM.ContactsLive
  alias Samen.Web.ListLive
  alias Samen.Web.Replay.PlayerLive
  alias Samen.WebTest.Operator.{Membership, User}

  @moduletag :landing_export
  @operator_org "0f000000-0000-4000-8000-0000000000aa"
  @blue_ridge "b1112d00-0000-4000-8000-000000000001"

  # Fictional people only (the landing page's Blue Ridge world). 555-01xx numbers are reserved
  # for fiction; every address is on a reserved `.example` domain.
  @contacts [
    {"Ada", "Whitfield", "ada.whitfield@blueridge.example", "+1 555 0142", "Dispatch Lead", "Blue Ridge Logistics"},
    {"Ada", "Villanueva", "ada.v@laurelfork.example", "+1 555 0177", "Account Manager", "Laurel Fork Supply"},
    {"Marcus", "Okafor", "marcus@cumberlandmills.example", "+1 555 0119", "Plant Manager", "Cumberland Mills"},
    {"Priya", "Raman", "priya.raman@blueridge.example", "+1 555 0163", "Controller", "Blue Ridge Logistics"},
    {"Lena", "Hartmann", "lena@shenandoahcold.example", "+1 555 0108", "Buyer", "Shenandoah Cold Chain"}
  ]
  # What the user types into the New-contact form (never stored; shape only).
  @typed %{"first" => "Noor", "last" => "Haddad", "display" => "Noor Haddad", "title" => "Fleet Safety"}
  @filter_text "ada"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Samen.WebTest.Repo, {:shared, self()})
    Cache.invalidate_all()

    on_exit(fn ->
      Cache.invalidate_all()
      Replay.erase_runtime_config()
      Capture.detach()
    end)

    :ok
  end

  test "export the landing replay demo" do
    out = System.get_env("LANDING_EXPORT_OUT") || Path.join(System.tmp_dir!(), "replay-demo")
    File.mkdir_p!(out)
    org = @blue_ridge

    people = seed!(org)
    ada = Enum.find(people, &(&1.display_name == "Ada Whitfield"))

    start_capture!([org])
    {replay_id, naive} = record!(org, build_mount(:crm, []))

    # -- what Postgres holds, verbatim ------------------------------------------------------
    %{rows: frame_rows} =
      Repo.query!(
        "SELECT rpf_seq, rpf_kind, rpf_at_ms, rpf_payload::text FROM replay_frame " <>
          "WHERE rpf_session_id = $1::uuid ORDER BY rpf_seq",
        [Ecto.UUID.dump!(replay_id)]
      )

    %{rows: [[session_json]]} =
      Repo.query!("SELECT row_to_json(s)::text FROM replay_session s WHERE rps_id = $1::uuid", [
        Ecto.UUID.dump!(replay_id)
      ])

    all_stored = Enum.map_join(frame_rows, "\n", &List.last/1) <> session_json

    # The positive control: the plaintext really was on the socket (naive), never in the rows.
    sentinels =
      Enum.flat_map(@contacts, fn {f, l, e, p, t, c} -> [f <> " " <> l, l, e, p, t, c] end) ++
        [@typed["last"], @typed["title"]]

    naive_text = Jason.encode!(naive)
    for s <- sentinels, do: refute(all_stored =~ s, "#{s} reached replay rows")
    assert naive_text =~ "ada.whitfield@blueridge.example"
    refute all_stored =~ "vt_"

    # -- four viewers ----------------------------------------------------------------------
    operator = "0e000000-0000-4000-8000-00000000c0de"
    granted_operator = "0e000000-0000-4000-8000-00000000beef"
    admin = user!(org, :admin)

    imp_plain = open_impersonation!(operator, org, "ticket 4242 — contacts list looks wrong")
    imp_grant = open_impersonation!(granted_operator, org, "ticket 4242 — contacts list looks wrong")
    grant!(granted_operator, ada.id, org)

    viewers = [
      {"operator_no_grant", fn -> operator_player(org, replay_id, operator) end},
      {"operator_with_grant", fn -> operator_player(org, replay_id, granted_operator) end},
      {"tenant_admin", fn -> tenant_player(org, replay_id, admin.id) end}
    ]

    played = for {name, open} <- viewers, into: %{}, do: {name, play_all(open.(), out, name)}

    {:ok, _} = Samen.Erasure.shred(ada.id, repo: Repo, org_id: org)
    played = Map.put(played, "after_shred", play_all(tenant_player(org, replay_id, admin.id), out, "after_shred"))

    # Rows are unchanged by the shred (same bytes, four views).
    %{rows: after_rows} =
      Repo.query!(
        "SELECT rpf_seq, rpf_kind, rpf_at_ms, rpf_payload::text FROM replay_frame " <>
          "WHERE rpf_session_id = $1::uuid ORDER BY rpf_seq",
        [Ecto.UUID.dump!(replay_id)]
      )

    assert after_rows == frame_rows

    %{rows: audit} =
      Repo.query!(
        "SELECT row_to_json(a)::text FROM (SELECT aud_event_type, aud_subject_id::text, aud_actor_id::text, " <>
          "aud_correlation_id::text, aud_detail FROM aud_event " <>
          "WHERE aud_event_type = 'replay.viewed' ORDER BY aud_occurred_at) a"
      )

    %{rows: audit_full} =
      Repo.query!("SELECT row_to_json(a)::text FROM aud_event a WHERE aud_event_type = 'replay.viewed'")

    frames =
      frame_rows
      |> Enum.with_index()
      |> Enum.map(fn {[seq, kind, at_ms, payload], i} ->
        %{
          index: i,
          seq: seq,
          kind: kind,
          at_ms: at_ms,
          label: played["tenant_admin"].labels |> Enum.at(i),
          stored: payload,
          naive: Enum.at(naive, i),
          views: Map.new(played, fn {name, p} -> {name, Enum.at(p.frames, i)} end)
        }
      end)

    export = %{
      generated_by: "scripts/landing/replay_demo_export_test.exs",
      replay_id: replay_id,
      org_id: org,
      people: Enum.map(people, &%{id: &1.id, display_name: &1.display_name}),
      shredded_subject: ada.id,
      grant_subject: ada.id,
      impersonation: %{operator_no_grant: imp_plain.id, operator_with_grant: imp_grant.id},
      viewer_ids: %{operator_no_grant: operator, operator_with_grant: granted_operator, tenant_admin: admin.id},
      session_row: Jason.decode!(session_json),
      drift: Map.new(played, fn {name, p} -> {name, p.drift} end),
      frames: frames,
      audit: Enum.map(audit, &Jason.decode!(hd(&1))),
      audit_columns: audit_full |> List.first() |> hd() |> Jason.decode!() |> Map.keys(),
      stored_bytes: frame_rows |> Enum.map(&byte_size(List.last(&1))) |> Enum.sum(),
      naive_bytes: byte_size(naive_text)
    }

    File.write!(Path.join(out, "replay_demo.json"), Jason.encode!(export, pretty: true))
  end

  # -- seed --------------------------------------------------------------------------------

  defp seed!(org) do
    companies =
      @contacts
      |> Enum.map(&elem(&1, 5))
      |> Enum.uniq()
      |> Map.new(fn name ->
        c =
          Samen.WebTest.Crm.Company
          |> Ash.Changeset.for_create(:create, %{org_id: org, name: name}, authorize?: false)
          |> Ash.create!()

        {name, c.id}
      end)

    for {first, last, email, phone, title, company} <- @contacts do
      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          company_id: companies[company],
          display_name: "#{first} #{last}",
          job_title: title,
          full_name: %Samen.Type.FullName{first: first, last: last},
          emails: [%{label: "work", address: email}],
          phones: [%{label: "mobile", number: phone}]
        },
        authorize?: false
      )
      |> Ash.create!()
    end
  end

  # -- record ------------------------------------------------------------------------------

  defp start_capture!(orgs) do
    config = %{
      enabled: true,
      rollout_pct: 0,
      stage: :ga,
      variants: %{},
      target_rules: [%{"attribute" => "org_id", "op" => "in", "values" => orgs, "then" => "allow"}]
    }

    start_supervised!({Replay.Supervisor, [flag_opts: [loader: fn "samen.replay" -> {:ok, config} end]]})
  end

  # land → sort by title → New contact → type into the form → save → filter "ada".
  defp record!(org, mount) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        socket =
          %Phoenix.LiveView.Socket{
            view: ContactsLive,
            router: Samen.WebTest.SecurityRouter,
            endpoint: Samen.WebTest.SecurityEndpoint,
            transport_pid: self(),
            private: %{lifecycle: %Lifecycle{}},
            assigns: %{__changed__: %{}, flash: %{}, live_action: :index}
          }
          |> Phoenix.Component.assign(:samen_mount, mount)
          |> Phoenix.Component.assign(:samen_acting_as, false)

        {:cont, socket} =
          Samen.Web.TenantAuthz.on_mount(:require_tenant, %{}, %{"samen_mount" => Samen.Web.Mount.to_session(mount)}, socket)

        socket = ContactsLive.load(Phoenix.Component.assign(socket, :org_id, org), org)
        naive = [%{kind: "mount", assigns: naive_assigns(socket.assigns, :all)}]
        uri = "http://localhost/crm/contacts?org=#{org}"
        naive = naive ++ [%{kind: "params", url: uri, params: %{"org" => org}}]
        {:cont, socket} = Lifecycle.handle_params(%{"org" => org}, uri, socket)
        {socket, naive} = render(socket, naive)

        # 1. sort by job title (a ListLive event — the mixin's hook path, called directly)
        {socket, naive} = list_event(socket, naive, "sort", %{"field" => "job_title"})
        # 2. New contact
        {socket, naive} = view_event(socket, naive, "new_contact", %{})
        # 3. type into the form
        form = %{
          "form" => %{
            "full_name" => %{"first" => @typed["first"], "last" => @typed["last"]},
            "display_name" => @typed["display"],
            "job_title" => @typed["title"]
          }
        }

        {socket, naive} = view_event(socket, naive, "validate_new", form)
        # 4. save
        {socket, naive} = view_event(socket, naive, "save_new", form)
        # 5. filter the list (typed text)
        {_socket, naive} = list_event(socket, naive, "filter", %{"filter" => @filter_text})

        send(parent, {:naive, naive ++ [%{kind: "exit", reason: "normal"}]})
        _ = :sys.get_state(Monitor)
      end)

    assert_receive {:naive, naive}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    :ok = Monitor.flush()

    %{rows: [[id]]} =
      Repo.query!(
        "SELECT rps_id::text FROM replay_session WHERE rps_org_id = $1::uuid ORDER BY rps_started_at DESC LIMIT 1",
        [Ecto.UUID.dump!(org)]
      )

    {id, naive}
  end

  defp telemetry!(socket, event, params) do
    :telemetry.execute(
      [:phoenix, :live_view, :handle_event, :start],
      %{system_time: System.system_time()},
      %{socket: socket, event: event, params: params}
    )
  end

  defp list_event(socket, naive, event, params) do
    telemetry!(socket, event, params)
    {:noreply, socket} = ListLive.handle_list_event(event, params, socket)
    render(socket, naive ++ [%{kind: "event", event: event, params: params}])
  end

  defp view_event(socket, naive, event, params) do
    telemetry!(socket, event, params)
    {:noreply, socket} = ContactsLive.handle_event(event, params, socket)
    render(socket, naive ++ [%{kind: "event", event: event, params: params}])
  end

  defp render(socket, naive) do
    changed = naive_assigns(socket.assigns, Map.keys(socket.assigns.__changed__ || %{}))
    socket = socket |> Lifecycle.after_render()
    socket = %{socket | assigns: Map.put(socket.assigns, :__changed__, %{})}
    {socket, naive ++ [%{kind: "render", assigns: changed}]}
  end

  # The values a replay that stores assigns BY VALUE would have kept: the socket's real assigns
  # (tenant plane — already resolved in the clear), made JSON-able.
  defp naive_assigns(assigns, keys) do
    keys = if keys == :all, do: Map.keys(assigns), else: keys

    for k <- keys,
        k not in [:__changed__, :flash, :samen_mount, :samen_replay, :samen_tenant_principal],
        into: %{} do
      {k, plain(Map.get(assigns, k), 0)}
    end
  end

  defp plain(_v, depth) when depth > 6, do: "…"
  defp plain(%Phoenix.HTML.Form{} = f, d), do: %{"$form" => plain(f.params, d + 1)}
  defp plain(%Samen.Web.Page{items: items}, d), do: %{"items" => plain(items, d + 1)}
  defp plain(%Samen.Type.FullName{} = n, _d), do: %{"first" => n.first, "last" => n.last}

  defp plain(%{__struct__: mod} = s, d) do
    cond do
      Ash.Resource.Info.resource?(mod) ->
        keep = [:id, :display_name, :full_name, :emails, :phones, :job_title, :company_id]
        Map.new(keep, &{&1, plain(Map.get(s, &1), d + 1)})

      mod in [DateTime, NaiveDateTime, Date, Decimal] ->
        to_string(s)

      true ->
        s |> Map.from_struct() |> Map.drop([:__meta__]) |> plain(d + 1)
    end
  rescue
    _ -> inspect(s, limit: 5)
  end

  defp plain(m, d) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), plain(v, d + 1)} end)
  defp plain(l, d) when is_list(l), do: Enum.map(l, &plain(&1, d + 1))
  defp plain(t, d) when is_tuple(t), do: t |> Tuple.to_list() |> plain(d)
  defp plain(v, _d) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp plain(v, _d) when is_atom(v), do: to_string(v)
  defp plain(v, _d), do: inspect(v, limit: 5)

  # -- play --------------------------------------------------------------------------------

  defp play_all(socket, out, name) do
    assert socket.assigns.state == :open, "#{name}: #{inspect(socket.assigns[:deny_reason])}"
    n = length(socket.assigns.frames)
    labels = Enum.map(socket.assigns.timeline |> Enum.filter(&(&1.type == :frame)), & &1.label)

    frames =
      for i <- 0..(n - 1) do
        s = PlayerLive.show(socket, i)
        html = s.assigns.frame_html

        if html, do: File.write!(Path.join(out, "#{name}-#{i}.html"), html)

        %{
          error: s.assigns.frame_error && inspect(s.assigns.frame_error),
          refs: Enum.map(s.assigns.refs, &Map.new(&1, fn {k, v} -> {k, to_string(v)} end)),
          rows: rows(html),
          count: count(html),
          modal: is_binary(html) and html =~ "new-contact-modal",
          srcdoc_bytes: html && byte_size(html)
        }
      end

    %{labels: labels, frames: frames, drift: to_string(socket.assigns.drift)}
  end

  defp rows(nil), do: []

  defp rows(html) do
    ~r/<tr[^>]*contact-row[^>]*>(.*?)<\/tr>/s
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [tr] ->
      %{
        initials: cell(tr, ~r/class="av"[^>]*>\s*(.*?)\s*<\/div>/s),
        name: cell(tr, ~r/class="p-full-name"[^>]*>\s*(.*?)\s*<\/span>/s),
        email: cell(tr, ~r/class="p-email"[^>]*>\s*(.*?)\s*<\/td>/s),
        phone: cell(tr, ~r/class="p-phone"[^>]*>\s*(.*?)\s*<\/td>/s),
        company: cell(tr, ~r/class="p-company"[^>]*>\s*(.*?)\s*<\/td>/s),
        title: cell(tr, ~r/class="p-title"[^>]*>\s*(.*?)\s*<\/td>/s)
      }
    end)
  end

  defp count(nil), do: nil

  defp count(html) do
    case Regex.run(~r/<span class="n">\s*(.*?)\s*<\/span>/s, html) do
      [_, n] -> n
      _ -> nil
    end
  end

  defp cell(tr, re) do
    case Regex.run(re, tr) do
      [_, v] -> v |> String.replace(~r/<[^>]+>/, "") |> String.trim() |> unescape()
      _ -> nil
    end
  end

  defp unescape(s),
    do:
      s
      |> String.replace("&amp;", "&")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&#39;", "'")

  # -- viewers (the replay_player_test.exs harness) -----------------------------------------

  defp user!(org_id, role) do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        handle: "blueridge-admin",
        full_name: %Samen.Type.FullName{first: "June", last: "Calloway"},
        emails: [%{address: "june.calloway@blueridge.example"}]
      })
      |> Ash.create!(authorize?: false)

    Membership
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, user_id: user.id, role: role})
    |> Ash.create!(authorize?: false)

    user
  end

  defp connected_socket do
    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      router: Samen.WebTest.SecurityRouter,
      endpoint: Samen.WebTest.SecurityEndpoint,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{__changed__: %{}, flash: %{}}
    }
  end

  defp tenant_player(org, replay_id, user_id) do
    mount = build_mount(:settings)
    session = %{"samen_mount" => Samen.Web.Mount.to_session(mount), "samen_current_user" => user_id}
    params = %{"id" => replay_id, "org" => org}
    {:cont, socket} = Samen.Web.TenantAuthz.on_mount(:require_tenant, params, session, connected_socket())
    {:ok, socket} = PlayerLive.mount(params, session, socket)
    socket
  end

  defp operator_player(org, replay_id, operator_id) do
    mount = build_operator_mount(@operator_org)
    session = %{"samen_mount" => Samen.Web.Mount.to_session(mount)}
    params = %{"org_id" => org, "id" => replay_id}
    socket = with_operator_identity(connected_socket(), operator_id)
    {:ok, socket} = PlayerLive.mount(params, session, socket)
    socket
  end

  defp grant!(operator_id, subject_id, org) do
    {:ok, req} =
      Grants.request(%{subject_id: subject_id, requestor_id: operator_id, reason: "ticket 4242 replay review", org_id: org})

    {:ok, grant} = Grants.approve(req, %{granted_by: Ash.UUID.generate(), org_id: org})
    grant
  end

end
