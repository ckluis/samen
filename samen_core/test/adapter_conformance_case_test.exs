defmodule Samen.AdapterConformanceCaseTest do
  @moduledoc """
  T188 — self-test for `Samen.AdapterConformanceCase`. Proves the kit's own guarantees,
  both directions (anti-tautology, CLAUDE.md red-path discipline):

    * the named compile-time error when the `adapter:` module is not loaded;
    * `assert_refusal_table!/1` passes on a genuinely fail-honest fake adapter and FLUNKS
      on one that fakes `{:ok, _}`;
    * `assert_masked_payload_only!/2` passes on a fake adapter with a real
      function-clause guard and FLUNKS when the "masked" call is itself over-strict;
    * `assert_masked_segments!/1` passes on clean segments and FLUNKS on a leaked
      `vt_*` token / non-binary segment.
  """
  use ExUnit.Case, async: true

  alias Samen.AdapterConformanceCase, as: Harness

  # A fake adapter behaving honestly: refuses unconfigured work, accepts a "masked"
  # struct via function-clause matching, and raises FunctionClauseError on raw input.
  defmodule HonestFakeAdapter do
    @moduledoc false
    defstruct sealed: true

    def call(%__MODULE__{}), do: {:ok, :did_the_work}
    def unconfigured_call(%__MODULE__{}), do: {:error, :not_configured}
  end

  # An adapter with a genuine, real FunctionClauseError-raising guard — used to model an
  # over-strict masked-call check below (it must raise ONLY on non-struct input).
  defmodule OverlyStrictFakeAdapter do
    @moduledoc false
    def call(%HonestFakeAdapter{}), do: :ok
  end

  # ---------------------------------------------------------------------------
  # the named compile-time error (T188 requirement)

  describe "use Samen.AdapterConformanceCase, adapter: <missing module>" do
    test "raises the named AdapterNotLoadedError at compile time" do
      source = """
      defmodule Samen.AdapterConformanceCase.FixtureMissingAdapterModule do
        use Samen.AdapterConformanceCase, adapter: Samen.AdapterConformanceCase.DoesNotExistNoReally
      end
      """

      assert_raise Samen.AdapterConformanceCase.AdapterNotLoadedError, fn ->
        Code.compile_string(source)
      end
    end

    test "a REAL, loaded adapter module compiles cleanly (positive control)" do
      # HonestFakeAdapter (defined above in this file) is already compiled/loaded by the
      # time this test runs, so the compile-time guard must let this fixture through.
      source = """
      defmodule Samen.AdapterConformanceCase.FixtureRealAdapterModule do
        use Samen.AdapterConformanceCase, adapter: Samen.AdapterConformanceCaseTest.HonestFakeAdapter
      end
      """

      assert [{Samen.AdapterConformanceCase.FixtureRealAdapterModule, _}] =
               Code.compile_string(source)
    end
  end

  # ---------------------------------------------------------------------------
  # assert_refusal_table!/1 — anti-tautology

  describe "assert_refusal_table!/1" do
    test "passes when every entry genuinely refuses with the expected error (positive control)" do
      assert :ok =
               Harness.assert_refusal_table!([
                 {"honest refusal",
                  fn -> HonestFakeAdapter.unconfigured_call(%HonestFakeAdapter{}) end,
                  :not_configured}
               ])
    end

    test "flunks when the adapter fakes a success instead of refusing (RED — non-vacuous)" do
      assert_raise ExUnit.AssertionError, ~r/FAKE success/, fn ->
        Harness.assert_refusal_table!([
          {"lying success", fn -> {:ok, :should_not_happen} end, :not_configured}
        ])
      end
    end

    test "flunks when the adapter returns the wrong error atom" do
      assert_raise ExUnit.AssertionError, fn ->
        Harness.assert_refusal_table!([
          {"wrong error", fn -> {:error, :not_implemented} end, :not_configured}
        ])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # assert_masked_payload_only!/2 — anti-tautology

  describe "assert_masked_payload_only!/2" do
    test "passes for a genuinely masked-only adapter (positive control)" do
      assert :ok =
               Harness.assert_masked_payload_only!(
                 fn -> HonestFakeAdapter.call(%HonestFakeAdapter{}) end,
                 fn -> HonestFakeAdapter.call("raw unmasked value") end
               )
    end

    test "flunks when the masked call is itself refused by function clause (over-strict guard)" do
      assert_raise ExUnit.AssertionError, ~r/refused by function clause/, fn ->
        Harness.assert_masked_payload_only!(
          # OverlyStrictFakeAdapter.call/1 only matches %HonestFakeAdapter{} — passing a
          # DIFFERENT struct genuinely raises FunctionClauseError, modeling a masked-call
          # guard that is too strict for its own "sealed" input.
          fn -> OverlyStrictFakeAdapter.call(%{not: :the_expected_struct}) end,
          fn -> HonestFakeAdapter.call("raw") end
        )
      end
    end

    test "flunks when the raw call is NOT refused by function clause (a real leak)" do
      assert_raise ExUnit.AssertionError, fn ->
        Harness.assert_masked_payload_only!(
          fn -> HonestFakeAdapter.call(%HonestFakeAdapter{}) end,
          fn -> {:ok, :raw_leaked_through} end
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # assert_masked_segments!/1 — anti-tautology (mirrors Samen.AgentCase's own red path)

  describe "assert_masked_segments!/1" do
    test "passes for clean, plain-binary segments (positive control)" do
      assert :ok = Harness.assert_masked_segments!([["hello", "world"], ["another turn"]])
    end

    test "flunks when a vt_* vault token leaks into a segment" do
      assert_raise ExUnit.AssertionError, ~r/INV-7/, fn ->
        Harness.assert_masked_segments!([["clean", "leaked vt_abc123"]])
      end
    end

    test "flunks when a grant_span tag leaks into a segment" do
      assert_raise ExUnit.AssertionError, fn ->
        Harness.assert_masked_segments!([["a grant_span tag here"]])
      end
    end

    test "flunks on a non-binary segment" do
      assert_raise ExUnit.AssertionError, fn ->
        Harness.assert_masked_segments!([[{:grant_span, :x}]])
      end
    end
  end
end
