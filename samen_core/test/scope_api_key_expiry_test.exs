defmodule Samen.ScopeApiKeyExpiryTest do
  @moduledoc """
  F3.4 — bounded API-key expiry (deny-on-read) as a PURE, refutable gate on
  `Samen.Scope.ApiKey`. The DB deny-on-read (the plug's `expires_at > now` filter)
  is proven in the demo suite; this proves the use-time predicate the plug's key map
  also carries (defence-in-depth), plus the mint-time bounding.

  Anti-tautology: every red assertion is paired with a positive control on the SAME
  key shape with the ONLY difference being the expiry time — a gate that cannot fail
  is a bug.
  """
  use ExUnit.Case, async: true

  alias Samen.Scope.ApiKey

  @now ~U[2026-07-20 12:00:00Z]

  defp key(expires_at) do
    %{
      org_id: "o1",
      plane: :tenant,
      scopes: %{crm: [:read, :write]},
      minter_role: :owner,
      expires_at: expires_at
    }
  end

  describe "expired?/2 — the hard time ceiling" do
    test "a key past its expiry IS expired" do
      assert ApiKey.expired?(key(DateTime.add(@now, -1, :second)), @now)
    end

    test "a key AT its expiry is expired (the instant it is reached, it is dead)" do
      assert ApiKey.expired?(key(@now), @now)
    end

    test "a key with a future expiry is NOT expired (positive control)" do
      refute ApiKey.expired?(key(DateTime.add(@now, 60, :second)), @now)
    end

    test "a legacy key with no expires_at is not expired by the pure predicate" do
      refute ApiKey.expired?(key(nil), @now)
      refute ApiKey.expired?(%{org_id: "o1", minter_role: :admin, scopes: %{}}, @now)
    end
  end

  describe "authorized?/5 — expiry is a fail-closed conjunct" do
    test "an EXPIRED key authorizes NOTHING even with matching org/scope/ceiling" do
      k = key(DateTime.add(@now, -1, :second))
      # It would authorize if not for the expiry — the positive control below proves it.
      refute ApiKey.authorized?(k, :read, :crm, "o1", @now)
      refute ApiKey.authorized?(k, :write, :crm, "o1", @now)
    end

    test "the SAME key, unexpired, DOES authorize (positive control — the gate is refutable)" do
      k = key(DateTime.add(@now, 60, :second))
      assert ApiKey.authorized?(k, :read, :crm, "o1", @now)
      assert ApiKey.authorized?(k, :write, :crm, "o1", @now)
    end

    test "authorized?/4 (implicit now) still honours org/scope/ceiling for a live key" do
      k = key(DateTime.add(DateTime.utc_now(), 3600, :second))
      assert ApiKey.authorized?(k, :read, :crm, "o1")
      refute ApiKey.authorized?(k, :read, :crm, "o2")
    end
  end

  describe "bounded_expiry/2 — no key is ever minted unbounded" do
    test "nil request → now + default_ttl" do
      got = ApiKey.bounded_expiry(nil, @now)
      assert DateTime.compare(got, @now) == :gt
      assert DateTime.diff(got, @now, :second) == ApiKey.default_ttl_seconds()
    end

    test "a request beyond the max ceiling clamps DOWN to now + max_ttl" do
      requested = DateTime.add(@now, ApiKey.max_ttl_seconds() * 3, :second)
      got = ApiKey.bounded_expiry(requested, @now)
      assert DateTime.diff(got, @now, :second) == ApiKey.max_ttl_seconds()
    end

    test "an already-dead request → now + default_ttl (can't mint an expired key)" do
      requested = DateTime.add(@now, -10, :second)
      got = ApiKey.bounded_expiry(requested, @now)
      assert DateTime.compare(got, @now) == :gt
      assert DateTime.diff(got, @now, :second) == ApiKey.default_ttl_seconds()
    end

    test "an in-window request is honoured verbatim" do
      requested = DateTime.add(@now, 7 * 24 * 60 * 60, :second)
      assert ApiKey.bounded_expiry(requested, @now) == requested
    end
  end
end
