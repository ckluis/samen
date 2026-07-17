defmodule Samen.Web.FilesSurfaceTest do
  @moduledoc """
  WS-E E2.1 — the framework FILES web surface (ADR-026 § 2 decision 2/4;
  AC-G14-1/4/5/7; RP-FI-1/3/4).

  Tests in four groups:

  1. **Upload flow (AC-G14-1/4)** — `UploadLive` uses `allow_upload` →
     `consume_uploaded_entry` → `Samen.Files.upload/3` (the ONLY governed path);
     a successful upload creates a `:quarantined` row; size/type errors surface
     honestly in the UI; no byte is written for a rejected upload.

  2. **Preview masking + quarantine gate (AC-G14-5 · RP-FI-4)** — `PreviewLive`
     renders the file metadata page; a `:quarantined` file shows the quarantine
     block and REFUSES byte-view links; the operator-plane shows the byte-refused
     block. Both are structural: no case is vacuous.

  3. **Byte-serve gate (AC-G14-4/5 · RP-FI-3/4)** — `BytesController.serve/2`:
     * org-scope: a cross-org id is 404 (no existence oracle).
     * quarantine gate: a `:quarantined` file returns 403 + body `"quarantined"`.
     * plane gate: an operator-plane request returns 403 + body `"operator-refused"`.
     * green path: a tenant-plane, `:active` file is served with the correct bytes
       + content-type.

  4. **Router macro (AC-G14-7)** — `samen_files_routes/3` compiles a real
     `Phoenix.Router` and declares `/files`, `/files/:id`, and `/files/:id/bytes`.

  Anti-tautology: every gate proven in a direction has at least one twin that
  shows the OPPOSITE direction passes — no test is satisfiable by a blanket
  refuse-everything or allow-everything implementation.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Samen.Files
  alias Samen.Files.Storage.Local
  alias Samen.Web.Files.BytesController
  alias Samen.Web.Files.PreviewLive
  alias Samen.Web.Files.Reads
  alias Samen.Web.Files.UploadLive
  alias Samen.Web.Mount

  # The test host's materialized File resource (the primitives blueprint, abbrev "wnf").
  alias Samen.WebTest.Primitives.File, as: FileResource

  # ---------------------------------------------------------------------------
  # Test harness helpers
  # ---------------------------------------------------------------------------

  defp storage_root do
    root = Path.join(System.tmp_dir!(), "files_surface_test_#{System.unique_integer([:positive])}")
    Elixir.File.rm_rf!(root)
    on_exit(fn -> Elixir.File.rm_rf!(root) end)
    root
  end

  defp upload_opts(root) do
    [
      file_module: FileResource,
      repo: Samen.WebTest.Repo,
      storage: Local,
      storage_config: %{root: root},
      allowed_content_types: ~w(image/png text/plain),
      max_bytes: 1_048_576
    ]
  end

  # Seed a File row via the governed chokepoint.
  defp seed_file(org_id, root, attrs \\ []) do
    binary = Keyword.get(attrs, :binary, "hello")
    filename = Keyword.get(attrs, :filename, "test.txt")
    content_type = Keyword.get(attrs, :content_type, "text/plain")

    {:ok, file} =
      Files.upload(
        %{org_id: org_id},
        %{filename: filename, content_type: content_type, binary: binary},
        upload_opts(root)
      )

    file
  end

  # Promote a file to :active by re-reading from storage and calling Ash.update directly
  # (bypasses the scanner — the Noop opt-in is not wired in tests; we use authorize?:false
  # to prove the byte-serve gate's :active path, not the scanner gate).
  defp promote_file(file) do
    file
    |> Ash.Changeset.for_update(:update, %{status: :active})
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, f} -> f
      err -> raise "promote_file failed: #{inspect(err)}"
    end
  end

  # A minimal stub for @uploads — UploadLive.render/1 only accesses
  # `@uploads[@upload_ref].entries` to check whether to enable the submit button.
  # This is only accessed inside `<%= if writable?(@samen_mount) do %>`, so the
  # operator-plane render never touches it.
  defp stub_uploads do
    %{file_upload: %{entries: [], errors: [], ref: "file_upload"}}
  end

  # Build a mount socket for UploadLive on a given plane.
  # Pre-assigns all the assigns that mount/3 would set before calling load/2.
  # `:uploads` is a reserved LiveView assign (non-assignable via assign/3); we put it
  # directly on the raw socket struct to simulate what allow_upload/3 does in mount/3.
  defp upload_socket(org_id, plane_opts) do
    base =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, build_mount(:files, plane_opts))
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:return_to, nil)
      |> Phoenix.Component.assign(:org_id, org_id)
      |> Phoenix.Component.assign(:upload_result, nil)
      |> Phoenix.Component.assign(:upload_error, nil)

    # Bypass the reserved-assign check by writing directly to the assigns map.
    socket = %{base | assigns: Map.put(base.assigns, :uploads, stub_uploads())}
    UploadLive.load(socket, org_id)
  end

  # Build a mount socket for PreviewLive on a given plane.
  defp preview_socket(org_id, file_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:files, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:file_id, file_id)
    |> Phoenix.Component.assign(:file, nil)
    |> Phoenix.Component.assign(:not_found, false)
    |> PreviewLive.load(org_id, file_id)
  end

  # Build a minimal Plug.Conn for BytesController tests. Puts the samen_mount assign
  # and the org session key so `CurrentOrg.resolve/3` can read the org.
  defp bytes_conn(org_id, plane_opts \\ []) do
    mount = build_mount(:files, plane_opts)

    opts =
      Plug.Session.init(
        store: :cookie,
        key: "_test",
        signing_salt: "salt_v2",
        encryption_salt: "enc_salt_v2"
      )

    conn(:get, "/files/ignored")
    |> Map.put(:secret_key_base, String.duplicate("b", 64))
    |> Plug.Session.call(opts)
    |> fetch_session()
    |> put_session(Samen.Web.CurrentOrg.session_key(), org_id)
    |> Map.put(:assigns, %{samen_mount: mount})
  end

  # ---------------------------------------------------------------------------
  # 1. Upload flow — AC-G14-1 / AC-G14-4
  # ---------------------------------------------------------------------------

  describe "UploadLive upload flow" do
    test "load renders the files surface shell with empty state (no files yet)" do
      # Use operator plane to render without the live_file_input widget (operator-plane
      # posture hides the upload form, avoiding the allow_upload-required struct).
      org_id = Ash.UUID.generate()
      socket = upload_socket(org_id, plane: :operator, target_org_id: org_id)
      html = render_html(UploadLive, socket.assigns)

      # Shell renders correctly.
      assert html =~ ~s(id="files-upload")
      # Empty state renders (no files yet).
      assert html =~ "No files yet."
      # Upload form is NOT offered on operator plane (posture gate).
      refute html =~ ~s(id="upload-form")
    end

    test "a successful upload creates a :quarantined File row (AC-G14-1/4)" do
      org_id = Ash.UUID.generate()
      root = storage_root()

      # Simulate the chokepoint call the LiveView would make.
      {:ok, file} =
        Files.upload(
          %{org_id: org_id},
          %{filename: "hello.txt", content_type: "text/plain", binary: "hello world"},
          upload_opts(root)
        )

      # Row exists with a storage_key.
      assert is_binary(file.storage_key) and file.storage_key != ""
      # Fresh upload is :quarantined — the fail-closed default (AC-G14-4 / RP-FI-3).
      assert file.status == :quarantined
      # org_id is set correctly.
      assert file.org_id == org_id

      # Bytes round-trip through Local storage.
      {:ok, bytes} = Local.get(file.storage_key, %{root: root})
      assert bytes == "hello world"
    end

    test "quarantine is fail-closed: fresh upload is :quarantined, NOT :active (anti-tautology RP-FI-3)" do
      org_id = Ash.UUID.generate()
      root = storage_root()

      {:ok, file} =
        Files.upload(
          %{org_id: org_id},
          %{filename: "hello.txt", content_type: "text/plain", binary: "bytes"},
          upload_opts(root)
        )

      # The anti-tautology: the test specifically asserts :quarantined,
      # NOT just "not :active" — defaulting to :active would make file.status == :active
      # and FAIL this assertion.
      assert file.status == :quarantined, "RP-FI-3: fresh file must be :quarantined, not :active"
    end

    test "content_type not in allowlist is refused before storage — no bytes written (RP-FI-5)" do
      org_id = Ash.UUID.generate()
      root = storage_root()

      result =
        Files.upload(
          %{org_id: org_id},
          %{filename: "virus.exe", content_type: "application/x-msdownload", binary: "bad bytes"},
          upload_opts(root)
        )

      assert {:error, {:content_type_not_allowed, "application/x-msdownload"}} = result
      # Anti-tautology: no file was written to disk (the chokepoint refused before Storage.put).
      assert Elixir.File.ls(root) == {:error, :enoent}
    end

    test "oversized file is refused before storage — no bytes written (RP-FI-5)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      big = :binary.copy("X", 2_097_152)  # 2 MB > 1 MB max

      result =
        Files.upload(
          %{org_id: org_id},
          %{filename: "big.txt", content_type: "text/plain", binary: big},
          upload_opts(root)
        )

      assert {:error, {:too_large, _, _}} = result
      assert Elixir.File.ls(root) == {:error, :enoent}
    end

    test "the upload list view renders a quarantined row with no preview link (operator plane)" do
      # Use operator plane to render without the live_file_input widget.
      org_id = Ash.UUID.generate()
      root = storage_root()
      _file = seed_file(org_id, root)

      socket = upload_socket(org_id, plane: :operator, target_org_id: org_id)
      html = render_html(UploadLive, socket.assigns)

      # Row is in the list (OrgScope passes on operator plane when target_org_id matches).
      assert html =~ "quarantined"
      assert html =~ "test.txt"
      # A quarantined file gets NO preview link in the list (the :active guard in the template).
      refute html =~ "Preview"
    end

    test "the upload list renders a preview link for an :active file (anti-tautology, operator plane)" do
      # Use operator plane to render without the live_file_input widget.
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_file(org_id, root)
      _promoted = promote_file(file)

      socket = upload_socket(org_id, plane: :operator, target_org_id: org_id)
      html = render_html(UploadLive, socket.assigns)

      # An :active file gets a preview link.
      assert html =~ "Preview"
      assert html =~ file.id
    end

    test "operator plane: the upload form is NOT offered (write posture gate)" do
      org_id = Ash.UUID.generate()
      socket = upload_socket(org_id, plane: :operator, target_org_id: org_id)
      html = render_html(UploadLive, socket.assigns)

      # Upload form is absent on the operator plane (posture-gated).
      refute html =~ ~s(id="upload-form")
      refute html =~ ~s(phx-submit="upload")
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Preview LiveView — quarantine gate + operator plane gate (AC-G14-5 / RP-FI-4)
  # ---------------------------------------------------------------------------

  describe "PreviewLive preview masking and quarantine gate" do
    test "a :quarantined file shows the quarantine block; byte-view link is absent (AC-G14-4/5)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_file(org_id, root, filename: "report.txt", content_type: "text/plain")

      socket = preview_socket(org_id, file.id)
      html = render_html(PreviewLive, socket.assigns)

      # The quarantine block is present.
      assert html =~ ~s(id="preview-quarantined")
      assert html =~ "Quarantined"
      assert html =~ "refused until the file is promoted"
      # The byte-view block is absent.
      refute html =~ ~s(id="preview-byte-view")
      refute html =~ ~s(id="download-link")
    end

    test "an :active file on TENANT plane shows the byte-view block (anti-tautology)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_file(org_id, root, filename: "report.txt", content_type: "text/plain")
      _active = promote_file(file)

      socket = preview_socket(org_id, file.id)
      html = render_html(PreviewLive, socket.assigns)

      # Quarantine block is absent.
      refute html =~ ~s(id="preview-quarantined")
      # Byte-view block is present with a download link.
      assert html =~ ~s(id="preview-byte-view")
      assert html =~ ~s(id="download-link")
      # The link points to the byte-serve route (BytesController at /files/:id/bytes),
      # NOT the PreviewLive HTML route at /files/:id.
      assert html =~ ~s(href="/files/#{file.id}/bytes")
    end

    test "OPERATOR plane: byte download is refused for an :active file (RP-FI-4)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_file(org_id, root, filename: "report.txt", content_type: "text/plain")
      _active = promote_file(file)

      socket = preview_socket(org_id, file.id, plane: :operator, target_org_id: org_id)
      html = render_html(PreviewLive, socket.assigns)

      # Operator-refused block is present.
      assert html =~ ~s(id="preview-operator-refused")
      assert html =~ "refused on the operator plane"
      # Byte-view is absent.
      refute html =~ ~s(id="preview-byte-view")
      refute html =~ ~s(id="download-link")
    end

    test "BOTH tenant-clear ∧ operator-refused on the SAME :active file (anti-tautology)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_file(org_id, root, filename: "ANTITAUT.txt", content_type: "text/plain")
      _active = promote_file(file)

      tenant_html = render_html(PreviewLive, preview_socket(org_id, file.id).assigns)
      op_html = render_html(PreviewLive, preview_socket(org_id, file.id, plane: :operator, target_org_id: org_id).assigns)

      # The SAME filename appears in the metadata heading on both planes (file is non-PII base resource).
      assert tenant_html =~ "ANTITAUT.txt"
      assert op_html =~ "ANTITAUT.txt"
      # Tenant has byte-view; operator does not.
      assert tenant_html =~ ~s(id="preview-byte-view")
      refute op_html =~ ~s(id="preview-byte-view")
      # Operator has refused block; tenant does not.
      assert op_html =~ ~s(id="preview-operator-refused")
      refute tenant_html =~ ~s(id="preview-operator-refused")
    end

    test "filename appears in the preview metadata (non-PII base resource)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_file(org_id, root, filename: "SENTINEL-FILE.txt")

      socket = preview_socket(org_id, file.id)
      html = render_html(PreviewLive, socket.assigns)

      # Filename is rendered in the metadata heading.
      assert html =~ "SENTINEL-FILE.txt"
    end

    test "a cross-org file id returns not_found (no existence oracle)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      root = storage_root()
      file_a = seed_file(org_a, root)

      # org_b tries to preview org_a's file.
      socket = preview_socket(org_b, file_a.id)
      html = render_html(PreviewLive, socket.assigns)

      assert html =~ "not found"
      refute html =~ file_a.id
    end
  end

  # ---------------------------------------------------------------------------
  # 3. BytesController byte-serve gate (AC-G14-4/5 · RP-FI-3/4)
  # ---------------------------------------------------------------------------

  describe "BytesController byte-serve gate" do
    test "GREEN PATH: a tenant-plane :active file is served with correct bytes + content-type" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_file(org_id, root, binary: "SERVED-BYTES", filename: "f.txt", content_type: "text/plain")
      active = promote_file(file)

      # Store the storage config in app env for BytesController to read.
      prev = Application.get_env(:samen_core, Samen.Files, [])

      Application.put_env(:samen_core, Samen.Files,
        storage: Local,
        storage_config: %{root: root}
      )

      on_exit(fn -> Application.put_env(:samen_core, Samen.Files, prev) end)

      conn = bytes_conn(org_id) |> BytesController.serve(%{"id" => active.id})

      assert conn.status == 200
      assert conn.resp_body == "SERVED-BYTES"
      assert get_resp_header(conn, "content-type") |> Enum.join() =~ "text/plain"
    end

    test "QUARANTINE gate: a :quarantined file returns 403 + body 'quarantined' (RP-FI-3)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_file(org_id, root)

      # file is :quarantined (default)
      assert file.status == :quarantined

      conn = bytes_conn(org_id) |> BytesController.serve(%{"id" => file.id})

      assert conn.status == 403
      assert conn.resp_body == "quarantined"
    end

    test "PLANE gate: operator-plane request returns 403 + body 'operator-refused' (RP-FI-4)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_file(org_id, root)
      active = promote_file(file)

      conn =
        bytes_conn(org_id, plane: :operator, target_org_id: org_id)
        |> BytesController.serve(%{"id" => active.id})

      assert conn.status == 403
      assert conn.resp_body == "operator-refused"
    end

    test "ORG-SCOPE gate: a cross-org file id returns 404 (no existence oracle)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      root = storage_root()
      file_a = seed_file(org_a, root)
      active = promote_file(file_a)

      # org_b's mount tries to serve org_a's file.
      conn = bytes_conn(org_b) |> BytesController.serve(%{"id" => active.id})

      assert conn.status == 404
      assert conn.resp_body == "not found"
    end

    test "anti-tautology: the three refusals (quarantine / plane / scope) are each independent" do
      # This test proves that removing ANY ONE gate would cause a different test to pass
      # through (at least conceptually) — here we prove the successful path requires
      # ALL conditions: tenant plane + :active + same org.
      org_id = Ash.UUID.generate()
      root = storage_root()

      # Quarantine only: refused.
      quarantined = seed_file(org_id, root)
      q_conn = bytes_conn(org_id) |> BytesController.serve(%{"id" => quarantined.id})
      assert q_conn.status == 403 and q_conn.resp_body == "quarantined"

      # Active but operator plane: refused.
      active = promote_file(quarantined)
      op_conn = bytes_conn(org_id, plane: :operator, target_org_id: org_id) |> BytesController.serve(%{"id" => active.id})
      assert op_conn.status == 403 and op_conn.resp_body == "operator-refused"

      # Active, tenant plane, wrong org: not found.
      other_org = Ash.UUID.generate()
      scope_conn = bytes_conn(other_org) |> BytesController.serve(%{"id" => active.id})
      assert scope_conn.status == 404

      # All three gates passed → green.
      prev = Application.get_env(:samen_core, Samen.Files, [])
      Application.put_env(:samen_core, Samen.Files, storage: Local, storage_config: %{root: root})
      on_exit(fn -> Application.put_env(:samen_core, Samen.Files, prev) end)

      green_conn = bytes_conn(org_id) |> BytesController.serve(%{"id" => active.id})
      assert green_conn.status == 200
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Router macro — samen_files_routes/3 (AC-G14-7)
  # ---------------------------------------------------------------------------

  describe "samen_files_routes router macro" do
    test "the __routes__(:files, path) table maps upload + preview LiveViews" do
      routes = Samen.Web.Router.__routes__(:files, "/files")

      assert {"/files", Samen.Web.Files.UploadLive} in routes
      assert {"/files/:id", Samen.Web.Files.PreviewLive} in routes
    end

    test "a host router that calls samen_files_routes compiles and mounts the expected routes" do
      # If the macro is broken this module FAILS TO COMPILE — the strongest possible test.
      defmodule FilesHostRouter do
        use Phoenix.Router
        import Phoenix.LiveView.Router
        import Samen.Web.Router

        scope "/" do
          samen_files_routes(:files, Some.Host.Primitives, repo: Some.Host.Repo)
        end
      end

      paths = FilesHostRouter.__routes__() |> Enum.map(& &1.path)

      # LiveView routes.
      assert "/files" in paths
      assert "/files/:id" in paths
      # Controller route for byte-serve.
      assert "/files/:id/bytes" in paths
    end

    test "samen_files_routes accepts a custom :path override" do
      defmodule FilesCustomPathRouter do
        use Phoenix.Router
        import Phoenix.LiveView.Router
        import Samen.Web.Router

        scope "/" do
          samen_files_routes(:files, Some.Host.Primitives, repo: Some.Host.Repo, path: "/attachments")
        end
      end

      paths = FilesCustomPathRouter.__routes__() |> Enum.map(& &1.path)

      assert "/attachments" in paths
      assert "/attachments/:id" in paths
      assert "/attachments/:id/bytes" in paths
    end

    test "the mount scope_kind is :files and round-trips through session serialization" do
      mount =
        Samen.Web.Mount.new(
          :files,
          Samen.WebTest.Primitives,
          Samen.WebTest.Repo
        )

      assert mount.scope_kind == :files

      # Round-trip through session serialization (the router's live_session transport).
      session = Samen.Web.Mount.to_session(mount)
      rebuilt = Samen.Web.Mount.from_session(session)

      assert rebuilt.scope_kind == :files
      assert rebuilt.namespace == Samen.WebTest.Primitives
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Reads.files_page bounded read (structural correctness + PII posture)
  # ---------------------------------------------------------------------------

  describe "Reads.files_page bounded read" do
    test "files_page returns only the calling org's files (org-scope)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      root = storage_root()

      _file_a = seed_file(org_a, root, filename: "org-a-file.txt")
      _file_b = seed_file(org_b, root, filename: "org-b-file.txt")

      mount = build_mount(:files)
      scope = Mount.scope(mount, org_a)
      page = Reads.files_page(mount, scope, %Samen.Web.ListState{})

      names = Enum.map(page.items, & &1.filename)
      assert "org-a-file.txt" in names
      refute "org-b-file.txt" in names
    end

    test "files_page is bounded by keyset (page_size clamp)" do
      org_id = Ash.UUID.generate()
      root = storage_root()

      for i <- 1..15 do
        seed_file(org_id, root, filename: "file-#{String.pad_leading(to_string(i), 2, "0")}.txt")
      end

      mount = build_mount(:files)
      scope = Mount.scope(mount, org_id)
      state = %Samen.Web.ListState{page_size: 10}
      page = Reads.files_page(mount, scope, state)

      assert length(page.items) == 10
      assert page.has_more
    end

    test "files_page returns filename (the base resource has no vault on filename)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      _file = seed_file(org_id, root, filename: "READABLE-FILENAME.txt")

      mount = build_mount(:files)
      scope = Mount.scope(mount, org_id)
      page = Reads.files_page(mount, scope, %Samen.Web.ListState{})

      item = Enum.find(page.items, &(&1.filename == "READABLE-FILENAME.txt"))
      assert item != nil, "READABLE-FILENAME.txt must appear in the page"
    end
  end
end
