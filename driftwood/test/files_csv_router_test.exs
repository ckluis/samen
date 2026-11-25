defmodule Driftwood.FilesCsvRouterTest do
  @moduledoc """
  The file-bytes and CSV-export routes on the REAL host: `DriftwoodWeb.Router` (its `samen_files_routes` and
  `samen_csv_routes` mounts), the real endpoint, and a REAL spine login (`SessionController.create/2`).

  Both routes used to be emitted without `assigns: %{samen_mount: mount}`, so every request answered 503
  "no mount" on this host. The gate probes (`gate_e2_files_e2e_test.exs`, `gate_e3_csv_e2e_test.exs`) call the
  controllers with the assign set by hand and never saw it. Nothing is put on the conn here.
  """
  use Driftwood.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_session: 2, get_resp_header: 2]

  alias Samen.Files
  alias Samen.Files.Storage.Local
  alias Samen.Identity.Invite
  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias Samen.Web.Auth.SessionController
  alias Samen.Web.Mount

  alias Driftwood.Operator.{AuthToken, Credential, Invitation, Membership, Org, User}

  @endpoint DriftwoodWeb.Endpoint
  @password "correct horse battery staple"

  setup do
    start_supervised!(DriftwoodWeb.Endpoint)

    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    prev_auth = Application.get_env(:driftwood, :auth_required?)
    prev_files = Application.get_env(:samen_core, Samen.Files, [])
    root = Path.join(System.tmp_dir!(), "driftwood_router_files_#{System.unique_integer([:positive])}")

    Application.put_env(:samen_core, :delivery_env, :test)
    Application.put_env(:driftwood, :auth_required?, true)
    Application.put_env(:samen_core, Samen.Files, storage: Local, storage_config: %{root: root})

    on_exit(fn ->
      File.rm_rf!(root)
      Application.put_env(:samen_core, Samen.Files, prev_files)

      if prev_delivery,
        do: Application.put_env(:samen_core, :delivery_env, prev_delivery),
        else: Application.delete_env(:samen_core, :delivery_env)

      if prev_auth == nil,
        do: Application.delete_env(:driftwood, :auth_required?),
        else: Application.put_env(:driftwood, :auth_required?, prev_auth)
    end)

    owner = register!()
    viewer = accept_into!(owner, :viewer)
    %{owner: owner, viewer: viewer, org_id: owner.org.id, root: root}
  end

  defp register_mods,
    do: %{org: Org, credential: Credential, user: User, membership: Membership, auth_token: AuthToken, repo: Driftwood.Repo}

  defp invite_mods, do: %{invitation: Invitation, credential: Credential, user: User, membership: Membership, repo: Driftwood.Repo}

  defp register! do
    attrs = %{
      org_name: "Router Freight #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "router-#{System.unique_integer([:positive])}@example.test",
      password: @password
    }

    {:ok, result} = Register.register(attrs, register_mods())
    Map.put(result, :email, attrs.email)
  end

  defp accept_into!(host, role) do
    invitee = register!()

    owner_scope = %Samen.Scope{
      actor: %{id: host.user.id, org_id: host.org.id, role: :owner, verified?: true, kind: :tenant, plane: :tenant}
    }

    {:ok, _inv, raw_token} = Invite.create(invite_mods(), owner_scope, %{email: invitee.email, role: role})
    {:ok, _joined} = Invite.accept(invite_mods(), raw_token)
    invitee
  end

  # The real login: `SessionController.create/2` with the mount the router builds for the auth routes.
  defp log_in(account) do
    opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "salt", encryption_salt: "esalt")

    conn =
      Plug.Test.conn(:post, "/login")
      |> Map.put(:secret_key_base, String.duplicate("b", 64))
      |> Plug.Session.call(opts)
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_private(:samen_mount, Mount.new(:auth, Driftwood.Operator, Driftwood.Repo))
      |> Plug.Conn.put_private(:samen_login_path, "/login")

    conn = SessionController.create(conn, %{"login" => %{"email" => account.email, "password" => @password}})
    token = get_session(conn, Auth.session_token_key())
    assert is_binary(token), "the real login must write the spine session token"
    build_conn() |> Plug.Test.init_test_session(%{Auth.session_token_key() => token})
  end

  defp upload!(org_id, root, binary) do
    {:ok, file} =
      Files.upload(
        %{org_id: org_id},
        %{filename: "manifest.txt", content_type: "text/plain", binary: binary},
        file_module: Driftwood.Primitives.File,
        repo: Driftwood.Repo,
        storage: Local,
        storage_config: %{root: root},
        allowed_content_types: ~w(text/plain),
        max_bytes: 1_048_576
      )

    file
  end

  defp promote!(file) do
    {:ok, active} = file |> Ash.Changeset.for_update(:promote, %{}) |> Ash.update(authorize?: false)
    active
  end

  defp person!(org_id, display_name) do
    Samen.Factory.create!(
      Driftwood.Crm.Person,
      Map.merge(Samen.Factory.person("Router", "Person"), %{display_name: display_name, org_id: org_id}),
      Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_id)
    )
  end

  test "file bytes: an owner and a viewer download an ACTIVE file; a QUARANTINED one is refused", ctx do
    active = ctx.org_id |> upload!(ctx.root, "DRIFTWOOD-BYTES") |> promote!()
    quarantined = upload!(ctx.org_id, ctx.root, "QUARANTINED-BYTES")

    for account <- [ctx.owner, ctx.viewer] do
      conn = get(log_in(account), "/files/#{active.id}/bytes?org=#{ctx.org_id}")
      assert conn.status == 200
      assert conn.resp_body == "DRIFTWOOD-BYTES"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    assert get(log_in(ctx.owner), "/files/#{active.id}/bytes?org=#{ctx.org_id}").assigns[:samen_acting_role] == :owner
    assert get(log_in(ctx.viewer), "/files/#{active.id}/bytes?org=#{ctx.org_id}").assigns[:samen_acting_role] == :viewer

    conn = get(log_in(ctx.owner), "/files/#{quarantined.id}/bytes?org=#{ctx.org_id}")
    assert conn.status == 403
    refute conn.resp_body =~ "QUARANTINED-BYTES"
  end

  test "file bytes: no session -> nothing served; another org's file id is a 404", ctx do
    mine = ctx.org_id |> upload!(ctx.root, "MINE") |> promote!()
    other = register!()
    theirs = other.org.id |> upload!(ctx.root, "OTHER-ORG-BYTES") |> promote!()

    conn = get(build_conn(), "/files/#{mine.id}/bytes?org=#{ctx.org_id}")
    assert conn.status in [302, 403, 404]
    refute conn.resp_body =~ "MINE"

    conn = get(log_in(ctx.owner), "/files/#{theirs.id}/bytes?org=#{ctx.org_id}")
    assert conn.status == 404
    refute conn.resp_body =~ "OTHER-ORG-BYTES"
  end

  test "CSV export: an owner and a viewer export the org's rows; another org's rows never appear", ctx do
    person!(ctx.org_id, "Our Driver")
    other = register!()
    person!(other.org.id, "Their Driver")

    for {account, role} <- [{ctx.owner, :owner}, {ctx.viewer, :viewer}] do
      conn = get(log_in(account), "/csv/export/Person?org=#{ctx.org_id}")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> Enum.join() =~ "text/csv"
      assert conn.resp_body =~ "Our Driver"
      refute conn.resp_body =~ "Their Driver"
      assert conn.assigns[:samen_acting_role] == role
    end
  end

  test "CSV export: no session -> no rows; an unknown resource is 404", ctx do
    person!(ctx.org_id, "Our Driver")

    conn = get(build_conn(), "/csv/export/Person?org=#{ctx.org_id}")
    assert conn.status in [302, 403, 404]
    refute conn.resp_body =~ "Our Driver"

    owner = log_in(ctx.owner)
    assert get(owner, "/csv/export/Person?org=#{ctx.org_id}").status == 200
    assert get(owner, "/csv/export/Nope?org=#{ctx.org_id}").status == 404
  end
end
