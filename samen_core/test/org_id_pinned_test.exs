defmodule Samen.OrgIdPinnedTest do
  @moduledoc """
  `Samen.Policy.OrgIdPinned` decides at ACTION time, not only when the changeset is built, and sees the
  write paths a build-time look cannot (identity-authz round 2, notes 9 and 11).

    * a changeset BUILT with `authorize?: false` and then RUN authorized is pinned (the pin re-checks when the
      action runs, from the authorization the run actually uses);
    * a changeset built normally and RUN with `authorize?: false` (the `Samen.Notifications.Digest` pattern) is
      system code at run time: its pin errors from the build still stand, nothing is re-checked at run time;
    * an atomic update whose own change writes `org_id` AFTER the pin has looked is still refused;
    * an authorized upsert that would rewrite `org_id` on a conflicting row, where `org_id` is not part of the
      identity it conflicts on (so it can take over ANOTHER org's row), is refused.

  The fixtures are purpose-built (no shipped resource writes `org_id` atomically, or upserts under an actor on an
  identity without it), so these prove the pin, not today's callers.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox

  @org_a "11111111-1111-4111-8111-111111111111"
  @org_b "22222222-2222-4222-8222-222222222222"

  # ── ETS: build/run authorization, non-atomic late writes, upsert ────────────

  defmodule Dom do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.OrgIdPinnedTest.Thing)
      resource(Samen.OrgIdPinnedTest.Doc)
      resource(Samen.OrgIdPinnedTest.ScopedThing)
    end
  end

  defmodule LateForce do
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      # runs AFTER the pin's own change (the action's changes follow the resource-level ones)
      Ash.Changeset.force_change_attribute(changeset, :org_id, "22222222-2222-4222-8222-222222222222")
    end
  end

  defmodule Thing do
    use Ash.Resource, domain: Samen.OrgIdPinnedTest.Dom, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, writable?: true)
      attribute(:slug, :string, public?: true)
      attribute(:name, :string, public?: true)
    end

    identities do
      identity(:unique_slug, [:slug], pre_check_with: Samen.OrgIdPinnedTest.Dom)
    end

    changes do
      change({Samen.Policy.OrgIdPinned, []}, on: [:create, :update])
    end

    actions do
      defaults([:read, create: :*, update: :*])

      create :upsert_by_slug do
        accept([:org_id, :slug, :name])
        upsert?(true)
        upsert_identity(:unique_slug)
        upsert_fields([:org_id, :name])
      end

      create :upsert_name_only do
        accept([:org_id, :slug, :name])
        upsert?(true)
        upsert_identity(:unique_slug)
        upsert_fields([:name])
      end

      update :late_force do
        accept([:name])
        require_atomic?(false)
        change(Samen.OrgIdPinnedTest.LateForce)
      end
    end
  end

  defmodule ScopedThing do
    use Ash.Resource, domain: Samen.OrgIdPinnedTest.Dom, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true, writable?: true)
      attribute(:slug, :string, public?: true)
      attribute(:name, :string, public?: true)
    end

    identities do
      identity(:unique_org_slug, [:org_id, :slug], pre_check_with: Samen.OrgIdPinnedTest.Dom)
    end

    changes do
      change({Samen.Policy.OrgIdPinned, []}, on: [:create, :update])
    end

    actions do
      defaults([:read, create: :*, update: :*])

      create :upsert_by_org_and_slug do
        accept([:org_id, :slug, :name])
        upsert?(true)
        upsert_identity(:unique_org_slug)
        upsert_fields([:org_id, :name])
      end
    end
  end

  # ── Postgres: an ATOMIC update whose change writes org_id after the pin looked ──

  defmodule LateAtomic do
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset

    @impl true
    def atomic(changeset, _opts, _context) do
      {:atomic, changeset, %{org_id: "22222222-2222-4222-8222-222222222222"}}
    end
  end

  defmodule Doc do
    use Ash.Resource, domain: Samen.OrgIdPinnedTest.Dom, data_layer: AshPostgres.DataLayer

    postgres do
      table("cpy_company")
      repo(SamenCore.TestRepo)
    end

    attributes do
      attribute(:id, :uuid, primary_key?: true, allow_nil?: false, public?: true, source: :cpy_id)
      attribute(:org_id, :uuid, public?: true, source: :cpy_org_id)
      attribute(:name, :string, public?: true, source: :cpy_name)
    end

    changes do
      change({Samen.Policy.OrgIdPinned, []}, on: [:create, :update])
    end

    actions do
      defaults([:read])

      update :late_atomic do
        accept([:name])
        require_atomic?(true)
        change(Samen.OrgIdPinnedTest.LateAtomic)
      end
    end
  end

  setup do
    :ok = Sandbox.checkout(SamenCore.TestRepo)
    :ok
  end

  defp actor(org), do: %{id: Ash.UUID.generate(), org_id: org}

  defp thing!(attrs), do: Ash.Seed.seed!(Thing, attrs)

  describe "note 9: the pin follows the authorization the action RUNS with" do
    test "RED: built with authorize?: false, then run authorized, a move to another org is refused" do
      row = thing!(%{org_id: @org_a, name: "n"})
      me = actor(@org_a)

      changeset = Ash.Changeset.for_update(row, :update, %{org_id: @org_b}, actor: me, authorize?: false)
      assert changeset.valid?, "built as system code: no build-time refusal"

      assert {:error, %Ash.Error.Invalid{errors: errors}} = Ash.update(changeset, actor: me, authorize?: true)
      assert Enum.any?(errors, &(Map.get(&1, :field) == :org_id))
      assert Ash.get!(Thing, row.id).org_id == @org_a
    end

    test "CONTROL: the same changeset run with authorize?: false is system code and moves the row" do
      row = thing!(%{org_id: @org_a, name: "n"})
      me = actor(@org_a)

      changeset = Ash.Changeset.for_update(row, :update, %{org_id: @org_b}, actor: me, authorize?: false)
      assert {:ok, %{org_id: @org_b}} = Ash.update(changeset, actor: me, authorize?: false)
    end

    test "the Digest pattern: built normally and run with authorize?: false still updates; an org_id change is a build-time error" do
      row = thing!(%{org_id: @org_a, name: "n"})
      me = actor(@org_a)

      # built normally, run as system code, no org_id involved: works exactly as before
      assert {:ok, %{name: "digest"}} =
               row |> Ash.Changeset.for_update(:update, %{name: "digest"}, actor: me) |> Ash.update(actor: me, authorize?: false)

      # the build-time pin still refuses an org_id change on a normally built changeset, whatever the run says
      changeset = Ash.Changeset.for_update(row, :update, %{org_id: @org_b}, actor: me)
      refute changeset.valid?
    end

    test "a late force_change_attribute from the action's own change is refused when authorized" do
      row = thing!(%{org_id: @org_a, name: "n"})
      me = actor(@org_a)

      assert {:error, %Ash.Error.Invalid{}} =
               row |> Ash.Changeset.for_update(:late_force, %{name: "x"}, actor: me) |> Ash.update(actor: me)

      assert Ash.get!(Thing, row.id).org_id == @org_a

      # CONTROL: as system code the same action is the sanctioned seed path
      assert {:ok, %{org_id: @org_b}} =
               row |> Ash.Changeset.for_update(:late_force, %{name: "x"}, authorize?: false) |> Ash.update(authorize?: false)
    end
  end

  describe "note 11a: an atomic update that writes org_id after the pin looked" do
    test "RED: the atomic change cannot move the row to another org" do
      {:ok, company} =
        SamenCore.TestRepo.query(
          "INSERT INTO cpy_company (cpy_name, cpy_org_id, cpy_inserted_at, cpy_updated_at) VALUES ('late', $1, now(), now()) RETURNING cpy_id",
          [Ecto.UUID.dump!(@org_a)]
        )

      [[id_bin]] = company.rows
      id = Ecto.UUID.load!(id_bin)
      me = actor(@org_a)

      result = Doc |> Ash.get!(id) |> Ash.Changeset.for_update(:late_atomic, %{name: "x"}, actor: me) |> Ash.update(actor: me)

      assert {:error, %Ash.Error.Invalid{errors: errors}} = result
      assert Enum.any?(errors, &(Map.get(&1, :field) == :org_id)), "refused by the pin, not by something else: #{inspect(errors)}"
      assert %{rows: [[org_bin]]} = SamenCore.TestRepo.query!("SELECT cpy_org_id FROM cpy_company WHERE cpy_id = $1", [id_bin])
      assert Ecto.UUID.load!(org_bin) == @org_a

      # and through a query-based bulk update, the other atomic entry point
      bulk =
        Doc
        |> Ash.Query.filter(id == ^id)
        |> Ash.bulk_update(:late_atomic, %{name: "x"}, actor: me, strategy: :atomic, return_errors?: true, return_records?: true)

      assert %Ash.BulkResult{status: status, errors: bulk_errors} = bulk
      assert status == :error or bulk_errors not in [nil, []], "the bulk atomic path must refuse it too: #{inspect(bulk)}"
      assert %{rows: [[org_bin2]]} = SamenCore.TestRepo.query!("SELECT cpy_org_id FROM cpy_company WHERE cpy_id = $1", [id_bin])
      assert Ecto.UUID.load!(org_bin2) == @org_a
    end
  end

  describe "note 11b: an authorized upsert cannot take over another org's row" do
    test "RED: an upsert on an identity without org_id that rewrites org_id is refused" do
      foreign = thing!(%{org_id: @org_b, slug: "shared", name: "theirs"})
      me = actor(@org_a)

      result =
        Thing
        |> Ash.Changeset.for_create(:upsert_by_slug, %{org_id: @org_a, slug: "shared", name: "mine"}, actor: me)
        |> Ash.create(actor: me)

      assert {:error, %Ash.Error.Invalid{errors: errors}} = result
      assert Enum.any?(errors, &(Map.get(&1, :field) == :org_id))
      assert %{org_id: @org_b, name: "theirs"} = Ash.get!(Thing, foreign.id)
    end

    test "RED: the same takeover through run options (upsert?: true, upsert_identity:) on a plain create is refused" do
      foreign = thing!(%{org_id: @org_b, slug: "opt", name: "theirs"})
      me = actor(@org_a)

      result =
        Thing
        |> Ash.Changeset.for_create(:create, %{org_id: @org_a, slug: "opt", name: "mine"}, actor: me)
        |> Ash.create(actor: me, upsert?: true, upsert_identity: :unique_slug, upsert_fields: [:org_id, :name])

      assert {:error, %Ash.Error.Invalid{errors: errors}} = result
      assert Enum.any?(errors, &(Map.get(&1, :field) == :org_id))
      assert Ash.get!(Thing, foreign.id).org_id == @org_b
    end

    test "CONTROL: a plain create is never mistaken for an upsert (Ash marks every create run with upsert?: true)" do
      me = actor(@org_a)

      assert {:ok, %{org_id: @org_a}} =
               Thing |> Ash.Changeset.for_create(:create, %{org_id: @org_a, slug: "plain", name: "n"}, actor: me) |> Ash.create(actor: me)
    end

    test "CONTROL: an upsert whose identity includes org_id, or that never writes org_id, still works" do
      mine = thing!(%{org_id: @org_a, slug: "own", name: "old"})
      scoped = Ash.Seed.seed!(ScopedThing, %{org_id: @org_a, slug: "own", name: "old"})
      me = actor(@org_a)

      assert {:ok, %{name: "new"}} =
               ScopedThing
               |> Ash.Changeset.for_create(:upsert_by_org_and_slug, %{org_id: @org_a, slug: "own", name: "new"}, actor: me)
               |> Ash.create(actor: me)

      assert {:ok, %{name: "newer"}} =
               Thing
               |> Ash.Changeset.for_create(:upsert_name_only, %{org_id: @org_a, slug: "own", name: "newer"}, actor: me)
               |> Ash.create(actor: me)

      assert Ash.get!(Thing, mine.id).org_id == @org_a
      assert Ash.get!(ScopedThing, scoped.id).name == "new"
    end

    test "CONTROL: as system code (authorize?: false) the same upsert is the sanctioned path" do
      foreign = thing!(%{org_id: @org_b, slug: "sys", name: "theirs"})

      assert {:ok, _} =
               Thing
               |> Ash.Changeset.for_create(:upsert_by_slug, %{org_id: @org_a, slug: "sys", name: "mine"}, authorize?: false)
               |> Ash.create(authorize?: false)

      assert Ash.get!(Thing, foreign.id).org_id == @org_a
    end
  end
end
