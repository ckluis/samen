defmodule SamenSmokeTest do
  use ExUnit.Case
  doctest SamenSmoke

  test "greets the world" do
    assert SamenSmoke.hello() == :world
  end

  # Deps check: verify all four target packages loaded and expose their expected
  # top-level modules. Fails if a package is missing or renamed.
  test "deps check: Ash 3.x, ash_postgres, spark, oban all resolve and compile" do
    # Ash 3.x
    assert Code.ensure_loaded?(Ash.Resource.Dsl), "Ash.Resource.Dsl not loaded"
    assert Code.ensure_loaded?(Ash.Domain), "Ash.Domain not loaded"

    # ash_postgres
    assert Code.ensure_loaded?(AshPostgres.DataLayer), "AshPostgres.DataLayer not loaded"

    # spark
    assert Code.ensure_loaded?(Spark.Dsl), "Spark.Dsl not loaded"
    assert Code.ensure_loaded?(Spark.Dsl.Transformer), "Spark.Dsl.Transformer not loaded"

    # oban
    assert Code.ensure_loaded?(Oban), "Oban not loaded"
    assert Code.ensure_loaded?(Oban.Worker), "Oban.Worker not loaded"
  end

  # Red path: a module that does not exist must NOT be considered loaded.
  # This confirms Code.ensure_loaded? actually fails closed on unknown modules
  # rather than blindly returning true.
  test "red path: Code.ensure_loaded? returns false for a nonexistent module" do
    refute Code.ensure_loaded?(Samen.ThisModuleDoesNotExist),
           "ensure_loaded? should return false for a module that does not exist"
  end
end
