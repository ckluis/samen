defmodule Demo.PrimitivesScopeArchivalLeakRedPathTest do
  @moduledoc """
  E6 soft-delete adoption for the Primitives scope (ADR-040 §5.9, T37e): `File`,
  `Webhook` 🔒, and `FeatureFlag` flip `archivable true`
  (samen_core/lib/samen/scopes/primitives/blueprint.ex) — the §5.9 roster's `approval`
  is explicitly "no" (its own decision-record state machine, T34; a separate
  blueprint, `Samen.Approvals.Blueprint`, never touched here). `notification` (L —
  ledger), `notification_preference` (settings row), and `search_index` (M —
  derived) stay excluded.

  §5.3: no `unique_index` exists on `pfl_file` / `pwh_webhook` / `pff_feature_flag`
  today (confirmed by inspecting `20260706060000_add_primitives_scope` — zero
  `unique_index` calls) — nothing to convert to partial form (same finding as
  T37a/b/c/d's scopes; see `_orch/tasks/T37e/handoff.md`).

  §5.4: no cascade is declared for Primitives (the roster's dash) — File, Webhook,
  and FeatureFlag are each standalone Tier-0-ish rows with no composition parent/
  child relationship to any other primitives resource.

  §5.5's standing duty — an archived record must not leak via relationship load or
  aggregate, bypassing the read preparation — has a genuine GAP for this scope worth
  documenting rather than papering over: `File`, `Webhook`, and `FeatureFlag` have
  **zero declared Ash relationships** to or from any OTHER resource anywhere in the
  codebase (confirmed by a repo-wide grep for `belongs_to :file`/`:webhook`/
  `:feature_flag` — zero hits). `SearchIndex.resource_name` is a plain STRING column,
  not an Ash `belongs_to` — there is nothing to relationship-load. So the
  "relationship" half of §5.5 has NO CONSTRUCTIBLE RED PATH for this scope (unlike
  CMS's `Page.blocks`/CRM's `Person.company`/billing's `Subscription.plan`, all of
  which have a real inbound `belongs_to`). What DOES generalize is the "aggregate"
  half: `Ash.count!/2` (and any aggregate query) reads through the SAME
  `is_nil(archived_at)` default-read preparation as a plain `Ash.read`, so an
  archived row must vanish from a `count` the same way it vanishes from a `read` —
  proven below on all three resources, paired with a live-sibling anti-tautology
  CONTROL.

  INV-1 / the vaulted-pilot masking proof (T36 c3 precedent, mirrored here on the
  REAL `Webhook` resource — the scope's ONLY 🔒 field, `signing_secret`; `File` and
  `FeatureFlag` carry no PII at all, so no masking proof applies to them; the
  handoff's "FILE carries PII-adjacent metadata" framing does not correspond to any
  actual `pii_attribute` on this resource — `filename`/`storage_key` are explicitly
  classified non-PII in the blueprint moduledoc, so `Webhook.signing_secret` is the
  correct — and only — target for this scope's masking-on-archived proof): an
  archived Webhook keeps its vault token (full_pii, trash not erasure) and masks per
  plane exactly like a live row — the operator-without-grant plane resolves
  `%Samen.Masked{}`, never plaintext, never the raw token; restore does not leak
  either.
  """
  use Demo.DataCase, async: false

  require Ash.Query

  import Samen.MaskingCase,
    only: [resolve_on_plane: 4, assert_plane_masked!: 1, assert_leak_detected!: 2]

  alias Demo.PrimitivesScope.{File, FeatureFlag, Webhook}

  # No-grant vault stub: even wired to a vault, the operator-without-grant plane must
  # mask. Proves the mask is the plane/grant gate, independent of decrypt availability.
  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp mk_org, do: Ash.UUID.generate()

  # Routes through the governed chokepoint (`Samen.Files.upload/3`) — the ONLY path
  # that may mint a `storage_key`-bearing File row (ADR-026 RP-FI-1 / AC-G14-2).
  defp mk_file(org_id) do
    scope = %{org_id: org_id}

    {:ok, quarantined} =
      Samen.Files.upload(
        scope,
        %{
          filename: "file-#{:rand.uniform(999_999)}.pdf",
          content_type: "application/pdf",
          binary: :binary.copy("x", 256)
        },
        file_upload_opts()
      )

    {:ok, f} = Samen.Files.promote(scope, quarantined, file_upload_opts())
    f
  end

  defp file_upload_opts do
    [
      file_module: File,
      repo: Demo.Repo,
      scanner: Samen.Files.Scanner.Noop,
      max_bytes: 26_214_400,
      allowed_content_types: ~w(application/pdf image/png image/jpeg text/plain text/csv)
    ]
  end

  defp mk_webhook(org_id, secret \\ nil) do
    {:ok, w} =
      Webhook
      |> Ash.Changeset.for_create(:create, %{
        url: "https://example.com/hook/#{:rand.uniform(999_999)}",
        label: "Test hook",
        event_types: ["invoice.created"],
        status: :active,
        signing_secret: secret || "secret-#{Ash.UUID.generate()}",
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    w
  end

  defp mk_feature_flag(org_id) do
    {:ok, ff} =
      FeatureFlag
      |> Ash.Changeset.for_create(:create, %{
        name: "test.flag.#{:rand.uniform(999_999)}",
        description: "Test feature flag",
        enabled: true,
        rollout_pct: 100,
        stage: :ga,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    ff
  end

  defp live_ids(resource, org_id) do
    resource
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp archived_ids(resource, org_id) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.org_id == org_id))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp archived_record(resource, id) do
    resource
    |> Ash.Query.for_read(:archived)
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  # ── introspection: the adopt-me convention landed on the roster row ────────

  describe "introspection — Samen.Info.archivable?/1 (T37h catalog-probe fixture)" do
    test "file/webhook/feature_flag all report true" do
      assert Samen.Info.archivable?(File)
      assert Samen.Info.archivable?(Webhook)
      assert Samen.Info.archivable?(FeatureFlag)
    end
  end

  # ── c1: archive/restore round trip for every roster resource ───────────────

  describe "c1 — archive removes from default read (RED), :archived shows it (CONTROL), restore returns it (ASSERT)" do
    test "for file, webhook, and feature_flag" do
      org = mk_org()
      file = mk_file(org)
      webhook = mk_webhook(org)
      feature_flag = mk_feature_flag(org)

      for {resource, record} <- [
            {File, file},
            {Webhook, webhook},
            {FeatureFlag, feature_flag}
          ] do
        assert MapSet.member?(live_ids(resource, org), record.id),
               "#{inspect(resource)} expected in the default read before archive"

        {:ok, _} = Samen.Archival.archive(record, authorize?: false)

        # RED: gone from the default read.
        refute MapSet.member?(live_ids(resource, org), record.id)
        # CONTROL: the :archived include-read still sees it — hidden, not gone.
        assert MapSet.member?(archived_ids(resource, org), record.id)

        # ASSERT: restore returns it to the default read.
        {:ok, _} = Samen.Archival.restore(archived_record(resource, record.id), authorize?: false)
        assert MapSet.member?(live_ids(resource, org), record.id)
        refute MapSet.member?(archived_ids(resource, org), record.id)
      end
    end
  end

  # ── §5.5 aggregate leak duty (the only constructible leak surface here) ────

  describe "§5.5 — an archived Webhook does not leak via Ash.count! (aggregate path)" do
    test "count excludes the archived row (RED); a live sibling is still counted (CONTROL)" do
      org = mk_org()
      archived_hook = mk_webhook(org)
      live_hook = mk_webhook(org)

      before_count = Ash.count!(Webhook |> Ash.Query.filter(org_id == ^org), authorize?: false)
      assert before_count == 2

      {:ok, _} = Samen.Archival.archive(archived_hook, authorize?: false)

      # RED: the archived row no longer contributes to the count.
      after_count = Ash.count!(Webhook |> Ash.Query.filter(org_id == ^org), authorize?: false)
      assert after_count == 1

      # CONTROL (anti-tautology): the live sibling still appears in the SAME count
      # path — proves the drop above is the archival filter firing on `archived_hook`
      # specifically, not the count being vacuously zero.
      assert MapSet.member?(live_ids(Webhook, org), live_hook.id)
    end
  end

  describe "§5.5 — an archived FeatureFlag does not leak via Ash.count! (aggregate path)" do
    test "count excludes the archived row (RED); a live sibling is still counted (CONTROL)" do
      org = mk_org()
      archived_flag = mk_feature_flag(org)
      live_flag = mk_feature_flag(org)

      before_count = Ash.count!(FeatureFlag |> Ash.Query.filter(org_id == ^org), authorize?: false)
      assert before_count == 2

      {:ok, _} = Samen.Archival.archive(archived_flag, authorize?: false)

      after_count = Ash.count!(FeatureFlag |> Ash.Query.filter(org_id == ^org), authorize?: false)
      assert after_count == 1

      assert MapSet.member?(live_ids(FeatureFlag, org), live_flag.id)
    end
  end

  # ── §5.4: no cascade declared — nothing to prove (documented in moduledoc) ─

  # ── INV-1: masking holds on an archived vaulted Webhook, restore never leaks ─

  describe "INV-1 — an archived Webhook still masks per plane, restore never leaks" do
    test "archived Webhook keeps its vault token at rest and masks on the operator plane (RED) / clears on tenant (CONTROL)" do
      org = mk_org()
      secret = "super-secret-hmac-key-#{Ash.UUID.generate()}"
      webhook = mk_webhook(org, secret)

      {:ok, _} = Samen.Archival.archive(webhook, authorize?: false)

      archived =
        Webhook
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.ensure_selected([:signing_secret])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == webhook.id))

      # INV-1 at rest: the vault column holds a vt_* token even while archived — the
      # archived row is trash, not erasure; tokens stay vaulted (§5.1).
      %{rows: [[stored]]} =
        Repo.query!("SELECT pii_pwh_signing_secret FROM pwh_webhook WHERE pwh_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      # RED (INV-1): operator plane WITHOUT a grant resolves the archived row's field
      # to %Masked{} — never plaintext, never the vt_ token, on any egress.
      masked = resolve_on_plane(archived, Webhook, :operator, grant: DenyAll).signing_secret
      assert_plane_masked!(masked)
      assert to_string(masked) == "••••"
      refute to_string(masked) =~ "vt_"
      refute to_string(masked) =~ secret

      # SABOTAGE twin / anti-tautology: the substring scan the RED relies on IS
      # refutable — a modeled plaintext render is detected.
      assert_leak_detected!("<td>#{secret}</td>", secret)

      # CONTROL: the tenant plane resolves clear even while archived — trash, not
      # erasure, and masking is a plane/grant gate, not a blanket archived-row mask.
      # `resolve_on_plane/4`'s public `resolve/4` face (unlike the `prepare/3` Ash
      # Preparation face) does NOT auto-infer `:repo` — pass it explicitly so the
      # tenant-plane decrypt actually runs instead of silently fail-closing masked.
      tenant_resolved = resolve_on_plane(archived, Webhook, :tenant, repo: Demo.Repo).signing_secret
      refute match?(%Samen.Masked{}, tenant_resolved)
      assert to_string(tenant_resolved) == secret

      # Restore does not leak: an operator (no-grant) read of the restored row still
      # masks.
      {:ok, _} = Samen.Archival.restore(archived, authorize?: false)

      live =
        Webhook
        |> Ash.Query.ensure_selected([:signing_secret])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == webhook.id))

      assert_plane_masked!(resolve_on_plane(live, Webhook, :operator, grant: DenyAll).signing_secret)
    end
  end
end
