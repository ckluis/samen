defmodule Samen.AdapterConformanceCase do
  @moduledoc """
  The SHARED cross-family adapter-conformance kit (T188; WS-C; INV-4 —
  `samen_core/ci.sh:126`). Generalizes three narrower, pre-existing things into ONE
  `ExUnit.CaseTemplate` any adapter FAMILY can `use`:

    * `Samen.Delivery.ProviderConformanceCase` (T27, WS-C C1) — the delivery/ESP-scoped
      fixture-driven harness. **A13/T27-owned follow-up decision
      (`_orch/nodes/A13a/work/conformance-case-decision.md`): `ProviderConformanceCase` is
      now a thin SHIM over this kit.** Its own public macro signature and public function
      names/arities stay FIXED and unchanged for its callers; internally its bodies that
      have a delivery-shaped equivalent here (`load_fixtures!/1`, the deliver-leak gate,
      redaction) now delegate to this kit's `load_fixtures!/1`, `assert_capture_no_leak!/2`
      and `assert_redaction!/3` instead of duplicating their logic. This module is
      `ProviderConformanceCase`'s backing implementation for those concerns, not merely a
      separate sibling kit.
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

    # Same BYTE-RECOVERY views as `assert_redaction!/3` (see its moduledoc). The defect
    # `_orch/verify/A13b-verdict.json` refuted three times was a property of the
    # SERIALIZER, not of one assertion, so this gate reads its captured requests through
    # exactly the same probe rather than through `inspect/1` alone.
    views = leak_probe_views(captured)
    report = leak_probe_report(captured)

    refute leaked?(views, "vt_"),
           "the adapter LEAKED a vault token (vt_) into its outbound payload — a vault " <>
             "reference must NEVER reach a provider, and it also leaks the vault scheme " <>
             "(INV-1/INV-7). Captured request(s): #{report}"

    for sentinel <- forbidden do
      assert is_binary(sentinel) and sentinel != "",
             "every forbidden plaintext sentinel must be a NON-EMPTY binary, got: " <>
               "#{inspect(sentinel)} — an empty or non-binary sentinel cannot be searched " <>
               "for and would make this gate vacuous."

      refute leaked?(views, sentinel),
             "the adapter LEAKED the forbidden plaintext sentinel #{inspect(sentinel)} into " <>
               "its outbound payload (INV-1) — an adapter that hand-reveals PII instead of " <>
               "using the framework render seam is caught here. Captured request(s): #{report}"
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

  `:pii_strings` must be a NON-EMPTY list of NON-EMPTY binaries. A fixture that documents
  no PII strings would make the leak check pass on any payload whatsoever, so it is
  refused rather than honoured.

  ## The guarantee this gate delivers: BYTE RECOVERY

  The leak check is a contiguous-byte search (`:binary.match/2`, never `=~`, so no
  UTF-8 validity is assumed of anything being searched). It is therefore only as strong
  as the rendering underneath it, and the rendering must deliver this:

  > **Byte recovery.** For every leaf of the redacted term, the probe emits at least one
  > view in which that leaf's own bytes appear CONTIGUOUSLY and UNESCAPED — at every one
  > of the eight bit alignments, and in both the byte and the decimal-text reading of a
  > numeric leaf. For every list and every tuple it additionally emits the `iodata` and
  > the `chardata` concatenations of that list, which are the two joins the LANGUAGE
  > defines over it. It also emits the traversal-order concatenation of every leaf, and
  > of every non-key leaf. Detection is the UNION over all views: each PII string is
  > searched for in every view INDEPENDENTLY.

  Two properties follow, and they are the whole point:

    * **No separator, escape or delimiter the probe itself introduces can split a leaf's
      bytes**, because no view is ever the only view — a leaf's raw bytes are always
      emitted on their own as well as inside any joined view.
    * **Views are strictly ADDITIVE, never alternatives.** No branch may return a weaker
      serialization INSTEAD of a stronger one, so there is no degrade path and no branch
      that can hand back `:ok` on bytes that were never compared.

  This was learned the expensive way; THREE serializers have now been REFUTED here
  (`_orch/verify/A13b-verdict.json` and its `attempt2` / `attempt3` siblings):

    * `inspect/1` alone missed a PII substring inside a struct that `@derive`s `Inspect`
      to hide the field while its `Jason.Encoder` still serialized it;
    * a `Jason.encode/1`-with-`inspect/1`-fallback union missed the same substring
      whenever the payload was not JSON-encodable at ALL, because the union then
      collapsed back to `inspect/1` alone;
    * a TOTAL structural walk that visited every term still missed three ordinary leaf
      kinds because it visited them without RENDERING them: multi-chunk iodata (split by
      the walk's own newline separator), charlists (emitted as decimal integers) and
      non-byte-aligned bitstrings (emitted as a numeric `inspect/1` literal).

  Traversal totality was never the guarantee the gate needed. Byte recovery is.

  `inspect/1` and `Jason.encode/1` are still concatenated on top as strictly-additive
  views — they can only ever reveal MORE (an encoder that transforms a value) — and
  nothing depends on either of them succeeding. `Jason` is invoked defensively: it can
  both return `{:error, _}` and RAISE (an improper list crashes `Jason.Encode.list/3`),
  and either way the failure reason is itself emitted as a view, because a
  `Jason.EncodeError` carries the offending value.

  ## What this gate CANNOT see — the residual, enumerated

  The probe READS bytes; it does not decode, decrypt or compute. It cannot see:

    1. **PII that is not present as plaintext bytes anywhere in the term** — a base64,
       hex, percent-encoded, compressed or encrypted rendering. The plaintext is not in
       the payload, so a plaintext-survival gate is the wrong instrument for it.
    2. **PII that only exists once a computation the payload defers is run** — a format
       string plus its arguments, or a fun that would BUILD the string rather than
       capture it. Captured free variables ARE read (`:erlang.fun_info/2` `:env`), so a
       closure OVER a PII value is caught; a PII value compiled into a fun's BODY as a
       literal is not, because it lives in the module's code, not in the term.
    3. **PII that lives outside the term the redaction function returned** — in a
       process's state, an ETS table, or a file — where the payload holds only a pid,
       port or reference pointing at it. Those three are exactly what reaches the walk's
       final clause; the BEAM has eleven term types and the clauses above name the other
       eight plus structs, so that clause is enumerated, not open-ended.
    4. **PII assembled only from fragments the language defines no join over** — two
       sibling map values, or two struct fields. The traversal-order dense views recover
       such fragments when they are ADJACENT in traversal order, which covers the common
       shapes, but that is best-effort and not a guarantee; a substring search over any
       finite set of renderings cannot be complete against arbitrary re-assembly.

  Scope: this is a CONFORMANCE-ASSERTION strength property in test support — an assertion
  that could silently pass — not a proven PII leak in shipped production code. No
  production redaction path is implicated. It matters because every adapter package that
  adopts this kit inherits this gate's reliability.
  """
  @spec assert_redaction!((map() -> map()), map(), keyword()) :: :ok
  def assert_redaction!(redact, payload, opts)
      when is_function(redact, 1) and is_map(payload) and is_list(opts) do
    pii_strings = Keyword.fetch!(opts, :pii_strings)
    retained_keys = Keyword.get(opts, :retained_keys, [])

    assert is_list(pii_strings) and pii_strings != [],
           "assert_redaction!/3 was given an EMPTY :pii_strings list — the leak check " <>
             "would then pass on ANY payload, including an unredacted one. A redaction " <>
             "fixture must document at least one PII string it expects to be stripped."

    for pii <- pii_strings do
      assert is_binary(pii) and pii != "",
             "every :pii_strings entry must be a NON-EMPTY binary, got: #{inspect(pii)} — " <>
               "an empty or non-binary entry cannot be searched for and would make this " <>
               "gate vacuous."
    end

    redacted = redact.(payload)

    assert is_map(redacted),
           "the redaction function must return a map, got: #{inspect(redacted)}"

    views = leak_probe_views(redacted)
    report = leak_probe_report(redacted)

    for pii <- pii_strings do
      refute leaked?(views, pii),
             "the redaction function LEAKED a PII fixture string (#{inspect(pii)}) into the " <>
               "persisted payload: #{report}"
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

  # ==========================================================================
  # The leak probe. See the `assert_redaction!/3` moduledoc for the BYTE-RECOVERY
  # guarantee these functions exist to deliver, and for the enumerated residual.
  # Shared by `assert_redaction!/3` and `assert_capture_no_leak!/2`.
  # ==========================================================================

  # Byte-exact, UTF-8-agnostic containment. `=~` is deliberately NOT used: the bit-
  # alignment views below are arbitrary byte sequences, not necessarily valid strings.
  defp leaked?(views, needle) when is_binary(needle) and byte_size(needle) > 0 do
    Enum.any?(views, fn view -> :binary.match(view, needle) != :nomatch end)
  end

  # Human-readable diagnostic for a failure message ONLY. Never the basis of a pass:
  # detection is `leaked?/2` over `leak_probe_views/1`.
  defp leak_probe_report(term) do
    IO.iodata_to_binary([
      inspect(term, limit: :infinity, printable_limit: :infinity),
      ?\n,
      term |> leak_probe_leaves() |> elem(0) |> dense_view(:text, :all)
    ])
  end

  # The full, ADDITIVE view set. Every PII string is searched in each of these
  # independently, so no view can weaken another.
  defp leak_probe_views(term) do
    {leaves, joins} = leak_probe_leaves(term)

    dense = [
      dense_view(leaves, :bytes, :all),
      dense_view(leaves, :text, :all),
      dense_view(leaves, :bytes, :values),
      dense_view(leaves, :text, :values)
    ]

    leaf_views = Enum.flat_map(leaves, fn {_key?, _bytes, _text, views} -> views end)

    protocol_views = [
      inspect(term, limit: :infinity, printable_limit: :infinity) | json_views(term)
    ]

    (leaf_views ++ joins ++ dense ++ protocol_views)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp leak_probe_leaves(term) do
    {leaves, joins} = probe_walk(term, false, {[], []})
    {Enum.reverse(leaves), Enum.reverse(joins)}
  end

  # Traversal-order concatenation. `:all` includes map keys; `:values` omits them, so
  # two sibling map values that are adjacent in traversal order still concatenate.
  defp dense_view(leaves, field, scope) do
    leaves
    |> Enum.filter(fn {key?, _bytes, _text, _views} -> scope == :all or not key? end)
    |> Enum.map(fn {_key?, bytes, text, _views} ->
      case field do
        :bytes -> bytes
        :text -> text
      end
    end)
    |> IO.iodata_to_binary()
  end

  # Additive only. Jason failing removes NO coverage — the byte-recovery views above are
  # complete without it — and the failure reason is itself emitted, because a
  # `Jason.EncodeError` carries the value it choked on. Nothing is swallowed.
  defp json_views(term) do
    case safe_json(term) do
      {:ok, json} -> [json]
      {:error, reason} -> [inspect(reason, limit: :infinity, printable_limit: :infinity)]
    end
  end

  defp safe_json(term) do
    case Jason.encode(term) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # -------------------------------------------------------------------- the walk
  # Every clause matches on the SHAPE of the term, so no protocol implementation —
  # `Inspect`, `Jason.Encoder` or any other — sits between the probe and the bytes.
  # Structs are read through `Map.from_struct/1`, which ignores `@derive {Inspect,
  # only: [...]}` entirely.

  defp probe_walk(term, key?, acc) when is_struct(term) do
    acc = probe_walk(term.__struct__, key?, acc)
    probe_walk(Map.from_struct(term), key?, acc)
  end

  defp probe_walk(term, key?, acc) when is_map(term) do
    Enum.reduce(Map.to_list(term), acc, fn {key, value}, acc ->
      probe_walk(value, key?, probe_walk(key, true, acc))
    end)
  end

  # `is_list/1` is true of improper lists and of `[]` as well as of proper lists, so a
  # cons cell can never escape this clause. The join views are taken HERE, at every
  # list, because `IO.iodata_to_binary/1` is defined over arbitrarily nested lists.
  defp probe_walk(term, key?, acc) when is_list(term) do
    walk_elements(term, key?, add_join_views(term, acc))
  end

  defp probe_walk(term, key?, acc) when is_tuple(term) do
    elements = Tuple.to_list(term)
    walk_elements(elements, key?, add_join_views(elements, acc))
  end

  # Covers binaries AND non-byte-aligned bitstrings. All eight bit alignments are
  # emitted, so PII bytes sitting at ANY bit offset are recovered by exactly one of
  # them; alignment 0 is the leaf's own bytes and is what the dense views concatenate.
  defp probe_walk(term, key?, acc) when is_bitstring(term) do
    [aligned | _] = views = bit_alignment_views(term)
    add_leaf(acc, key?, aligned, aligned, views)
  end

  # Both readings: the BYTE reading (so a charlist's codepoints reassemble into its
  # text) and the DECIMAL-TEXT reading (so numeric PII carried as integers is found).
  defp probe_walk(term, key?, acc) when is_integer(term) do
    text = Integer.to_string(term)
    bytes = integer_bytes(term)
    add_leaf(acc, key?, bytes, text, [bytes, text | extra_integer_views(term)])
  end

  defp probe_walk(term, key?, acc) when is_float(term) do
    text = Float.to_string(term)
    add_leaf(acc, key?, text, text, [text])
  end

  defp probe_walk(term, key?, acc) when is_atom(term) do
    text = Atom.to_string(term)
    add_leaf(acc, key?, text, text, [text, inspect(term)])
  end

  # A fun's CAPTURED FREE VARIABLES are readable, so a closure over a PII value is not a
  # hiding place. (A PII literal compiled into the fun's BODY is not in the term at all
  # — residual 2 in the moduledoc.) A fun's environment is fixed at creation and BEAM
  # terms cannot be cyclic, so this recursion always terminates.
  defp probe_walk(term, key?, acc) when is_function(term) do
    acc = add_leaf(acc, key?, "", "", [inspect(term)])
    probe_walk(fun_environment(term), key?, acc)
  end

  # ENUMERATED catch-all. The BEAM has eleven term types; the clauses above name atom,
  # integer, float, bitstring, list, tuple, map and fun, plus structs. What reaches here
  # is exactly a pid, a port or a reference — a HANDLE to state that lives outside the
  # term the redaction function returned, carrying no bytes of its own. Residual 3.
  defp probe_walk(term, key?, acc) do
    rendered = inspect(term, limit: :infinity, printable_limit: :infinity)
    add_leaf(acc, key?, rendered, rendered, [rendered])
  end

  defp walk_elements([head | tail], key?, acc) do
    walk_elements(tail, key?, probe_walk(head, key?, acc))
  end

  defp walk_elements([], _key?, acc), do: acc
  defp walk_elements(improper_tail, key?, acc), do: probe_walk(improper_tail, key?, acc)

  defp add_leaf({leaves, joins}, key?, bytes, text, views) do
    {[{key?, bytes, text, views |> Enum.uniq() |> Enum.reject(&(&1 == ""))} | leaves], joins}
  end

  # The two joins the LANGUAGE defines over a list: `iodata` (bytes) and `chardata`
  # (codepoints). They are ADDITIVE, not alternatives — a non-latin1 charlist recovers
  # only through the chardata one, and a list of raw bytes only through the iodata one.
  defp add_join_views(elements, {leaves, joins}) do
    joins =
      [
        safe_join(fn -> IO.iodata_to_binary(elements) end),
        safe_join(fn -> List.to_string(elements) end)
      ]
      |> Enum.reduce(joins, fn
        {:ok, joined}, acc -> [joined | acc]
        :error, acc -> acc
      end)

    {leaves, joins}
  end

  defp safe_join(fun) do
    case fun.() do
      joined when is_binary(joined) -> {:ok, joined}
      _other -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp bit_alignment_views(bits) do
    0..7
    |> Enum.map(&align_bits(bits, &1))
    |> Enum.uniq()
  end

  defp align_bits(bits, offset) when bit_size(bits) >= offset do
    <<_::size(^offset), rest::bitstring>> = bits
    padding = rem(8 - rem(bit_size(rest), 8), 8)
    <<rest::bitstring, 0::size(padding)>>
  end

  defp align_bits(_bits, _offset), do: ""

  defp integer_bytes(int)
       when int >= 0 and int <= 0x10FFFF and (int < 0xD800 or int > 0xDFFF),
       do: <<int::utf8>>

  defp integer_bytes(int) when int >= 0, do: :binary.encode_unsigned(int)
  defp integer_bytes(int), do: Integer.to_string(int)

  defp extra_integer_views(int) when int >= 0, do: [:binary.encode_unsigned(int)]
  defp extra_integer_views(_int), do: []

  defp fun_environment(fun) do
    case :erlang.fun_info(fun, :env) do
      {:env, env} when is_list(env) -> env
      _other -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end
