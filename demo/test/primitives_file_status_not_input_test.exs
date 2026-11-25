defmodule Demo.PrimitivesFileStatusNotInputTest do
  @moduledoc """
  A member could un-quarantine a File: `status` was a public attribute on the generic
  `:create`/`:update`, so `Ash.update(file, %{status: :active}, actor: member)` skipped the scan
  that `Samen.Files.promote/3`, `previewable?/1` and `fetch_bytes` rely on. `status` is no input on
  any actor write now; only the system action `:promote` (the scan verdict) sets `:active`.
  """
  use Demo.DataCase, async: false

  alias Demo.PrimitivesScope.File
  alias Demo.Identity.{Org, User}

  defp mk_org do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: "fs-#{:rand.uniform(999_999)}"}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_actor(org_id, role) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "fs-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "F", last: "S"},
        emails: ["fs#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp opts do
    [
      file_module: File,
      repo: Demo.Repo,
      scanner: Samen.Files.Scanner.Noop,
      max_bytes: 26_214_400,
      allowed_content_types: ~w(application/pdf)
    ]
  end

  defp quarantined(org_id) do
    {:ok, f} =
      Samen.Files.upload(
        %{org_id: org_id},
        %{filename: "q.pdf", content_type: "application/pdf", binary: :binary.copy("x", 64)},
        opts()
      )

    assert f.status == :quarantined
    f
  end

  test "RED: a member cannot set status on an update (the file stays quarantined)" do
    org = mk_org()
    member = mk_actor(org.id, :member)
    file = quarantined(org.id)

    assert {:error, _} =
             file
             |> Ash.Changeset.for_update(:update, %{status: :active}, actor: member.actor)
             |> Ash.update(actor: member.actor)

    assert Ash.get!(File, file.id, authorize?: false).status == :quarantined
  end

  test "RED: an admin cannot either, and status is no input on create" do
    org = mk_org()
    admin = mk_actor(org.id, :admin)
    file = quarantined(org.id)

    assert {:error, _} =
             file
             |> Ash.Changeset.for_update(:update, %{status: :active}, actor: admin.actor)
             |> Ash.update(actor: admin.actor)

    assert {:error, _} =
             File
             |> Ash.Changeset.for_create(
               :create,
               %{filename: "n.pdf", org_id: org.id, status: :active},
               actor: admin.actor
             )
             |> Ash.create(actor: admin.actor)
  end

  test "RED: no actor may run the :promote system action" do
    org = mk_org()
    admin = mk_actor(org.id, :admin)
    file = quarantined(org.id)

    assert {:error, %Ash.Error.Forbidden{}} =
             file |> Ash.Changeset.for_update(:promote, %{}, actor: admin.actor) |> Ash.update(actor: admin.actor)

    assert Ash.get!(File, file.id, authorize?: false).status == :quarantined
  end

  test "POSITIVE: a member still edits other fields, and the scan-gated promote path still activates" do
    org = mk_org()
    member = mk_actor(org.id, :member)
    file = quarantined(org.id)

    assert {:ok, renamed} =
             file
             |> Ash.Changeset.for_update(:update, %{filename: "renamed.pdf"}, actor: member.actor)
             |> Ash.update(actor: member.actor)

    assert renamed.filename == "renamed.pdf"
    assert renamed.status == :quarantined

    assert {:ok, promoted} = Samen.Files.promote(%{org_id: org.id}, renamed, opts())
    assert promoted.status == :active
  end
end
