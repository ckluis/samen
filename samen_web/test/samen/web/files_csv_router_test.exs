defmodule Samen.Web.FilesCsvRouterTest do
  @moduledoc """
  The plain-controller routes the framework macros emit - `GET /files/:id/bytes` and
  `GET /csv/export/:resource` - driven through the REAL router (`Samen.WebTest.SecurityRouter`, built by
  `samen_files_routes/3` and `samen_csv_routes/3`) with a REAL spine login (`POST /login`).

  Both routes were emitted without `assigns: %{samen_mount: mount}`, so through a router every request
  answered 503 "no mount" on every host: the controller tests that "went through the mounted route" put the
  assign on the conn by hand and never saw it. These tests put nothing on the conn.

  Every refusal is paired with the positive control that proves the same request is served.
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias Samen.Files
  alias Samen.Files.Storage.Local
  alias Samen.WebTest.SecurityHost
  alias Samen.WebTest.SpineAccounts, as: Accounts

  @endpoint Samen.WebTest.SecurityEndpoint

  setup do
    prev = Application.get_env(SecurityHost.otp_app(), :auth_required?)
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    prev_files = Application.get_env(:samen_core, Samen.Files, [])
    Application.put_env(:samen_core, :delivery_env, :test)
    SecurityHost.arm!()

    root = Path.join(System.tmp_dir!(), "files_csv_router_#{System.unique_integer([:positive])}")
    Application.put_env(:samen_core, Samen.Files, storage: Local, storage_config: %{root: root})

    on_exit(fn ->
      File.rm_rf!(root)
      SecurityHost.revoke_all!()
      Application.put_env(:samen_core, Samen.Files, prev_files)

      case prev do
        nil -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
        v -> Application.put_env(SecurityHost.otp_app(), :auth_required?, v)
      end

      case prev_delivery do
        nil -> Application.delete_env(:samen_core, :delivery_env)
        v -> Application.put_env(:samen_core, :delivery_env, v)
      end
    end)

    owner = Accounts.register!()
    member = Accounts.accept_into!(owner, :member)
    viewer = Accounts.accept_into!(owner, :viewer)
    %{owner: owner, member: member, viewer: viewer, org_id: owner.org.id, root: root}
  end

  # -- harness -----------------------------------------------------------------------------------

  defp log_in(account) do
    conn = post(build_conn(), "/login", %{"login" => %{"email" => account.email, "password" => Accounts.password()}})
    assert redirected_to(conn)
    recycle(conn)
  end

  # A LEGACY-session principal the host's `:authorized_orgs` seam grants `org_id`: the org resolves, so it is the
  # membership lookup alone that decides (a suspended spine member would just fall back to its own org).
  defp legacy_conn(user_id, org_id) do
    SecurityHost.grant!(user_id, [org_id])
    build_conn() |> Plug.Test.init_test_session(%{"samen_current_user" => user_id})
  end

  defp upload!(org_id, root, attrs) do
    {:ok, file} =
      Files.upload(
        %{org_id: org_id},
        %{filename: attrs[:filename] || "report.txt", content_type: attrs[:content_type] || "text/plain", binary: attrs[:binary] || "ROUTER-BYTES"},
        file_module: Samen.WebTest.Primitives.File,
        repo: Samen.WebTest.Repo,
        storage: Local,
        storage_config: %{root: root},
        allowed_content_types: ~w(image/png text/plain text/html application/pdf),
        max_bytes: 1_048_576
      )

    file
  end

  defp active_file!(org_id, root, attrs \\ []) do
    file = upload!(org_id, root, attrs)
    {:ok, active} = file |> Ash.Changeset.for_update(:promote, %{}) |> Ash.update(authorize?: false)
    active
  end

  defp person!(org_id, display_name) do
    scope = Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_id)

    Samen.WebTest.Crm.Person
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, display_name: display_name}, scope: scope)
    |> Ash.create!()
  end

  # The `aud_event` rows of `type` written by (or about) `who` (an actor id): this test host has no `aud_chain` table, so
  # the org-partitioned chain entry (what a migrated host also gets) is not readable here; the row itself is.
  defp access_events(who, type) do
    import Ecto.Query

    Samen.WebTest.Repo.all(
      from(e in Samen.AuditEvent,
        where: e.event_type == ^type and (e.actor_id == ^who or e.subject_id == ^who),
        order_by: [asc: e.occurred_at],
        select: %{actor_id: e.actor_id, subject_id: e.subject_id, detail: e.detail}
      )
    )
  end

  defp bytes(conn, file, org_id), do: get(conn, "/files/#{file.id}/bytes?org=#{org_id}")
  defp export(conn, resource, org_id), do: get(conn, "/csv/export/#{resource}?org=#{org_id}")

  # -- file bytes ---------------------------------------------------------------------------------

  describe "GET /files/:id/bytes through the router" do
    test "a member downloads an ACTIVE file's bytes; the controller got the mount from the router", ctx do
      file = active_file!(ctx.org_id, ctx.root)
      conn = bytes(log_in(ctx.member), file, ctx.org_id)

      assert conn.status == 200
      assert conn.resp_body == "ROUTER-BYTES"
      assert get_resp_header(conn, "content-type") |> Enum.join() =~ "text/plain"
      assert conn.assigns[:samen_acting_role] == :member
      assert conn.assigns[:samen_mount].scope_kind == :files
    end

    test "a download is audited (actor, org, file id, byte size, outcome), a refused one too, and it needs the audit to work", ctx do
      file = active_file!(ctx.org_id, ctx.root)
      uid = Accounts.user_id(ctx.member, ctx.org_id)
      member = log_in(ctx.member)
      assert bytes(member, file, ctx.org_id).status == 200

      assert [%{actor_id: ^uid, subject_id: subject, detail: detail}] = access_events(to_string(file.id), "file_download")
      assert subject == to_string(file.id)
      assert detail == "event=file_download bytes=12 outcome=ok"

      # a quarantined file is refused (403) and the refusal is recorded
      quarantined = upload!(ctx.org_id, ctx.root, [])
      assert bytes(member, quarantined, ctx.org_id).status == 403
      assert Enum.any?(access_events(to_string(quarantined.id), "file_download"), &(&1.subject_id == to_string(quarantined.id) and &1.detail == "event=file_download outcome=quarantined"))

      # an audit that cannot be written refuses the download and serves nothing
      Application.put_env(:samen_web, Samen.Web.AccessAudit, repo: Samen.WebTest.NoSuchRepo)
      on_exit(fn -> Application.delete_env(:samen_web, Samen.Web.AccessAudit) end)
      conn = bytes(member, file, ctx.org_id)
      assert conn.status == 503
      refute conn.resp_body =~ "ROUTER-BYTES"
    end

    test "a viewer gets what the policies give a viewer: reads are OrgScope only, so the file, as a viewer", ctx do
      file = active_file!(ctx.org_id, ctx.root)
      conn = bytes(log_in(ctx.viewer), file, ctx.org_id)

      assert conn.status == 200
      assert conn.resp_body == "ROUTER-BYTES"
      assert conn.assigns[:samen_acting_role] == :viewer
    end

    test "no active membership -> 403, nothing served (the same request is 200 while the membership is active)", ctx do
      file = active_file!(ctx.org_id, ctx.root)
      uid = Accounts.user_id(ctx.member, ctx.org_id)

      assert bytes(legacy_conn(uid, ctx.org_id), file, ctx.org_id).status == 200

      Accounts.suspend!(ctx.member, ctx.org_id)
      conn = bytes(legacy_conn(uid, ctx.org_id), file, ctx.org_id)
      assert conn.status == 403
      refute conn.resp_body =~ "ROUTER-BYTES"
    end

    test "no principal at all -> nothing served, and never the router-level 503 \"no mount\"", ctx do
      file = active_file!(ctx.org_id, ctx.root)
      conn = bytes(build_conn(), file, ctx.org_id)

      assert conn.status in [403, 404]
      refute conn.resp_body =~ "ROUTER-BYTES"
      refute conn.resp_body == "no mount"
    end

    test "a QUARANTINED file is not served (403), where the promoted twin is", ctx do
      quarantined = upload!(ctx.org_id, ctx.root, binary: "QUARANTINED-BYTES")
      active = active_file!(ctx.org_id, ctx.root, binary: "ACTIVE-BYTES")
      member = log_in(ctx.member)

      conn = bytes(member, quarantined, ctx.org_id)
      assert conn.status == 403
      assert conn.resp_body == "quarantined"
      refute conn.resp_body =~ "QUARANTINED-BYTES"

      assert bytes(member, active, ctx.org_id).resp_body == "ACTIVE-BYTES"
    end

    test "another org's file id is a 404 for a member of this org: no existence oracle across orgs", ctx do
      other = Accounts.register!()
      theirs = active_file!(other.org.id, ctx.root, binary: "OTHER-ORG-BYTES")
      mine = active_file!(ctx.org_id, ctx.root)
      member = log_in(ctx.member)

      conn = bytes(member, theirs, ctx.org_id)
      assert conn.status == 404
      refute conn.resp_body =~ "OTHER-ORG-BYTES"
      # selecting the other org with ?org= does not widen what this member may read either
      assert bytes(member, theirs, other.org.id).status != 200
      assert bytes(member, mine, ctx.org_id).status == 200
    end

    test "a stored file cannot run as a page on the app's origin: nosniff, sandboxed, and an attachment unless it is a safe inline type", ctx do
      html = active_file!(ctx.org_id, ctx.root, filename: "x.html", content_type: "text/html", binary: "<script>alert(1)</script>")
      png = active_file!(ctx.org_id, ctx.root, filename: "a.png", content_type: "image/png", binary: "PNG")
      member = log_in(ctx.member)

      conn = bytes(member, html, ctx.org_id)
      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") |> Enum.join() =~ "sandbox"
      assert get_resp_header(conn, "content-disposition") |> Enum.join() =~ "attachment"

      conn = bytes(member, png, ctx.org_id)
      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-disposition") |> Enum.join() =~ "inline"
    end

    test "the sandboxed response cannot be framed either: its CSP carries frame-ancestors 'none'; an inline type keeps the base CSP", ctx do
      html = active_file!(ctx.org_id, ctx.root, filename: "x.html", content_type: "text/html", binary: "<b>x</b>")
      png = active_file!(ctx.org_id, ctx.root, filename: "a.png", content_type: "image/png", binary: "PNG")
      member = log_in(ctx.member)

      csp = bytes(member, html, ctx.org_id) |> get_resp_header("content-security-policy") |> Enum.join()
      assert csp =~ "sandbox"
      assert csp =~ "frame-ancestors 'none'"

      inline = bytes(member, png, ctx.org_id) |> get_resp_header("content-security-policy") |> Enum.join()
      refute inline =~ "sandbox"
    end

    test "the download name is a plain token: no path, quote or header-breaking byte survives", ctx do
      file = active_file!(ctx.org_id, ctx.root, filename: ~s(../../etc/pa"ss wd.txt))
      conn = bytes(log_in(ctx.member), file, ctx.org_id)

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~r/filename="[\w.\-]+"$/
      refute disposition =~ "/"
      refute disposition =~ "\\"
    end
  end

  # -- CSV export ---------------------------------------------------------------------------------

  describe "GET /csv/export/:resource through the router" do
    test "a member exports the org's rows as an attachment; the controller got the mount from the router", ctx do
      person!(ctx.org_id, "Router Row")
      conn = export(log_in(ctx.member), "Person", ctx.org_id)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> Enum.join() =~ "text/csv"
      assert get_resp_header(conn, "content-disposition") |> Enum.join() =~ "attachment"
      assert conn.resp_body =~ "Router Row"
      assert conn.assigns[:samen_acting_role] == :member
    end

    test "a viewer gets what the policies give a viewer: the same rows, as a viewer", ctx do
      person!(ctx.org_id, "Router Row")
      conn = export(log_in(ctx.viewer), "Person", ctx.org_id)

      assert conn.status == 200
      assert conn.resp_body =~ "Router Row"
      assert conn.assigns[:samen_acting_role] == :viewer
    end

    test "no active membership -> 403 and no row leaves (the same request is 200 while the membership is active)", ctx do
      person!(ctx.org_id, "Router Row")
      uid = Accounts.user_id(ctx.member, ctx.org_id)

      assert export(legacy_conn(uid, ctx.org_id), "Person", ctx.org_id).status == 200

      Accounts.suspend!(ctx.member, ctx.org_id)
      conn = export(legacy_conn(uid, ctx.org_id), "Person", ctx.org_id)
      assert conn.status == 403
      refute conn.resp_body =~ "Router Row"
    end

    test "another org's rows never appear in this org's export", ctx do
      other = Accounts.register!()
      person!(other.org.id, "Other Org Row")
      person!(ctx.org_id, "Own Row")
      member = log_in(ctx.member)

      conn = export(member, "Person", ctx.org_id)
      assert conn.resp_body =~ "Own Row"
      refute conn.resp_body =~ "Other Org Row"
      # `?org=` of an org the member does not belong to cannot select it
      refute export(member, "Person", other.org.id).resp_body =~ "Other Org Row"
    end

    test "deny-by-default resource names: an unknown or foreign resource is 404", ctx do
      member = log_in(ctx.member)
      assert export(member, "Person", ctx.org_id).status == 200
      assert export(member, "Nope", ctx.org_id).status == 404
      assert export(member, "Org", ctx.org_id).status == 404
    end

    test "a cell that a spreadsheet would evaluate is defanged (CSV formula injection)", ctx do
      person!(ctx.org_id, "=HYPERLINK(\"http://evil.test\",\"x\")")
      person!(ctx.org_id, "@SUM(1+1)")
      body = export(log_in(ctx.member), "Person", ctx.org_id).resp_body

      assert body =~ ~s('=HYPERLINK)
      assert body =~ "'@SUM"
      refute body =~ ~r/(^|,|\r\n)=HYPERLINK/
      refute body =~ ~r/(^|,|\r\n)@SUM/
    end

    test "a vault-routed field never reaches the file as a token, and the body carries no vt_ reference", ctx do
      person!(ctx.org_id, "Router Row")
      body = export(log_in(ctx.member), "Person", ctx.org_id).resp_body
      refute body =~ "vt_"
    end

    test "an export larger than the row limit is refused (413), not built in memory and not silently truncated", ctx do
      previous = Application.get_env(:samen_web, Samen.Web.Csv, [])
      Application.put_env(:samen_web, Samen.Web.Csv, max_export_rows: 2)
      on_exit(fn -> Application.put_env(:samen_web, Samen.Web.Csv, previous) end)

      person!(ctx.org_id, "Row 1")
      person!(ctx.org_id, "Row 2")
      member = log_in(ctx.member)
      assert export(member, "Person", ctx.org_id).status == 200

      person!(ctx.org_id, "Row 3")
      conn = export(member, "Person", ctx.org_id)
      assert conn.status == 413
      refute conn.resp_body =~ "Row 1"

      # The case the in-loop limit exists for: the org passes the up-front COUNT (3 <= 3) and then grows before the
      # paged read. A telemetry handler runs in the querying process right after the scoped COUNT and inserts one more
      # row (once), so the read sees 4 > 3: the in-loop check alone must refuse, with no body.
      Application.put_env(:samen_web, Samen.Web.Csv, max_export_rows: 3)
      assert export(member, "Person", ctx.org_id).status == 200

      grown = :atomics.new(1, [])
      org_id = ctx.org_id
      id = {:csv_growth, System.unique_integer([:positive])}
      event = Samen.WebTest.Repo.config()[:telemetry_prefix] ++ [:query]

      :telemetry.attach(
        id,
        event,
        fn _e, _m, meta, _c ->
          if meta.query =~ "swp_person" and meta.query =~ "count(" and :atomics.compare_exchange(grown, 1, 0, 1) == :ok do
            person!(org_id, "Grow 4")
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      conn = export(member, "Person", ctx.org_id)
      assert :atomics.get(grown, 1) == 1, "the growth never happened: the handler did not see the COUNT"
      assert conn.status == 413
      refute conn.resp_body =~ "Grow"
    end

    # Every SQL statement the repo runs while `fun` does: a COUNT is not a row read, and a vault read is a resolution.
    defp queries_during(fun) do
      parent = self()
      id = {:csv_queries, System.unique_integer([:positive])}
      event = Samen.WebTest.Repo.config()[:telemetry_prefix] ++ [:query]
      :telemetry.attach(id, event, fn _e, _m, meta, _c -> send(parent, {id, meta.query}) end, nil)
      result = fun.()
      :telemetry.detach(id)
      {result, drain(id, [])}
    end

    defp drain(id, acc) do
      receive do
        {^id, query} -> drain(id, [query | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp row_reads(queries), do: Enum.filter(queries, &(&1 =~ "swp_person" and not (&1 =~ "count(")))

    test "an export above the row limit is refused after a scoped COUNT: no row is read and nothing is vault-resolved", ctx do
      previous = Application.get_env(:samen_web, Samen.Web.Csv, [])
      Application.put_env(:samen_web, Samen.Web.Csv, max_export_rows: 2)
      on_exit(fn -> Application.put_env(:samen_web, Samen.Web.Csv, previous) end)

      for n <- 1..3, do: person!(ctx.org_id, "Count Row #{n}")
      member = log_in(ctx.member)

      {conn, queries} = queries_during(fn -> export(member, "Person", ctx.org_id) end)
      assert conn.status == 413
      assert Enum.any?(queries, &(&1 =~ "swp_person" and &1 =~ "count(")), "the refusal must come from a COUNT"
      assert row_reads(queries) == [], "a row was read before the refusal: #{inspect(row_reads(queries))}"
      refute Enum.any?(queries, &(&1 =~ ~r/vault/i)), "a vault row was read before the refusal"

      # positive control: under the limit the same detector DOES see the row reads and the vault resolution
      Application.put_env(:samen_web, Samen.Web.Csv, max_export_rows: 10)
      {ok, queries} = queries_during(fn -> export(member, "Person", ctx.org_id) end)
      assert ok.status == 200
      assert row_reads(queries) != []
    end

    test "an export is audited: who, which org, which resource, how many rows, and the outcome (403, 413 included)", ctx do
      person!(ctx.org_id, "Audit Row 1")
      person!(ctx.org_id, "Audit Row 2")
      uid = Accounts.user_id(ctx.member, ctx.org_id)
      assert export(log_in(ctx.member), "Person", ctx.org_id).status == 200

      assert [%{actor_id: ^uid, detail: detail, subject_id: nil}] = access_events(uid, "csv_export")
      assert detail == "event=csv_export resource=Person rows=2 outcome=ok"
      refute detail =~ "Audit Row"

      # a refusal is recorded too (413), with the limit and no rows
      previous = Application.get_env(:samen_web, Samen.Web.Csv, [])
      Application.put_env(:samen_web, Samen.Web.Csv, max_export_rows: 1)
      on_exit(fn -> Application.put_env(:samen_web, Samen.Web.Csv, previous) end)
      assert export(log_in(ctx.member), "Person", ctx.org_id).status == 413
      assert Enum.any?(access_events(uid, "csv_export"), &(&1.detail == "event=csv_export resource=Person outcome=too_large limit=1"))

      # and so is a denial (403): a suspended member
      Accounts.suspend!(ctx.member, ctx.org_id)
      assert export(legacy_conn(uid, ctx.org_id), "Person", ctx.org_id).status == 403
      assert Enum.any?(access_events(uid, "csv_export"), &(&1.detail == "event=csv_export resource=Person outcome=denied"))
      assert Enum.all?(access_events(uid, "csv_export"), &(&1.actor_id == uid))
    end

    test "an export whose audit write fails is refused (503) and delivers nothing; the same request succeeds when it works", ctx do
      person!(ctx.org_id, "Unaudited Row")
      member = log_in(ctx.member)
      assert export(member, "Person", ctx.org_id).status == 200

      Application.put_env(:samen_web, Samen.Web.AccessAudit, repo: Samen.WebTest.NoSuchRepo)
      on_exit(fn -> Application.delete_env(:samen_web, Samen.Web.AccessAudit) end)
      conn = export(member, "Person", ctx.org_id)
      assert conn.status == 503
      refute conn.resp_body =~ "Unaudited Row"
    end

    test "the row limit counts what the read would return: archived rows are not counted", ctx do
      previous = Application.get_env(:samen_web, Samen.Web.Csv, [])
      Application.put_env(:samen_web, Samen.Web.Csv, max_export_rows: 2)
      on_exit(fn -> Application.put_env(:samen_web, Samen.Web.Csv, previous) end)

      for n <- 1..2, do: person!(ctx.org_id, "Live #{n}")
      {:ok, _} = Samen.Archival.archive(person!(ctx.org_id, "Gone"), authorize?: false)
      assert export(log_in(ctx.member), "Person", ctx.org_id).status == 200
    end
  end
end
