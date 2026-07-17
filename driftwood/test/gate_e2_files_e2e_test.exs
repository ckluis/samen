defmodule Driftwood.GateE2FilesE2ETest do
  @moduledoc """
  GATE PROBE (WS-E E2.3) — end-to-end files lifecycle on a REAL host (Driftwood):
  upload → quarantine → (Noop scan) promote → preview render → byte-serve.

  Exercises the full stack the `samen_files_routes` macro mounts, on a real vertical's
  Primitives mount + repo. A gate artifact, not part of the shipped suites.
  """
  use Driftwood.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Samen.Files
  alias Samen.Files.Storage.Local
  alias Samen.Web.Files.BytesController
  alias Samen.Web.Files.PreviewLive

  alias Driftwood.Primitives.File, as: FileResource

  defp root do
    r = Path.join(System.tmp_dir!(), "e2e_files_#{System.unique_integer([:positive])}")
    Elixir.File.rm_rf!(r)
    on_exit(fn -> Elixir.File.rm_rf!(r) end)
    r
  end

  defp opts(root, extra \\ []) do
    Keyword.merge(
      [
        file_module: FileResource,
        repo: Driftwood.Repo,
        storage: Local,
        storage_config: %{root: root},
        allowed_content_types: ~w(image/png text/plain),
        max_bytes: 1_048_576
      ],
      extra
    )
  end

  defp bytes_conn(org_id, plane_opts) do
    mount = driftwood_mount(:files, plane_opts)

    sopts =
      Plug.Session.init(
        store: :cookie,
        key: "_e2e",
        signing_salt: "salt_e2e",
        encryption_salt: "enc_e2e"
      )

    conn(:get, "/files/ignored")
    |> Map.put(:secret_key_base, String.duplicate("z", 64))
    |> Plug.Session.call(sopts)
    |> fetch_session()
    |> put_session(Samen.Web.CurrentOrg.session_key(), org_id)
    |> Map.put(:assigns, %{samen_mount: mount})
  end

  defp preview_html(org_id, file_id, plane_opts) do
    mount = driftwood_mount(:files, plane_opts)
    render_framework(PreviewLive, mount, [org_id, file_id], %{return_to: nil})
  end

  test "FULL LIFECYCLE: upload → quarantine → Noop promote → preview → byte-serve (AC-G14-1/4/5/7)" do
    org_id = Ash.UUID.generate()
    r = root()
    raw = "E2E-DRIFTWOOD-BYTES-#{System.unique_integer([:positive])}"

    # 1. UPLOAD via the chokepoint (the only governed path).
    {:ok, file} =
      Files.upload(
        %{org_id: org_id},
        %{filename: "manifest.txt", content_type: "text/plain", binary: raw},
        opts(r)
      )

    assert is_binary(file.storage_key) and file.storage_key != ""

    # 2. QUARANTINE — fresh file is fail-closed :quarantined.
    assert file.status == :quarantined

    # 2a. Byte-serve REFUSED while quarantined (403, before any scan).
    prev = Application.get_env(:samen_core, Samen.Files, [])
    Application.put_env(:samen_core, Samen.Files, storage: Local, storage_config: %{root: r})
    on_exit(fn -> Application.put_env(:samen_core, Samen.Files, prev) end)

    q_conn = bytes_conn(org_id, []) |> BytesController.serve(%{"id" => file.id})
    assert q_conn.status == 403
    assert q_conn.resp_body == "quarantined"

    # 2b. Preview shows the quarantine block, no byte-view.
    q_html = preview_html(org_id, file.id, [])
    assert q_html =~ ~s(id="preview-quarantined")
    refute q_html =~ ~s(id="preview-byte-view")

    # 3. PROMOTE via the Noop scanner (explicit operator opt-in — the ONLY auto-clean path).
    {:ok, promoted} =
      Files.promote(
        %{org_id: org_id},
        file,
        opts(r, scanner: Samen.Files.Scanner.Noop)
      )

    assert promoted.status == :active

    # 4. PREVIEW (tenant plane) — byte-view present, filename in the clear.
    html = preview_html(org_id, promoted.id, [])
    assert html =~ ~s(id="preview-byte-view")
    assert html =~ "manifest.txt"
    assert html =~ ~s(href="/files/#{promoted.id}/bytes")
    refute html =~ ~s(id="preview-quarantined")

    # 5. BYTE-SERVE (tenant, :active) — exact bytes, correct content-type.
    g_conn = bytes_conn(org_id, []) |> BytesController.serve(%{"id" => promoted.id})
    assert g_conn.status == 200
    assert g_conn.resp_body == raw
    assert get_resp_header(g_conn, "content-type") |> Enum.join() =~ "text/plain"

    # 6. OPERATOR plane byte-serve REFUSED even for the :active file.
    op_conn =
      bytes_conn(org_id, plane: :operator, target_org_id: org_id)
      |> BytesController.serve(%{"id" => promoted.id})

    assert op_conn.status == 403
    assert op_conn.resp_body == "operator-refused"
    refute op_conn.resp_body =~ raw
  end

  test "Reject scanner (default) HOLDS: promote leaves the file quarantined (RP-FI-3 fail-closed)" do
    org_id = Ash.UUID.generate()
    r = root()

    {:ok, file} =
      Files.upload(
        %{org_id: org_id},
        %{filename: "held.txt", content_type: "text/plain", binary: "held"},
        opts(r)
      )

    # Default scanner is Reject → :held → stays quarantined.
    assert {:ok, :held, still} = Files.promote(%{org_id: org_id}, file, opts(r))
    assert still.status == :quarantined
  end
end
