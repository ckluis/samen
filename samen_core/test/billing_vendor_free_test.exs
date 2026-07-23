defmodule Samen.Billing.VendorFreeTest do
  @moduledoc """
  ADR-038 §8.3 vendor-string grep probe (INV-4), owned by T18 and TIGHTENED by T106.

  `samen_core` must carry ZERO vendor coupling from the billing adapter work (INV-4):
  no vendor module reference, no vendor HTTP client dep, and no bare case-insensitive
  "stripe" string ANYWHERE in `samen_core/lib`.

  ## Ratchet 24 → 0 (T106 — the carve-out is CLOSED)

  `lib/samen/scopes/billing/blueprint.ex` historically named its provider-mirror
  external-reference attributes with vendor-branded names (`stripe_customer_id` and
  siblings), documented as the ONE ratcheted carve-out (baseline 24 occurrences). T106
  renamed every one to the vendor-neutral `provider_<object>_ref` shape (updating the
  four downstream hosts' committed migrations + `schema.dict.json` catalogs), so the
  carve-out now reads ZERO. Per the original carve-out test's own exit instruction
  ("if this ever reads 0, delete this carve-out test and fold the file back into the
  strict check above"), the ratchet test is retired and the strict zero-in-`lib` check
  below now covers blueprint.ex with NO exception.

  This is the T18-owned slice of the full INV-4 probe; the T31 phase-gate probe
  (ADR-038 §8.4) additionally moves all four adapter dirs out of the tree and reruns
  `samen_core`/`samen_web`'s suites with everything absent — this test does not
  attempt that (samen_core never depends on samen_stripe in the first place, so
  there is nothing to move for THIS probe to be meaningful).
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../lib", __DIR__)
  @mix_exs Path.expand("../mix.exs", __DIR__)

  describe "count_occurrences self-test (anti-tautology floor)" do
    # The probes below assert a count of ZERO. A test that asserts `== 0` is only
    # meaningful if the counter it trusts can actually PRODUCE a non-zero count — a
    # broken counter that always returns 0 would make every scan below silently
    # vacuous. This self-test pins the counter to a fixture with a KNOWN number of
    # case-insensitive "stripe" hits, so the whole file cannot pass tautologically.
    test "counts case-insensitive occurrences (proves the scan is refutable)" do
      # 3 hits (STRIPE / Stripe / stripe), case-insensitive; the surrounding letters
      # never form a fourth.
      assert count_occurrences("aSTRIPEb Stripe c-stripe-d", "stripe") == 3
      assert count_occurrences("no vendor here", "stripe") == 0
      # A real leak (one attribute reintroduced) WOULD be caught: prove the counter
      # sees the exact shape the ratchet used to tolerate.
      assert count_occurrences("attribute(:stripe_customer_id, :string)", "stripe") == 1
    end
  end

  describe "ADR-038 §8.3: samen_core/mix.exs is vendor-string clean" do
    test "zero case-insensitive 'stripe' occurrences in mix.exs" do
      content = File.read!(@mix_exs)
      assert count_occurrences(content, "stripe") == 0
    end

    test "no vendor HTTP client dep (req/hackney/finch/httpoison) in samen_core/mix.exs" do
      content = File.read!(@mix_exs)

      for vendor_http <- ~w(:req :hackney :finch :httpoison) do
        refute String.contains?(content, vendor_http),
               "samen_core/mix.exs must never gain an HTTP client dep (INV-4/ADR-038 §8.2) " <>
                 "— found #{vendor_http}"
      end
    end
  end

  describe "ADR-038 §8.3: samen_core/lib is vendor-string clean (ratchet 0, no carve-out)" do
    test "zero case-insensitive 'stripe' occurrences ANYWHERE in samen_core/lib" do
      offenders =
        @lib_root
        |> ex_files()
        |> Enum.map(fn path -> {relative(path), count_occurrences(File.read!(path), "stripe")} end)
        |> Enum.filter(fn {_path, count} -> count > 0 end)

      assert offenders == [],
             "'stripe' leaked into samen_core/lib — billing (and every other scope) must " <>
               "stay vendor-generic (INV-4). The T106 rename drove this to zero with no " <>
               "documented exception; any occurrence here is a new vendor coupling: " <>
               "#{inspect(offenders)}"
    end

    test "no SamenStripe (or other vendor adapter) module is referenced from samen_core/lib" do
      offenders =
        @lib_root
        |> ex_files()
        |> Enum.map(fn path -> {relative(path), File.read!(path)} end)
        |> Enum.filter(fn {_path, content} ->
          String.contains?(content, "SamenStripe") or String.contains?(content, "Elixir.SamenStripe")
        end)

      assert offenders == [],
             "samen_core must never reference the samen_stripe adapter module by name " <>
               "(runtime dispatch is via host config, not a compile-time alias): #{inspect(offenders)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp ex_files(root) do
    Path.wildcard(Path.join(root, "**/*.ex"))
  end

  defp relative(path), do: Path.relative_to(path, @lib_root)

  defp count_occurrences(content, needle) do
    content
    |> String.downcase()
    |> String.split(String.downcase(needle))
    |> length()
    |> Kernel.-(1)
  end
end
