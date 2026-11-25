defmodule Samen.Web.TenantActorGuardTest do
  @moduledoc """
  No NEW implicit fixed-role tenant scope (ADR-045 §4.4 residual, the `:member` default).

  `Mount.scope/2` / `Plane.scope/2` fabricate the synthetic org-level actor with a fixed
  `role: :member`. A tenant surface acting for a signed-in person must use
  `Samen.Web.TenantActor.scope/3` (the person's resolved role); one that really needs the fixed role
  says so by name (`TenantActor.system_scope/2`).

  This is a RATCHET over the sites not yet converted (`@baseline`, the owner's work list): a file may
  not gain a call, a file not listed may not contain one, and when a file is converted its entry
  must be LOWERED here (a stale, higher number would let a regression hide behind it). The baseline's
  TOTAL is pinned too (`@baseline_total`, `@baseline_files`), so raising an entry is a second, visible edit.

  Three detectors, each with its own ratchet (see `Samen.Web.TenantActor.Guard`): the fixed-role scope calls
  in every spelling (`Mount.scope(`, `&Mount.scope/2`, an `as:` alias, an `import`, `apply/3`), the literal tenant
  actor maps (`@literal_actor_allowlist`), and the escape hatches that name a role without resolving one
  (`system_scope(`, `admin_scope(`, `user_scope(` with no role: `@escape_hatch_baseline`). The hosts' own request-path
  sites are ratcheted in their own tests (`Driftwood.TenantActorHostGuardTest`, `PawChart.TenantActorHostGuardTest`).
  """
  use ExUnit.Case, async: true

  alias Samen.Web.TenantActor.Guard

  # Where `Mount.scope(` / `Plane.scope(` are still called (path under `samen_web/lib`, calls).
  # `mount.ex` (the definition), `tenant_actor.ex` (`system_scope/2`) and `tenant_actor/guard.ex`
  # (this detector) are the only exempt files.
  @baseline %{
    "samen/web/ai/agent_live.ex" => 1,
    "samen/web/ai/agent_reads.ex" => 2,
    "samen/web/ai/server.ex" => 1,
    "samen/web/automation/builder_live.ex" => 5,
    "samen/web/billing/dunning_live.ex" => 1,
    "samen/web/billing/invoices_live.ex" => 1,
    "samen/web/billing/overview_live.ex" => 2,
    "samen/web/billing/plans_live.ex" => 1,
    "samen/web/billing/settings_live.ex" => 2,
    "samen/web/billing/usage_live.ex" => 1,
    "samen/web/chat.ex" => 1,
    "samen/web/chat/thread_live.ex" => 3,
    "samen/web/chat/threads_live.ex" => 3,
    "samen/web/crm/calendar_live.ex" => 1,
    "samen/web/crm/company_live.ex" => 5,
    "samen/web/crm/contacts_gallery_live.ex" => 1,
    "samen/web/crm/dashboard_live.ex" => 1,
    "samen/web/crm/mailbox_live.ex" => 1,
    "samen/web/crm/pipeline_live.ex" => 2,
    "samen/web/crm/sequences_live.ex" => 2,
    "samen/web/files/preview_live.ex" => 3,
    "samen/web/files/upload_live.ex" => 2,
    "samen/web/first_run.ex" => 1,
    "samen/web/flags/settings_live.ex" => 2,
    "samen/web/ics/export_controller.ex" => 1,
    "samen/web/marketing/campaign_live.ex" => 2,
    "samen/web/marketing/campaigns_live.ex" => 1,
    "samen/web/marketing/segments_live.ex" => 1,
    "samen/web/notifications/inbox_live.ex" => 1,
    "samen/web/onboarding/wizard_controller.ex" => 1,
    "samen/web/onboarding/wizard_live.ex" => 2,
    "samen/web/operator.ex" => 2,
    "samen/web/operator/flag_admin_live.ex" => 2,
    "samen/web/replay/access.ex" => 2,
    "samen/web/sample_data.ex" => 1,
    "samen/web/search/search_live.ex" => 1,
    "samen/web/settings/api_keys_live.ex" => 2,
    "samen/web/settings/invitations_live.ex" => 2,
    "samen/web/settings/reads.ex" => 1,
    "samen/web/settings/reveal_approvals_live.ex" => 1,
    "samen/web/settings/security_live.ex" => 1,
    "samen/web/support/kb_live.ex" => 3,
    "samen/web/support/kb_reads.ex" => 1,
    "samen/web/support/ticket_live.ex" => 3,
    "samen/web/support/tickets_live.ex" => 3,
    "samen/web/tenant/analytics_live.ex" => 1,
    "samen/web/tenant_role.ex" => 1,
    "samen/web/work/projects_live.ex" => 3,
    "samen/web/work/task_live.ex" => 2,
    "samen/web/work/task_tree_live.ex" => 1,
    "samen/web/work/tasks_live.ex" => 3,
    "samen/web/work/timeline_live.ex" => 1,
  }

  # The exact size of the work list: a silent bump of an entry (or a new entry) fails here, not only in the ratchet.
  @baseline_total 91
  @baseline_files 52

  @exempt ~w(samen/web/mount.ex samen/web/tenant_actor.ex samen/web/tenant_actor/guard.ex)

  # Hand-spelled roles (a map with `org_id:` and a literal `role:`, an id-less one included; a `%{actor | role: :x}`
  # update; `Map.put(actor, :role, :x)`) in samen_web/lib. `plane.ex` is the definition.
  #   chat.ex           NOT an actor: the creator's thread-participant ROW (`role: :owner` is the participant's data)
  #   chat/identity.ex  the disclosure actor: reads the org's own PII in the clear for the tenant-as-owner rule
  #   saved_views.ex    `owner_scope/2`: the saved-view owner's scope (OwnerOnly + OrgScope), role :member by design
  @literal_actor_allowlist %{
    "samen/web/chat.ex" => 1,
    "samen/web/chat/identity.ex" => 1,
    "samen/web/saved_views.ex" => 1
  }
  @literal_actor_exempt ~w(samen/web/plane.ex samen/web/tenant_actor.ex samen/web/tenant_actor/guard.ex)

  # Callers of `system_scope(` / `admin_scope(` / `user_scope(` without a role. `TenantRole.admin_scope/3` takes the
  # principal pinned by the tenant gate, so its callers are the unconverted admin-gated reads; `api_keys_live.ex`
  # calls its own private `admin_scope/3` (user, org and the membership's role). Not exempt: nothing new may appear.
  @escape_hatch_baseline %{
    "samen/web/billing/reads.ex" => 2,
    "samen/web/chat.ex" => 1,
    "samen/web/flags/reads.ex" => 1,
    "samen/web/marketing/reads.ex" => 1,
    "samen/web/settings/api_keys_live.ex" => 2,
    "samen/web/support/kb_reads.ex" => 1
  }
  @escape_hatch_exempt ~w(samen/web/tenant_actor.ex samen/web/tenant_actor/guard.ex)

  @root Path.expand("../../../lib", __DIR__)

  defp found, do: @root |> Guard.scan() |> Map.drop(@exempt)
  defp found_literal_actors, do: @root |> Guard.scan(&Guard.literal_actors/1) |> Map.drop(@literal_actor_exempt)
  defp found_escape_hatches, do: @root |> Guard.scan(&Guard.escape_hatches/1) |> Map.drop(@escape_hatch_exempt)

  test "no file gains an implicit fixed-role scope call and no new file introduces one" do
    over = for {file, n} <- found(), n > Map.get(@baseline, file, 0), do: {file, Map.get(@baseline, file, 0), n}

    assert over == [],
           "implicit `Mount.scope/2` / `Plane.scope/2` (a fixed :member) in tenant web code: " <>
             "#{inspect(over)} — derive the actor with `Samen.Web.TenantActor.scope/3`, or name the " <>
             "fixed role with `TenantActor.system_scope/2`"
  end

  test "the baseline is not stale: a converted file lowers its entry" do
    stale = for {file, n} <- @baseline, Map.get(found(), file, 0) < n, do: {file, n, Map.get(found(), file, 0)}
    assert stale == [], "lower these @baseline entries (file, baseline, now): #{inspect(stale)}"
  end

  test "the baseline is pinned: its exact size is stated here, so raising an entry is a second visible edit" do
    assert Enum.sum(Map.values(@baseline)) == @baseline_total
    assert map_size(@baseline) == @baseline_files
    # and the tree agrees with the pin exactly (not merely "at most")
    assert Enum.sum(Map.values(found())) == @baseline_total
    assert map_size(found()) == @baseline_files
  end

  test "no file gains a literal tenant actor map, and the allowlist is exact" do
    assert found_literal_actors() == @literal_actor_allowlist,
           "a literal role (`%{org_id:, role: :atom}`, `%{actor | role: :atom}`, `Map.put(actor, :role, :atom)`) in samen_web/lib acts with a role nobody resolved: derive it with " <>
             "`Samen.Web.TenantActor.scope/3`, or add the file here WITH its reason"
  end

  test "no file gains an escape-hatch call (system_scope / admin_scope / user_scope without a role), and the baseline is exact" do
    assert found_escape_hatches() == @escape_hatch_baseline,
           "an escape hatch names a role without resolving one: lower the entry when a file is converted, never raise it"
  end

  test "non-vacuity: the sweep sees the whole tree and the converted surfaces are really clean" do
    assert map_size(found()) > 40
    assert Enum.sum(Map.values(found())) > 90
    refute Map.has_key?(found(), "samen/web/crm/contacts_live.ex")
    refute Map.has_key?(found(), "samen/web/crm/companies_live.ex")
    refute Map.has_key?(found(), "samen/web/csv/export_controller.ex")
    refute Map.has_key?(found(), "samen/web/files/bytes_controller.ex")
    refute Map.has_key?(found(), "samen/web/settings/profile_live.ex")
  end

  describe "the detector discriminates (anti-tautology)" do
    test "an implicit call is counted; the named, resolved and commented forms are not" do
      assert Guard.implicit_calls("scope = Mount.scope(mount, org_id)") == 1
      assert Guard.implicit_calls("a = Plane.scope(plane, o); b = Samen.Web.Mount.scope(m, o)") == 2
      assert Guard.implicit_calls("TenantActor.system_scope(mount, org_id)") == 0
      assert Guard.implicit_calls("TenantActor.scope(mount, org_id, ref)") == 0
      assert Guard.implicit_calls("# scope = Mount.scope(mount, org_id)") == 0
      assert Guard.implicit_calls("see Mount.scope/2 for the shape") == 0
    end

    test "the capture, alias, import and apply spellings are counted; their look-alikes are not" do
      # captures
      assert Guard.implicit_calls("f = &Mount.scope/2") == 1
      assert Guard.implicit_calls("Enum.map(os, &Plane.scope(p, &1))") == 1
      assert Guard.implicit_calls("f = &Samen.Web.Mount.scope/2") == 1
      assert Guard.implicit_calls("f = &TenantActor.scope/3") == 0

      # an `as:` alias
      aliased = "alias Samen.Web.Mount, as: M\nx = M.scope(m, o)\nf = &M.scope/2\n"
      assert Guard.implicit_calls(aliased) == 2
      assert Guard.implicit_calls("x = M.scope(m, o)") == 0, "without the alias line `M` is some other module"
      assert Guard.implicit_calls("alias Samen.Web.Plane, as: P\nP.scope(p, o)") == 1

      # an import
      assert Guard.implicit_calls("import Samen.Web.Mount") == 1
      assert Guard.implicit_calls("import Samen.Web.Mount, only: [scope: 2]") == 1
      assert Guard.implicit_calls("import Samen.Web.Mount, only: [new: 3]") == 0
      assert Guard.implicit_calls("import Samen.Web.Mount, except: [scope: 2]") == 0
      assert Guard.implicit_calls("import Samen.Web.Plane") == 1

      # apply
      assert Guard.implicit_calls("apply(Mount, :scope, [m, o])") == 1
      assert Guard.implicit_calls("apply(Samen.Web.Plane, :scope, [p, o])") == 1
      assert Guard.implicit_calls("apply(Mount, :new, [m, o])") == 0
    end

    test "a literal tenant actor map is counted; a participant row, a resolved role and a comment are not" do
      assert Guard.literal_actors("a = %{id: u, org_id: o, role: :member, kind: :tenant, plane: :tenant}") == 1
      assert Guard.literal_actors(~s|a = %{id: "broker:\#{org_id}", org_id: org_id, role: :member}|) == 1
      assert Guard.literal_actors("a = %{\n  id: u,\n  org_id: o,\n  role: :admin\n}") == 1
      assert Guard.literal_actors("Samen.Scope.new(%{id: user_id, org_id: org_id, role: :member})") == 1
      assert Guard.literal_actors("a = %{id: u, org_id: o, role: role}") == 0
      # a participant ROW has the same shape as an actor: counted, and allowlisted by file where it is data
      assert Guard.literal_actors("a = %{thread_id: t, org_id: o, role: :owner, principal_id: p}") == 1
      assert Guard.literal_actors("# a = %{id: u, org_id: o, role: :member}") == 0
    end

    test "an id-less actor, a nested one, a role update and Map.put/merge of a literal role are counted" do
      # id-less: all OrgScope and RoleAtLeast need
      assert Guard.literal_actors("a = %{org_id: o, role: :admin}") == 1
      assert Guard.literal_actors("s = %Samen.Scope{actor: %{org_id: org_id, role: :admin}}") == 1
      # a nested map: the outer map and the inner one are each judged on their own top level
      assert Guard.literal_actors("a = %{org_id: o, meta: %{x: 1}, role: :admin}") == 1
      assert Guard.literal_actors("a = %{meta: %{org_id: o, role: :admin}, x: 1}") == 1
      assert Guard.literal_actors("a = %{org_id: o, role: :admin, extra: [%{a: 1}, %{b: {1, 2}}]}") == 1
      # an update of an actor's role, and the Map functions
      assert Guard.literal_actors("a = %{actor | role: :admin}") == 1
      assert Guard.literal_actors("a = %{actor | org_id: o, role: :owner}") == 1
      assert Guard.literal_actors("a = Map.put(actor, :role, :admin)") == 1
      assert Guard.literal_actors("a = Map.merge(actor, %{role: :admin})") == 1
      # look-alikes: a resolved role, an update of something else, doc text and a map with no org
      assert Guard.literal_actors("a = %{actor | role: role}") == 0
      assert Guard.literal_actors("a = %{actor | name: :x}") == 0
      assert Guard.literal_actors("a = Map.put(actor, :role, role)") == 0
      assert Guard.literal_actors("a = %{role: :admin}") == 0
      assert Guard.literal_actors("@moduledoc \"\"\"\n  Map.put(actor, :role, :admin)\n  \"\"\"\n") == 0
    end

    test "user_scope with a literal nil role is an escape hatch; a real role and a variable are not" do
      assert Guard.escape_hatches("Reads.user_scope(mount, org_id, user_id, nil)") == 1
      assert Guard.escape_hatches("Reads.user_scope(mount, org_id, user_id, nil )") == 1
      assert Guard.escape_hatches("Reads.user_scope(mount, org_id, user_id, role)") == 0
      assert Guard.escape_hatches("Reads.user_scope(mount, org_id, user_id, :member)") == 0
      assert Guard.escape_hatches("Reads.user_scope(\n  mount,\n  org_id,\n  user_id,\n  nil\n)") == 1
      assert Guard.escape_hatches("Reads.user_scope(mount, org_id, user_id, fetch(a, nil))") == 0
    end

    test "an import that excludes another function named like scope still imports scope; a multi-line alias is seen" do
      # `scope_kind: 1` is not `scope: 2`
      assert Guard.implicit_calls("import Samen.Web.Mount, except: [scope_kind: 1]") == 1
      assert Guard.implicit_calls("import Samen.Web.Mount, except: [scope: 2, scope_kind: 1]") == 0
      assert Guard.implicit_calls("import Samen.Web.Mount, only: [scope_kind: 1]") == 0
      assert Guard.implicit_calls("import Samen.Web.Mount, only: [scope: 2, scope_kind: 1]") == 1
      # `alias ..., as:` split over lines
      assert Guard.implicit_calls("alias Samen.Web.Mount,\n  as: M\nx = M.scope(m, o)\n") == 1
      assert Guard.implicit_calls("alias Samen.Web.Plane,\n    as: P\nP.scope(p, o)\nf = &P.scope/2\n") == 2
    end

    test "an escape hatch is counted: system_scope, admin_scope and user_scope WITHOUT a role" do
      assert Guard.escape_hatches("TenantActor.system_scope(mount, org_id)") == 1
      assert Guard.escape_hatches("TenantRole.admin_scope(mount, org_id)") == 1
      assert Guard.escape_hatches("TenantRole.admin_scope(mount, org_id, principal)") == 1
      assert Guard.escape_hatches("Reads.user_scope(mount, org_id, user_id)") == 1
      assert Guard.escape_hatches("Reads.user_scope(mount, org_id, user_id, role)") == 0
      assert Guard.escape_hatches("Reads.user_scope(\n  socket.assigns.mount,\n  org_id,\n  fetch(a, b),\n  role\n)") == 0
      assert Guard.escape_hatches("Reads.user_scope(fetch(a, b), org_id, u)") == 1
      assert Guard.escape_hatches("def system_scope(mount, org_id), do: x") == 0
      assert Guard.escape_hatches("defp admin_scope(user_id, org_id, role) do") == 0
      assert Guard.escape_hatches("# TenantActor.system_scope(mount, org_id)") == 0
      assert Guard.escape_hatches("restore_admin_scope(scope, socket)") == 0
    end

    test "a modeled new file is reported by every detector" do
      dir = Path.join(System.tmp_dir!(), "tenant_actor_guard_all_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "a_live.ex"), "defmodule A do\n  def x(m, o), do: Enum.map([o], &Mount.scope(m, &1))\nend\n")
      File.write!(Path.join(dir, "b_live.ex"), "defmodule B do\n  def x(o), do: %{id: o, org_id: o, role: :member}\nend\n")
      File.write!(Path.join(dir, "c_live.ex"), "defmodule C do\n  def x(m, o), do: TenantActor.system_scope(m, o)\nend\n")

      assert Guard.scan(dir) == %{"a_live.ex" => 1}
      assert Guard.scan(dir, &Guard.literal_actors/1) == %{"b_live.ex" => 1}
      assert Guard.scan(dir, &Guard.escape_hatches/1) == %{"c_live.ex" => 1}
    end

    test "a modeled new file with an implicit call would be reported" do
      dir = Path.join(System.tmp_dir!(), "tenant_actor_guard_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "new_live.ex"), "defmodule NewLive do\n  def x(m, o), do: Mount.scope(m, o)\nend\n")
      on_exit(fn -> File.rm_rf!(dir) end)
      assert Guard.scan(dir) == %{"new_live.ex" => 1}
    end
  end
end
