defmodule Samen.Fleet.Resolution.ResolveTest do
  @moduledoc """
  T84b — `Samen.Fleet.Resolution.resolve/3` (ADR-044 §16.2 cockpit-side name
  resolution) and its reference `resolve_via_org_scan/5` seam.

  `resolve/3` itself is generic (fail-closed to `%{}`, filters a permissive/
  leaky seam back down to the requested handle set). `resolve_via_org_scan/5`
  is the load-bearing PROOF that name resolution can be composed from
  `Samen.Fleet.Handle.matches?/4` (product-local, keyless-to-the-cockpit) +
  `scope_of/2` (the SAME answer that gates tier-2 visibility, §16.2) without
  ever exposing the HMAC key itself.
  """
  use ExUnit.Case, async: false

  alias Samen.Fleet.{Handle, Resolution}

  @app_id "11111111-1111-4111-8111-111111111111"
  @test_host :samen_core_resolve_test_host

  setup do
    on_exit(fn -> Application.delete_env(@test_host, :fleet_resolution) end)
    :ok
  end

  describe "resolve/3 — fail-closed + mask-by-omission at the reader" do
    test "no seam configured -> every handle masked" do
      assert Resolution.resolve(@test_host, "op-1", ["deadbeef"]) == %{}
    end

    test "an erroring seam -> every handle masked (never a crash)" do
      Application.put_env(@test_host, :fleet_name_resolver, {__MODULE__, :raising_resolver, []})
      assert Resolution.resolve(@test_host, "op-1", ["deadbeef"]) == %{}
    end

    test "a permissive/leaky seam is filtered back down to the REQUESTED handles only" do
      Application.put_env(@test_host, :fleet_name_resolver, {__MODULE__, :leaky_resolver, []})

      resolved = Resolution.resolve(@test_host, "op-1", ["asked-for"])

      assert resolved == %{"asked-for" => "Asked For Inc"}
      refute Map.has_key?(resolved, "not-asked-for")
    end

    test "a non-string name value from the seam is dropped, not admitted" do
      Application.put_env(@test_host, :fleet_name_resolver, {__MODULE__, :bad_value_resolver, []})
      assert Resolution.resolve(@test_host, "op-1", ["h1"]) == %{}
    end
  end

  describe "resolve_via_org_scan/5 — the reference product-side seam" do
    setup do
      {:ok, handle} = Handle.compute(@app_id, "org-alpha", version: 1)
      {:ok, other_handle} = Handle.compute(@app_id, "org-beta", version: 1)
      %{handle: handle, other_handle: other_handle}
    end

    test "GREEN (:all scope): resolves a handle to its org's name via the scan", %{handle: handle} do
      orgs_fn = fn -> [%{id: "org-alpha", name: "Alpha Co"}, %{id: "org-beta", name: "Beta Co"}] end

      Application.put_env(:samen_core_resolve_scan_all, :fleet_resolution, {__MODULE__, :all_scope, []})

      resolved =
        Resolution.resolve_via_org_scan(:samen_core_resolve_scan_all, orgs_fn, @app_id, "admin", [handle])

      assert resolved == %{handle => "Alpha Co"}
    end

    test "RED (:none scope): scope excludes the org -> the handle stays masked", %{handle: handle} do
      orgs_fn = fn -> [%{id: "org-alpha", name: "Alpha Co"}] end

      Application.put_env(:samen_core_resolve_scan_none, :fleet_resolution, {__MODULE__, :none_scope, []})

      resolved =
        Resolution.resolve_via_org_scan(:samen_core_resolve_scan_none, orgs_fn, @app_id, "nobody", [handle])

      assert resolved == %{}
    end

    test "a scoped {:accounts, set} resolves only the in-scope handle, masking the out-of-scope one", %{
      handle: handle,
      other_handle: other_handle
    } do
      orgs_fn = fn -> [%{id: "org-alpha", name: "Alpha Co"}, %{id: "org-beta", name: "Beta Co"}] end

      Application.put_env(:samen_core_resolve_scan_partial, :fleet_resolution, {__MODULE__, :alpha_only_scope, []})

      resolved =
        Resolution.resolve_via_org_scan(
          :samen_core_resolve_scan_partial,
          orgs_fn,
          @app_id,
          "sales-rep",
          [handle, other_handle]
        )

      assert resolved == %{handle => "Alpha Co"}
      refute Map.has_key?(resolved, other_handle)
    end

    test "a handle computed under a DIFFERENT app_id never resolves (unlinkable across products)" do
      {:ok, foreign_handle} = Handle.compute("22222222-2222-4222-8222-222222222222", "org-alpha", version: 1)
      orgs_fn = fn -> [%{id: "org-alpha", name: "Alpha Co"}] end

      Application.put_env(:samen_core_resolve_scan_foreign, :fleet_resolution, {__MODULE__, :all_scope, []})

      resolved =
        Resolution.resolve_via_org_scan(
          :samen_core_resolve_scan_foreign,
          orgs_fn,
          @app_id,
          "admin",
          [foreign_handle]
        )

      assert resolved == %{}
    end
  end

  # -- fixture resolvers -------------------------------------------------------

  def raising_resolver(_principal, _handles), do: raise("boom")

  def leaky_resolver(_principal, _handles),
    do: %{"asked-for" => "Asked For Inc", "not-asked-for" => "Should Never Appear"}

  def bad_value_resolver(_principal, _handles), do: %{"h1" => %{not: "a string"}}

  def all_scope(_principal), do: :all
  def none_scope(_principal), do: :none
  def alpha_only_scope(_principal), do: {:accounts, MapSet.new(["org-alpha"])}
end
