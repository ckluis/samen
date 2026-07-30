defmodule Samen.Web.AutomationBuilderLiveTest do
  @moduledoc """
  T118 (ADR-039 §12 done-criterion 4 UI half) — the TENANT-plane automation
  (workflow) builder LiveView, over the samen_web test host's direct
  `Samen.WebTest.Automation.Workflow` mount (`test/support/automation.ex`, the SAME
  fixture T42's `operator_automation_health_test.exs` reads).

    * **Render + JS-off (ADR-042 Class B)** — the disconnected `render_live` helper
      never wires a socket; the workflow list renders real content from it.
    * **End-to-end authoring** — create → add condition → add action → appears in
      the list, all through the real governed `Workflow` actions (no simulated
      write).
    * **INV-1 eligible-fields-only** — the condition-key `<select>` for a resource
      with a vault (`:token`) attribute NEVER offers it; a non-PII attribute of the
      SAME resource IS offered (the positive control — an anti-tautology pairing).
      A SEPARATE red-path test forges a non-eligible attribute directly into
      `handle_event`, bypassing the picker entirely, and asserts the kernel refuses
      the write anyway (`Samen.Automation.NonPiiPredicates`, not a UI-only filter).
    * **Pause/resume** — writes the SAME `status` column T39/T42 read, asserted via
      a direct resource read, not just UI state.
    * **Manual "Run now"** — enqueues through `Samen.Automation.trigger_manual/2`.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Automation.BuilderLive
  alias Samen.WebTest.Automation.Workflow

  # The full-fidelity vault case (ADR-039's NonPiiPredicates precedent target):
  # full_name/emails/phones are vault-routed (`:token`); display_name/job_title are
  # plain public strings WITHOUT a non_pii! clearance (`:plaintext_pii`, refused
  # too); company_id/id/timestamps are bounded structural scalars (ELIGIBLE by
  # construction) — the eligible/ineligible pairing this suite proves.
  @person_resource_key "Samen.WebTest.Crm.Person"

  setup do
    org_id = Ash.UUID.generate()
    {:ok, org_id: org_id}
  end

  defp mount, do: build_mount(:automation, plane: :tenant)

  defp create_workflow!(org_id, attrs \\ %{}) do
    base = %{
      org_id: org_id,
      name: "wf-#{System.unique_integer([:positive])}",
      status: :active,
      trigger_kind: :manual,
      conditions: [],
      actions: []
    }

    Workflow
    |> Ash.Changeset.for_create(:create, Map.merge(base, attrs))
    |> Ash.create!(authorize?: false)
  end

  defp reload!(id) do
    Workflow
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp mount_socket(org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount())
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> BuilderLive.load(org_id)
  end

  defp html(socket), do: render_html(BuilderLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = BuilderLive.handle_event(name, params, socket)
    socket
  end

  # ---------------------------------------------------------------------------

  test "renders the workflow list with NO connected socket (ADR-042 Class B)", %{org_id: org_id} do
    wf = create_workflow!(org_id, %{name: "escalate-stale-deals"})

    html = render_live(BuilderLive, mount(), [org_id])

    assert html =~ wf.name
    assert html =~ "manual"
    # No phx-click was fired; the content is already present on the dead render.
    assert html =~ ~s(phx-click="edit_workflow")
    assert html =~ ~s(phx-click="new_workflow")
  end

  test "end-to-end authoring: create -> add condition -> add action -> appears in list" do
    org_id = Ash.UUID.generate()
    socket = mount_socket(org_id)

    socket = event(socket, "new_workflow", %{})
    assert html(socket) =~ ~s(id="workflow-form")

    socket =
      event(socket, "save_workflow", %{
        "workflow" => %{
          "name" => "escalate open deals",
          "trigger_kind" => "resource_event",
          "resource_key" => @person_resource_key,
          "event" => "updated",
          "schedule_cron" => ""
        }
      })

    refute html(socket) =~ "Could not save"
    wf = socket.assigns.edit_workflow
    assert wf != :new
    assert wf.name == "escalate open deals"
    assert wf.resource_key == @person_resource_key

    # A non-PII, eligible attribute is offered and acceptable as a condition key.
    socket = event(socket, "add_condition", %{"condition" => %{"attribute" => "company_id", "op" => "eq", "values" => "Acme"}})
    assert socket.assigns.cond_error == nil
    assert [%{"attribute" => "company_id"}] = socket.assigns.edit_workflow.conditions

    socket =
      event(socket, "add_action", %{
        "action" => %{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired", "template_key" => "workflow_notify"}
      })

    assert socket.assigns.action_error == nil
    assert [%{"kind" => "notify"}] = socket.assigns.edit_workflow.actions

    # The saved-and-composed workflow shows up in the list, real rows, real write.
    list_html = render_live(BuilderLive, mount(), [org_id])
    assert list_html =~ "escalate open deals"

    reloaded = reload!(wf.id)
    assert reloaded.conditions == [%{"attribute" => "company_id", "op" => "eq", "values" => ["Acme"]}]
    assert [%{"kind" => "notify"}] = reloaded.actions
  end

  # -- INV-1: eligible-fields-only (the masking/eligibility proof) ---------------

  describe "INV-1 — condition-key picker offers ONLY condition-eligible attributes" do
    test "GREEN control: a legal structural-scalar attribute (company_id) IS offered" do
      org_id = Ash.UUID.generate()
      wf = create_workflow!(org_id, %{resource_key: @person_resource_key})

      socket = mount_socket(org_id) |> event("edit_workflow", %{"id" => to_string(wf.id)})

      # Bounded structural scalars (uuid FK / id / timestamps) are eligible by
      # construction — no clearance needed (Samen.Cdc.Projection.classify_columns/2).
      assert "company_id" in socket.assigns.eligible_attrs

      rendered = html(socket)
      assert rendered =~ ~s(value="company_id")
    end

    test "RED: a vault-routed attribute (full_name/emails/phones) is NEVER offered as a selectable condition key" do
      org_id = Ash.UUID.generate()
      wf = create_workflow!(org_id, %{resource_key: @person_resource_key})

      socket = mount_socket(org_id) |> event("edit_workflow", %{"id" => to_string(wf.id)})

      refute "full_name" in socket.assigns.eligible_attrs
      refute "emails" in socket.assigns.eligible_attrs
      refute "phones" in socket.assigns.eligible_attrs
      # Bonus finding: a freeform string WITHOUT a two-reviewer non_pii! clearance
      # default-denies too (`:plaintext_pii`), not just vault (`:token`) columns —
      # display_name/job_title are plain public strings but still refused.
      refute "display_name" in socket.assigns.eligible_attrs
      refute "job_title" in socket.assigns.eligible_attrs

      rendered = html(socket)
      # Attempt to find it in the rendered picker <option> values — and fail.
      refute rendered =~ ~s(value="full_name")
      refute rendered =~ ~s(value="emails")
      refute rendered =~ ~s(value="phones")
      # Anti-tautology: the scan itself is capable of finding a present value —
      # the GREEN control test above proves "company_id" DOES match.
    end

    test "RED PATH (write-time, bypassing the picker entirely): forging a vault attribute directly into handle_event is REFUSED" do
      org_id = Ash.UUID.generate()
      wf = create_workflow!(org_id, %{resource_key: @person_resource_key})

      socket = mount_socket(org_id) |> event("edit_workflow", %{"id" => to_string(wf.id)})

      # Bypass the <select> entirely — simulate a hostile client posting a raw
      # form payload keyed on the vault attribute.
      socket = event(socket, "add_condition", %{"condition" => %{"attribute" => "full_name", "op" => "eq", "values" => "x"}})

      assert socket.assigns.cond_error =~ "refused"
      assert socket.assigns.cond_error =~ "full_name" or socket.assigns.cond_error =~ "non-PII"

      # Nothing persisted — the kernel oracle refused it, not a UI-only filter.
      reloaded = reload!(wf.id)
      assert reloaded.conditions == []
    end

    test "RED PATH — action-interpolation gate also refuses a non-eligible {{subject.<attr>}} reference" do
      org_id = Ash.UUID.generate()
      wf = create_workflow!(org_id, %{resource_key: @person_resource_key})
      scope = %Samen.Scope{actor: %{id: "t", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}}

      assert {:error, message} =
               Samen.Web.Automation.Reads.add_action(mount(), scope, wf.id, %{
                 "kind" => "notify",
                 "body" => "hi {{subject.emails}}"
               })

      assert message =~ "refused"
      assert reload!(wf.id).actions == []
    end

    test "an UNRESOLVABLE resource_key yields NO eligible attributes (default-deny, never a crash)" do
      org_id = Ash.UUID.generate()
      wf = create_workflow!(org_id, %{resource_key: "Not.A.Real.Module"})

      socket = mount_socket(org_id) |> event("edit_workflow", %{"id" => to_string(wf.id)})
      assert socket.assigns.eligible_attrs == []
    end
  end

  # -- pause/resume (the tenant switch, not the operator kill-switch) ------------

  test "pause/resume writes the SAME status column T39/T42 read — a direct resource read confirms it" do
    org_id = Ash.UUID.generate()
    wf = create_workflow!(org_id, %{status: :active})

    socket = mount_socket(org_id)
    assert reload!(wf.id).status == :active

    socket = event(socket, "toggle_pause", %{"id" => to_string(wf.id)})
    assert reload!(wf.id).status == :paused
    assert html(socket) =~ "Resume"

    socket = event(socket, "toggle_pause", %{"id" => to_string(wf.id)})
    assert reload!(wf.id).status == :active
    assert html(socket) =~ "Pause"

    # Pause/resume never touches the OPERATOR kill-switch columns.
    reloaded = reload!(wf.id)
    assert is_nil(reloaded.disabled_by_operator_at)
    assert is_nil(reloaded.disabled_reason)
  end

  # -- manual "Run now" ------------------------------------------------------------

  test "\"Run now\" enqueues through Samen.Automation.trigger_manual/2 (the same dispatch pipeline)" do
    org_id = Ash.UUID.generate()
    wf = create_workflow!(org_id, %{trigger_kind: :manual, status: :active})

    socket = mount_socket(org_id)
    socket = event(socket, "run_now", %{"id" => to_string(wf.id)})

    assert socket.assigns.run_error == nil
    assert socket.assigns.run_ok =~ "Run enqueued"
    assert html(socket) =~ "Run enqueued"
  end

  test "\"Run now\" fails HONESTLY (not silently) when the target workflow_module is unwired" do
    org_id = Ash.UUID.generate()
    wf = create_workflow!(org_id)

    # `Samen.Automation.trigger_manual/2` fails CLOSED (`{:error, :no_automation_module}`)
    # when no workflow module is reachable — never a silent no-op (the fail-honest
    # adapter contract). `Reads.run_now/3` always supplies one derived from the
    # mount, so this exercises the underlying kernel contract directly, the same
    # guarantee `run_now/3` rides.
    assert Samen.Automation.trigger_manual(%{workflow_id: wf.id, org_id: org_id}, workflow_module: nil, repo: nil) ==
             {:error, :no_automation_module}
  end

  # -- host adoption (≈0 LOC macro mount) -----------------------------------------

  test "the macro-mounted route resolves to THIS module (no per-host copy)" do
    assert Samen.Web.Router.__routes__(:automation, "/automation") == [{"/automation", BuilderLive}]
  end
end
