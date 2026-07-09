defmodule Demo.CmsScopeVaultRoutingTest do
  @moduledoc """
  CMS scope PII classification test (T3.5).

  The CMS scope has NO vault-routed PII objects (the doc's 🔒 map has no mark
  on any CMS resource). This test:

    1. Proves NO vault tokens appear in CMS rows (all fields are plain, not
       vault-routed).
    2. Proves the `pii_classify` default-deny (ADR-015) flags uncleared freeform
       CMS columns, and that the committed baseline / two-reviewer `non_pii!`
       clearances are the ONLY ways a freeform column passes.
    3. Proves `csm_description` is classified as non-PII via the registry
       (the mask-unknown-by-default proof — D9).
    4. Proves the non-PII registration requires distinct reviewers (distinct-party
       discipline — same as reveal grants).
    5. Proves the oracle's `registered_non_pii` tier works for CMS rows (a
       registered `csm_description` row can be redacted on erasure).

  This replaces the standard vault_routing_test for scopes that have no 🔒 objects.
  The task spec (T3.5) says "No PII objects — but prove mask-unknown-by-default
  classification on free-text fields is handled (classified non-PII deliberately,
  documented)."
  """
  use Demo.DataCase, async: false

  alias Demo.CmsScope.{Page, Post, SeoMeta}
  alias Demo.Identity.Org
  alias Samen.NonPii

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)
    org
  end

  # =========================================================================
  # No vault tokens in CMS rows.
  # =========================================================================

  test "CMS page fields are plain strings (no vt_* tokens)" do
    org = mk_org("cms-vault-page")

    {:ok, page} =
      Page
      |> Ash.Changeset.for_create(:create, %{
        title: "Plain Title",
        slug: "plain-slug",
        body: "Plain body content.",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    # Query the raw DB columns — they should be plain text, NOT vt_* tokens.
    %{rows: [[title_col, body_col]]} =
      Repo.query!(
        "SELECT cpg_title, cpg_body FROM cpg_page WHERE cpg_id = $1",
        [Ecto.UUID.dump!(page.id)]
      )

    # Plain strings — not vault-routed.
    refute String.starts_with?(title_col || "", "vt_"),
           "cpg_title should be plain text, not a vt_ token"
    refute String.starts_with?(body_col || "", "vt_"),
           "cpg_body should be plain text, not a vt_ token"

    # The values are the actual authored content.
    assert title_col == "Plain Title"
    assert body_col == "Plain body content."
  end

  test "CMS post fields are plain strings (no vault routing)" do
    org = mk_org("cms-vault-post")

    {:ok, post} =
      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "Plain Post Title",
        body: "Plain post body.",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    %{rows: [[title_col]]} =
      Repo.query!(
        "SELECT cpt_title FROM cpt_post WHERE cpt_id = $1",
        [Ecto.UUID.dump!(post.id)]
      )

    assert title_col == "Plain Post Title"
    refute String.starts_with?(title_col || "", "vt_")
  end

  test "CMS SeoMeta csm_description is plain text (non-PII classified)" do
    org = mk_org("cms-vault-seo")

    # Create a page to attach SEO meta to.
    {:ok, page} =
      Page
      |> Ash.Changeset.for_create(:create, %{
        title: "SEO Test Page",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    {:ok, seo} =
      SeoMeta
      |> Ash.Changeset.for_create(:create, %{
        meta_title: "Test Meta",
        description: "A plain authored description for SEO.",
        org_id: org.id,
        page_id: page.id
      })
      |> Ash.create(authorize?: false)

    %{rows: [[desc_col]]} =
      Repo.query!(
        "SELECT csm_description FROM csm_seo_meta WHERE csm_id = $1",
        [Ecto.UUID.dump!(seo.id)]
      )

    # The description is the authored content — plain, not a token.
    assert desc_col == "A plain authored description for SEO."
    refute String.starts_with?(desc_col || "", "vt_")
  end

  test "no CMS resource has any pii_* columns (no vault-routed fields)" do
    # Structural assertion: none of the CMS tables should have pii_* columns.
    cms_tables = [
      "cpg_page",
      "cpt_post",
      "cbl_block",
      "cmd_media",
      "cnv_navigation",
      "csm_seo_meta",
      "cvr_content_version"
    ]

    Enum.each(cms_tables, fn table ->
      {:ok, %{columns: cols}} = Repo.query("SELECT * FROM #{table} LIMIT 0")

      pii_cols = Enum.filter(cols, fn c -> String.starts_with?(c, "pii_") end)

      assert pii_cols == [],
             "Table #{table} should have NO pii_* columns, but found: #{inspect(pii_cols)}"
    end)
  end

  # =========================================================================
  # pii_classify default-denies CMS freeform columns (ADR-015).
  # =========================================================================

  test "pii_classify default-denies uncleared CMS freeform columns; baseline + non_pii! clear (ADR-015)" do
    # ADR-015 flip: a freeform CMS column with a benign name (title/body/slug/…)
    # is NO LONGER waved through by the name-token heuristic. New + uncleared →
    # it flags with a freeform default-deny reason. The committed schema.dict.json
    # baseline grandfathers the pre-flip columns (CI stays green, AC-G3-4), and a
    # two-reviewer non_pii! entry clears a column deliberately (csm_description).
    alias Samen.PiiClassify

    # RED PATH: with no baseline and no registry, every freeform Page column
    # flags — including the benign-named ones the old heuristic passed silently.
    flags = PiiClassify.scan_resource(Demo.CmsScope.Page, MapSet.new(), [])
    flagged = Enum.map(flags, & &1.logical_name)

    Enum.each([:title, :body, :slug], fn field_name ->
      assert field_name in flagged,
             "default-deny must flag uncleared freeform CMS field #{inspect(field_name)}"
    end)

    assert Enum.all?(flags, fn f ->
             Enum.any?(f.reasons, &String.contains?(&1, "default-denied"))
           end),
           "every flag must carry the freeform default-deny reason"

    # GREEN: the committed baseline grandfathers the pre-flip columns — the C4
    # CI gate does not re-flag them.
    baseline = PiiClassify.load_baseline(Path.expand("../schema.dict.json", __DIR__))
    assert PiiClassify.scan_resource(Demo.CmsScope.Page, baseline, []) == []

    # GREEN: a two-reviewer non_pii! clearance clears a column without the
    # baseline (csm_description — the load-bearing D9 registration).
    :ok = Demo.CmsScope.NonPiiSetup.register_all()
    entries = Samen.NonPii.entries()

    seo_flags = PiiClassify.scan_resource(Demo.CmsScope.SeoMeta, MapSet.new(), entries)
    refute :description in Enum.map(seo_flags, & &1.logical_name),
           "non_pii!-cleared csm_description must not flag"
  end

  # =========================================================================
  # csm_description non-PII classification (mask-unknown-by-default proof).
  # =========================================================================

  test "csm_description is registered as non-PII with distinct reviewers (D9 proof)" do
    {:ok, entry} =
      NonPii.register(%{
        table_name: "csm_seo_meta",
        column_name: "csm_description",
        cleared_by: "cms-vault-test-author",
        reviewed_by: "cms-vault-test-reviewer",
        reason:
          "SEO description is authored marketing copy generated by the product operator — " <>
            "it describes pages/posts, not natural persons. Evaluated under D9 " <>
            "mask-unknown-by-default: consciously cleared as non-PII with distinct-reviewer " <>
            "sign-off (T3.5 CMS scope vault routing test).",
        subject_column: "csm_org_id",
        redaction: "[REDACTED_CONTENT]"
      })

    assert entry.table_name == "csm_seo_meta"
    assert entry.column_name == "csm_description"
    assert entry.cleared_by != entry.reviewed_by, "distinct-party discipline: reviewers must differ"
  end

  test "csm_description non-PII self-review fails (distinct-party discipline — red path)" do
    result =
      NonPii.register(%{
        table_name: "csm_seo_meta",
        column_name: "csm_description",
        cleared_by: "same-person",
        reviewed_by: "same-person",
        reason: "attempted self-review",
        subject_column: "csm_org_id"
      })

    assert {:error, :self_review} = result
  end

  test "registered csm_description can be redacted (non-PII oracle arm)" do
    # This proves the erasure arm works for CMS non-PII columns.
    org = mk_org("cms-vault-redact")

    # Register csm_description as non-PII.
    {:ok, _} =
      NonPii.register(%{
        table_name: "csm_seo_meta",
        column_name: "csm_description",
        cleared_by: "redact-test-author",
        reviewed_by: "redact-test-reviewer",
        reason: "Test: authored marketing copy, not PII.",
        subject_column: "csm_org_id",
        redaction: "[REDACTED_CONTENT]"
      })

    # Create a page + seo_meta row.
    {:ok, page} =
      Page
      |> Ash.Changeset.for_create(:create, %{
        title: "Redaction Test Page",
        org_id: org.id
      })
      |> Ash.create(authorize?: false)

    {:ok, _seo} =
      SeoMeta
      |> Ash.Changeset.for_create(:create, %{
        description: "Pre-redaction marketing copy.",
        org_id: org.id,
        page_id: page.id
      })
      |> Ash.create(authorize?: false)

    # Redact for this org (the subject_column is csm_org_id).
    {:ok, count, details} = NonPii.redact_for_subject(org.id, Repo)

    # At least one cell was redacted.
    assert count >= 1

    # The detail identifies csm_seo_meta.csm_description.
    csm_detail = Enum.find(details, fn d ->
      d["table"] == "csm_seo_meta" and d["column"] == "csm_description"
    end)

    assert csm_detail != nil, "Expected csm_seo_meta.csm_description in redaction details"
    assert csm_detail["redacted"] >= 1

    # The DB column now holds the sentinel.
    # Cast csm_org_id to text so Postgrex treats the UUID string param as text.
    %{rows: [[desc_after]]} =
      Repo.query!(
        "SELECT csm_description FROM csm_seo_meta WHERE csm_org_id::text = $1",
        [org.id]
      )

    assert desc_after == "[REDACTED_CONTENT]",
           "csm_description should be the redaction sentinel after erasure"
  end

  # =========================================================================
  # Anti-tautology probe documentation.
  # =========================================================================

  # The anti-tautology probe for the non-PII classification was run manually
  # (per the scope-authoring guide §9 requirement):
  #
  #   Probe: temporarily removed the `NonPii.register/1` call and confirmed
  #   that the `pii_classify` verifier does NOT flag `csm_description` (because
  #   "description" is not in the PII name-token list). This confirms the C4
  #   scanner is correctly non-triggering for this column name — the non-PII
  #   registration is the EXPLICIT classification proof, not a scanner workaround.
  #
  #   Probe: temporarily made `NonPii.register/1` return `{:error, :self_review}`
  #   for all calls — confirmed the `csm_description non-PII self-review fails`
  #   test PASSED (it expects :self_review) and the `registered as non-PII` test
  #   FLIPPED to failing. Reverted.
  #
  # Result: the non-PII registration check is a non-vacuous discriminator.
end
