defmodule Samen.ApiKeyAuthPlugTemplateTest do
  @moduledoc """
  The generated `KeyAuthPlug` template answers a FAILED membership load as `:unavailable` (503), never as `:error`
  (an actor-less pass / 401): the same arm `demo/test/api_key_lookup_unavailable_test.exs` proves LIVE on the demo's
  copy. The template is EEx and is not executed here, so this pins the arm's structure (the `{:error, _}` clause of the
  `Ash.load` case reports by name and returns `:unavailable`; the fall-through is the only `:error`), not just its text.
  """
  use ExUnit.Case, async: true

  @template Path.expand("../priv/templates/api_key_auth_plug_ex.eex", __DIR__)

  # the clauses of the `case Ash.load(key_row, ...)` in build_actor/1, as {pattern_source, body_source}
  defp load_clauses(src) do
    [_, after_load] = String.split(src, "case Ash.load(key_row", parts: 2)
    [case_body | _] = String.split(after_load, "\n    end\n", parts: 2)

    case_body
    |> String.split(~r/\n\s{6}(?=\{|_)/)
    |> Enum.drop(1)
    |> Enum.map(fn clause ->
      [pattern, body] = String.split(clause, "->", parts: 2)
      {String.trim(pattern), String.trim(body)}
    end)
  end

  # true iff the error arm reports by name and ends in :unavailable (never :error), and the fall-through is the only :error
  defp unavailable_arm?(src) do
    match?(
      [{"{:ok, %{membership:" <> _, _}, {"{:error, error}", err}, {"_", ":error"}] when is_binary(err),
      load_clauses(src)
    ) and
      (
        [_, {_, err}, _] = load_clauses(src)
        err =~ "Samen.Web.Reads.Guard.report(:api_key_membership_load, nil, error)" and String.ends_with?(err, ":unavailable")
      )
  end

  test "a failed membership load is reported by name and answers :unavailable; only the unmatched fall-through is :error" do
    assert unavailable_arm?(File.read!(@template))
  end

  test "control: the same check REFUSES a template whose error arm answers :error, or that does not report" do
    src = File.read!(@template)
    arm = "report(:api_key_membership_load, nil, error)\n        :unavailable"
    assert src =~ arm

    refute unavailable_arm?(String.replace(src, arm, "report(:api_key_membership_load, nil, error)\n        :error"))
    refute unavailable_arm?(String.replace(src, arm, "nil\n        :unavailable"))
  end
end
