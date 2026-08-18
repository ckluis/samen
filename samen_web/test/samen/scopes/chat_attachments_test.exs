defmodule Samen.Scopes.ChatAttachmentsTest do
  @moduledoc """
  T61 / C7 (A) — CHAT ATTACHMENTS through the Files chokepoint (INV-1).

  Proves, sabotage-refutably, that a chat attachment:

    * is minted ONLY through `Samen.Files.upload/3` — a direct `storage_key` write is
      structurally REFUSED by `Samen.Files.ChokepointGuard` (bypass fails; the chokepoint
      succeeds as the positive control);
    * lands `:quarantined` (fail-closed) and is NOT downloadable until a CLEAN scan
      promotes it to `:active` (the default `Scanner.Reject` leaves it held);
    * is ORG-SCOPED — an attachment on org A's message is unreachable from org B; and
    * renders in a server-rendered (no-JS) list whose filename is HTML-escaped (attacker
      filename inert) and whose download link is quarantine-gated.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Files
  alias Samen.Files.Storage.Local
  alias Samen.Scopes.Chat.Attachments
  alias Samen.Scopes.Chat.SearchComponents
  alias Samen.WebTest.Chat.ChatMessage
  alias Samen.WebTest.Primitives.File, as: FileResource

  # -- storage / opts ----------------------------------------------------------

  defp storage_root do
    root = Path.join(System.tmp_dir!(), "chat_attach_test_#{System.unique_integer([:positive])}")
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
      allowed_content_types: ~w(image/png text/plain application/pdf),
      max_bytes: 1_048_576
    ]
  end

  defp tenant_scope(org_id), do: Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_id)

  defp render(component, assigns) do
    SearchComponents
    |> apply(component, [Map.put(assigns, :__changed__, %{})])
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # ==========================================================================
  # Chokepoint + quarantine
  # ==========================================================================

  describe "chokepoint + quarantine (INV-1)" do
    test "an attachment routes through Files.upload/3 and lands :quarantined (fail-closed)" do
      org_id = Ash.UUID.generate()
      root = storage_root()

      assert {:ok, file} =
               Attachments.upload(
                 tenant_scope(org_id),
                 %{filename: "rate-conf.pdf", content_type: "application/pdf", binary: "PDF-BYTES"},
                 upload_opts(root)
               )

      # Fail-closed default: fresh attachment is quarantined, NOT viewable.
      assert file.status == :quarantined
      assert is_binary(file.storage_key)
      refute Files.previewable?(file)
    end

    test "a DIRECT storage_key write is REFUSED by the chokepoint (bypass fails) — sabotage-refutable" do
      org_id = Ash.UUID.generate()
      root = storage_root()

      # POSITIVE CONTROL: the sanctioned chokepoint path succeeds.
      assert {:ok, _governed} =
               Attachments.upload(
                 tenant_scope(org_id),
                 %{filename: "ok.pdf", content_type: "application/pdf", binary: "OK"},
                 upload_opts(root)
               )

      # SABOTAGE: a direct create that mints its own storage_key must be structurally
      # refused (ChokepointGuard) — an ungoverned file row is impossible by construction.
      assert {:error, _} =
               FileResource
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org_id,
                 filename: "smuggled.pdf",
                 content_type: "application/pdf",
                 storage_key: "ungoverned-key-#{System.unique_integer([:positive])}",
                 status: :active
               })
               |> Ash.create(authorize?: false)
    end

    test "a quarantined attachment is NOT downloadable until a CLEAN scan promotes it" do
      org_id = Ash.UUID.generate()
      root = storage_root()

      {:ok, file} =
        Attachments.upload(
          tenant_scope(org_id),
          %{filename: "scan-me.pdf", content_type: "application/pdf", binary: "BYTES"},
          upload_opts(root)
        )

      # Default scanner (Scanner.Reject) HOLDS — stays quarantined, still not viewable.
      assert {:ok, :held, held} = Files.promote(%{org_id: org_id}, file, upload_opts(root))
      assert held.status == :quarantined
      refute Files.previewable?(held)

      # A clean scan (Scanner.Noop, explicit opt-in) promotes to :active → viewable.
      assert {:ok, active} =
               Files.promote(
                 %{org_id: org_id},
                 file,
                 Keyword.put(upload_opts(root), :scanner, Samen.Files.Scanner.Noop)
               )

      assert active.status == :active
      assert Files.previewable?(active)
    end
  end

  # ==========================================================================
  # Org-scope
  # ==========================================================================

  describe "org-scope (org B can't reach org A's attachment)" do
    test "load returns the file for its own org and NOTHING for a foreign org" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      root = storage_root()

      {:ok, file} =
        Attachments.upload(
          tenant_scope(org_a),
          %{filename: "org-a-only.pdf", content_type: "application/pdf", binary: "A"},
          upload_opts(root)
        )

      # POSITIVE CONTROL: org A loads its own attachment.
      assert [loaded] =
               Attachments.load(tenant_scope(org_a), [file.storage_key], file_module: FileResource)

      assert loaded.id == file.id

      # ORG B cannot reach org A's attachment — OrgScope narrows to zero rows.
      assert [] = Attachments.load(tenant_scope(org_b), [file.storage_key], file_module: FileResource)
    end

    test "a storage_key stored on a ChatMessage.attachments array round-trips org-scoped" do
      org_id = Ash.UUID.generate()
      root = storage_root()
      chat = Seeds.seed_chat(org_id)

      {:ok, file} =
        Attachments.upload(
          tenant_scope(org_id),
          %{filename: "in-thread.pdf", content_type: "application/pdf", binary: "T"},
          upload_opts(root)
        )

      {:ok, message} =
        ChatMessage
        |> Ash.Changeset.for_create(:create, %{
          org_id: org_id,
          thread_id: chat.thread.id,
          participant_id: chat.tenant_participant.id,
          sender_party: :tenant,
          kind: :message,
          body: "Here is the doc.",
          attachments: [file.storage_key]
        })
        |> Ash.create(authorize?: false)

      assert message.attachments == [file.storage_key]
      # The array holds the GOVERNED storage_key (chokepoint-minted), never a raw write.
      assert [loaded] =
               Attachments.load(tenant_scope(org_id), message.attachments, file_module: FileResource)

      assert loaded.id == file.id
    end
  end

  # ==========================================================================
  # Server-rendered attachment list — quarantine-gated + XSS-safe
  # ==========================================================================

  describe "attachment_list rendering (no-JS, quarantine-gated, XSS-safe)" do
    test "an attacker filename is INERT and a quarantined file gets NO download link" do
      org_id = Ash.UUID.generate()
      root = storage_root()

      {:ok, file} =
        Attachments.upload(
          tenant_scope(org_id),
          %{
            filename: "<script>alert('x')</script>evil.pdf",
            content_type: "application/pdf",
            binary: "E"
          },
          upload_opts(root)
        )

      [loaded] = Attachments.load(tenant_scope(org_id), [file.storage_key], file_module: FileResource)

      html = render(:attachment_list, %{files: [loaded]})

      # XSS-safe: the attacker filename is escaped, never a live script tag.
      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;"
      # Quarantine-gated: no /files/:id download link for a non-:active file.
      refute html =~ "/files/#{loaded.id}"
      assert html =~ "Scanning"
    end

    test "a promoted (:active) file renders a download link keyed by file id" do
      org_id = Ash.UUID.generate()
      root = storage_root()

      {:ok, file} =
        Attachments.upload(
          tenant_scope(org_id),
          %{filename: "clean.pdf", content_type: "application/pdf", binary: "C"},
          upload_opts(root)
        )

      {:ok, active} =
        Files.promote(
          %{org_id: org_id},
          file,
          Keyword.put(upload_opts(root), :scanner, Samen.Files.Scanner.Noop)
        )

      [loaded] = Attachments.load(tenant_scope(org_id), [active.storage_key], file_module: FileResource)

      html = render(:attachment_list, %{files: [loaded]})
      assert html =~ "/files/#{loaded.id}"
      assert html =~ "clean.pdf"
      # The opaque storage_key is NEVER rendered into the DOM.
      refute html =~ loaded.storage_key
    end
  end
end
