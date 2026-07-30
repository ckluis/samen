defmodule Demo.RetentionArchivedRosterTest do
  @moduledoc """
  ADR-040 §5.6 (T37g — retention integration + archived-count sweep, the last leg of
  the T37 adoption sweep after T36 + T37a–f all shipped DONE+CONFIRMED): every
  resource the per-scope adopters (T37a billing, T37b cms, T37c crm, T37d marketing,
  T37e primitives, T37f support) flipped `archivable: true` gets a
  `Samen.Retention.Spec{timestamp_field: :archived_at}` entry — proven here by
  WALKING demo's own catalog (`Samen.Retention.archivable_specs/2`, backed by
  `Samen.Catalog.resource_modules/1` + `Samen.Info.archivable?/1`), never a
  hand-maintained resource list, so the roster assertion cannot silently drift as
  scopes adopt E6 (the binding done-criterion in `_orch/tasks/T37g/handoff.md`).

  Chat (`samen_web`'s T37e rider) is proven separately in
  `samen_web/test/samen/scopes/chat_retention_roster_test.exs` — demo does not mount
  the Chat scope.

  Also proves the sweep mechanism end-to-end on a REAL adopted resource (CRM
  `Company`, not the samen_core kernel `Widget`/`Person` pilots that
  `samen_core/test/retention_sweep_test.exs` already covers): an archived row past
  its retention window is truly purged via `:destroy_permanently` (never a bare
  `Ash.destroy!`, which would silently re-archive it); one within the window is
  retained; the archived-count sweep report is accurate.
  """
  use Demo.DataCase, async: false

  alias Demo.CrmScope.Company
  alias Samen.Retention
  alias Samen.Retention.Spec

  @now ~U[2026-07-29 12:00:00Z]

  defp mk_company(org_id, name) do
    {:ok, c} =
      Company
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "#{name}-#{:rand.uniform(999_999)}"})
      |> Ash.create(authorize?: false)

    c
  end

  defp backdate!(table, id_col, col, id, age_days, now) do
    ts = DateTime.add(now, -age_days * 24 * 60 * 60, :second) |> DateTime.truncate(:microsecond)
    Repo.query!("UPDATE #{table} SET #{col} = $1 WHERE #{id_col} = $2", [ts, Ecto.UUID.dump!(id)])
  end

  describe "archivable_specs/2 walks demo's catalog — the T37a-f roster is fully covered (§5.6)" do
    test "every archivable resource across demo's mounted scopes gets a spec, all timestamp_field: :archived_at" do
      domains = Application.fetch_env!(:samen_core, :ash_domains)
      specs = Retention.archivable_specs(domains)

      archivable_resources =
        domains
        |> Samen.Catalog.resource_modules()
        |> Enum.filter(&Samen.Info.archivable?/1)
        |> MapSet.new()

      spec_resources = specs |> Enum.map(& &1.resource) |> MapSet.new()

      # Set-equality against a fresh catalog walk (not the same list twice) — this is
      # the drift-proof assertion; a resource flipping `archivable: true` tomorrow is
      # covered automatically, and one that never adopts stays absent automatically.
      assert spec_resources == archivable_resources
      assert Enum.all?(specs, &(&1.timestamp_field == :archived_at))
      assert archivable_resources != MapSet.new([]), "sanity: demo must mount SOME archivable resource"

      # Named spot-check: the T37a-f roster (ADR-040 §5.9) resources demo actually
      # mounts (billing/cms/crm/marketing/primitives/support — chat is
      # samen_web/driftwood-only, proven in the samen_web suite).
      for resource <- [
            Demo.BillingScope.Plan,
            Demo.BillingScope.Price,
            Demo.CmsScope.Page,
            Demo.CmsScope.Post,
            Demo.CmsScope.Block,
            Demo.CmsScope.Media,
            Demo.CmsScope.Navigation,
            Demo.CmsScope.SeoMeta,
            Demo.CrmScope.Company,
            Demo.CrmScope.Person,
            Demo.CrmScope.Pipeline,
            Demo.CrmScope.Opportunity,
            Demo.CrmScope.Attachment,
            Demo.MarketingScope.Campaign,
            Demo.MarketingScope.Segment,
            Demo.MarketingScope.Template,
            Demo.MarketingScope.Subscriber,
            Demo.PrimitivesScope.File,
            Demo.PrimitivesScope.Webhook,
            Demo.PrimitivesScope.FeatureFlag,
            Demo.SupportScope.Ticket,
            Demo.SupportScope.Agent,
            Demo.SupportScope.Sla,
            Demo.SupportScope.Macro
          ] do
        assert MapSet.member?(spec_resources, resource), "#{inspect(resource)} missing a retention spec"
      end

      # Exclusion-class sanity (ADR-040 §5.9): a known EXCLUDED resource never gets a
      # spec from this walk — proves the filter is `archivable?/1`, not "everything".
      refute MapSet.member?(spec_resources, Demo.BillingScope.Customer)
      refute MapSet.member?(spec_resources, Demo.MarketingScope.EmailEvent)
    end
  end

  describe "end-to-end sweep on a REAL adopted resource — CRM Company (§5.6)" do
    test "archived Company past its window is truly purged; one within the window is retained; report is accurate" do
      org = Ash.UUID.generate()
      stale = mk_company(org, "stale")
      fresh = mk_company(org, "fresh")

      {:ok, _} = Samen.Archival.archive(stale, authorize?: false)
      {:ok, _} = Samen.Archival.archive(fresh, authorize?: false)

      backdate!("cmp_company", "cmp_id", "cmp_archived_at", stale.id, 400, @now)

      spec = %Spec{
        resource: Company,
        ttl_seconds: 365 * 24 * 60 * 60,
        action: :delete,
        timestamp_field: :archived_at
      }

      report = Retention.sweep([spec], now: @now)

      assert report.swept == 1
      assert report.archived == 1
      assert [%{resource: Company, action: :delete, swept: 1, archived: 1}] = report.by_spec

      # Truly gone — not merely hidden by the default filter, not re-archived.
      %{rows: [[n]]} =
        Repo.query!("SELECT count(*) FROM cmp_company WHERE cmp_id = $1", [Ecto.UUID.dump!(stale.id)])

      assert n == 0

      # The in-TTL row is retained — still visible via the :archived (trash) read.
      archived_ids =
        Company |> Ash.Query.for_read(:archived) |> Ash.read!(authorize?: false) |> Enum.map(& &1.id)

      assert fresh.id in archived_ids
      refute stale.id in archived_ids
    end
  end
end
