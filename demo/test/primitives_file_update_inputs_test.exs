defmodule Demo.PrimitivesFileUpdateInputsTest do
  @moduledoc """
  `content_type`, `size_bytes` and `uploaded_by_id` are facts the UPLOAD records (`Samen.Files.upload/3`
  enforces the type allowlist and the size cap, then stamps them). `File :update` used to accept them, so a
  member could rewrite a scanned `text/plain` file as `text/html` or `application/javascript`: the byte route
  serves inline with the STORED content type, so that is same-origin scripting, and it skipped
  `Samen.Files.enforce/4` entirely.

  `:update` now takes only what a person may legitimately change (`filename`, `metadata`).
  """
  use Demo.DataCase, async: false

  alias Demo.PrimitivesScope.File
  alias Demo.Identity.{Org, User}

  defp mk_org do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: "fu-#{:rand.uniform(999_999)}"}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_actor(org_id, role) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "fu-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "F", last: "U"},
        emails: ["fu#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp upload!(org_id) do
    {:ok, f} =
      Samen.Files.upload(
        %{org_id: org_id},
        %{filename: "notes.txt", content_type: "text/plain", binary: "hello"},
        file_module: File,
        repo: Demo.Repo,
        scanner: Samen.Files.Scanner.Noop,
        max_bytes: 1024,
        allowed_content_types: ~w(text/plain)
      )

    f
  end

  defp update(file, input, actor) do
    file |> Ash.Changeset.for_update(:update, input, actor: actor) |> Ash.update(actor: actor)
  end

  test "RED: a member cannot rewrite the stored content type, size or uploader of a file" do
    org = mk_org()
    member = mk_actor(org.id, :member)
    file = upload!(org.id)

    for input <- [
          %{content_type: "text/html"},
          %{content_type: "application/javascript"},
          %{size_bytes: 1},
          %{uploaded_by_id: Ash.UUID.generate()}
        ] do
      assert {:error, %Ash.Error.Invalid{}} = update(file, input, member.actor), "accepted #{inspect(input)}"
    end

    stored = Ash.get!(File, file.id, authorize?: false)
    assert stored.content_type == "text/plain"
    assert stored.size_bytes == file.size_bytes
    assert stored.uploaded_by_id == file.uploaded_by_id
  end

  test "POSITIVE: a member still renames a file and edits its metadata" do
    org = mk_org()
    member = mk_actor(org.id, :member)
    file = upload!(org.id)

    assert {:ok, updated} = update(file, %{filename: "renamed.txt", metadata: %{"note" => "x"}}, member.actor)
    assert updated.filename == "renamed.txt"
    assert updated.metadata == %{"note" => "x"}
    assert updated.content_type == "text/plain"
  end
end
