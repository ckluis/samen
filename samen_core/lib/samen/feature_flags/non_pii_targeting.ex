defmodule Samen.FeatureFlags.NonPiiTargeting do
  @moduledoc """
  Write-time validation that a feature flag's `target_rules` key ONLY off governed,
  NON-PII attributes (ADR-020 §2 decision 3, design G6 §3.5 RP-F3). A targeting rule
  keyed on a PII-classified attribute (`email`, `phone`, `ssn`, …) is REFUSED at the
  earliest possible boundary — the flag WRITE — so a PII subject key can NEVER reach
  `evaluate/2` by construction.

  ## Two gates (default-DENY)

    1. **PII-name refusal** — the rule's `attribute` is run through the shared
       `Samen.PiiClassify.pii_name?/1` oracle (the same substring identifier-shape
       matcher the C4 `pii_classify` verifier uses: `email`, `phone`, `ssn`, `dob`,
       `address`, …). A hit is rejected. This is the load-bearing refusal RP-F3
       sabotages: allow the PII attribute → the refusal test FAILS.

    2. **Non-PII allowlist** — even a benign-named attribute must be in the bounded
       allowlist of governed targeting keys (`org_id`, `plan`, `tier`, `stage`,
       `role`, `region`). An attribute that is neither PII-named NOR allow-listed is
       refused too (default-deny — you cannot target on an arbitrary uncleared key).

  Both gates run on WRITE. `evaluate/2` therefore trusts its rules unconditionally;
  the non-PII guarantee is proven once, at the boundary, not re-checked per read.
  """
  use Ash.Resource.Validation

  alias Samen.PiiClassify

  # The bounded, governed set of non-PII targeting keys. These are the ONLY
  # attributes a target rule may key off — a config-row lever, not a subject query.
  @allowlist ~w(org_id plan tier stage role region)

  @impl true
  def validate(changeset, _opts, _context) do
    rules = Ash.Changeset.get_attribute(changeset, :target_rules)

    case check_rules(rules) do
      :ok ->
        :ok

      {:error, attribute, reason} ->
        {:error,
         field: :target_rules,
         message:
           "targeting rule keyed on #{inspect(attribute)} is refused: #{reason}. " <>
             "Target rules may key ONLY off governed non-PII attributes " <>
             "(#{Enum.join(@allowlist, ", ")})."}
    end
  end

  @doc """
  Pure check used by the validation and directly by the red-path test. Returns
  `:ok` or `{:error, attribute, reason}` on the FIRST refused rule.
  """
  @spec check_rules(term()) :: :ok | {:error, term(), String.t()}
  def check_rules(nil), do: :ok
  def check_rules([]), do: :ok

  def check_rules(rules) when is_list(rules) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case check_one(rule) do
        :ok -> {:cont, :ok}
        {:error, _, _} = err -> {:halt, err}
      end
    end)
  end

  # A non-list target_rules is structurally invalid — refuse rather than silently
  # accept (default-deny).
  def check_rules(other), do: {:error, other, "target_rules must be a list of rule maps"}

  defp check_one(%{} = rule) do
    attribute = rule["attribute"] || rule[:attribute]

    cond do
      not is_binary(attribute) or attribute == "" ->
        {:error, attribute, "missing or non-string attribute"}

      # GATE 1 — PII-name refusal (the shared classification oracle).
      PiiClassify.pii_name?(attribute) ->
        {:error, attribute, "matches a PII identifier pattern"}

      # GATE 2 — non-PII allowlist (default-deny for uncleared keys).
      attribute not in @allowlist ->
        {:error, attribute, "not in the governed non-PII targeting allowlist"}

      true ->
        :ok
    end
  end

  defp check_one(other), do: {:error, other, "rule is not a map"}

  @doc "The governed non-PII targeting allowlist (introspection for tests/UI)."
  @spec allowlist() :: [String.t()]
  def allowlist, do: @allowlist
end
