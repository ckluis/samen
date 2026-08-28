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
      `vt_*` token / non-binary segment;
    * (UXD-07 / A6, the delivery-shaped additions) `load_fixtures!/1` loads a real
      fixture and FLUNKS on a missing one; `assert_capture_no_leak!/2` passes on a clean
      outbound payload and FLUNKS on a leaked `vt_*` token, a leaked plaintext sentinel,
      and on a call that built NO request at all; `assert_redaction!/3` passes on a
      surgical redaction and FLUNKS on a PII leak, a dropped retained key, and a
      wipe-everything no-op.
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
  # ---------------------------------------------------------------------------
  # load_fixtures!/1 — UXD-07 / A6 (delivery-shaped addition)

  describe "load_fixtures!/1" do
    test "loads a real, checked-in conformance fixture (positive control)" do
      # The toy fixture samen_core already ships for its own harness self-test — an
      # adapter-package-shaped `<dir>/conformance.exs` evaluating to a map.
      fixtures = Harness.load_fixtures!("test/fixtures/toy_conformance")

      assert is_map(fixtures)
      assert Map.has_key?(fixtures, :configured_config)
    end

    test "flunks with a named message when the fixture file is missing (RED)" do
      assert_raise ExUnit.AssertionError, ~r/no conformance fixture found/, fn ->
        Harness.load_fixtures!("test/fixtures/there_is_no_such_fixture_dir")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # assert_capture_no_leak!/2 — UXD-07 / A6 (delivery-shaped addition), anti-tautology

  describe "assert_capture_no_leak!/2" do
    test "passes when the captured outbound payload is clean (positive control)" do
      assert :ok =
               Harness.assert_capture_no_leak!(
                 fn capture -> capture.(%{to: "recipient@example.test", subject: "hello"}) end,
                 ["OTHER-SUBJECT-SENTINEL@leak.test"]
               )
    end

    test "flunks when a vt_* vault token reaches the outbound payload (RED)" do
      assert_raise ExUnit.AssertionError, ~r/vault token/, fn ->
        Harness.assert_capture_no_leak!(fn capture ->
          capture.(%{to: "vt_rogue_token_must_not_reach_the_provider"})
        end)
      end
    end

    test "flunks when a forbidden plaintext sentinel reaches the outbound payload (RED)" do
      assert_raise ExUnit.AssertionError, ~r/forbidden plaintext sentinel/, fn ->
        Harness.assert_capture_no_leak!(
          fn capture -> capture.(%{subject: "OTHER-SUBJECT-SENTINEL@leak.test"}) end,
          ["OTHER-SUBJECT-SENTINEL@leak.test"]
        )
      end
    end

    test "flunks when the call built NO outbound request at all (non-vacuity)" do
      assert_raise ExUnit.AssertionError, ~r/NO outbound request/, fn ->
        Harness.assert_capture_no_leak!(fn _capture -> {:error, :not_configured} end)
      end
    end

    test "an adapter that raises still has its captured request inspected" do
      assert_raise ExUnit.AssertionError, ~r/vault token/, fn ->
        Harness.assert_capture_no_leak!(fn capture ->
          capture.(%{to: "vt_leaked"})
          raise "the adapter blew up on the probe's error return"
        end)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # assert_redaction!/3 — UXD-07 / A6 (delivery-shaped addition), anti-tautology

  describe "assert_redaction!/3" do
    @payload %{
      "MessageID" => "msg-1",
      "Email" => "known-pii@example.test",
      "FromName" => "Known Pii Name"
    }

    test "passes for a surgical redaction (positive control)" do
      surgical = fn payload -> Map.take(payload, ["MessageID"]) end

      assert :ok =
               Harness.assert_redaction!(surgical, @payload,
                 pii_strings: ["known-pii@example.test", "Known Pii Name"],
                 retained_keys: ["MessageID"]
               )
    end

    test "flunks when a PII string survives redaction (RED)" do
      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        Harness.assert_redaction!(&Function.identity/1, @payload,
          pii_strings: ["known-pii@example.test"],
          retained_keys: ["MessageID"]
        )
      end
    end

    test "flunks when a documented retained key is dropped (wipe-everything no-op)" do
      assert_raise ExUnit.AssertionError, ~r/must be surgical, not total/, fn ->
        Harness.assert_redaction!(fn _ -> %{} end, @payload,
          pii_strings: ["known-pii@example.test"],
          retained_keys: ["MessageID"]
        )
      end
    end

    test "flunks on an EMPTY result for a non-empty payload with no documented retained_keys" do
      assert_raise ExUnit.AssertionError, ~r/wipe-everything/, fn ->
        Harness.assert_redaction!(fn _ -> %{} end, @payload,
          pii_strings: ["known-pii@example.test"]
        )
      end
    end
  end
end
