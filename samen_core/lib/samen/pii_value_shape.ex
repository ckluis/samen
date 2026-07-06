defmodule Samen.PiiValueShape do
  @moduledoc """
  Shared **value-shape heuristic** for PII-shaped literals (email / SSN / phone /
  space-separated name).

  This is the single source of truth for "does this string *look like* a PII
  value?" — extracted so the two call sites share one set of regexes instead of
  duplicating them:

    * `Samen.PiiClassify` (C4) — flags a NEW plain-typed column whose seed/default
      value is PII-shaped (build-time schema lint).
    * `Samen.WideEvent` (J2 runtime guard) — rejects a PII-shaped literal stuffed
      into a bounded `:opaque_id` / `:token` field, or a PII/name-shaped atom in an
      open `:enum` (`:action`).

  ## What this is — and is NOT

  This is a **value-shape heuristic, not a taint proof.** It recognises the obvious
  literal shapes (an email has an `@` and a dotted domain; an SSN is `NNN-NN-NNNN`;
  a phone is a grouped 10-digit run; a personal name has an internal space). It does
  **not** and cannot prove a value is or isn't PII — a single-token opaque handle
  that happens to be a real surname (`"anders"`) is indistinguishable from a
  legitimate token by shape alone.

  For `Samen.WideEvent` the load-bearing J2 defence is the **schema** (no
  free-string field exists — `mix samen.verify.sink_schema`), not this runtime
  heuristic. The heuristic is a belt that catches the obvious "a host typed a PII
  literal into an opaque-ID field" mistake; it is not a completeness guarantee.
  """

  # Email-shaped value: local@domain.tld
  @email_regex ~r/^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$/

  # SSN-shaped value: NNN-NN-NNNN or NNNNNNNNN
  @ssn_regex ~r/^\d{3}-?\d{2}-?\d{4}$/

  # Phone-shaped: various common formats.
  # E.g. +1-800-555-1234, (800) 555-1234, 800.555.1234, 8005551234, +15551234567
  @phone_regex ~r/^(\+\d{1,3}[\s\-.]?)?\(?\d{3}\)?[\s\-.]?\d{3}[\s\-.]?\d{4}$/

  @typedoc "The kind of PII shape a value matched, or nil for no match."
  @type shape :: :email | :ssn | :phone | :name | nil

  @doc """
  Classify a string against the PII value-shape heuristics **excluding** the
  space-separated-name shape.

  Returns `{true, :email | :ssn | :phone}` on a hit, `{false, nil}` otherwise.

  This is the C4 seed-value heuristic: a name-shaped value is intentionally NOT
  matched here (a two-word `:default` in a schema is not a reliable PII signal),
  so `Samen.PiiClassify` keeps its historical behaviour unchanged.
  """
  @spec classify_value(String.t()) :: {boolean(), :email | :ssn | :phone | nil}
  def classify_value(value) when is_binary(value) do
    cond do
      Regex.match?(@email_regex, value) -> {true, :email}
      Regex.match?(@ssn_regex, value) -> {true, :ssn}
      Regex.match?(@phone_regex, value) -> {true, :phone}
      true -> {false, nil}
    end
  end

  def classify_value(_), do: {false, nil}

  @doc """
  The runtime-guard variant: `classify_value/1` PLUS the space-separated-name
  shape (a value with internal whitespace between word characters).

  Returns `{true, :email | :ssn | :phone | :name}` on a hit, `{false, nil}`
  otherwise. Used by `Samen.WideEvent.bounded_id_shape?/1` to reject a PII literal
  in a bounded ID/token field.
  """
  @spec classify_id_value(String.t()) :: {boolean(), shape()}
  def classify_id_value(value) when is_binary(value) do
    case classify_value(value) do
      {true, shape} -> {true, shape}
      {false, nil} -> if name_shaped?(value), do: {true, :name}, else: {false, nil}
    end
  end

  def classify_id_value(_), do: {false, nil}

  @doc """
  True if the value has PII-*literal* shape usable in a bounded ID/token field —
  i.e. `classify_id_value/1` matched. Convenience boolean for guard call sites.
  """
  @spec pii_shaped_id?(String.t()) :: boolean()
  def pii_shaped_id?(value) do
    case classify_id_value(value) do
      {true, _} -> true
      {false, _} -> false
    end
  end

  @doc """
  True if a printable form contains an internal space/tab/newline between word
  characters — the "someone put a full name here" shape.
  """
  @spec name_shaped?(String.t()) :: boolean()
  def name_shaped?(value) when is_binary(value) do
    Regex.match?(~r/\S[ \t\n]+\S/u, value)
  end

  def name_shaped?(_), do: false
end
