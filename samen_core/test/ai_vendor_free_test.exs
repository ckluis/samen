defmodule Samen.AI.VendorFreeTest do
  @moduledoc """
  INV-4 (ADR-043 §5.1; the `Samen.Delivery.VendorFreeTest` mirror for the AI plane):
  `samen_core` is a hand-built kernel with ZERO vendor AI deps. Asserts no
  `anthropic`/`SamenAnthropic` string in `samen_core/lib` + `mix.exs`, no NEW vendor HTTP
  client dep in `mix.exs`, and — the ADR-037 §5.6 ruling — no `ash_ai` dependency. Runtime
  provider dispatch is via host config, never a compile-time alias, so the grep stays green
  with `samen_anthropic` absent.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../lib", __DIR__)
  @mix_exs Path.expand("../mix.exs", __DIR__)

  describe "samen_core/mix.exs is AI-vendor clean" do
    test "zero case-insensitive 'anthropic' occurrences in mix.exs" do
      assert count(File.read!(@mix_exs), "anthropic") == 0
    end

    test "no ash_ai dependency (ADR-037 §5.6 REJECT — the kernel is hand-built)" do
      content = File.read!(@mix_exs)
      refute String.contains?(content, ":ash_ai"),
             "samen_core must never gain ash_ai (ADR-037 §5.6): the AI kernel is hand-built"
    end

    test "no NEW vendor HTTP client dep introduced by the AI plane" do
      content = File.read!(@mix_exs)

      for http <- ~w(:req :hackney :finch :httpoison) do
        refute String.contains?(content, http),
               "samen_core/mix.exs must stay HTTP-client-free (INV-4) — found #{http}"
      end
    end
  end

  describe "samen_core/lib is AI-vendor clean" do
    test "zero case-insensitive 'anthropic' occurrences anywhere in lib" do
      offenders =
        @lib_root
        |> ex_files()
        |> Enum.map(fn p -> {rel(p), count(File.read!(p), "anthropic")} end)
        |> Enum.filter(fn {_p, n} -> n > 0 end)

      assert offenders == [], "unexpected 'anthropic' leaked into samen_core/lib: #{inspect(offenders)}"
    end

    test "no SamenAnthropic module is referenced from samen_core/lib" do
      offenders =
        @lib_root
        |> ex_files()
        |> Enum.filter(fn p -> String.contains?(File.read!(p), "SamenAnthropic") end)
        |> Enum.map(&rel/1)

      assert offenders == [],
             "samen_core must never reference the samen_anthropic adapter module by name " <>
               "(runtime dispatch is via host config): #{inspect(offenders)}"
    end
  end

  describe "the vendor-token matcher is refutable (anti-tautology)" do
    test "count/2 detects a planted token and a clean string yields zero" do
      assert count("alias SamenAnthropic.Provider", "SamenAnthropic") == 1
      assert count(~s({:anthropic_client, "~> 1.0"}), "anthropic") == 1
      assert count("the kernel is hand-built", "anthropic") == 0
    end
  end

  defp ex_files(root), do: Path.wildcard(Path.join(root, "**/*.ex"))
  defp rel(path), do: Path.relative_to(path, @lib_root)

  defp count(content, needle) do
    content |> String.downcase() |> String.split(String.downcase(needle)) |> length() |> Kernel.-(1)
  end
end
