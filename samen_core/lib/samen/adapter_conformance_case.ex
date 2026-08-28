defmodule Samen.AdapterConformanceCase do
  @moduledoc """
  The SHARED cross-family adapter-conformance kit (T188; WS-C; INV-4 —
  `samen_core/ci.sh:126`). Generalizes three narrower, pre-existing things into ONE
  `ExUnit.CaseTemplate` any adapter FAMILY can `use`:

    * `Samen.Delivery.ProviderConformanceCase` (T27, WS-C C1) — the delivery/ESP-scoped
      fixture-driven harness. **Left UNCHANGED here** — its own moduledoc freezes its
      signature ("any needed harness change is a T27-owned follow-up, never an in-place
      edit"). This module does not wrap or replace it; it is a SEPARATE, more general kit
      new/other adapter families adopt going forward.
    * `test/kms_conformance_test.exs`'s one-off hardcoded `@adapters` loop — the
      fail-honest refusal-semantics assertion it hand-rolls is generalized here as
      `assert_refusal_table!/1`.
    * `Samen.AgentCase.assert_masked_only_payloads!/0` (agent_case.ex:211) — the
      masked-only segment scan is generalized here as `assert_masked_segments!/1` and
      `Samen.AgentCase` now delegates to it (same contract, same callers, DRY).

  UXD-07 / A6 extends this kit with the DELIVERY-SHAPED assertions an ESP adapter package
  needs in order to adopt it — `load_fixtures!/1`, `assert_capture_no_leak!/2` and
  `assert_redaction!/3`, the ADR-038 §4.5 (d)/(f) guarantees restated family-neutrally. The
  ADR-038 §8.1 REFERENCE delivery adapter is the kit's first delivery-family consumer; the
  remaining ESP adapter packages, and samen_core's own `Samen.Delivery.DeliverLeakGateTest`
  and `Samen.Delivery.ChokepointAntiBypassProbeTest`, keep consuming
  `Samen.Delivery.ProviderConformanceCase` exactly as before, so its frozen signature never
  moves. (No adapter package is NAMED here — INV-4 / ADR-038 §8.3 keep samen_core
  vendor-string clean; see the ADR for which package adopted which kit.)

  ## Usage

      use Samen.AdapterConformanceCase, adapter: MyAdapter.Module

  `adapter:` is the ONLY required option — the module under test. It is checked at
  **compile time** via `Code.ensure_loaded?/1`; if the module is not loaded, `use` raises
  the NAMED `Samen.AdapterConformanceCase.AdapterNotLoadedError` rather than an opaque
  `UndefinedFunctionError` surfacing later, mid-test. This is the kit's "one optional
  dependency": from `samen_core`'s side, an adapter module is optional by construction
  (INV-4 — `samen_core` never lists an adapter package as a real `mix.exs` dep in either
  direction); the compile-time guard makes that optionality a named, provable failure
  instead of a silent one.

  Helper functions below are PLAIN functions (the `Samen.MaskingCase`/`Samen.RedPath`
  house convention — test infra ships in `lib`), imported by `using/1`, called explicitly
  from the consuming test's own `test` blocks — not a macro-generated fixture DSL like
  `ProviderConformanceCase`. Every consumer proves BOTH the acceptance direction
  (`%MaskedPayload{}`/valid input works) and the refusal direction (raw input / an
  unconfigured or unimplemented capability refuses honestly) — anti-tautology, per
  CLAUDE.md's red-path discipline.
  """

  defmodule AdapterNotLoadedError do
    @moduledoc """
    Raised at compile time by `Samen.AdapterConformanceCase`'s `using/1` when the
    `adapter:` module named in `use Samen.AdapterConformanceCase, adapter: ...` is not
    loaded — the kit's one, named, compile-time-checked optional dependency (T188).
    """
    defexception [:adapter]

    @impl true
    def message(%{adapter: adapter}) do
      "Samen.AdapterConformanceCase: adapter module #{inspect(adapter)} is not loaded. " <>
        "This kit's ONE optional dependency is the adapter under test — is its package " <>
        "in your :test deps, and did it actually compile? (T188; use Samen." <>
        "AdapterConformanceCase, adapter: YourAdapterModule)"
    end
  end

  use ExUnit.CaseTemplate

  using opts do
    adapter = Keyword.fetch!(opts, :adapter)

    quote bind_quoted: [adapter: adapter] do
      unless Code.ensure_loaded?(adapter) do
        raise Samen.AdapterConformanceCase.AdapterNotLoadedError, adapter: adapter
      end

      import Samen.AdapterConformanceCase
      @conformance_adapter adapter
    end
  end

  import ExUnit.Assertions

  @doc """
  Fail-honest refusal table (generalizes `ProviderConformanceCase.assert_unconfigured_table!/3`
  and the KMS family's ad hoc refusal checks). `table` is a list of
  `{description, invoke_fn/0, expected_error}` tuples. For each entry, `invoke_fn.()` MUST
  return `{:error, expected_error}` — NEVER a fake `{:ok, _}` (the CLAUDE.md fail-honest
  adapter contract; ADR-014/024/026).
  """
  @spec assert_refusal_table!([{String.t(), (-> term()), term()}]) :: :ok
  def assert_refusal_table!(table) when is_list(table) do
    for {description, invoke, expected} <- table do
      case invoke.() do
        {:error, ^expected} ->
          :ok

        {:ok, _} = ok ->
          flunk(
            "#{description}: got a FAKE success #{inspect(ok)} instead of " <>
              "{:error, #{inspect(expected)}} — an adapter must never claim success for " <>
              "work it did not do (CLAUDE.md fail-honest adapter contract)."
          )

        other ->
          flunk("#{description}: expected {:error, #{inspect(expected)}}, got #{inspect(other)}")
      end
    end

    :ok
  end

  @doc """
  `%MaskedPayload{}`-only acceptance and refusal (generalizes the by-construction
  raw-refusal proofs shipped ad hoc per AI-provider adapter). `invoke_masked.()` MUST
  complete without a `FunctionClauseError` (a properly-sealed payload is accepted — the
  positive control; it may still error for other reasons, e.g. `:not_configured`).
  `invoke_raw.()` MUST raise `FunctionClauseError` (a raw/unmasked value can never reach
  the adapter — the INV-7 seam).
  """
  @spec assert_masked_payload_only!((-> term()), (-> term())) :: :ok
  def assert_masked_payload_only!(invoke_masked, invoke_raw)
      when is_function(invoke_masked, 0) and is_function(invoke_raw, 0) do
    try do
      invoke_masked.()
    rescue
      e in FunctionClauseError ->
        flunk(
          "a properly-sealed %MaskedPayload{} call was refused by function clause: " <>
            "#{Exception.message(e)} — the adapter's ingress guard is too strict (it must " <>
            "accept a real sealed payload; only RAW input may be refused this way)."
        )
    end

    assert_raise FunctionClauseError, fn -> invoke_raw.() end

    :ok
  end

  @doc """
  Segment-level masked-only property (generalizes
  `Samen.AgentCase.assert_masked_only_payloads!/0` verbatim — `Samen.AgentCase` now
  delegates here). Every segment of every recorded payload in `segments_list` must be a
  plain binary, carry no `vt_*` vault token, and no `grant_span` tag.
  """
  @spec assert_masked_segments!([[term()]]) :: :ok
  def assert_masked_segments!(segments_list) when is_list(segments_list) do
    for segments <- segments_list, segment <- segments do
      assert is_binary(segment),
             "a non-binary segment reached the provider: #{inspect(segment)} — masked " <>
               "history/payload segments must be rendered binaries ONLY."

      refute segment =~ "vt_", "a vt_* vault token reached the provider (INV-7)"
      refute segment =~ "grant_span", "a grant-span tag leaked onto the provider path"
    end

    :ok
  end
  @doc """
  Family-neutral conformance-fixture loader (the delivery-shaped generalization of
  `Samen.Delivery.ProviderConformanceCase`'s own ESP-scoped loader, which stays
  UNCHANGED). `fixtures_dir` is relative to the adapter PACKAGE root — the cwd `mix test`
  runs from. Evaluates `<fixtures_dir>/conformance.exs` (checked-in, hand-curated data,
  never network-recorded in CI — ADR-038 §7.2) and returns its value.
  """
  @spec load_fixtures!(Path.t()) :: term()
  def load_fixtures!(fixtures_dir) when is_binary(fixtures_dir) do
    path = Path.join(Path.expand(fixtures_dir), "conformance.exs")

    unless File.exists?(path) do
      flunk(
        "Samen.AdapterConformanceCase: no conformance fixture found at #{path} — an adapter " <>
          "package adopting this kit ships its fixture data as <fixtures_dir>/conformance.exs " <>
          "(see the kit moduledoc)."
      )
    end

    {fixtures, _bindings} = Code.eval_file(path)
    fixtures
  end

  @doc """
  Outbound-payload leak gate, generalized across adapter families (the delivery-shaped
  generalization of `Samen.Delivery.ProviderConformanceCase.assert_deliver_no_leak!/2`,
  which stays UNCHANGED and ESP-scoped — ADR-038 §4.5(f) / C3 T29, INV-1). `invoke` is
  arity-1: given the harness CAPTURE function, it must run the adapter's REAL outbound
  call with that capture wired in as the adapter's injectable transport. The adapter's
  RETURN VALUE is ignored — only the requests it actually built are inspected: at least
  one must be captured (a call that builds nothing cannot prove no leak), none may carry
  a `vt_*` vault token (INV-1/INV-7), and none may carry any `forbidden` plaintext
  sentinel. This makes masking enforced-by-a-gate rather than adapter goodwill.
  """
  @spec assert_capture_no_leak!(((term() -> term()) -> term()), [String.t()]) :: :ok
  def assert_capture_no_leak!(invoke, forbidden \\ [])
      when is_function(invoke, 1) and is_list(forbidden) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    capture = fn request ->
      Agent.update(agent, fn acc -> [request | acc] end)
      # Adapter request/response shapes differ across families, so there is no universal
      # success to hand back; return an error the adapter will surface. Only the CAPTURED
      # outbound request is inspected — never the adapter's result.
      {:error, :harness_leak_probe}
    end

    _ =
      try do
        invoke.(capture)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end

    captured = Agent.get(agent, &Enum.reverse/1)
    Agent.stop(agent)

    assert captured != [],
           "the adapter built NO outbound request through the harness capture transport — " <>
             "the leak gate cannot prove no leak. The call under test MUST route its outbound " <>
             "payload through its injectable transport hook so the harness can prove the " <>
             "payload carries no vault token."

    serialized = inspect(captured, limit: :infinity, printable_limit: :infinity)

    refute serialized =~ "vt_",
           "the adapter LEAKED a vault token (vt_) into its outbound payload — a vault " <>
             "reference must NEVER reach a provider, and it also leaks the vault scheme " <>
             "(INV-1/INV-7). Captured request(s): #{serialized}"

    for sentinel <- forbidden do
      refute serialized =~ sentinel,
             "the adapter LEAKED the forbidden plaintext sentinel #{inspect(sentinel)} into " <>
               "its outbound payload (INV-1) — an adapter that hand-reveals PII instead of " <>
               "using the framework render seam is caught here. Captured request(s): #{serialized}"
    end

    :ok
  end

  @doc """
  Surgical-redaction property (the delivery-shaped generalization of
  `Samen.Delivery.ProviderConformanceCase`'s ESP-scoped redaction assertion, which stays
  UNCHANGED — ADR-038 §4.5(d)). `redact.(payload)` must strip every `:pii_strings`
  substring, must RETAIN every `:retained_keys` key the fixture documents as non-PII, and
  — when no retained keys are documented — must not return an empty result for a
  non-empty payload. The last two are the anti-tautology halves: redaction must be
  surgical, never a wipe-everything no-op that trivially passes the PII check.
  """
  @spec assert_redaction!((map() -> map()), map(), keyword()) :: :ok
  def assert_redaction!(redact, payload, opts)
      when is_function(redact, 1) and is_map(payload) and is_list(opts) do
    pii_strings = Keyword.fetch!(opts, :pii_strings)
    retained_keys = Keyword.get(opts, :retained_keys, [])

    redacted = redact.(payload)

    assert is_map(redacted),
           "the redaction function must return a map, got: #{inspect(redacted)}"

    serialized = inspect(redacted, limit: :infinity, printable_limit: :infinity)

    for pii <- pii_strings do
      refute serialized =~ pii,
             "the redaction function LEAKED a PII fixture string (#{inspect(pii)}) into the " <>
               "persisted payload: #{serialized}"
    end

    for key <- retained_keys do
      assert Map.has_key?(redacted, key),
             "the redaction function dropped the non-PII key #{inspect(key)} that the fixture " <>
               "documents as retained — redaction must be surgical, not total."
    end

    if retained_keys == [] and map_size(payload) > 0 do
      refute map_size(redacted) == 0,
             "the redaction function returned an EMPTY map for a non-empty payload with no " <>
               "documented retained_keys — this cannot be distinguished from a wipe-everything " <>
               "no-op; document retained_keys to prove redaction is surgical."
    end

    :ok
  end
end
