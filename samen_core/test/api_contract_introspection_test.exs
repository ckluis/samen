defmodule Samen.ApiContractIntrospectionTest do
  @moduledoc """
  Honest reads, kernel phase E: a resource whose JSON:API introspection FAILS is not "a resource that is not exposed".
  `Snapshot.build` used to rescue every failure into absence, so `--update` could write a contract silently missing a
  resource (and fields/routes silently emptied) that every later diff then blessed. It now raises
  `Samen.ApiContract.IntrospectionError` naming the resource and the exception module, and the mix task fails closed.
  """
  use ExUnit.Case, async: true

  alias Samen.ApiContract
  alias Samen.ApiContract.IntrospectionError
  alias SamenCore.Support.Archivable

  # A stand-in for AshJsonApi.Resource.Info: Widget is exposed, Person is not a JSON:API resource, and the
  # `Broken*` behaviours raise from the real introspection call sites.
  defmodule Healthy do
    @moduledoc false
    def type(SamenCore.Support.Archivable.Widget), do: "widget"
    def type(_), do: nil
    def show_fields(_), do: [:id, :code]
    def routes(_), do: []
  end

  defmodule BrokenType do
    @moduledoc false
    def type(SamenCore.Support.Archivable.Widget), do: "widget"
    def type(SamenCore.Support.Archivable.Person), do: raise(ArgumentError, "cohort tier=Secret-7731")
    def show_fields(_), do: [:id]
    def routes(_), do: []
  end

  defmodule BrokenFields do
    @moduledoc false
    def type(_), do: "x"
    def show_fields(_), do: raise(RuntimeError, "no fields")
    def routes(_), do: []
  end

  defmodule BrokenRoutes do
    @moduledoc false
    def type(_), do: "x"
    def show_fields(_), do: [:id]
    def routes(_), do: raise(RuntimeError, "no routes")
  end

  test "POSITIVE CONTROL: a healthy introspection snapshots the exposed resource and skips the unexposed one" do
    assert %{"resources" => [%{"type" => "widget", "fields" => fields}]} =
             ApiContract.snapshot([Archivable], "v1", info_mod: Healthy)

    assert Enum.map(fields, & &1["name"]) == ["code", "id"]
  end

  test "RED: a resource whose type introspection raises fails the build, naming the resource and the exception module only" do
    err = assert_raise IntrospectionError, fn -> ApiContract.snapshot([Archivable], "v1", info_mod: BrokenType) end

    assert err.failures == [{Archivable.Person, ArgumentError}]
    assert Exception.message(err) =~ "SamenCore.Support.Archivable.Person (ArgumentError)"
    refute Exception.message(err) =~ "Secret-7731"
  end

  test "RED: a failing show_fields or routes introspection fails the build instead of emptying the resource" do
    for mod <- [BrokenFields, BrokenRoutes] do
      err = assert_raise IntrospectionError, fn -> ApiContract.snapshot([Archivable], "v1", info_mod: mod) end
      assert Enum.map(err.failures, &elem(&1, 1)) == [RuntimeError, RuntimeError]
    end
  end

  test "without the JSON:API library nothing is exposed: an honest empty contract (the task's floor refuses it)" do
    assert %{"resources" => []} = ApiContract.snapshot([Archivable], "v1", info_mod: NoSuchInfoModule)
  end
end
