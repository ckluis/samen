defmodule Samen.Verifiers.NoPanColumns do
  @moduledoc """
  Compile-time Spark verifier enforcing the **no-PAN invariant** (ADR-038 §3.5 B5;
  T23; spec §B5 "card on file via hosted provider surfaces only … no PAN touches
  samen"). Card-on-file lives EXCLUSIVELY in the hosted billing provider's own
  vault (billing portal / SetupIntent hosted session); samen never stores a raw
  card number (PAN) or a card security code (CVC/CVV), full stop.

  Unlike `Samen.Verifiers.NoPiiColumns` (scoped to the aggregate plane only), this
  verifier is wired into the BASE `Samen.Extension` — it runs on **every** Samen
  resource, in every plane (tenant/operator/aggregate), in every host app. No
  resource anywhere may declare a PAN/CVC-shaped attribute, ever. This is what
  makes done-criterion 1 ("no column matching PAN/card-number/cvc shapes
  ANYWHERE") a structural, governed-by-construction guarantee rather than a
  convention someone could forget: a future resource that accidentally grows a
  `card_number` field simply does not compile, in ANY host.

  ## Shape matching (token-based — avoids false positives on legitimate words)

  An attribute name is lower-cased and split on `_` into tokens. It is a
  violation when:

    * a WHOLE token is `pan`, `cvc`, `cvv`, `cvc2`, or `cvv2`;
    * the tokens contain BOTH (`card` OR `cc`) and `number` (in any position/order);
    * the tokens contain BOTH `security` and `code`;
    * the un-split lower-cased name contains the no-underscore spellings
      `cardnumber`, `cardnum`, or `ccnum`.

  Token-based (not raw substring) matching is deliberate: a bare `String.contains?`
  on `"pan"` would false-positive on `expansion`/`company`/`spanish`-shaped words,
  and a bare `"card"` substring would false-positive on the real, unrelated
  `medical_card_expiry` attribute (`driftwood/lib/driftwood/freight.ex` — a DOT
  medical-certification expiry date, nothing to do with payment cards). Splitting
  on `_` and requiring whole-token/token-pair matches avoids both.

  ## Explicitly NOT flagged (ADR-038 §3.5 allowed display metadata)

  `brand`, `last4`, `exp_month`, `exp_year` — the hosted provider's own
  "non-PAN by industry definition" payment-method display metadata. These are
  fine to mirror; only the PAN/CVC itself is forbidden.

  ## Why compile-time, base-wired

  The doc's B5 claim is structural: "no PAN ever touches samen." A runtime-only
  policy could be misconfigured or simply never run for a new resource; a
  compile-time check on the BASE extension makes a PAN-shaped attribute not
  compile, anywhere, by construction — the same discipline `Samen.Type.VaultField`
  applies to raw PII writes. The whole-app CI backstop
  (`mix samen.verify.no_pan_columns`) sweeps every configured domain's resources
  AND their live physical tables for the same violations (catching a resource
  that somehow bypassed the DSL via a raw-SQL migration).

  ## Why a transformer ALSO exists (`Samen.Transformers.NoPanColumns`)

  This module is the Spark VERIFIER — the named rule source for introspection and
  the whole-app sweep. But in this Ash/Spark version a verifier's `{:error, _}`
  does NOT reliably ABORT `Code.compile_string` (the same quirk
  `Samen.Aggregate.NoPiiTransformer`'s moduledoc documents for its own verifier
  twin). To make the compile-time guarantee actually fail-closed,
  `Samen.Transformers.NoPanColumns` runs the IDENTICAL `violations/2` rule as a
  TRANSFORMER (whose `{:error, Spark.Error.DslError}` return reliably aborts the
  build) — it is wired into the base `Samen.Extension`'s `transformers:` list
  alongside this verifier in `verifiers:`. Both call this module's `violations/2` —
  one rule, no drift.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @whole_token_hits ~w(pan cvc cvv cvc2 cvv2)
  @no_underscore_hits ~w(cardnumber cardnum ccnum)

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    case violations(dsl_state, module) do
      [] ->
        :ok

      [{path, message} | _] ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: path,
           message: message
         )}
    end
  end

  @doc """
  Compute the PAN-shape violations for a resource's DSL state (or a compiled
  module). Returns a list of `{path, message}` tuples — empty means clean.
  Separated from `verify/1` so the mix-task backstop can reuse the EXACT same
  rule (single source of truth for the shape-matching logic).
  """
  @spec violations(Spark.Dsl.t() | module(), module()) :: [{list(), String.t()}]
  def violations(dsl_state, module) do
    dsl_state
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(fn attr -> pan_shaped?(to_string(attr.name)) end)
    |> Enum.map(fn attr ->
      {[:attributes, attr.name],
       "resource #{inspect(module)} declares attribute #{inspect(attr.name)}, which is " <>
         "PAN/CVC-shaped. No samen resource may EVER store a raw card number or a card " <>
         "security code (ADR-038 §3.5 B5 no-PAN invariant) — card-on-file lives exclusively " <>
         "in the hosted billing provider's own vault. Non-PAN display metadata (brand/last4/" <>
         "exp_month/exp_year) is explicitly allowed; rename or remove this attribute."}
    end)
  end

  @doc """
  Is `name` (a string) shaped like a raw PAN or a card security code? Exposed
  (not just a private helper) so the mix-task physical-column sweep can apply
  the IDENTICAL rule to live `information_schema` column names.
  """
  @spec pan_shaped?(String.t()) :: boolean()
  def pan_shaped?(name) when is_binary(name) do
    lower = String.downcase(name)
    tokens = String.split(lower, "_")

    Enum.any?(@whole_token_hits, &(&1 in tokens)) or
      (("card" in tokens or "cc" in tokens) and "number" in tokens) or
      ("security" in tokens and "code" in tokens) or
      Enum.any?(@no_underscore_hits, &String.contains?(lower, &1))
  end
end
