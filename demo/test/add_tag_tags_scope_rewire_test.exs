defmodule Demo.AddTagTagsScopeRewireTest do
  @moduledoc """
  T122 — the `add_tag` automation action (`Samen.Automation.Actions.AddTag`)
  rewired onto the generic F4 Tag/Tagging mechanism (`Samen.Scopes.Tags`),
  exercised end-to-end against DEMO's REAL `Demo.SupportScope.Ticket` +
  `Demo.Tags.Tagging` (Postgres-backed), via the `:tags_scope_resources`
  config seam wired in `demo/config/config.exs`.

  Before T122, `add_tag` against a Ticket honestly returned
  `{:error, :no_tag_surface}` (T46 dropped `Ticket.tags`). This suite proves:

    * **POSITIVE** — `add_tag` against a Ticket now creates a real, queryable
      `Tagging` row (round-trip write+read, not just changeset-accepted) —
      NOT `:no_tag_surface`.
    * **RED + CONTROL (org-scope)** — a cross-org `add_tag` attempt is inert
      (no orphaned Tagging, an honest error); the SAME actor against its OWN
      org's ticket succeeds (anti-tautology).
    * **Idempotency** — repeating `add_tag` with the SAME tag string against
      the SAME ticket does not create a second `Tag` row (org+name) or a
      second `Tagging` row.
    * **INV-1** — the Tagging created carries no vault-routed field of the
      ticket (structurally impossible — `Tagging`'s attribute set is closed
      to id/org_id/timestamps/tag_id/subject_key/subject_id).
  """
  use Demo.DataCase, async: false

  require Ash.Query

  alias Demo.Identity.{Org, User}
  alias Demo.SupportScope.Ticket
  alias Demo.Tags.Tagging
  alias Samen.Automation.Actions.AddTag
  alias Samen.Automation.Context

  # -- helpers -----------------------------------------------------------------

  defp mk_org(name) do
    {:ok, org} =
      Org
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

    org
  end

  defp mk_actor(org_id, role \\ :member) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "add-tag-actor-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "Add", last: "Tag"},
        emails: ["addtag#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp mk_ticket(org_id) do
    {:ok, ticket} =
      Ticket
      |> Ash.Changeset.for_create(:create, %{
        subject: "Demo ticket #{:rand.uniform(999_999)}",
        status: :open,
        priority: :normal,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    ticket
  end

  defp ctx(org_id, actor, ticket, tag_str) do
    config = %{"tag" => tag_str}

    run_ctx = %Context{
      org_id: org_id,
      workflow_id: "wf-t122",
      subject_ref: "samen:support_scope.ticket:#{ticket.id}",
      resource_key: "Demo.SupportScope.Ticket",
      record_id: to_string(ticket.id),
      actor: actor
    }

    {config, run_ctx}
  end

  defp taggings_for(ticket_id, actor) do
    Tagging
    |> Ash.Query.filter(subject_key == "support_scope.ticket" and subject_id == ^ticket_id)
    |> Ash.Query.load(:tag)
    |> Ash.read!(actor: actor)
  end

  # -- POSITIVE: add_tag against a Ticket now creates a real, queryable Tagging -

  describe "add_tag against Demo.SupportScope.Ticket (T122 rewire)" do
    test "creates a real Tagging (round-trip write+read) — NOT :no_tag_surface (pre-T122 behavior)" do
      org = mk_org("Acme")
      actor = mk_actor(org.id)
      ticket = mk_ticket(org.id)

      {config, run_ctx} = ctx(org.id, actor, ticket, "urgent")

      assert {:ok, %{kind: :add_tag, record_id: record_id, tag: "urgent"}} = AddTag.run(config, run_ctx)
      assert record_id == to_string(ticket.id)

      taggings = taggings_for(ticket.id, actor)
      assert [tagging] = taggings
      assert tagging.subject_key == "support_scope.ticket"
      assert tagging.subject_id == ticket.id
      assert tagging.tag.name == "urgent"
    end

    test "the subject_key matches Samen.ObjectKey.key_for/1 (the SAME derivation samen_web's " <>
           "ObjectRef.Catalog.key_for/1 delegates to) — a workflow-attached Tag is queryable " <>
           "through the same read helpers a UI-attached Tag would use" do
      assert Samen.ObjectKey.key_for(Ticket) == "support_scope.ticket"
    end

    test "INV-1: the created Tagging carries no vault-routed field of the ticket — structurally " <>
           "impossible (Tagging's attribute set is closed to the opaque anchor + tag_id)" do
      org = mk_org("Acme")
      actor = mk_actor(org.id)
      ticket = mk_ticket(org.id)

      {config, run_ctx} = ctx(org.id, actor, ticket, "vip")
      assert {:ok, _} = AddTag.run(config, run_ctx)

      [tagging] = taggings_for(ticket.id, actor)

      attr_names = Tagging |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name) |> MapSet.new()

      assert attr_names ==
               MapSet.new([:id, :org_id, :inserted_at, :updated_at, :tag_id, :subject_key, :subject_id])

      refute Map.has_key?(tagging, :subject)
      refute Map.has_key?(tagging, :breached)
    end
  end

  # -- RED + CONTROL: org-scope (cross-org add_tag is inert) --------------------

  describe "org-scope — a cross-org add_tag attempt is inert" do
    test "RED: an actor from org B cannot tag org A's ticket — no orphaned Tagging, honest error" do
      org_a = mk_org("Org A")
      org_b = mk_org("Org B")
      attacker = mk_actor(org_b.id)
      victim_ticket = mk_ticket(org_a.id)

      {config, run_ctx} = ctx(org_b.id, attacker, victim_ticket, "hijacked")

      result = AddTag.run(config, run_ctx)
      assert match?({:error, _}, result)

      # No orphaned Tagging landed in EITHER org.
      assert taggings_for(victim_ticket.id, attacker) == []

      owner_actor = mk_actor(org_a.id)
      assert taggings_for(victim_ticket.id, owner_actor) == []
    end

    test "CONTROL: the SAME shape succeeds for the OWNING org's actor (anti-tautology — the red " <>
           "path is not a blanket refusal)" do
      org = mk_org("Org Owner")
      actor = mk_actor(org.id)
      ticket = mk_ticket(org.id)

      {config, run_ctx} = ctx(org.id, actor, ticket, "hijacked")

      assert {:ok, %{kind: :add_tag}} = AddTag.run(config, run_ctx)
      assert [_tagging] = taggings_for(ticket.id, actor)
    end
  end

  # -- Idempotency ---------------------------------------------------------------

  describe "idempotency — repeated add_tag with the same tag string" do
    test "does not create a duplicate Tag (org+name) or a duplicate Tagging" do
      org = mk_org("Idempotent Co")
      actor = mk_actor(org.id)
      ticket = mk_ticket(org.id)

      {config, run_ctx} = ctx(org.id, actor, ticket, "repeat-me")

      assert {:ok, %{kind: :add_tag}} = AddTag.run(config, run_ctx)
      assert {:ok, %{kind: :add_tag}} = AddTag.run(config, run_ctx)

      taggings = taggings_for(ticket.id, actor)
      assert length(taggings) == 1

      tag_ids =
        Demo.Tags.Tag
        |> Ash.Query.filter(name == "repeat-me")
        |> Ash.read!(actor: actor)
        |> Enum.map(& &1.id)

      assert length(tag_ids) == 1
    end
  end
end
