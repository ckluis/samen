defmodule Samen.Hardening.FilesChokepointFailClosedTest do
  @moduledoc """
  Fail-closed PROOF for the one `Samen.Files.ChokepointGuard` clause the ADR-049 mutation
  gate found SURVIVING (ledgered ACCEPTED_GAP as MG-07): `sets_storage_key?/1`'s
  `{:ok, nil} -> false` arm — "an untouched storage_key, OR AN EXPLICIT NIL, is not a mint"
  (line 144 on `0216ce8`; `false` → `true`).

  Verified RED-FIRST by hand: with that literal flipped the named test below fails, and it
  passes again on the byte-exact restored source. The shipped behaviour is unchanged.
  """
  use ExUnit.Case, async: false

  alias Samen.Files
  alias Samen.Files.Storage.Local
  alias SamenCore.Support.NotificationFixture.File, as: FileResource
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    root =
      Path.join(System.tmp_dir!(), "hardening_chokepoint_#{System.unique_integer([:positive])}")

    Elixir.File.rm_rf!(root)
    on_exit(fn -> Elixir.File.rm_rf!(root) end)

    %{storage_config: %{root: root}}
  end

  defp base_opts(ctx) do
    [
      file_module: FileResource,
      repo: TestRepo,
      storage: Local,
      storage_config: ctx.storage_config,
      max_bytes: 1_000_000,
      allowed_content_types: ~w(text/plain)
    ]
  end

  defp governed_file!(ctx) do
    scope = %{org_id: Ash.UUID.generate(), actor_id: Ash.UUID.generate()}

    payload = %{filename: "hello.txt", content_type: "text/plain", binary: "the quick brown fox"}

    {:ok, file} = Files.upload(scope, payload, base_opts(ctx))
    file
  end

  defp messages(%Ash.Error.Invalid{} = err), do: Exception.message(err)
  defp messages(other), do: inspect(other)

  describe "MG-07 — an explicit nil storage_key is NOT a mint (line 144)" do
    test "MG-07: a destroy-typed changeset whose storage_key is explicitly NILLED is ALLOWED",
         ctx do
      file = governed_file!(ctx)

      # The `:destroy`-typed path is the only one on which an explicit nil `storage_key`
      # reaches the guard at all: on create/update Ash's own `allow_nil?: false` required
      # rule refuses a nil before any `before_action` hook runs. A hard destroy writes no
      # column, so the guard's verdict is the ONLY thing standing between this changeset and
      # the DELETE — and its verdict must be ALLOW, because a nil repoints nothing and mints
      # no ungoverned pointer. Flipping `{:ok, nil} -> false` to `true` makes
      # `sets_storage_key?/1` read the clear as a mint and the guard refuses.
      assert :ok =
               file
               |> Ash.Changeset.for_destroy(:destroy_permanently, %{})
               |> Ash.Changeset.force_change_attribute(:storage_key, nil)
               |> Ash.destroy(authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = Ash.get(FileResource, file.id, authorize?: false)
    end

    test "CONTROL (anti-tautology): the SAME destroy shape with a NON-nil storage_key IS refused",
         ctx do
      file = governed_file!(ctx)
      smuggled = "#{file.storage_key}-smuggled"

      result =
        file
        |> Ash.Changeset.for_destroy(:destroy_permanently, %{})
        |> Ash.Changeset.force_change_attribute(:storage_key, smuggled)
        |> Ash.destroy(authorize?: false)

      assert {:error, error} = result
      assert messages(error) =~ "ungoverned-file-row"

      # No residue — the row is still there, still pointing at the governed key.
      reloaded = Ash.get!(FileResource, file.id, authorize?: false)
      assert reloaded.storage_key == file.storage_key
    end

    test "CONTROL (anti-tautology): a NON-nil ungoverned UPDATE repoint IS refused as a mint",
         ctx do
      file = governed_file!(ctx)

      result =
        file
        |> Ash.Changeset.for_update(:update, %{storage_key: "#{file.org_id}/SMUGGLED"})
        |> Ash.update(authorize?: false)

      assert {:error, error} = result
      assert messages(error) =~ "ungoverned-file-row"
      assert Ash.get!(FileResource, file.id, authorize?: false).storage_key == file.storage_key
    end
  end
end
