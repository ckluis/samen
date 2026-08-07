defmodule Samen.ScopeMaskCaseTest do
  @moduledoc """
  Self-test for the scope-mask harness (ADR-044 §16.3) — proves `Samen.ScopeMaskCase`
  is NON-TAUTOLOGICAL before T84b's tier-2 name proofs consume it: a scoped viewer
  sees the name, an out-of-scope viewer sees neither name nor handle, and a "sabotage
  twin" that flips `scope_of/2` permissive is CAUGHT (the masked assertion fails on the
  leaked render). A mask assertion that could never fail is a bug (CLAUDE.md
  anti-tautology); this file makes the flip explicit.
  """
  use ExUnit.Case, async: true
  use Samen.ScopeMaskCase

  # A minimal model of the tier-2 cockpit render's mask-by-omission (§16.2/§16.4a): a
  # row shows its tenant name + a deep link carrying the handle ONLY when the handle is
  # in the viewer's scope; otherwise it renders counts + an inert "not in your scope"
  # affordance and NO handle anywhere (not even in an attribute).
  #
  # `scope` is a MapSet of in-scope handles. `permissive?` models the sabotage twin:
  # `scope_of/2` flipped to admit every handle.
  defp render_rows(rows, scope, opts \\ []) do
    permissive? = Keyword.get(opts, :permissive?, false)

    rows
    |> Enum.map_join("\n", fn %{name: name, handle: handle} ->
      if permissive? or MapSet.member?(scope, handle) do
        ~s(<tr class="row"><td class="name">#{name}</td>) <>
          ~s(<td><a href="/operator/deliverability/#{handle}" data-handle="#{handle}">drill in</a></td></tr>)
      else
        ~s(<tr class="row masked"><td class="counts">12 sent</td>) <>
          ~s(<td><span class="inert">not in your scope</span></td></tr>)
      end
    end)
  end

  @acme %{name: "Acme Freight Co", handle: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"}
  @globex %{name: "Globex Logistics", handle: "f6e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1"}

  describe "assert_scope_resolved!/2 (green — the in-scope viewer)" do
    test "an in-scope viewer sees the tenant name inline" do
      html = render_rows([@acme], MapSet.new([@acme.handle]))
      assert_scope_resolved!(html, [@acme.name])
    end

    test "refuses to pass on an empty render (anti-vacuous)" do
      # The name is NOT present — a resolution proof must FAIL here, not pass silently.
      assert_raise ExUnit.AssertionError, fn ->
        assert_scope_resolved!("<table></table>", [@acme.name])
      end
    end

    test "refuses an empty names list (a green proof that asserts nothing)" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_scope_resolved!(render_rows([@acme], MapSet.new([@acme.handle])), [])
      end
    end
  end

  describe "assert_scope_masked!/3 (red — the out-of-scope / :none viewer)" do
    test "an out-of-scope viewer sees neither the name nor the handle (mask by omission)" do
      html = render_rows([@acme], MapSet.new())
      assert_scope_masked!(html, [@acme.name], [@acme.handle])
      # the inert affordance IS present — masked, not missing.
      assert html =~ "not in your scope"
    end

    test "catches a name that leaked into a masked row" do
      leaked = ~s(<tr class="row masked"><td class="name">#{@acme.name}</td></tr>)

      assert_raise ExUnit.AssertionError, fn ->
        assert_scope_masked!(leaked, [@acme.name], [@acme.handle])
      end
    end

    test "catches a handle that leaked into a DOM attribute (§16.4a no-handle ruling)" do
      # No visible name, but the handle sits in a data- attribute — still a leak.
      leaked = ~s(<tr class="row masked" data-handle="#{@acme.handle}"><td>12 sent</td></tr>)

      assert_raise ExUnit.AssertionError, fn ->
        assert_scope_masked!(leaked, [@acme.name], [@acme.handle])
      end
    end

    test "refuses an empty names AND handles pair (a mask proof over nothing)" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_scope_masked!(render_rows([@acme], MapSet.new()), [], [])
      end
    end
  end

  describe "sabotage twin — flipping scope_of/2 permissive is CAUGHT" do
    test "a permissive scope leaks the name+handle to an out-of-scope viewer, and the mask assertion FAILS" do
      # The viewer's scope is EMPTY (out of scope for Acme), but the resolver was
      # sabotaged permissive — the name and handle now appear where they must not.
      leaked = render_rows([@acme], MapSet.new(), permissive?: true)

      # Non-vacuous: the leak is genuinely present (assert_leak_detected!/2 from MaskingCase).
      assert_leak_detected!(leaked, @acme.name)
      assert_leak_detected!(leaked, @acme.handle)

      # And the mask assertion the red proof relies on MUST flip red on that leak.
      assert_raise ExUnit.AssertionError, fn ->
        assert_scope_masked!(leaked, [@acme.name], [@acme.handle])
      end
    end
  end

  describe "mixed render — one table, mixed visibility (§16.3 salesperson)" do
    test "named rows for in-scope accounts AND masked rows for out-of-scope, single render" do
      # Acme in scope, Globex out — one render, both proofs.
      html = render_rows([@acme, @globex], MapSet.new([@acme.handle]))

      assert_scope_resolved!(html, [@acme.name])
      assert_scope_masked!(html, [@globex.name], [@globex.handle])
    end
  end
end
