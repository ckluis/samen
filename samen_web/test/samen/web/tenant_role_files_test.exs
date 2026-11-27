defmodule Samen.Web.TenantRoleFilesTest do
  @moduledoc """
  ADR-045 §4.4 residual (the `:member` default), Files: the upload page and the preview page act with the role the
  signed-in person's ACTIVE membership resolves to (`Samen.Web.TenantActor`), never `Mount.scope/2`'s fixed `:member`.

  Driven with a REAL spine login (`POST /login`) and the REAL tenant gate (`Samen.WebTest.RoleHarness`). Every refusal is
  paired with a positive control.

  Role choice: listing and previewing files is a read open to every active member (a viewer included; the per-plane masking
  of the filename and the byte gate are the preview's own and unchanged); uploading is a member's, checked by the handler and
  offered to a member only.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Files.{PreviewLive, UploadLive}
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.Primitives.File, as: FileResource
  alias Samen.WebTest.SpineAccounts

  setup do
    ctx = H.setup_accounts()
    root = Path.join(System.tmp_dir!(), "files_role_#{System.unique_integer([:positive])}")
    Elixir.File.mkdir_p!(root)
    on_exit(fn -> Elixir.File.rm_rf!(root) end)

    {:ok, file} =
      Samen.Files.upload(
        %{org_id: ctx.org_id},
        %{filename: "zebra-notes.txt", content_type: "text/plain", binary: "hello"},
        file_module: FileResource,
        repo: Samen.WebTest.Repo,
        storage: Samen.Files.Storage.Local,
        storage_config: %{root: root},
        allowed_content_types: ~w(text/plain),
        max_bytes: 1_048_576
      )

    Map.put(ctx, :stored, file)
  end

  defp html(view, socket), do: render_html(view, socket.assigns)
  # Mount, then the route's `handle_params` (both pages load their data there).
  defp upload(login, ctx), do: H.params(UploadLive, H.live_socket(login, UploadLive, "/files", ctx.org_id), %{})

  defp preview(login, ctx) do
    extra = %{"id" => ctx.stored.id}
    H.params(PreviewLive, H.live_socket(login, PreviewLive, "/files/:id", ctx.org_id, extra), extra)
  end

  test "both pages act with the RESOLVED role, not :member, and every role reads", ctx do
    for role <- [:viewer, :member, :admin, :owner] do
      login = H.log_in(Map.fetch!(ctx, role))

      for socket <- [upload(login, ctx), preview(login, ctx)] do
        assert socket.assigns.actor_state == :ok
        assert socket.assigns.acting_scope.actor.role == role
        assert socket.assigns.acting_scope.actor.resolved == true
      end

      assert html(UploadLive, upload(login, ctx)) =~ "zebra-notes.txt", "#{role}: the list is open to every member"
      assert html(PreviewLive, preview(login, ctx)) =~ "zebra-notes.txt", "#{role}: the preview is open to every member"
    end
  end

  test "uploading is a member's: a viewer is offered no form and a crafted upload is refused; a member's reaches the upload", ctx do
    viewer = upload(H.log_in(ctx.viewer), ctx)
    assert viewer.assigns.can_write == false
    refute html(UploadLive, viewer) =~ ~s(id="upload-form")
    viewer = H.event(UploadLive, "upload", %{}, viewer)
    assert viewer.assigns.upload_error =~ "can view files but not upload"

    member = upload(H.log_in(ctx.member), ctx)
    assert member.assigns.can_write == true
    assert html(UploadLive, member) =~ ~s(id="upload-form")
    member = H.event(UploadLive, "upload", %{}, member)
    assert member.assigns.upload_error == "no file selected", "the member's event reached the upload (positive control)"
  end

  test "NAVIGATION: a suspended member's pages are the denied state: nothing is read", ctx do
    login = H.log_in(ctx.member)
    sockets = [{UploadLive, upload(login, ctx), %{}}, {PreviewLive, preview(login, ctx), %{"id" => ctx.stored.id}}]

    for {view, socket, _} <- sockets, do: assert(html(view, socket) =~ "zebra-notes.txt", "vacuous control")

    SpineAccounts.suspend!(ctx.member, ctx.org_id)

    refused_all =
      for {view, socket, extra} <- sockets do
        refused = H.params(view, socket, extra)
        assert refused.assigns.actor_state == :denied
        assert refused.assigns.acting_scope == nil
        out = html(view, refused)
        assert out =~ ~s(id="actor-denied")
        refute out =~ "zebra-notes.txt"
        if view == PreviewLive, do: assert(refused.assigns.file == nil, "the denied preview still holds the file")
        {view, refused}
      end

    {UploadLive, refused} = hd(refused_all)
    assert H.event(UploadLive, "upload", %{}, refused).assigns == refused.assigns
  end

  test "a failed membership lookup is the UNAVAILABLE state, never an empty page", ctx do
    login = H.log_in(ctx.member)

    for {view, socket, extra} <- [
          {UploadLive, upload(login, ctx) |> H.break_identity(), %{}},
          {PreviewLive, preview(login, ctx) |> H.break_identity(), %{"id" => ctx.stored.id}}
        ] do
      {refused, _log} = ExUnit.CaptureLog.with_log(fn -> H.params(view, socket, extra) end)
      assert refused.assigns.actor_state == :unavailable
      assert html(view, refused) =~ ~s(id="actor-unavailable")
      refute html(view, refused) =~ "zebra-notes.txt"
    end
  end

  test "OPEN PAGE: a member demoted to viewer while the page is open is refused the upload at the next event; an unchanged member is not", ctx do
    open = H.open_socket(H.log_in(ctx.member), UploadLive, "/files", ctx.org_id)
    assert open.assigns.can_write

    SpineAccounts.set_role!(ctx.member, ctx.org_id, :viewer)
    demoted = H.live_event(UploadLive, "upload", %{}, open)
    assert demoted.assigns.acting_scope.actor.role == :viewer
    refute demoted.assigns.can_write
    assert demoted.assigns.upload_error =~ "can view files but not upload"

    SpineAccounts.set_role!(ctx.member, ctx.org_id, :member)
    fresh = H.open_socket(H.log_in(ctx.member), UploadLive, "/files", ctx.org_id)
    fresh = H.live_event(UploadLive, "upload", %{}, fresh)
    assert fresh.assigns.upload_error == "no file selected"
  end
end
