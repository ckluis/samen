defmodule Demo.PrimitivesScopePolicyMatrixTest do
  @moduledoc """
  The Primitives scope org-scope + RBAC policy matrix (T3.7). Exercises the REAL
  mounted Primitives resources against the REAL Postgres, through the REAL Ash policy
  authorizer.

  Covers:
    * cross-org read denied (org-scope FilterCheck) — a property test over many
      org pairs (notification, file, feature_flag);
    * cross-org write denied;
    * PII masked-by-default on the tenant-plane read (notification🔒 rendered_body,
      webhook🔒 signing_secret);
    * positive cases (an actor sees + writes its OWN org's rows);
    * Tier-0 config rows (webhook, feature_flag) — admin-gate enforced;
    * smoke usage: one round-trip per resource (proves host-mounting works).
  """
  use Demo.DataCase, async: false
  use ExUnitProperties

  require Ash.Query

  alias Demo.PrimitivesScope.{Notification, File, SearchIndex, Webhook, FeatureFlag}
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
        handle: "prim-actor-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "Prim", last: "Actor"},
        emails: ["prim#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp mk_notification(org_id) do
    {:ok, n} =
      Notification
      |> Ash.Changeset.for_create(:create, %{
        recipient_id: Ash.UUID.generate(),
        channel: :email,
        event_type: "invoice.created",
        status: :sent,
        rendered_body: "Dear Alice, invoice ##{:rand.uniform(9999)} is ready.",
        sent_at: DateTime.utc_now(),
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    n
  end

  # Route through the governed chokepoint (`Samen.Files.upload/3`) — the ONLY path that
  # may mint a `storage_key`-bearing File row (ADR-026 RP-FI-1 / AC-G14-2). A direct
  # `Ash.create` setting `storage_key` is refused by `Samen.Files.ChokepointGuard`. The
  # upload lands `:quarantined` (fail-closed, RP-FI-3); we promote it through the governed
  # `promote/3` path (Noop scanner → `{:ok, :clean}`) so the fixture is `:active`.
  defp mk_file(org_id) do
    scope = %{org_id: org_id}

    {:ok, quarantined} =
      Samen.Files.upload(
        scope,
        %{
          filename: "file-#{:rand.uniform(9999)}.pdf",
          content_type: "application/pdf",
          binary: :binary.copy("x", 512)
        },
        file_upload_opts()
      )

    {:ok, f} = Samen.Files.promote(scope, quarantined, file_upload_opts())
    f
  end

  # Files-engine seams for the governed upload/promote path. The Local storage adapter
  # falls back to a temp root when none is configured, so no storage_config is needed.
  defp file_upload_opts do
    [
      file_module: File,
      repo: Demo.Repo,
      scanner: Samen.Files.Scanner.Noop,
      max_bytes: 26_214_400,
      allowed_content_types: ~w(application/pdf image/png image/jpeg text/plain text/csv)
    ]
  end

  defp mk_webhook(org_id) do
    {:ok, w} =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook/#{:rand.uniform(9999)}",
        label: "Test hook",
        event_types: ["invoice.created"],
        status: :active,
        signing_secret: "secret-#{Ash.UUID.generate()}",
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    w
  end

  defp mk_feature_flag(org_id) do
    {:ok, ff} =
      FeatureFlag
      |> Ash.Changeset.for_create(:create, %{
        name: "test.flag.#{:rand.uniform(9999)}",
        description: "Test feature flag",
        enabled: true,
        rollout_pct: 100,
        stage: :ga,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    ff
  end

  # =========================================================================
  # Cross-org read denial — property tests
  # =========================================================================

  property "an actor scoped to org A never reads another org's notifications (cross-org)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 8),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 8),
            max_runs: 20
          ) do
      org_a = mk_org("pntA-" <> name_a)
      org_b = mk_org("pntB-" <> name_b)

      scope_a = mk_actor(org_a.id)
      mk_notification(org_b.id)

      query = Notification |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      refute org_b.id in seen_orgs
    end
  end

  property "an actor scoped to org A never reads another org's files (cross-org)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 8),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 8),
            max_runs: 20
          ) do
      org_a = mk_org("pflA-" <> name_a)
      org_b = mk_org("pflB-" <> name_b)

      scope_a = mk_actor(org_a.id)
      mk_file(org_b.id)

      query = File |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      refute org_b.id in seen_orgs
    end
  end

  property "an actor scoped to org A never reads another org's feature flags (cross-org)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 8),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 8),
            max_runs: 20
          ) do
      org_a = mk_org("pffA-" <> name_a)
      org_b = mk_org("pffB-" <> name_b)

      scope_a = mk_actor(org_a.id)
      mk_feature_flag(org_b.id)

      query = FeatureFlag |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      refute org_b.id in seen_orgs
    end
  end

  # =========================================================================
  # Cross-org WRITE denial
  # =========================================================================

  test "an actor cannot update a foreign org's notification (cross-org write denied)" do
    org_a = mk_org("wba-ntf")
    org_b = mk_org("wbb-ntf")

    scope_a = mk_actor(org_a.id, :admin)
    notification_b = mk_notification(org_b.id)

    result =
      notification_b
      |> Ash.Changeset.for_update(:update, %{status: :read})
      |> Ash.update(actor: scope_a.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an actor cannot update a foreign org's feature flag (cross-org write denied)" do
    org_a = mk_org("wba-pff")
    org_b = mk_org("wbb-pff")

    scope_a = mk_actor(org_a.id, :admin)
    flag_b = mk_feature_flag(org_b.id)

    result =
      flag_b
      |> Ash.Changeset.for_update(:update, %{enabled: false})
      |> Ash.update(actor: scope_a.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # Org-less actor — fail closed (sees zero rows)
  # =========================================================================

  test "an actor with no org_id reads zero notifications (fail closed)" do
    org = mk_org("no-org-ntf")
    mk_notification(org.id)

    no_scope = %Samen.Scope{actor: %{id: Ash.UUID.generate(), org_id: nil, role: :member}}

    query = Notification |> Ash.Query.select([:id])
    result = Ash.read(query, actor: no_scope.actor, authorize?: true)

    case result do
      {:ok, seen} ->
        assert seen == [], "Expected no rows for nil org_id actor, got: #{inspect(seen)}"

      {:error, %Ash.Error.Forbidden{}} ->
        :ok

      other ->
        flunk("Unexpected result for nil org_id read: #{inspect(other)}")
    end
  end

  # =========================================================================
  # Positive controls (own org is visible)
  # =========================================================================

  test "an actor reads and writes its own org's files (positive control)" do
    org = mk_org("pos-pfl")
    scope = mk_actor(org.id, :member)
    file = mk_file(org.id)

    query = File |> Ash.Query.select([:id, :org_id])
    {:ok, seen} = Ash.read(query, actor: scope.actor, authorize?: true)
    assert Enum.any?(seen, fn f -> f.id == file.id end)

    # Can update own org's file.
    {:ok, _updated} =
      file
      |> Ash.Changeset.for_update(:update, %{status: :archived})
      |> Ash.update(actor: scope.actor, authorize?: true)
  end

  test "an actor reads its own org's feature flags (positive control)" do
    org = mk_org("pos-pff")
    scope = mk_actor(org.id, :member)
    flag = mk_feature_flag(org.id)

    query = FeatureFlag |> Ash.Query.select([:id, :name, :enabled])
    {:ok, seen} = Ash.read(query, actor: scope.actor, authorize?: true)
    assert Enum.any?(seen, fn f -> f.id == flag.id end)
  end

  # =========================================================================
  # Tier-0 config rows: admin-gate enforced
  # =========================================================================

  test "a member actor cannot create a webhook (admin-gate — Tier-0 config)" do
    org = mk_org("tier0-pwh")
    member_scope = mk_actor(org.id, :member)

    result =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook/test",
        event_types: ["invoice.created"],
        signing_secret: "test-secret",
        org_id: org.id
      })
      |> Ash.create(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an admin actor can create a webhook (Tier-0 admin control)" do
    org = mk_org("tier0-pwh-admin")
    admin_scope = mk_actor(org.id, :admin)

    result =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook/admin-test-#{:rand.uniform(9999)}",
        event_types: ["invoice.created"],
        signing_secret: "admin-secret-#{Ash.UUID.generate()}",
        org_id: org.id
      })
      |> Ash.create(actor: admin_scope.actor, authorize?: true)

    assert {:ok, _webhook} = result
  end

  test "a member actor cannot create a feature flag (admin-gate)" do
    org = mk_org("tier0-pff")
    member_scope = mk_actor(org.id, :member)

    result =
      FeatureFlag
      |> Ash.Changeset.for_create(:create, %{
        name: "test.member.flag",
        enabled: true,
        org_id: org.id
      })
      |> Ash.create(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an admin actor can create a feature flag (Tier-0 admin control)" do
    org = mk_org("tier0-pff-admin")
    admin_scope = mk_actor(org.id, :admin)

    result =
      FeatureFlag
      |> Ash.Changeset.for_create(:create, %{
        name: "admin.feature.flag.#{:rand.uniform(9999)}",
        description: "Admin-created flag",
        enabled: true,
        org_id: org.id
      })
      |> Ash.create(actor: admin_scope.actor, authorize?: true)

    assert {:ok, _flag} = result
  end

  test "a member actor cannot create a search index entry (admin-gate)" do
    org = mk_org("tier0-psh")
    member_scope = mk_actor(org.id, :member)

    result =
      SearchIndex
      |> Ash.Changeset.for_create(:create, %{
        resource_name: "Demo.PrimitivesScope.File",
        field_name: "filename",
        vector_column: "pfl_search_vector",
        org_id: org.id
      })
      |> Ash.create(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # PII masked by default on tenant-plane reads
  # =========================================================================

  test "notification rendered_body is masked (%Masked{}) on default read" do
    org = mk_org("pii-mask-ntf")
    _notification = mk_notification(org.id)
    scope = mk_actor(org.id, :member)

    query = Notification |> Ash.Query.select([:id, :rendered_body])
    {:ok, [loaded]} = Ash.read(query, actor: scope.actor, authorize?: true)

    assert %Samen.Masked{} = loaded.rendered_body
    refute inspect(loaded) =~ "Dear Alice"
  end

  test "webhook signing_secret is masked (%Masked{}) on default read" do
    org = mk_org("pii-mask-pwh")
    _webhook = mk_webhook(org.id)
    scope = mk_actor(org.id, :admin)

    query = Webhook |> Ash.Query.select([:id, :signing_secret])
    {:ok, [loaded]} = Ash.read(query, actor: scope.actor, authorize?: true)

    assert %Samen.Masked{} = loaded.signing_secret
    refute inspect(loaded) =~ "secret-"
  end

  # =========================================================================
  # Smoke usage — one round-trip per resource (proves host-mounting works)
  # =========================================================================

  test "smoke: full round-trip through all five Primitives resources" do
    org = mk_org("smoke-primitives")

    {:ok, results} = Demo.PrimitivesScope.Smoke.run(org.id)

    assert %{
             notification: _,
             file: _,
             search_index: _,
             webhook: _,
             feature_flag: _
           } = results

    assert results.feature_flag.enabled == true
    assert results.file.status == :active
    assert is_binary(results.notification.id)
    assert is_binary(results.webhook.id)
  end

  test "smoke: feature flag seeder creates two flags" do
    org = mk_org("smoke-ff-seed")
    Demo.PrimitivesScope.Seeds.seed_feature_flags(org.id)

    {:ok, flags} =
      FeatureFlag
      |> Ash.Query.select([:id, :name, :enabled])
      |> Ash.Query.filter(org_id == ^org.id)
      |> Ash.read(authorize?: false)

    assert length(flags) >= 2
    names = Enum.map(flags, & &1.name)
    assert "notifications.enabled" in names
    assert "search.enabled" in names
  end

  test "audit writers emit to aud_event tier (no new audit table created)" do
    org = mk_org("audit-writers")
    {:ok, webhook} = Demo.PrimitivesScope.Smoke.mk_webhook(org.id)

    # Audit writes to aud_event — no new table, just the existing append-only tier.
    # Pass a struct with org_id explicitly set (Ash.NotLoaded is not a valid UUID for correlation_id).
    webhook_with_org = Map.put(webhook, :org_id, org.id)

    result =
      Samen.Scopes.Primitives.Audit.webhook_registered(Demo.Repo, webhook_with_org, Ash.UUID.generate())

    assert {:ok, _} = result

    # Confirm no new prim_ or prm_ audit table exists — audit rides aud_event.
    {:error, _} = Demo.Repo.query("SELECT 1 FROM prim_audit LIMIT 1")
  end
end
