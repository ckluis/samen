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

    # A13b (attempt 2) — this test ships the verifier's own probe
    # (`_orch/verify/A13b-redaction-divergence-probe.md`) that REFUTED A13's original
    # shim. `inspect/1` alone silently misses a PII substring that survives redaction
    # inside a struct field a `@derive {Inspect, only: [...]}` hides from `inspect/1`
    # while its `@derive {Jason.Encoder, ...}` still serializes it — a common
    # secret-hiding pattern (Ecto schemas / credential-bearing structs). The leak-check
    # MUST still catch it (via the `Jason.encode/1` half of the union serializer) even
    # though it never appears in `inspect/1`'s own output.
    defmodule LeakySecretStruct do
      @moduledoc false
      @derive {Jason.Encoder, only: [:safe, :secret]}
      @derive {Inspect, only: [:safe]}
      defstruct [:safe, :secret]
    end

    test "flunks on a PII leak hidden from inspect/1 but still present via Jason.Encoder (RED — VA13 probe)" do
      leaked_pii = "user-ssn-123-45-6789"
      leaky = %LeakySecretStruct{safe: "ok-field", secret: leaked_pii}

      # Sanity: confirm this struct really does hide :secret from inspect/1 (the
      # divergence this test exists to close), so the assertion below is proven to
      # exercise the Jason.encode/1 half of the union, not a vacuous no-op.
      refute inspect(leaky) =~ leaked_pii

      not_actually_redacting = fn payload -> Map.put(payload, "leftover", leaky) end

      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        Harness.assert_redaction!(not_actually_redacting, @payload,
          pii_strings: [leaked_pii],
          retained_keys: ["MessageID", "Email", "FromName"]
        )
      end
    end

    # A13b (attempt 3) — VA13's REFUTING probe (`_orch/verify/A13b-verdict.json`,
    # `fallback_branch_ruling`). Attempt 2's serializer was a UNION with a FALLBACK:
    # `Jason.encode/1` when it succeeded, otherwise `inspect/1` ALONE. For a payload
    # that is not JSON-encodable AT ALL, that union collapsed back to exactly the
    # `inspect/1`-only serializer attempt 1 was refuted for, so a struct that
    # `@derive {Inspect, only: [...]}` hides a field from and that derives NO
    # `Jason.Encoder` leaked its PII substring past the gate with `:ok` returned and
    # nothing raised. This is not a contrived shape: credential-bearing structs, config
    # structs and Ecto schemas routinely derive `Inspect` for log-safety and are never
    # given a `Jason.Encoder` because nobody expected them to be JSON-encoded. The leak
    # probe must read such a payload STRUCTURALLY and still flunk.
    defmodule OpaqueLeakySecretStruct do
      @moduledoc false
      @derive {Inspect, only: [:safe]}
      defstruct [:safe, :secret]
    end

    test "flunks on a PII leak hidden from inspect/1 in a payload Jason cannot encode at all (RED — VA13 attempt-2 probe)" do
      leaked_pii = "user-ssn-123-45-6789"
      leaky = %OpaqueLeakySecretStruct{safe: "ok-field", secret: leaked_pii}

      # Sanity 1 (anti-tautology): `inspect/1` really does hide `:secret`, so this test
      # cannot pass merely because the old `inspect/1` serializer happened to see it.
      refute inspect(leaky, limit: :infinity, printable_limit: :infinity) =~ leaked_pii

      # Sanity 2 (anti-tautology): the payload is genuinely NOT JSON-encodable, and
      # `Jason.encode/1` REPORTS that as `{:error, _}` rather than raising — so attempt
      # 2's fallback branch was genuinely reached, not bypassed by a crash.
      assert {:error, %Protocol.UndefinedError{protocol: Jason.Encoder}} =
               Jason.encode(%{"leftover" => leaky})

      not_actually_redacting = fn payload -> Map.put(payload, "leftover", leaky) end

      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        Harness.assert_redaction!(not_actually_redacting, @payload,
          pii_strings: [leaked_pii],
          retained_keys: ["MessageID", "Email", "FromName"]
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # assert_redaction!/3 — BYTE-RECOVERY (A13b attempt 4)
  #
  # `_orch/verify/A13b-verdict.json` REFUTED attempt 3's structural walk. The walk was
  # total in TRAVERSAL and lossy in RENDERING: it visited every term but emitted three
  # ordinary leaf kinds in a form the contiguous-substring assertion could not match, so
  # `assert_redaction!/3` returned `:ok` on bytes it had looked at but could not
  # recognise. The guarantee the gate actually needs is BYTE RECOVERY — every PII-bearing
  # leaf rendered as the contiguous bytes the assertion looks for — and these tests pin
  # it. VA13's own three payloads are ATTACK A / B / C, verbatim in shape; the remaining
  # tests pin the generalizations of them, so the same class cannot be reopened one
  # variant at a time.

  describe "assert_redaction!/3 byte-recovery (A13b attempt 4 — VA13 attempt-3 probes)" do
    @a4_payload %{
      "MessageID" => "msg-1",
      "Email" => "user-ssn-123-45-6789",
      "FromName" => "Acme"
    }
    @a4_pii "user-ssn-123-45-6789"
    @a4_retained ["MessageID", "FromName"]

    defp a4_leak!(leftover) do
      Samen.AdapterConformanceCase.assert_redaction!(
        fn payload -> payload |> Map.delete("Email") |> Map.put("leftover", leftover) end,
        @a4_payload,
        pii_strings: [@a4_pii],
        retained_keys: @a4_retained
      )
    end

    # A closure built in a COMPILED function, so the captured value really is in the
    # fun's environment (`:erlang.fun_info/2`) rather than inlined as a literal.
    defp a4_closure_over(value), do: fn -> value end

    # ATTACK A — VA13 attempt-3 probe A. PII carried as multi-chunk iodata. Attempt 3's
    # walk joined leaves with `?\n`, so the walk's OWN separator split the substring;
    # `inspect/1` renders `["user-", "ssn-..."]` (quote + comma between the chunks) and
    # Jason renders a JSON array — no view held the contiguous bytes. No struct, no
    # `@derive`, no exotic term: ordinary iodata, which is how Erlang/Elixir HTTP bodies
    # are routinely carried.
    test "flunks on PII carried as multi-chunk iodata (RED — VA13 attempt-3 ATTACK A)" do
      chunks = ["user-", "ssn-123-45-6789"]

      # anti-tautology: the chunks really do reassemble to the PII, and neither chunk
      # alone contains it.
      assert IO.iodata_to_binary(chunks) == @a4_pii
      assert Enum.all?(chunks, &(:binary.match(&1, @a4_pii) == :nomatch))

      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        a4_leak!(chunks)
      end
    end

    # ATTACK A, generalized 1 — nested iodata. `IO.iodata_to_binary/1` is defined over
    # arbitrarily nested lists, so the join view must be taken at every list, not only a
    # flat one.
    test "flunks on PII carried as NESTED iodata (RED — generalization of ATTACK A)" do
      chunks = ["user-", ["ssn-", ["123-", "45-6789"]]]
      assert IO.iodata_to_binary(chunks) == @a4_pii

      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        a4_leak!(chunks)
      end
    end

    # ATTACK A, generalized 2 — an IMPROPER list is still valid iodata and still a
    # `is_list/1` term. A walk that only matches proper lists would miss it.
    test "flunks on PII carried as an IMPROPER-list iodata tail (RED — generalization of ATTACK A)" do
      chunks = ["user-" | "ssn-123-45-6789"]
      assert IO.iodata_to_binary(chunks) == @a4_pii

      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        a4_leak!(chunks)
      end
    end

    # ATTACK B — VA13 attempt-3 probe B. A charlist inside a struct that `@derive`s
    # `Inspect` to hide the field and derives NO `Jason.Encoder`. Attempt 3's walk saw a
    # list of INTEGERS and emitted `117\n115\n101\n...`; the only view that would have
    # rendered it as text is the protocol the payload's author suppressed.
    defmodule CharlistHidingStruct do
      @moduledoc false
      @derive {Inspect, only: [:safe]}
      defstruct [:safe, :contact]
    end

    test "flunks on charlist PII inside an Inspect-hiding, non-JSON-encodable struct (RED — VA13 attempt-3 ATTACK B)" do
      leaky = %CharlistHidingStruct{safe: "ok", contact: String.to_charlist(@a4_pii)}

      # anti-tautology 1: inspect really does hide the field.
      refute inspect(%{"leftover" => leaky}, limit: :infinity, printable_limit: :infinity) =~
               @a4_pii

      # anti-tautology 2: the payload really is not JSON-encodable at all.
      assert {:error, %Protocol.UndefinedError{protocol: Jason.Encoder}} =
               Jason.encode(%{"leftover" => leaky})

      # anti-tautology 3: the charlist really does hold the PII.
      assert List.to_string(leaky.contact) == @a4_pii

      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        a4_leak!(leaky)
      end
    end

    # ATTACK B, generalized — a charlist whose codepoints are NOT all latin-1. Such a
    # list is still `is_list/1` and still holds the text, but `IO.iodata_to_binary/1`
    # renders codepoint 252 as the single byte 0xFC while the PII string is that
    # codepoint's UTF-8 encoding. Only the `List.to_string/1` view recovers it, so the
    # two list-join views must be ADDITIVE, never alternatives.
    test "flunks on a non-latin1 charlist whose UTF-8 rendering is the PII (RED — generalization of ATTACK B)" do
      pii = "üser-ssn-123-45-6789"
      chars = String.to_charlist(pii)

      # anti-tautology: the iodata view genuinely does NOT recover these bytes; only the
      # chardata view does.
      assert :binary.match(IO.iodata_to_binary(chars), pii) == :nomatch
      assert List.to_string(chars) == pii

      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        Samen.AdapterConformanceCase.assert_redaction!(
          fn payload -> Map.put(payload, "leftover", chars) end,
          @a4_payload,
          pii_strings: [pii],
          retained_keys: @a4_retained
        )
      end
    end

    # ATTACK C — VA13 attempt-3 probe C. A non-byte-aligned bitstring: `is_binary/1` is
    # false, so attempt 3's walk skipped its binary clause and fell to the `inspect/1`
    # catch-all, which renders `<<117, 115, 101, ...>>`.
    test "flunks on PII in a non-byte-aligned bitstring (RED — VA13 attempt-3 ATTACK C)" do
      bits = <<@a4_pii::binary, 0::size(1)>>

      # anti-tautology: it really is not a binary, so no binary-only clause can see it.
      refute is_binary(bits)
      assert rem(bit_size(bits), 8) == 1

      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        a4_leak!(bits)
      end
    end

    # ATTACK C, generalized — the same PII bytes at a NON-ZERO BIT OFFSET inside a term
    # that IS a binary. Padding the tail alone does not recover it; only re-aligning the
    # leading bit offset does. This is the general form of ATTACK C, and closing it
    # closes every bit alignment at once rather than the one VA13 happened to pick.
    test "flunks on PII at a non-zero BIT OFFSET inside a byte-aligned binary (RED — generalization of ATTACK C)" do
      shifted = <<0::size(3), @a4_pii::binary, 0::size(5)>>

      # anti-tautology: it IS a binary, and its raw bytes do NOT contain the PII.
      assert is_binary(shifted)
      assert :binary.match(shifted, @a4_pii) == :nomatch

      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        a4_leak!(shifted)
      end
    end

    # The residual attempt 3 DISCLOSED but did not close: PII captured in a function
    # closure's environment. `:erlang.fun_info/2` exposes the captured free variables of
    # a local fun, so this one is closable rather than merely disclosable.
    test "flunks on PII captured in a function closure's environment (RED — attempt 3's disclosed residual)" do
      closure = a4_closure_over(@a4_pii)

      # anti-tautology 1: no protocol renders a fun's captured environment.
      refute inspect(closure, limit: :infinity, printable_limit: :infinity) =~ @a4_pii
      # anti-tautology 2: the PII really is in the environment, not inlined as a literal.
      assert {:env, env} = :erlang.fun_info(closure, :env)
      assert @a4_pii in env

      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        a4_leak!(closure)
      end
    end

    # Fragment attacks that are NOT list-shaped: the same "the payload never joins it"
    # trick applied to a tuple and to two sibling map values.
    test "flunks on PII split across TUPLE elements (RED)" do
      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        a4_leak!({"user-", "ssn-123-45-6789"})
      end
    end

    test "flunks on PII split across two sibling MAP VALUES (RED)" do
      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        a4_leak!(%{"a" => "user-", "b" => "ssn-123-45-6789"})
      end
    end

    # PII carried as a list of INTEGERS whose DECIMAL rendering — not their byte
    # rendering — is the PII. The byte and decimal views must both be emitted.
    test "flunks on numeric PII carried as integer leaves (RED)" do
      pii = "123456789"

      assert_raise ExUnit.AssertionError, ~r/LEAKED a PII fixture string/, fn ->
        Samen.AdapterConformanceCase.assert_redaction!(
          fn payload -> Map.put(payload, "leftover", [123, 456, 789]) end,
          @a4_payload,
          pii_strings: [pii],
          retained_keys: @a4_retained
        )
      end
    end

    # Non-vacuity of the CALLER surface (`_orch/verify/A13b-verdict.json`
    # `minor_observations[0]`): a fixture that documents NO pii strings makes the leak
    # check pass on any payload whatsoever. That must be refused, not honoured.
    test "flunks when :pii_strings is empty — the leak check would otherwise be vacuous (RED)" do
      assert_raise ExUnit.AssertionError, ~r/EMPTY :pii_strings/, fn ->
        Samen.AdapterConformanceCase.assert_redaction!(&Function.identity/1, @a4_payload,
          pii_strings: [],
          retained_keys: @a4_retained
        )
      end
    end

    test "flunks when a :pii_strings entry is not a non-empty binary (RED)" do
      assert_raise ExUnit.AssertionError, ~r/:pii_strings/, fn ->
        Samen.AdapterConformanceCase.assert_redaction!(&Function.identity/1, @a4_payload,
          pii_strings: [""],
          retained_keys: @a4_retained
        )
      end
    end

    # POSITIVE CONTROL for the whole byte-recovery machinery: the additional views —
    # eight bit alignments per byte-bearing leaf, the list-join views, and the
    # traversal-order dense views — must NOT turn a genuinely surgical redaction red.
    # Without this, every test above could be satisfied by a serializer that always
    # flunks.
    test "still PASSES a genuinely surgical redaction over a payload of every leaf kind (positive control)" do
      rich = %{
        "MessageID" => "msg-1",
        "FromName" => "Acme",
        "chunks" => ["safe-", "value"],
        "chars" => ~c"safe chars",
        "bits" => <<"safe"::binary, 0::size(3)>>,
        "tuple" => {"safe", 1, 2.5, :safe_atom},
        "nested" => %{"a" => "safe-", "b" => "tail"},
        "fun" => a4_closure_over("safe closure value"),
        "pid" => self(),
        "ref" => make_ref()
      }

      assert :ok =
               Samen.AdapterConformanceCase.assert_redaction!(
                 fn _payload -> rich end,
                 @a4_payload,
                 pii_strings: [@a4_pii, "known-pii@example.test"],
                 retained_keys: ["MessageID", "FromName"]
               )
    end
  end

  # ---------------------------------------------------------------------------
  # assert_capture_no_leak!/2 shares the SAME leak-probe views (A13b attempt 4). The
  # defect VA13 refuted three times was a property of the serializer, not of one
  # assertion, so the outbound-leak gate is pinned against the same class here.

  describe "assert_capture_no_leak!/2 byte-recovery (A13b attempt 4)" do
    test "flunks on a forbidden sentinel carried as multi-chunk iodata (RED)" do
      sentinel = "OTHER-SUBJECT-SENTINEL@leak.test"
      chunks = ["OTHER-SUBJECT-", "SENTINEL@leak.test"]
      assert IO.iodata_to_binary(chunks) == sentinel

      assert_raise ExUnit.AssertionError, ~r/forbidden plaintext sentinel/, fn ->
        Samen.AdapterConformanceCase.assert_capture_no_leak!(
          fn capture -> capture.(%{subject: chunks}) end,
          [sentinel]
        )
      end
    end

    defmodule OutboundHidingStruct do
      @moduledoc false
      @derive {Inspect, only: [:safe]}
      defstruct [:safe, :contact]
    end

    test "flunks on a vt_* vault token hidden from inspect/1 by @derive (RED)" do
      leaky = %Samen.AdapterConformanceCaseTest.OutboundHidingStruct{
        safe: "ok",
        contact: "vt_rogue_token"
      }

      refute inspect(leaky, limit: :infinity, printable_limit: :infinity) =~ "vt_"

      assert_raise ExUnit.AssertionError, ~r/vault token/, fn ->
        Samen.AdapterConformanceCase.assert_capture_no_leak!(fn capture ->
          capture.(%{to: leaky})
        end)
      end
    end
  end
end
