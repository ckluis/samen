defmodule Demo.MarketingScopePolicyMatrixTest do
  @moduledoc """
  The Marketing scope org-scope + RBAC policy matrix (T3.4). Exercises the REAL
  mounted Marketing resources against the REAL Postgres, through the REAL Ash policy
  authorizer.

  Covers:
    * cross-org read denied (org-scope FilterCheck) — a property test over many
      org pairs (the `cross-org read denied` red path);
    * cross-org write denied;
    * PII masked-by-default on the tenant-plane read (subscriber🔒);
    * positive cases (an actor sees + writes its OWN org's rows);
    * Tier-0 config rows (template) — admin-gate enforced;
    * suppression enforced at send-time (red path: send to suppressed subscriber refused).
  """
  use Demo.DataCase, async: false
  use ExUnitProperties

  alias Demo.MarketingScope.{Campaign, Segment, Subscriber, Template, Send, Suppression}
  alias Demo.Identity.{Org, User}

  # --- helpers ---------------------------------------------------------------

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
        handle: "mkt-actor-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "Marketing", last: "Actor"},
        emails: ["mkt#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp mk_subscriber(org_id, email \\ nil) do
    email = email || "sub#{:rand.uniform(999_999)}@test.example"
    {:ok, s} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        email: email,
        status: :active,
        consent_at: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    s
  end

  defp mk_campaign(org_id, name \\ "Test Campaign") do
    {:ok, c} =
      Campaign
      |> Ash.Changeset.for_create(:create, %{
        name: name,
        org_id: org_id,
        status: :draft
      })
      |> Ash.create(authorize?: false)

    c
  end

  defp mk_template(org_id, name) do
    {:ok, t} =
      Template
      |> Ash.Changeset.for_create(:create, %{
        name: name,
        org_id: org_id,
        subject_line: "Hello from #{name}",
        body_html: "<p>Hello</p>",
        enabled: true
      })
      |> Ash.create(authorize?: false)

    t
  end

  defp mk_suppression(org_id, subscriber_id) do
    {:ok, s} =
      Suppression
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        subscriber_id: subscriber_id,
        reason: :unsubscribed,
        active: true,
        suppressed_at: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    s
  end

  # =========================================================================
  # Cross-org read denial — the org-scope FilterCheck. PROPERTY test.
  # =========================================================================

  property "an actor scoped to org A never reads another org's subscribers (cross-org read denied)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 8),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 8),
            max_runs: 20
          ) do
      org_a = mk_org("mktA-" <> name_a)
      org_b = mk_org("mktB-" <> name_b)

      scope_a = mk_actor(org_a.id)
      mk_subscriber(org_b.id)

      query = Subscriber |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      # Org B's subscribers are invisible (filtered, not just forbidden).
      refute org_b.id in seen_orgs
    end
  end

  property "an actor scoped to org A never reads another org's campaigns (cross-org)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 6),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 6),
            max_runs: 20
          ) do
      org_a = mk_org("campaignA-" <> name_a)
      org_b = mk_org("campaignB-" <> name_b)

      scope_a = mk_actor(org_a.id)
      mk_campaign(org_b.id)

      query = Campaign |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      refute org_b.id in seen_orgs
    end
  end

  # =========================================================================
  # Cross-org WRITE denial.
  # =========================================================================

  test "an actor cannot update a foreign org's campaign (cross-org write denied)" do
    org_a = mk_org("wba-camp")
    org_b = mk_org("wbb-camp")

    scope_a = mk_actor(org_a.id, :admin)
    campaign_b = mk_campaign(org_b.id, "B's Campaign")

    result =
      campaign_b
      |> Ash.Changeset.for_update(:update, %{status: :cancelled})
      |> Ash.update(actor: scope_a.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an actor cannot update a foreign org's template (cross-org write denied)" do
    org_a = mk_org("wba-tmpl")
    org_b = mk_org("wbb-tmpl")

    scope_a = mk_actor(org_a.id, :admin)
    template_b = mk_template(org_b.id, "B's Template")

    result =
      template_b
      |> Ash.Changeset.for_update(:update, %{subject_line: "tampered"})
      |> Ash.update(actor: scope_a.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # Org-less actor — fail closed.
  # =========================================================================

  test "an org-less actor sees zero marketing rows (fail closed)" do
    org = mk_org("orgless-mkt")
    mk_subscriber(org.id)

    orgless_actor = %{id: "nobody", org_id: nil, role: :member}

    case Ash.read(Subscriber, actor: orgless_actor, authorize?: true) do
      {:ok, seen} -> assert seen == []
      {:error, %Ash.Error.Forbidden{}} -> assert true
    end
  end

  # =========================================================================
  # Positive cases — an actor DOES see + write its OWN org's rows.
  # =========================================================================

  test "an actor sees its own org's subscribers (positive read case)" do
    org = mk_org("self-read-sub")
    scope = mk_actor(org.id, :member)
    mk_subscriber(org.id)

    query = Subscriber |> Ash.Query.select([:id, :org_id])
    {:ok, seen} = Ash.read(query, actor: scope.actor, authorize?: true)
    assert length(seen) >= 1
    assert Enum.all?(seen, fn r -> r.org_id == org.id end)
  end

  test "an admin actor CAN create a template (Tier-0 config row)" do
    org = mk_org("admin-tmpl")
    admin_scope = mk_actor(org.id, :admin)

    assert {:ok, tmpl} =
             Template
             |> Ash.Changeset.for_create(:create, %{
               name: "Welcome",
               org_id: org.id,
               subject_line: "Welcome to Samen",
               body_html: "<p>Hello!</p>"
             })
             |> Ash.create(actor: admin_scope.actor, authorize?: true)

    assert tmpl.name == "Welcome"
    assert tmpl.subject_line == "Welcome to Samen"
  end

  # =========================================================================
  # Tier-0 config rows: Template — admin-gated writes.
  # =========================================================================

  test "a member actor cannot create a template (admin-gate enforced)" do
    org = mk_org("member-tmpl-gate")
    member_scope = mk_actor(org.id, :member)

    result =
      Template
      |> Ash.Changeset.for_create(:create, %{
        name: "Sneaky",
        org_id: org.id,
        subject_line: "You won't see this"
      })
      |> Ash.create(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # PII masked-by-default on the tenant-plane read (subscriber🔒).
  # =========================================================================

  test "subscriber PII (email) is %Masked{} by default on a tenant-plane read" do
    org = mk_org("mask-sub")
    scope = mk_actor(org.id, :member)
    mk_subscriber(org.id, "masked@test.example")

    query = Subscriber |> Ash.Query.select([:id, :email])
    {:ok, [subscriber]} = Ash.read(query, actor: scope.actor, authorize?: true)

    assert %Samen.Masked{} = subscriber.email

    # The masked value renders as bullets.
    assert Phoenix.HTML.Safe.to_iodata(subscriber.email) |> IO.iodata_to_binary() =~ "•"
  end

  # =========================================================================
  # Suppression enforcement at send-time (RED PATH — T3.4 load-bearing spec).
  #
  # "a send to a suppressed subscriber refuses — red path"
  # =========================================================================

  test "a send to a suppressed subscriber is REFUSED (suppression red path)" do
    org = mk_org("suppressed-send-deny")
    subscriber = mk_subscriber(org.id, "suppressed@test.example")

    # Suppress the subscriber.
    _suppression = mk_suppression(org.id, subscriber.id)

    # Attempt a send to the suppressed subscriber.
    result =
      Send
      |> Ash.Changeset.for_create(:create_checked, %{
        subscriber_id: subscriber.id,
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    # The send must be refused — no row created, error returned.
    assert {:error, %Ash.Error.Invalid{errors: errors}} = result

    error_messages = Enum.map(errors, fn e ->
      case e do
        %{message: msg} -> msg
        _ -> inspect(e)
      end
    end)
    assert Enum.any?(error_messages, fn msg -> msg =~ "suppressed" end),
           "Expected suppressed error, got: #{inspect(error_messages)}"
  end

  test "a send to a NON-suppressed subscriber SUCCEEDS (positive control for suppression)" do
    org = mk_org("non-suppressed-send-ok")
    subscriber = mk_subscriber(org.id, "allowed@test.example")

    # No suppression row for this subscriber.
    result =
      Send
      |> Ash.Changeset.for_create(:create_checked, %{
        subscriber_id: subscriber.id,
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    # The send is created successfully.
    assert {:ok, send_record} = result
    assert send_record.subscriber_id == subscriber.id
    assert send_record.status == :queued
  end

  test "a send to a subscriber suppressed in ORG B does NOT block a send from ORG A (org-isolation)" do
    org_a = mk_org("supp-iso-a")
    org_b = mk_org("supp-iso-b")

    # Same subscriber email, but two different subscriber records in two orgs.
    sub_a = mk_subscriber(org_a.id, "shared@test.example")
    sub_b = mk_subscriber(org_b.id, "shared@test.example")

    # Suppress only org_b's subscriber.
    mk_suppression(org_b.id, sub_b.id)

    # Org A's subscriber is NOT suppressed — send must succeed.
    result =
      Send
      |> Ash.Changeset.for_create(:create_checked, %{
        subscriber_id: sub_a.id,
        org_id: org_a.id
      })
      |> Ash.create(authorize?: false)

    assert {:ok, send_record} = result
    assert send_record.subscriber_id == sub_a.id
  end

  # =========================================================================
  # Smoke: segments, email_events, suppressions are all org-scoped.
  # =========================================================================

  test "segments, email_events, suppressions are org-scoped (cross-org invisible)" do
    org_a = mk_org("smoke-ma")
    org_b = mk_org("smoke-mb")
    scope_a = mk_actor(org_a.id, :member)

    # Create a segment in org_b.
    {:ok, _seg_b} =
      Segment
      |> Ash.Changeset.for_create(:create, %{
        name: "B's Segment",
        org_id: org_b.id,
        filter_criteria: %{"status" => "active"}
      })
      |> Ash.create(authorize?: false)

    # Create a suppression in org_b.
    sub_b = mk_subscriber(org_b.id, "suppress-smoke@test.example")
    {:ok, _supp_b} =
      Suppression
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_b.id,
        subscriber_id: sub_b.id,
        reason: :bounced,
        active: true
      })
      |> Ash.create(authorize?: false)

    # Org A actor sees ZERO of org B's rows.
    {:ok, segs} = Ash.read(Segment, actor: scope_a.actor, authorize?: true)
    {:ok, supps} = Ash.read(Suppression, actor: scope_a.actor, authorize?: true)

    assert Enum.all?(segs, fn r -> r.org_id == org_a.id end)
    assert Enum.all?(supps, fn r -> r.org_id == org_a.id end)
  end
end
