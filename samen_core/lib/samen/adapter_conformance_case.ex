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
end
