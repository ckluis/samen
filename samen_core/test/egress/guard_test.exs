defmodule Samen.Egress.GuardTest do
  @moduledoc """
  Issue #25 — the shared `Samen.Egress.Guard` range/scheme matrix.

  The delivery-worker and automation-action tests prove the guard is WIRED; this file
  proves it is CORRECT, range by range, including the two IPv4-in-IPv6 wrappings that a
  guard "covering IPv6" typically waves through.
  """
  use ExUnit.Case, async: false

  alias Samen.Egress.Guard

  @public {93, 184, 216, 34}

  setup do
    prev = Application.get_env(:samen_core, Guard)

    Application.put_env(:samen_core, Guard,
      resolver: Samen.Egress.Guard.Resolver.Test,
      resolver_map: %{"public.example.test" => @public}
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, Guard, prev),
        else: Application.delete_env(:samen_core, Guard)
    end)

    :ok
  end

  describe "private_ip?/1 — IPv4" do
    test "#25: denies loopback, RFC1918, CGNAT, link-local (metadata), multicast and reserved" do
      for ip <- [
            {0, 0, 0, 0},
            {10, 1, 2, 3},
            {100, 64, 0, 1},
            {100, 127, 255, 255},
            {127, 0, 0, 1},
            {169, 254, 169, 254},
            {172, 16, 0, 1},
            {172, 31, 255, 255},
            {192, 0, 0, 1},
            {192, 168, 1, 1},
            {198, 18, 0, 1},
            {224, 0, 0, 1},
            {240, 0, 0, 1}
          ] do
        assert Guard.private_ip?(ip), "#{:inet.ntoa(ip)} must be denied"
      end
    end

    test "#25 POSITIVE CONTROL: allows genuinely public IPv4" do
      for ip <- [{93, 184, 216, 34}, {8, 8, 8, 8}, {1, 1, 1, 1}, {172, 32, 0, 1}, {100, 63, 0, 1}, {192, 0, 1, 1}] do
        refute Guard.private_ip?(ip), "#{:inet.ntoa(ip)} must be allowed"
      end
    end
  end

  describe "private_ip?/1 — IPv6" do
    test "#25: denies ::, ::1, fc00::/7, fe80::/10 and ff00::/8" do
      for ip <- [
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFC00, 0, 0, 0, 0, 0, 0, 1},
            {0xFD12, 0x3456, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1}
          ] do
        assert Guard.private_ip?(ip), "#{:inet.ntoa(ip)} must be denied"
      end
    end

    test "#25: unwraps IPv4-mapped and IPv4-compatible forms instead of waving them through" do
      {:ok, mapped_metadata} = :inet.parse_address(~c"::ffff:169.254.169.254")
      {:ok, mapped_loopback} = :inet.parse_address(~c"::ffff:127.0.0.1")
      {:ok, mapped_rfc1918} = :inet.parse_address(~c"::ffff:10.0.0.1")
      {:ok, compatible_loopback} = :inet.parse_address(~c"::127.0.0.1")
      {:ok, nat64_metadata} = :inet.parse_address(~c"64:ff9b::169.254.169.254")

      assert Guard.private_ip?(mapped_metadata)
      assert Guard.private_ip?(mapped_loopback)
      assert Guard.private_ip?(mapped_rfc1918)
      assert Guard.private_ip?(compatible_loopback)
      assert Guard.private_ip?(nat64_metadata)
    end

    test "#25 POSITIVE CONTROL: allows a public IPv6 and an IPv4-mapped PUBLIC address" do
      {:ok, mapped_public} = :inet.parse_address(~c"::ffff:93.184.216.34")
      refute Guard.private_ip?(mapped_public)
      refute Guard.private_ip?({0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946})
    end

    test "#25: an unrecognised shape fails CLOSED" do
      assert Guard.private_ip?(:not_an_ip)
      assert Guard.private_ip?({1, 2, 3})
    end
  end

  describe "check/2 — the delivery-time authority" do
    test "#25: refuses a literal metadata / loopback / RFC1918 / IPv6-loopback URL" do
      assert {:error, :ssrf_blocked} = Guard.check("http://169.254.169.254/latest/meta-data/")
      assert {:error, :ssrf_blocked} = Guard.check("http://127.0.0.1:4000/hook")
      assert {:error, :ssrf_blocked} = Guard.check("http://10.0.0.1/hook")
      assert {:error, :ssrf_blocked} = Guard.check("http://[::1]/hook")
      assert {:error, :ssrf_blocked} = Guard.check("http://[::ffff:169.254.169.254]/hook")
    end

    test "#25: a literal IP host is judged WITHOUT DNS — a resolver stub cannot launder it" do
      Application.put_env(:samen_core, Guard,
        resolver: Samen.Egress.Guard.Resolver.Test,
        # A stub that would "resolve" the literal loopback string to a public address.
        resolver_map: %{"127.0.0.1" => @public}
      )

      assert {:error, :ssrf_blocked} = Guard.check("http://127.0.0.1/hook")
    end

    test "#25: an unresolvable host fails CLOSED" do
      assert {:error, :ssrf_blocked} = Guard.check("https://nowhere.example.invalid/hook")
    end

    test "#25: refuses a non-http(s) scheme and an unparseable/hostless URL" do
      assert {:error, :invalid_scheme} = Guard.check("gopher://example.test/hook")
      assert {:error, :invalid_url} = Guard.check("/relative/path")
      assert {:error, :invalid_url} = Guard.check(nil)
    end

    test "#25: outside dev/test, http is refused — https is required" do
      assert {:error, :https_required} =
               Guard.check("http://public.example.test/hook", env: :prod)

      assert :ok = Guard.check("https://public.example.test/hook", env: :prod)
    end

    test "#25 POSITIVE CONTROL: a public host resolving publicly passes" do
      assert :ok = Guard.check("https://public.example.test/hook")
    end
  end

  describe "check_literal/2 — the registration-time check" do
    test "#25: refuses a literal private/metadata address and a bad scheme, with NO DNS" do
      assert {:error, :ssrf_blocked} = Guard.check_literal("http://169.254.169.254/x")
      assert {:error, :ssrf_blocked} = Guard.check_literal("https://127.0.0.1/hook")
      assert {:error, :ssrf_blocked} = Guard.check_literal("http://[::1]/hook")
      assert {:error, :ssrf_blocked} = Guard.check_literal("http://[::ffff:10.0.0.1]/hook")
      assert {:error, :invalid_scheme} = Guard.check_literal("gopher://example.test/hook")
      # `file:///etc/passwd` has NO host at all, so it is refused one step earlier as
      # `:invalid_url` — still refused, and named for the reason it actually failed.
      assert {:error, :invalid_url} = Guard.check_literal("file:///etc/passwd")
      assert {:error, :invalid_url} = Guard.check_literal("not a url")
    end

    test "#25: HONEST about its own scope — a hostname is not resolved here, so it passes" do
      # `unmapped.example.invalid` would be refused by `check/2` (nxdomain -> fail
      # closed). `check_literal/2` does no DNS by design: the write path must not block
      # on a resolver, and a resolve-at-registration allow would be a stale allow.
      assert :ok = Guard.check_literal("https://unmapped.example.invalid/hook")
    end

    test "#25 POSITIVE CONTROL: a public https URL passes the literal check" do
      assert :ok = Guard.check_literal("https://hooks.example.com/samen")
    end
  end
end
