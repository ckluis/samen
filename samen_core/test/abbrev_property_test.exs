defmodule Samen.AbbrevPropertyTest do
  @moduledoc """
  T1.1 property: for arbitrary attribute names, storage name == `abbrev <> "_" <>
  name`, and create/read via the *logical* name round-trips.

  Two properties:

    * **prefix property** — dynamically compile a resource with StreamData-generated
      attribute names and assert every attribute's `:source` is exactly
      `"<abbrev>_<name>"` while the logical name is untouched.
    * **round-trip property** — for arbitrary string values written to the logical
      fields of a persisted fixture, create then read-back returns the same values.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  require Ash.Query
  alias Ash.Resource.Info

  setup do
    # StreamData runs the property body in the test process, but Ash/Ecto may hand
    # work to pool processes; shared sandbox mode (safe under async: false) lets
    # them all see the same checked-out connection.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(SamenCore.TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(SamenCore.TestRepo, {:shared, self()})
    :ok
  end

  # A valid Elixir/Ash attribute name atom: lowercase letters/digits/underscore,
  # starting with a letter, not colliding with the injected core columns.
  @reserved ~w(id org_id inserted_at updated_at)a

  defp attr_name do
    gen all(
          first <- StreamData.string(?a..?z, length: 1),
          rest <- StreamData.string([?a..?z, ?0..?9, ?_..?_], min_length: 0, max_length: 10),
          name = String.to_atom(first <> rest),
          name not in @reserved
        ) do
      name
    end
  end

  # Fixed module name owning the registered "pgn" abbrev. We recompile it with
  # different attribute sets each run (purging between), so the registry sees the
  # same one-owner mapping every time — proving the *real* production path
  # (`use Samen.Resource` + registry + transformer) end to end, not just internals.
  @gen_module SamenCore.Support.PropGen

  property "every attribute's storage source is `<abbrev>_<name>`; logical name untouched" do
    check all(names <- StreamData.uniq_list_of(attr_name(), min_length: 1, max_length: 6),
              max_runs: 40) do
      attr_lines =
        names
        |> Enum.map(fn n -> "    attribute #{inspect(n)}, :string, public?: true" end)
        |> Enum.join("\n")

      # No data layer: the prefix property is pure compile-time introspection over
      # `attribute.source`; persistence is covered by the round-trip property below.
      # AshPostgres data layer (supports select) so VerifySelectedByDefault is
      # satisfied by the injected primary key. Introspecting `attribute.source`
      # never touches the DB, so the (unmigrated) table is irrelevant here.
      src = """
      defmodule #{inspect(@gen_module)} do
        use Samen.Resource,
          otp_app: :samen_core,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: AshPostgres.DataLayer,
          abbrev: "pgn"

        postgres do
          table "pgn_gen"
          repo SamenCore.TestRepo
        end

        attributes do
      #{attr_lines}
        end
      end
      """

      # Purge the fixture module AND its derived Inspect protocol impl. Ash
      # resources define a per-module `Inspect.<Resource>` impl; recompiling the
      # fixture each run redefines that impl, which emits a "redefining module"
      # warning that `mix test --warnings-as-errors` treats as an error. Purging
      # the impl module too keeps the runtime-recompile loop warning-free.
      inspect_impl = Module.concat(Inspect, @gen_module)
      :code.purge(@gen_module)
      :code.delete(@gen_module)
      :code.purge(inspect_impl)
      :code.delete(inspect_impl)
      modules = Code.compile_string(src)
      assert Enum.any?(modules, fn {m, _bin} -> m == @gen_module end)

      sources = Map.new(Info.attributes(@gen_module), &{&1.name, &1.source})
      logical_names = Enum.map(Info.attributes(@gen_module), & &1.name)

      for name <- names do
        assert sources[name] == :"pgn_#{name}",
               "expected pgn_#{name}, got #{inspect(sources[name])}"

        assert name in logical_names
        refute :"pgn_#{name}" in logical_names
      end

      # Injected core columns are present and prefixed too.
      for core <- @reserved do
        assert sources[core] == :"pgn_#{core}"
      end
    end
  end

  # Pin a printable-string generator to values that survive the `:string` type's
  # write-time normalization (trim + empty→nil), so any round-trip difference is
  # attributable to the abbrev prefix mechanism under test, never to trimming.
  defp trim_stable(gen) do
    gen
    |> StreamData.map(&String.trim/1)
    |> StreamData.filter(&(&1 != ""), 200)
  end

  # Non-empty values: Ash's :string type coerces `""` to nil by default (a type
  # concern, not a storage-prefix concern), which is out of scope for this T1.1
  # property. The point here is that arbitrary values round-trip through the
  # *prefixed physical columns* via their logical names.
  #
  # ROOT-CAUSE FIX (T102, the T100 "1 of 15 properties" flake): the declared
  # `:string` type ALSO defaults `trim?: true` + `allow_empty?: false`
  # (deps/ash/lib/ash/type/string.ex:19-27 — "values are trimmed and empty values
  # are set to nil"). `String.trim/1` strips ALL Unicode whitespace, so a value
  # that is only-whitespace (StreamData once shrank to " ", a SIX-PER-EM
  # SPACE) or has leading/trailing whitespace is normalized on write and no longer
  # equals the raw input — the round-trip assertion then fails for a reason
  # unrelated to the abbrev PREFIX this property actually tests. `min_length: 1`
  # already guards the empty case; `trim_stable/1` completes that guard by pinning
  # the generated value to what the type stores (trim it, reject the ones that
  # trim to empty). Same class of fix as `min_length: 1`, not an assertion change —
  # the `==` round-trip assertions below are untouched.
  property "create/read round-trips via the logical name for arbitrary values" do
    check all(
            name <- trim_stable(StreamData.string(:printable, min_length: 1, max_length: 40)),
            label <- trim_stable(StreamData.string(:printable, min_length: 1, max_length: 40)),
            notes <- trim_stable(StreamData.string(:printable, min_length: 1, max_length: 200)),
            org_id = Ash.UUID.generate(),
            max_runs: 60
          ) do
      rec =
        SamenCore.Support.PropFixture
        |> Ash.Changeset.for_create(:create, %{
          org_id: org_id,
          name: name,
          label: label,
          notes: notes
        })
        |> Ash.create!()

      [read_back] =
        SamenCore.Support.PropFixture
        |> Ash.Query.filter(id == ^rec.id)
        |> Ash.Query.ensure_selected([:name, :label, :notes, :org_id])
        |> Ash.read!()

      assert read_back.name == name
      assert read_back.label == label
      assert read_back.notes == notes
      assert read_back.org_id == org_id
    end
  end

  # DETERMINISTIC regression for the T100 "1 of 15 properties" flake (T102): pins
  # BOTH sides of the trim boundary that the property's generator now respects, so
  # the flake can never silently return and the fix's premise stays honest.
  describe "T102 — string-normalization boundary the round-trip property depends on" do
    test "a trim-stable value round-trips byte-for-byte via the prefixed column" do
      org_id = Ash.UUID.generate()
      value = "gráce notes — vïa"

      rec =
        SamenCore.Support.PropFixture
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "n", label: "l", notes: value})
        |> Ash.create!()

      [read_back] =
        SamenCore.Support.PropFixture
        |> Ash.Query.filter(id == ^rec.id)
        |> Ash.Query.ensure_selected([:notes])
        |> Ash.read!()

      assert read_back.notes == value
    end

    test "the exact shrunk flake vector — a whitespace-only string (U+2006) — is normalized to nil by the :string type" do
      # This is INTENDED, documented Ash `:string` behaviour (trim? + allow_empty?
      # defaults, deps/ash/lib/ash/type/string.ex), NOT a substrate bug — which is
      # precisely why `trim_stable/1` excludes such values from the round-trip
      # generator. Asserting it here proves the exclusion is contract-correct.
      org_id = Ash.UUID.generate()

      rec =
        SamenCore.Support.PropFixture
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "n", label: "l", notes: " "})
        |> Ash.create!()

      [read_back] =
        SamenCore.Support.PropFixture
        |> Ash.Query.filter(id == ^rec.id)
        |> Ash.Query.ensure_selected([:notes])
        |> Ash.read!()

      assert read_back.notes == nil
    end
  end
end
