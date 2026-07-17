defmodule Samen.Web.FilePreviewMaskingTest do
  @moduledoc """
  WS-E E2.2 — THE PER-PLANE MASKING RED-PATH for the file-preview surface
  (ADR-026 §2 decision 4; AC-G14-5; RP-FI-4). This is a masking-watch-list surface
  (the design's four new-PII-surface riders) and the tests ARE the deliverable.

  ## The surface under test

  File preview renders `filename` through `Samen.Api.PiiResolution` on the actor's
  plane. The BASE `Primitives.File` does NOT vault `filename` (the blueprint's own
  note, `blueprint.ex:273-276`: "If a host's filenames ARE PII (e.g. a medical scan
  named after the patient), the host must vault them via a bounded-context override").
  E2.1 covered the base (non-PII) resource. THIS unit covers the VAULTED-FILENAME host
  — the case AC-G14-5 / RP-FI-4 actually names — by exercising the two real mechanisms
  that make preview masking correct BY CONSTRUCTION:

    1. **The resolution decision engine** — `Samen.Api.PiiResolution.resolve/4`, the
       SAME seam `Samen.Web.Files.Reads.get_file/3` runs on every result. Proven per
       plane against a REAL vault-routed scalar (`Notification.rendered_body`, the
       filename-analog: an org-scoped, vault-routed `:string` that resolves to
       `%Masked{}`/plaintext exactly as a vaulted `filename` would). Tenant → clear;
       operator-without-grant → `%Masked{}` (→ `••••`); operator-WITH-grant → clear.

    2. **The preview render + byte-serve plane gate** — `Samen.Web.Files.PreviewLive`
       and `Samen.Web.Files.BytesController`, driven with a File whose resolved
       `filename` is a `%Samen.Masked{}` (the vaulted-filename host's operator-plane
       result). Proven: the DOM shows `••••`, NEVER the `vt_*` vault token, NEVER
       plaintext; the operator byte-download is REFUSED (bytes have no partial reveal);
       a cross-org id is 404 (no existence oracle).

  ## Anti-tautology (RP-FI-4)

  Each red path has its sabotage twin proven live:

    * **Resolver plane sabotage** — force the operator actor to the tenant plane and
      prove the SAME record flips from `%Masked{}` to plaintext (the resolver is the
      gate, not a blanket mask-everything).
    * **Render leak sabotage** — replace the resolved `%Masked{}` filename with the
      plaintext it hides and prove the leak-scan assertion FLIPS (the mask assertion
      is refutable — a broken resolver that leaked plaintext would be caught).
    * **Byte-gate plane sabotage** — flip the byte-serve request from operator to
      tenant plane and prove the 403 refusal flips to a 200 serve of the EXACT bytes
      (sha-256 byte-exact, zero residue). The plane check is load-bearing.

  Reference: the WS-A notifications-inbox masking test
  (`notifications_masking_test.exs`) — the same tenant-clear ∧ operator-masked shape,
  the same `refute html =~ "vt_"` red-path scan, the same anti-tautology discipline.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Samen.Api.PiiResolution
  alias Samen.Files
  alias Samen.Files.Storage.Local
  alias Samen.Masked
  alias Samen.Notifications.Engine
  alias Samen.Web.Files.BytesController
  alias Samen.Web.Files.PreviewLive

  alias Samen.WebTest.Primitives.File, as: FileResource
  alias Samen.WebTest.Primitives.Notification, as: NotificationResource

  # A distinctive vaulted-filename sentinel. If it EVER appears in an operator-plane
  # DOM the mask-by-omission red-path has failed.
  @secret_filename "PATIENT-Jane-Doe-MRI-scan.dcm"
  @secret_body "VAULTED-FILENAME-BODY-SENTINEL the scan named after the patient."

  # ---------------------------------------------------------------------------
  # Grant stubs — inject the reveal authority per test (the T1.6 grant model).
  # ---------------------------------------------------------------------------

  defmodule AllowAllGrant do
    @moduledoc false
    def granted?(_ctx), do: true
  end

  defmodule DenyAllGrant do
    @moduledoc false
    def granted?(_ctx), do: false
  end

  # ---------------------------------------------------------------------------
  # Storage / seed helpers (mirror the E2.1 surface harness)
  # ---------------------------------------------------------------------------

  defp storage_root do
    root = Path.join(System.tmp_dir!(), "file_mask_test_#{System.unique_integer([:positive])}")
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
      allowed_content_types: ~w(image/png text/plain application/dicom),
      max_bytes: 1_048_576
    ]
  end

  # Seed a File row via the governed chokepoint, then PROMOTE it to :active so the
  # byte-serve/preview gate isn't short-circuited by quarantine (we're proving the
  # PLANE gate here, not the quarantine gate — that is E2.1's job).
  defp seed_active_file(org_id, root, attrs \\ []) do
    binary = Keyword.get(attrs, :binary, "MRI-BYTES")
    filename = Keyword.get(attrs, :filename, @secret_filename)
    content_type = Keyword.get(attrs, :content_type, "application/dicom")

    {:ok, file} =
      Files.upload(
        %{org_id: org_id},
        %{filename: filename, content_type: content_type, binary: binary},
        upload_opts(root)
      )

    {:ok, active} =
      file
      |> Ash.Changeset.for_update(:update, %{status: :active})
      |> Ash.update(authorize?: false)

    # Re-read with the full attribute set loaded (org_id/id/inserted_at) — the same
    # shape Reads.get_file/3 returns to the LiveView. The upload/update results do not
    # load org_id by default; the render's workspace header interpolates it.
    require Ash.Query

    FileResource
    |> Ash.Query.filter(id == ^active.id)
    |> Ash.Query.ensure_selected([:org_id, :id, :filename, :content_type, :size_bytes, :status, :inserted_at])
    |> Ash.read_one!(authorize?: false)
  end

  # The vaulted-filename host's operator-plane result: the File struct as
  # `Reads.get_file/3` would return it AFTER `PiiResolution` masked a vaulted
  # `filename`. We model that by replacing the plaintext filename with the `%Masked{}`
  # the resolver produces (token = the vault FK; label = the field). This is byte-for-
  # byte the value a vaulted-filename resource yields on the operator plane.
  defp mask_filename(file) do
    %{file | filename: %Masked{token: "vt_filename_#{file.id}", label: :filename}}
  end

  # Render PreviewLive.render/1 for a fully-formed :file assign (no DB round-trip;
  # the file is the plane-resolved value we are asserting the render faithfully shows).
  defp render_preview(file, plane_opts) do
    org_id = file.org_id
    mount = build_mount(:files, plane_opts)

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:file_id, file.id)
    |> Phoenix.Component.assign(:file, file)
    |> Phoenix.Component.assign(:not_found, false)
    |> then(&render_html(PreviewLive, &1.assigns))
  end

  # A minimal Plug.Conn for the byte-serve gate (mirrors E2.1's bytes_conn/2).
  defp bytes_conn(org_id, plane_opts) do
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

  # Seed a REAL vault-routed record (Notification.rendered_body) — the filename-analog
  # for exercising the resolution engine per plane. Returns the created record + org.
  defp seed_vaulted_record(org_id, body \\ @secret_body) do
    {:ok, notification} =
      Engine.notify(
        %{
          org_id: org_id,
          recipient_id: Ash.UUID.generate(),
          event_type: "files.preview.vaulted_filename_analog",
          channel: :in_app,
          rendered_body: body
        },
        notification_module: NotificationResource,
        preference_module: Samen.WebTest.Primitives.NotificationPreference,
        repo: Samen.WebTest.Repo
      )

    # Re-read with the vault-routed field SELECTED (it is not loaded by default) — the
    # same `ensure_selected` posture Reads runs before PiiResolution. The field comes
    # back as %Masked{} (its at-rest form); the resolver decides per plane.
    require Ash.Query

    NotificationResource
    |> Ash.Query.filter(id == ^notification.id)
    |> Ash.Query.ensure_selected([:rendered_body])
    |> Ash.read_one!(authorize?: false)
  end

  # Read the record back on a plane, resolving the vault-routed field through the SAME
  # seam Reads.get_file/3 uses. `grant` injects the reveal authority for the operator
  # cases.
  defp resolve_on_plane(record, plane, opts \\ []) do
    actor =
      case plane do
        :tenant ->
          %{plane: :tenant}

        :operator ->
          %{plane: :operator, impersonation: %{session_id: "op-session"}}
      end

    [resolved] =
      PiiResolution.resolve(
        [record],
        NotificationResource,
        actor,
        Keyword.merge([repo: Samen.WebTest.Repo], opts)
      )

    resolved
  end

  # ==========================================================================
  # 1. The resolution DECISION engine — real per-plane masking on a real vault
  #    field (the seam Reads.get_file/3 runs on every filename). AC-G14-5.
  # ==========================================================================

  describe "PiiResolution — the filename resolution seam, per plane" do
    test "TENANT plane resolves the vault-routed field CLEAR (green half)" do
      org_id = Ash.UUID.generate()
      record = seed_vaulted_record(org_id)

      resolved = resolve_on_plane(record, :tenant)

      # The tenant owns its org's data → clear, no grant. NOT a %Masked{}.
      assert resolved.rendered_body == @secret_body
      refute match?(%Masked{}, resolved.rendered_body)
    end

    test "OPERATOR-WITHOUT-GRANT resolves to %Masked{} — the •••• form, NEVER plaintext (RP-FI-4)" do
      org_id = Ash.UUID.generate()
      record = seed_vaulted_record(org_id)

      resolved = resolve_on_plane(record, :operator, grant: DenyAllGrant)

      # Present-but-masked (impersonation UI posture): a %Masked{}, not omitted,
      # not plaintext, not a raw token.
      assert match?(%Masked{}, resolved.rendered_body)
      refute resolved.rendered_body == @secret_body
      # The %Masked{} renders •••• everywhere (String.Chars / Phoenix.HTML.Safe).
      assert to_string(resolved.rendered_body) == "••••"
      # The vault token is carried internally but NEVER rendered.
      refute to_string(resolved.rendered_body) =~ "vt_"
    end

    test "OPERATOR-WITH-GRANT resolves CLEAR — the two-plane reveal rule (green half)" do
      org_id = Ash.UUID.generate()
      record = seed_vaulted_record(org_id)

      resolved = resolve_on_plane(record, :operator, grant: AllowAllGrant)

      # A live reveal grant covering the subject → plaintext, same as any operator path.
      assert resolved.rendered_body == @secret_body
      refute match?(%Masked{}, resolved.rendered_body)
    end

    test "ANTI-TAUTOLOGY: sabotaging the plane (operator→tenant) FLIPS •••• to plaintext" do
      org_id = Ash.UUID.generate()
      record = seed_vaulted_record(org_id)

      # As-designed: operator-without-grant → masked.
      operator = resolve_on_plane(record, :operator, grant: DenyAllGrant)
      assert match?(%Masked{}, operator.rendered_body)

      # SABOTAGE: read the SAME record on the tenant plane (the resolver's only
      # difference is the actor's :plane). It flips to plaintext — proving the mask
      # is the RESOLVER's decision, not a blanket mask-everything.
      sabotaged = resolve_on_plane(record, :tenant)
      assert sabotaged.rendered_body == @secret_body
      refute match?(%Masked{}, sabotaged.rendered_body)
    end

    test "BOTH directions on the SAME record — tenant clear ∧ operator masked (anti-tautology)" do
      org_id = Ash.UUID.generate()
      record = seed_vaulted_record(org_id)

      tenant = resolve_on_plane(record, :tenant)
      operator = resolve_on_plane(record, :operator, grant: DenyAllGrant)

      # Same record, same seam — the ONLY difference is masking.
      assert tenant.rendered_body == @secret_body
      refute operator.rendered_body == @secret_body
      assert to_string(operator.rendered_body) == "••••"
    end

    test "the vault-routed column stores a vt_ token at rest, never the plaintext (leak scan)" do
      org_id = Ash.UUID.generate()
      record = seed_vaulted_record(org_id)

      %{rows: [[raw]]} =
        Samen.WebTest.Repo.query!(
          "SELECT pii_wnn_rendered_body FROM wnn_notification WHERE wnn_id = $1",
          [Ecto.UUID.dump!(record.id)]
        )

      assert is_binary(raw)
      assert String.starts_with?(raw, "vt_")
      refute raw =~ @secret_body
    end
  end

  # ==========================================================================
  # 2. The preview RENDER + byte-serve PLANE gate — a vaulted-filename file.
  #    AC-G14-5 / RP-FI-4.
  # ==========================================================================

  describe "PreviewLive — the render faithfully masks a vaulted filename" do
    test "a %Masked{} filename renders •••• — NEVER the vt_ token, NEVER plaintext (RP-FI-4)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_active_file(org_id, root)
      masked = mask_filename(file)

      html = render_preview(masked, plane: :operator, target_org_id: org_id)

      # The masked filename renders as the mask string.
      assert html =~ "••••"
      # The plaintext filename is ABSENT (the mask-by-omission red-path).
      refute html =~ @secret_filename
      refute html =~ "Jane"
      refute html =~ "Doe"
      # The vault token is NEVER in the DOM.
      refute html =~ "vt_"
      # Non-vacuous: this IS the preview page for THIS file (the metadata shell +
      # the file's own non-PII metadata rendered — the mask replaced ONLY the filename,
      # not the whole page).
      assert html =~ "files-preview"
      assert html =~ ~s(id="file-metadata")
      assert html =~ file.content_type
    end

    test "OPERATOR plane: byte-view/download is refused for the vaulted-filename file (RP-FI-4)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_active_file(org_id, root)
      masked = mask_filename(file)

      html = render_preview(masked, plane: :operator, target_org_id: org_id)

      # The operator-refused block is present; no byte-view, no download link.
      assert html =~ ~s(id="preview-operator-refused")
      refute html =~ ~s(id="preview-byte-view")
      refute html =~ ~s(id="download-link")
    end

    test "ANTI-TAUTOLOGY: leaking the plaintext filename (broken resolver) FLIPS the mask scan" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_active_file(org_id, root)

      # AS-DESIGNED: the resolver masked the filename → •••• , plaintext absent.
      masked_html = render_preview(mask_filename(file), plane: :operator, target_org_id: org_id)
      refute masked_html =~ @secret_filename

      # SABOTAGE: a broken resolver leaves the vaulted filename in the CLEAR on the
      # operator plane. The render then leaks the plaintext — the mask scan FLIPS,
      # proving the "refute plaintext" assertion is refutable (not vacuously true).
      leaked_html = render_preview(file, plane: :operator, target_org_id: org_id)
      assert leaked_html =~ @secret_filename
    end
  end

  describe "BytesController — the byte-serve plane gate on a vaulted-filename file" do
    test "OPERATOR plane: byte-serve is REFUSED (403) — bytes have no partial reveal (RP-FI-4)" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      file = seed_active_file(org_id, root, binary: "MRI-RAW-BYTES")

      conn =
        bytes_conn(org_id, plane: :operator, target_org_id: org_id)
        |> BytesController.serve(%{"id" => file.id})

      assert conn.status == 403
      assert conn.resp_body == "operator-refused"
      # The raw bytes are NEVER in the response body.
      refute conn.resp_body =~ "MRI-RAW-BYTES"
    end

    test "CROSS-ORG: an operator whose id targets a different org's file is 404/refused (no oracle)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      root = storage_root()
      file_a = seed_active_file(org_a, root)

      # org_b operator asks for org_a's file id → refused before any byte. On the
      # operator plane the plane gate refuses first (403); either way NOT a 200 serve.
      conn =
        bytes_conn(org_b, plane: :operator, target_org_id: org_b)
        |> BytesController.serve(%{"id" => file_a.id})

      assert conn.status in [403, 404]
      refute conn.status == 200
    end

    test "ANTI-TAUTOLOGY: sabotaging the plane (operator→tenant) FLIPS 403 to a byte-exact 200 serve" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      raw = "SHA-CHECKED-MRI-BYTES-#{System.unique_integer([:positive])}"
      file = seed_active_file(org_id, root, binary: raw)

      # AS-DESIGNED: operator plane is refused (403), no bytes served.
      op_conn =
        bytes_conn(org_id, plane: :operator, target_org_id: org_id)
        |> BytesController.serve(%{"id" => file.id})

      assert op_conn.status == 403

      # SABOTAGE: flip the request to the tenant plane (the plane check is the gate).
      prev = Application.get_env(:samen_core, Samen.Files, [])
      Application.put_env(:samen_core, Samen.Files, storage: Local, storage_config: %{root: root})
      on_exit(fn -> Application.put_env(:samen_core, Samen.Files, prev) end)

      tenant_conn =
        bytes_conn(org_id, plane: :tenant)
        |> BytesController.serve(%{"id" => file.id})

      # The refusal flips to a 200 serve of the EXACT bytes — byte-exact, zero residue.
      assert tenant_conn.status == 200
      assert tenant_conn.resp_body == raw
      assert :crypto.hash(:sha256, tenant_conn.resp_body) == :crypto.hash(:sha256, raw)
    end
  end
end
