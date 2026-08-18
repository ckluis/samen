defmodule Samen.MailboxVendorFreeTest do
  @moduledoc """
  INV-4 for the MAILBOX seam (T74, spec §I1; the `Samen.Delivery.VendorFreeTest` /
  `Samen.AI.VendorFreeTest` mirror): `samen_core` defines the mailbox behaviour and
  the whole threading pipeline while carrying ZERO mailbox-vendor coupling.

  Asserts no IMAP/Gmail/Graph/mail-parsing dependency in `samen_core/mix.exs`, no
  HTTP client, and no vendor mailbox module named anywhere in `samen_core/lib`.
  Runtime provider dispatch is host config (`config :samen_core, :mailbox_provider`),
  never a compile-time alias — so this grep stays green with every real adapter absent,
  which is exactly the state CI runs in.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../lib", __DIR__)
  @mix_exs Path.expand("../mix.exs", __DIR__)

  # Deps a real mailbox connector would need — none may ever appear in the kernel.
  @vendor_deps ~w(:yugo :eximap :mailibex :gen_smtp :mail :swoosh :bamboo :gmail :ex_imap)
  @http_deps ~w(:req :hackney :finch :httpoison :tesla)
  # Vendor module/service names a real adapter would reference.
  @vendor_tokens ~w(SamenImap SamenGmail SamenGraph imap.gmail.com outlook.office365.com)

  describe "samen_core/mix.exs is mailbox-vendor clean" do
    test "no IMAP / mail-protocol dependency" do
      content = File.read!(@mix_exs)

      for dep <- @vendor_deps do
        refute String.contains?(content, dep),
               "samen_core/mix.exs must never gain a mailbox-protocol dep (INV-4) — found #{dep}"
      end
    end

    test "no HTTP client dependency (a Gmail/Graph adapter would need one — it lives elsewhere)" do
      content = File.read!(@mix_exs)

      for http <- @http_deps do
        refute String.contains?(content, http),
               "samen_core/mix.exs must stay HTTP-client-free (INV-4) — found #{http}"
      end
    end
  end

  describe "samen_core/lib is mailbox-vendor clean" do
    test "no vendor mailbox module or endpoint is referenced anywhere in lib" do
      offenders =
        for path <- ex_files(@lib_root),
            content = File.read!(path),
            token <- @vendor_tokens,
            String.contains?(content, token),
            do: {Path.relative_to(path, @lib_root), token}

      assert offenders == [],
             "samen_core must never name a mailbox vendor (dispatch is host config): " <>
               inspect(offenders)
    end

    test "the mailbox seam itself references only core modules" do
      seam = Path.join(@lib_root, "samen/mailbox")
      assert File.dir?(seam)

      for path <- ex_files(seam) do
        content = File.read!(path)

        for token <- @vendor_tokens do
          refute String.contains?(content, token), "#{path} names vendor token #{token}"
        end
      end
    end
  end

  describe "the vendor-token matcher is refutable (anti-tautology)" do
    test "a planted token IS detected and a clean string is not" do
      assert String.contains?("alias SamenImap.Provider", "SamenImap")
      assert String.contains?(~s({:yugo, "~> 1.0"}), ":yugo")
      refute String.contains?("the mailbox seam is behaviour-only", "SamenImap")
    end
  end

  defp ex_files(root), do: Path.wildcard(Path.join(root, "**/*.ex"))
end
