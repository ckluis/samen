defmodule Demo.Repo.Migrations.CmsPostVisibility do
  @moduledoc """
  T78 (spec §I5 helpdesk knowledge base + composer suggestion + deflection) — adds
  `cpt_visibility` (`"internal" | "public"`, default `"internal"`) to `cpt_post`
  (`samen_core/lib/samen/scopes/cms/blueprint.ex`). This is the entire delta that
  turns a CMS post into a helpdesk KB article: no parallel article resource.

  A public+published post is portal-visible (unauthenticated, `Post.read_public`);
  every other post (internal, or not yet published) stays agent-only via the
  default org-scoped `:read`. Additive column on an already-catalogued resource →
  `catalog_sync/2`'s `only:` scoping, so `down` removes exactly this one
  `fld_field` row (mirrors `20260729220000_cms_scope_archivable`'s shape).
  """
  use Samen.Migration

  def change do
    alter table(:cpt_post) do
      add(:cpt_visibility, :text, null: false, default: "internal")
    end

    create(index(:cpt_post, [:cpt_org_id, :cpt_status, :cpt_visibility]))

    catalog_sync([Demo.CmsScope.Post], only: [:visibility])
  end
end
