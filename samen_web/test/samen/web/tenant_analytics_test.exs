defmodule Samen.Web.TenantAnalyticsTest do
  @moduledoc """
  P17 (ADR-045 §3) — the TENANT own-org analytics read (`Samen.Web.Tenant.AnalyticsReads`).
  Proves the covert-channel discipline the brief names, all at the read layer where the
  security lives:

    * **Sub-floor suppression (fail closed)** — a count-of-one own-org cohort is `⊘`
      (`%Suppressed{}`), never a raw count; a `>= k` cohort releases. The floor is the
      shipped `Samen.Aggregate.Privacy.apply/3`, REUSED (the `k:` override proves it is
      load-bearing — the anti-tautology flip).
    * **Cross-org isolation** — org A's read binds `paf_org_id` off its OWN authenticated
      scope; org B's rows are never in the result. No cohort spans orgs.
    * **Role gate (P17 Q3)** — a masked `:member` MAY query (insight-without-PII, the whole
      point); an org-less / role-less caller is refused (`can_query?/1` fail-closed) and
      `funnel/3` returns `[]`.
    * **The MaskingCase twin** — the floor IS the intra-org masking enforcement: the SAME
      lower-privilege plane that resolves a subject's vault field to `••••` sees a
      count-of-one org cohort as `⊘`; NEUTER the floor (`k: 1`) and the count-of-one
      reconstructs ("exactly 1 subject reached this stage") — leak DETECTED.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.Aggregate.Suppressed
  alias Samen.Web.Mount
  alias Samen.Web.Tenant.AnalyticsReads

  defp insert_paf!(org_id, stage, actor_count) do
    Ecto.Adapters.SQL.query!(
      Samen.WebTest.Repo,
      """
      INSERT INTO paf_product_event_rollup (paf_org_id, paf_kind, paf_stage, paf_actor_count)
      VALUES ($1, 'funnel', $2, $3)
      """,
      [Ecto.UUID.dump!(org_id), stage, actor_count]
    )
  end

  defp stage(funnel, name), do: Enum.find(funnel, &(&1.stage == name))

  # ---------------------------------------------------------------------------
  # Sub-floor suppression — the shipped floor, load-bearing
  # ---------------------------------------------------------------------------

  test "k-anon: a count-of-one own-org stage SUPPRESSES (⊘); a >= k stage RELEASES" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    insert_paf!(org, "signup", 8)
    insert_paf!(org, "first_record", 1)

    funnel = AnalyticsReads.funnel(mount, scope, k: 5)

    assert %{actor_count: 8} = stage(funnel, "signup")
    lonely = stage(funnel, "first_record")
    assert Suppressed.suppressed?(lonely.actor_count)
    assert lonely.actor_count.reason == :k_anonymity
    assert to_string(lonely.actor_count) == Suppressed.glyph()
  end

  test "anti-tautology: neutering the floor (k: 1) RELEASES the count-of-one — the flip" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)
    insert_paf!(org, "first_record", 1)

    assert Suppressed.suppressed?(stage(AnalyticsReads.funnel(mount, scope, k: 5), "first_record").actor_count)
    assert stage(AnalyticsReads.funnel(mount, scope, k: 1), "first_record").actor_count == 1
  end

  # ---------------------------------------------------------------------------
  # Cross-org isolation
  # ---------------------------------------------------------------------------

  test "cross-org: org A's read never sees org B's rows (org_id bound from the scope)" do
    mount = build_mount(:crm)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    scope_a = Mount.scope(mount, org_a)

    insert_paf!(org_a, "signup", 6)
    insert_paf!(org_b, "signup", 999_999)

    funnel = AnalyticsReads.funnel(mount, scope_a, k: 5)
    assert %{actor_count: 6} = stage(funnel, "signup")
    refute Enum.any?(funnel, &(&1.actor_count == 999_999))
  end

  # ---------------------------------------------------------------------------
  # Role gate (P17 Q3)
  # ---------------------------------------------------------------------------

  test "role gate: a masked :member MAY query; an org-less caller is refused" do
    assert AnalyticsReads.can_query?(%{org_id: Ash.UUID.generate(), role: :member})
    assert AnalyticsReads.can_query?(%{org_id: Ash.UUID.generate(), role: :admin})
    refute AnalyticsReads.can_query?(%{role: :member})
    refute AnalyticsReads.can_query?(%{org_id: Ash.UUID.generate(), role: :guest})
    refute AnalyticsReads.can_query?(nil)
  end

  test "a caller who may not query gets [] (fail closed), even with seeded rows" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    insert_paf!(org, "signup", 8)
    orgless = %Samen.Scope{actor: %{id: "x", role: :member, plane: :tenant}}
    assert AnalyticsReads.funnel(mount, orgless, k: 1) == []
  end

  # ---------------------------------------------------------------------------
  # The MaskingCase twin — the floor IS the intra-org masking enforcement
  # ---------------------------------------------------------------------------

  test "twin: same lower-priv plane → •••• on the vault field AND ⊘ on the count-of-one; neuter → leak" do
    require Ash.Query
    seeded = Seeds.seed_all()
    org = seeded.org_id

    # Re-read the person with the vault-routed field SELECTED (not loaded by default) —
    # the same ensure_selected posture the framework Reads run before PiiResolution.
    person =
      Samen.WebTest.Crm.Person
      |> Ash.Query.filter(id == ^seeded.crm.person.id)
      |> Ash.Query.ensure_selected([:full_name])
      |> Ash.read_one!(authorize?: false)

    # (a) DIRECT field read on the operator-without-grant (lower-priv) plane → ••••.
    operator = resolve_on_plane(person, Samen.WebTest.Crm.Person, :operator, repo: Samen.WebTest.Repo)
    assert_plane_masked!(operator.full_name)

    # (b) The count-of-one org COHORT for the SAME org, same floor → ⊘.
    mount = build_mount(:crm)
    scope = Mount.scope(mount, org)
    insert_paf!(org, "first_record", 1)

    floored = stage(AnalyticsReads.funnel(mount, scope, k: 5), "first_record")
    assert Suppressed.suppressed?(floored.actor_count)
    assert to_string(floored.actor_count) == Suppressed.glyph()

    # (c) SABOTAGE flip: neuter the floor → the count-of-one reconstructs (leak detected).
    #     "exactly 1 subject reached first_record" is the re-identifying fact the floor withheld.
    leaked = stage(AnalyticsReads.funnel(mount, scope, k: 1), "first_record")
    assert leaked.actor_count == 1
    refute Suppressed.suppressed?(leaked.actor_count)
  end

  # ---------------------------------------------------------------------------
  # The LiveView renderer (direct load + render — no router integration needed)
  # ---------------------------------------------------------------------------

  alias Samen.Web.Tenant.AnalyticsLive

  defp render_funnel(org) do
    mount = build_mount(:crm)

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> AnalyticsLive.load(org)
    |> then(&render_html(AnalyticsLive, &1.assigns))
  end

  test "LiveView render: a >= k stage shows its count; a count-of-one stage renders ⊘, never the value" do
    org = Ash.UUID.generate()
    insert_paf!(org, "signup", 8)
    insert_paf!(org, "first_record", 1)

    html = render_funnel(org)

    assert html =~ "Signed up"
    assert html =~ ">8<"
    # the count-of-one stage suppresses — ⊘ present, the withheld "1" never rendered as a count
    assert html =~ "⊘"
    assert html =~ "suppressed to prevent re-identification"
    refute html =~ ~r/first-record.*>1</s
  end

  test "LiveView render: no org resolved → the empty state (fail closed, no data)" do
    html = render_funnel(nil)
    assert html =~ "analytics-empty"
    refute html =~ "funnel-table"
  end
end
