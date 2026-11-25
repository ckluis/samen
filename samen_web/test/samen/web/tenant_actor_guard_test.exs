defmodule Samen.Web.TenantActorGuardTest do
  @moduledoc """
  No NEW implicit fixed-role tenant scope (ADR-045 §4.4 residual, the `:member` default).

  `Mount.scope/2` / `Plane.scope/2` fabricate the synthetic org-level actor with a fixed
  `role: :member`. A tenant surface acting for a signed-in person must use
  `Samen.Web.TenantActor.scope/3` (the person's resolved role); one that really needs the fixed role
  says so by name (`TenantActor.system_scope/2`).

  This is a RATCHET over the sites not yet converted (`@baseline`, the owner's work list): a file may
  not gain a call, a file not listed may not contain one, and when a file is converted its entry
  must be LOWERED here (a stale, higher number would let a regression hide behind it).
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
    "samen/web/crm/contact_live.ex" => 4,
    "samen/web/crm/contacts_gallery_live.ex" => 1,
    "samen/web/crm/dashboard_live.ex" => 1,
    "samen/web/crm/mailbox_live.ex" => 1,
    "samen/web/crm/pipeline_live.ex" => 2,
    "samen/web/crm/sequences_live.ex" => 2,
    "samen/web/csv/import_live.ex" => 1,
    "samen/web/files/preview_live.ex" => 3,
    "samen/web/files/upload_live.ex" => 2,
    "samen/web/first_run.ex" => 1,
    "samen/web/flags/settings_live.ex" => 2,
    "samen/web/ics/export_controller.ex" => 1,
    "samen/web/marketing/campaign_live.ex" => 2,
    "samen/web/marketing/campaigns_live.ex" => 1,
    "samen/web/marketing/leads_live.ex" => 1,
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

  @exempt ~w(samen/web/mount.ex samen/web/tenant_actor.ex samen/web/tenant_actor/guard.ex)

  @root Path.expand("../../../lib", __DIR__)

  defp found, do: @root |> Guard.scan() |> Map.drop(@exempt)

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

    test "a modeled new file with an implicit call would be reported" do
      dir = Path.join(System.tmp_dir!(), "tenant_actor_guard_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "new_live.ex"), "defmodule NewLive do\n  def x(m, o), do: Mount.scope(m, o)\nend\n")
      on_exit(fn -> File.rm_rf!(dir) end)
      assert Guard.scan(dir) == %{"new_live.ex" => 1}
    end
  end
end
