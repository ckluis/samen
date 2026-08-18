defmodule Samen.Delivery.VendorFreeTest do
  @moduledoc """
  ADR-038 §8.3 vendor-string grep probe (INV-4), scoped to what T27 owns: ZERO
  case-insensitive `postmark`/`postmarkapp` occurrences in `samen_core/lib` +
  `samen_core/mix.exs`, and no compile-time reference to the `SamenPostmark`
  adapter module (runtime dispatch is via host config, never a compile-time
  alias). Mirrors `Samen.Billing.VendorFreeTest`'s T18 precedent for the
  billing/Stripe side.

  Unlike T18's billing probe, delivery carries NO pre-existing carve-out here —
  this is a brand-new behaviour finalized by this task, so the assertion is
  unconditional (no ratchet needed).
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../lib", __DIR__)
  @mix_exs Path.expand("../mix.exs", __DIR__)

  describe "ADR-038 §8.3: samen_core/mix.exs is vendor-string clean" do
    test "zero case-insensitive 'postmark' occurrences in mix.exs" do
      content = File.read!(@mix_exs)
      assert count_occurrences(content, "postmark") == 0
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

  describe "ADR-038 §8.3: samen_core/lib is vendor-string clean" do
    test "zero case-insensitive 'postmark' occurrences anywhere in lib" do
      offenders =
        @lib_root
        |> ex_files()
        |> Enum.map(fn path -> {relative(path), count_occurrences(File.read!(path), "postmark")} end)
        |> Enum.filter(fn {_path, count} -> count > 0 end)

      assert offenders == [],
             "unexpected 'postmark' occurrences leaked into samen_core/lib: #{inspect(offenders)}"
    end

    test "no SamenPostmark module is referenced from samen_core/lib" do
      offenders =
        @lib_root
        |> ex_files()
        |> Enum.map(fn path -> {relative(path), File.read!(path)} end)
        |> Enum.filter(fn {_path, content} ->
          String.contains?(content, "SamenPostmark") or String.contains?(content, "Elixir.SamenPostmark")
        end)

      assert offenders == [],
             "samen_core must never reference the samen_postmark adapter module by name " <>
               "(runtime dispatch is via host config, not a compile-time alias): #{inspect(offenders)}"
    end
  end

  # T31 addendum #5 — persist the per-vendor freeness for the two ESP adapters
  # T27 did NOT (Resend / SES). NOTE on needle choice: unlike the collision-free
  # brand "postmark", the bare words `resend` and `ses` occur legitimately in
  # samen_core as ENGLISH — `Samen.Identity.Confirm.resend/2` (the verification
  # re-send flow) and the ADR-035 abbrev `ses` for `Session` — so a bare-substring
  # ban would be unkeepable-by-construction, not a real invariant. We instead ban
  # the DISTINCTIVE vendor identifiers: the adapter module names, the AWS markers
  # (`amazonaws` host family + the `aws_signature` SigV4 dep + the `SESv2` API),
  # and the Resend API host (`resend.com`). Runtime dispatch is via host config;
  # samen_core never names an ESP vendor at compile time. The substantive
  # dependency property is already enforced elsewhere (adapters-absent INV-4 probe
  # DC#2 + the no-HTTP-client-dep assertion above + core standalone compile); this
  # is P3 defense-in-depth completeness.
  @resend_vendor_tokens ~w(SamenResend resend.com)
  @ses_vendor_tokens ~w(SamenSes amazonaws aws_signature SESv2)

  describe "ADR-038 §8.3: samen_core is Resend-vendor-string clean (T31 #5)" do
    test "no Resend vendor token in mix.exs" do
      assert vendor_offenders_in(File.read!(@mix_exs), @resend_vendor_tokens) == []
    end

    test "no Resend vendor token anywhere in lib" do
      assert lib_vendor_offenders(@resend_vendor_tokens) == []
    end
  end

  describe "ADR-038 §8.3: samen_core is SES-vendor-string clean (T31 #5)" do
    test "no SES vendor token in mix.exs" do
      assert vendor_offenders_in(File.read!(@mix_exs), @ses_vendor_tokens) == []
    end

    test "no SES vendor token anywhere in lib" do
      assert lib_vendor_offenders(@ses_vendor_tokens) == []
    end
  end

  describe "the vendor-token matcher is refutable (anti-tautology)" do
    test "count_occurrences detects a planted vendor token (matcher can fail)" do
      assert count_occurrences("alias SamenResend.Provider", "SamenResend") == 1
      assert count_occurrences(~s(host: "email.us-east-1.amazonaws.com"), "amazonaws") == 1
      assert count_occurrences("{:aws_signature, \"~> 0.4\"}", "aws_signature") == 1
      # and a clean string yields zero — the ban is not vacuously true
      assert count_occurrences("resend confirmation email", "SamenResend") == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp vendor_offenders_in(content, tokens) do
    for token <- tokens, count_occurrences(content, token) > 0, do: token
  end

  defp lib_vendor_offenders(tokens) do
    @lib_root
    |> ex_files()
    |> Enum.flat_map(fn path ->
      content = File.read!(path)
      for token <- tokens, count_occurrences(content, token) > 0, do: {relative(path), token}
    end)
  end

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
