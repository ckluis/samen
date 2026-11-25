defmodule Samen.Gen.LiveActorRoleTest do
  @moduledoc """
  A generated `--live` screen acts with the signed-in person's RESOLVED membership role
  (ADR-045 §4.4 residual): through `Samen.Web.TenantActor.access/4` — never a hard-coded role, never the
  old `membership_role/3` that fell back to `:member` for "no membership". The generated app is compiled
  and exercised by `priv/gen_post_probe.exs`; this pins the template text of all three screens.
  """
  use ExUnit.Case, async: true

  @templates [:resource_index_live, :resource_show_live, :resource_form_live]

  defp source(name), do: apply(Samen.Gen.PostTemplates, name, [])

  for name <- @templates do
    test "#{name}: the role comes from the shared resolver and a refusal carries no role" do
      src = source(unquote(name))

      assert src =~ "Samen.Web.TenantActor.access(@samen_authn_mount"
      assert src =~ "{:refused, _state} -> nil"
      assert src =~ ~s(id="actor-denied")
      assert src =~ ~s(id="actor-unavailable")
      assert src =~ "samen_principal_ref: Samen.Web.Settings.Reads.principal_ref("
    end

    test "#{name}: no hard-coded or defaulted role survives" do
      src = source(unquote(name))

      refute src =~ "membership_role"
      refute src =~ "role: :member"
      refute src =~ "role: :admin"
      # the dev convenience is named ONCE, as the disarmed argument of the resolver
      assert length(Regex.scan(~r/:admin\)/, src)) == 1
    end
  end
end
