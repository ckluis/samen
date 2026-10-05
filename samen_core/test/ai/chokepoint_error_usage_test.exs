defmodule Samen.AI.ChokepointErrorUsageTest do
  @moduledoc """
  Issue #11 / ADR-048 §6 Level 2 constraint 1 — the chokepoint keeps a failed call's
  token usage for the agent loop to bill, WITHOUT widening EG6.

  `{:error, reason, usage}` is the one channel carrying adapter-authored data past the
  normalizer, so it is NARROWER than the reason channel:

    * the reason still goes through `normalize_error/2` (an atom passes; anything richer
      becomes the content-free `{:provider_error, provider}`);
    * the usage is REBUILT from an allowlist: exactly `:input_tokens`, `:cached_input_tokens`
      (input served from the prompt cache, issue #74) and `:output_tokens`, each a
      non-negative integer (anything else is 0), and no other key travels;
    * a non-map or a struct in the usage slot is not usage: the whole return reduces to
      the content-free 2-tuple;
    * only a caller that passes `error_usage: true` sees the 3-tuple. Every other caller
      gets the `{:error, reason}` it always has.
  """
  use ExUnit.Case, async: true

  alias Samen.AI.Chokepoint
  alias Samen.AI.MaskedPayload

  # A raw provider: returns exactly what its config says, so the chokepoint's own guard is
  # what is under test (the Scripted double refuses some shapes before they get here).
  defmodule Raw do
    @behaviour Samen.AI.Provider
    def complete(%MaskedPayload{}, %{return: result}), do: result
    def embed(%MaskedPayload{}, _config), do: {:error, :not_implemented}
  end

  @canary "the whole prompt: Ada Lovelace, 12 Analytical Way"

  defp complete(result, opts \\ [error_usage: true]),
    do: Chokepoint.complete(Raw, %{return: result}, :complete, ["p"], opts)

  test "the usage is kept, as exactly three non-negative integers, for a caller that asks" do
    assert complete({:error, :context_overflow, %{input_tokens: 5, output_tokens: 2}}) ==
             {:error, :context_overflow,
              %{input_tokens: 5, cached_input_tokens: 0, output_tokens: 2}}
  end

  test "the cached-input bucket travels as its own count (issue #74)" do
    assert complete(
             {:error, :context_overflow,
              %{input_tokens: 5, cached_input_tokens: 70, output_tokens: 2}}
           ) ==
             {:error, :context_overflow,
              %{input_tokens: 5, cached_input_tokens: 70, output_tokens: 2}}
  end

  test "EG6: no other key in the usage map travels — the map is rebuilt, never passed through" do
    usage = %{:input_tokens => 5, :output_tokens => 2, "leak" => @canary, :prompt => @canary}

    result = complete({:error, :context_overflow, usage})

    # Positive control: the two counts DID travel, so the refutes are not vacuous.
    assert {:error, :context_overflow, kept} = result
    assert kept == %{input_tokens: 5, cached_input_tokens: 0, output_tokens: 2}
    refute inspect(result) =~ "Lovelace"
  end

  test "EG6: the reason is still normalized — a rich reason never travels beside the usage" do
    result = complete({:error, {:boom, @canary}, %{input_tokens: 5, output_tokens: 2}})

    assert result ==
             {:error, {:provider_error, Raw},
              %{input_tokens: 5, cached_input_tokens: 0, output_tokens: 2}}

    refute inspect(result) =~ "Lovelace"
  end

  test "a count that is not a non-negative integer bills 0, never a guess" do
    assert complete(
             {:error, :context_overflow,
              %{input_tokens: -1, cached_input_tokens: 1.5, output_tokens: "9"}}
           ) ==
             {:error, :context_overflow,
              %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0}}

    assert complete({:error, :context_overflow, %{}}) ==
             {:error, :context_overflow,
              %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0}}
  end

  test "EG6: a charlist, a struct or an exception in the usage slot reduces to the content-free 2-tuple" do
    for bad <- [~c"#{@canary}", %URI{path: @canary}, %RuntimeError{message: @canary}] do
      result = complete({:error, :context_overflow, bad})
      assert result == {:error, {:provider_error, Raw}}
      refute inspect(result) =~ "Lovelace"
    end
  end

  test "a caller that does not ask gets the two-element error it always has" do
    with_usage = {:error, :context_overflow, %{input_tokens: 5, output_tokens: 2}}

    assert complete(with_usage, []) == {:error, :context_overflow}
    assert complete(with_usage, error_usage: false) == {:error, :context_overflow}
    # Positive control: the same return DOES carry usage when asked.
    assert {:error, :context_overflow, %{input_tokens: 5}} = complete(with_usage)
  end

  test "Samen.AI.complete/4 keeps the two-element error by default" do
    with_usage = {:error, :context_overflow, %{input_tokens: 5, output_tokens: 2}}
    provider = {Raw, %{return: with_usage}}

    assert Samen.AI.complete(nil, ["p"], %{}, provider: provider, grounding: %{}) ==
             {:error, :context_overflow}

    assert Samen.AI.complete(nil, ["p"], %{},
             provider: provider,
             grounding: %{},
             error_usage: true
           ) ==
             {:error, :context_overflow,
              %{input_tokens: 5, cached_input_tokens: 0, output_tokens: 2}}
  end

  test "a raised exception still reduces to the 2-tuple — a raise has no honest usage" do
    defmodule Raises do
      def complete(%MaskedPayload{}, _config), do: raise("boom: " <> "Lovelace")
    end

    assert Chokepoint.complete(Raises, %{}, :complete, ["p"], error_usage: true) ==
             {:error, {:provider_error, Raises}}
  end
end
