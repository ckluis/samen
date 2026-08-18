defmodule Demo.MarketingScopeArchivalLeakRedPathTest do
  @moduledoc """
  E6 soft-delete adoption for the Marketing scope (ADR-040 §5.9, T37d):
  `Campaign`, `Segment`, `Subscriber` 🔒, and `Template` flip `archivable true`
  (samen_core/lib/samen/scopes/marketing/blueprint.ex). `Send`, `EmailEvent`,
  `Suppression`, and `ConsentEvent` are NOT adopted — all four are excluded per
  the §5.9 roster (send/email_event/consent_event are (L) append-only ledgers;
  `suppression`'s exclusion is absolute: "a hidden suppression row is a
  compliance leak").

  §5.3: no unique index exists on `mca_campaign`/`msg_segment`/`msu_subscriber`/
  `mtp_template` — the partial-index conversion has nothing to convert for this
  scope (confirmed by the c1 round trip below never constructing a
  `:restore_conflict` case; see `_orch/tasks/T37d/handoff.md`).

  §5.4: no cascade is declared for Marketing — archiving Campaign/Segment/
  Subscriber/Template leaves `Send`/`EmailEvent`/`Suppression` rows untouched
  (none of those three is itself archivable, so cascade could not apply to
  them regardless).

  §5.5's standing duty for every adopting scope: an archived record must not
  leak via relationship load or aggregate, bypassing the read preparation.
  `Send` carries `belongs_to :subscriber/:campaign/:template` — three
  independent consumers, each proven separately below. `Segment` carries no
  incoming relationship in the current schema (nothing references a segment by
  FK), so the relationship/aggregate leak class does not structurally apply to
  it; its own default-read exclusion is fully covered by the c1 round trip.
  Every RED here (archived does not surface) is paired with a distinct
  positive-control CONTROL (a live row DOES surface via the same path) so the
  RED assertion is provably falsifiable, not a tautology (house masking-watch-
  list discipline, CLAUDE.md).

  §5.9 footnote ‡ (binding, this scope's unique compliance duty): archiving a
  `subscriber` must NEVER touch suppression state. Suppression is enforced at
  the C2 delivery chokepoint (`Samen.Delivery.Chokepoint.suppressed?/2`, backed
  by the kernel `dlv_suppression` store via `Samen.Delivery.SuppressionCheck`)
  — a plain Ecto schema with NO relationship to the Ash `Subscriber` resource,
  so archive/restore cannot reach it by construction. Proven behaviorally
  below, paired with a non-suppressed archived-subscriber positive control so
  the RED assertion is not vacuously true.

  INV-1: an archived Subscriber (the scope's only 🔒 resource) keeps its vault
  token and still masks on every plane exactly like a live row — proven on the
  REAL Marketing `Subscriber` resource (T36 c3 kernel-pilot precedent, T37a/
  T37c per-scope precedent).
  """
  use Demo.DataCase, async: false

  require Ash.Query

  import Samen.MaskingCase,
    only: [resolve_on_plane: 4, assert_plane_masked!: 1, assert_leak_detected!: 2]

  alias Demo.MarketingScope.{Campaign, Segment, Send, Subscriber, Suppression, Template}
  alias Samen.Delivery.Chokepoint
  alias Samen.Delivery.Suppression, as: DlvSuppression
  alias Samen.Delivery.SuppressionCheck

  # No-grant vault stub: even wired to a vault, the operator-without-grant plane must
  # mask. Proves the mask is the plane/grant gate, independent of decrypt availability.
  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp mk_org, do: Ash.UUID.generate()

  defp mk_campaign(org_id, name \\ "Campaign") do
    {:ok, c} =
      Campaign
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "#{name}-#{:rand.uniform(999_999)}"})
      |> Ash.create(authorize?: false)

    c
  end

  defp mk_segment(org_id, name \\ "Segment") do
    {:ok, s} =
      Segment
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "#{name}-#{:rand.uniform(999_999)}"})
      |> Ash.create(authorize?: false)

    s
  end

  defp mk_template(org_id, name \\ "Template") do
    {:ok, t} =
      Template
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        name: "#{name}-#{:rand.uniform(999_999)}",
        subject_line: "Hello"
      })
      |> Ash.create(authorize?: false)

    t
  end

  defp mk_subscriber(org_id, email \\ nil) do
    email = email || "sub#{:rand.uniform(999_999)}@t37d.example"

    {:ok, s} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, email: email, status: :active})
      |> Ash.create(authorize?: false)

    s
  end

  defp mk_send(org_id, attrs) do
    {:ok, s} =
      Send
      |> Ash.Changeset.for_create(:create_checked, Map.put(attrs, :org_id, org_id))
      |> Ash.create(authorize?: false)

    s
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

  # ── introspection: the adopt-me convention landed on the right rows only ───

  describe "introspection — Samen.Info.archivable?/1 (T37h catalog-probe fixture)" do
    test "campaign/segment/subscriber/template all report true" do
      assert Samen.Info.archivable?(Campaign)
      assert Samen.Info.archivable?(Segment)
      assert Samen.Info.archivable?(Subscriber)
      assert Samen.Info.archivable?(Template)
    end

    test "send/email_event/suppression/consent_event all report false — suppression's exclusion is absolute" do
      refute Samen.Info.archivable?(Send)
      refute Samen.Info.archivable?(Suppression)
      refute Samen.Info.archivable?(Demo.MarketingScope.EmailEvent)
      refute Samen.Info.archivable?(Demo.MarketingScope.ConsentEvent)
    end
  end

  # ── c1: archive/restore round trip for every roster resource ───────────────

  describe "c1 — archive removes from default read (RED), :archived shows it (CONTROL), restore returns it (ASSERT)" do
    test "for campaign, segment, subscriber, and template" do
      org = mk_org()
      campaign = mk_campaign(org)
      segment = mk_segment(org)
      subscriber = mk_subscriber(org)
      template = mk_template(org)

      for {resource, record} <- [
            {Campaign, campaign},
            {Segment, segment},
            {Subscriber, subscriber},
            {Template, template}
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

  # ── §5.5 leak duty: relationship load — Send.subscriber ────────────────────

  describe "§5.5 — an archived Subscriber does not leak via Send.subscriber relationship load" do
    test "Send.subscriber resolves to nil for an archived subscriber (RED); a live subscriber surfaces (CONTROL)" do
      org = mk_org()
      archived_sub = mk_subscriber(org, "archived-sub@t37d.example")
      live_sub = mk_subscriber(org, "live-sub@t37d.example")

      send_on_archived = mk_send(org, %{subscriber_id: archived_sub.id})
      send_on_live = mk_send(org, %{subscriber_id: live_sub.id})

      {:ok, _} = Samen.Archival.archive(archived_sub, authorize?: false)

      loaded_on_archived = Ash.load!(send_on_archived, :subscriber, authorize?: false)
      assert loaded_on_archived.subscriber == nil

      # CONTROL (anti-tautology): the same relationship load path DOES surface a
      # live subscriber — proves the nil above is the archival filter firing.
      loaded_on_live = Ash.load!(send_on_live, :subscriber, authorize?: false)
      assert %Subscriber{id: live_id} = loaded_on_live.subscriber
      assert live_id == live_sub.id
    end
  end

  # ── §5.5 leak duty: relationship load — Send.campaign ───────────────────────

  describe "§5.5 — an archived Campaign does not leak via Send.campaign relationship load" do
    test "Send.campaign resolves to nil for an archived campaign (RED); a live campaign surfaces (CONTROL)" do
      org = mk_org()
      archived_camp = mk_campaign(org, "Archived")
      live_camp = mk_campaign(org, "Live")
      subscriber = mk_subscriber(org)

      send_on_archived = mk_send(org, %{subscriber_id: subscriber.id, campaign_id: archived_camp.id})
      send_on_live = mk_send(org, %{subscriber_id: subscriber.id, campaign_id: live_camp.id})

      {:ok, _} = Samen.Archival.archive(archived_camp, authorize?: false)

      loaded_on_archived = Ash.load!(send_on_archived, :campaign, authorize?: false)
      assert loaded_on_archived.campaign == nil

      # CONTROL: a second independent belongs_to consumer (Send -> Campaign) is
      # ALSO filtered — proves the preparation is resource-level, not wired for
      # Subscriber only.
      loaded_on_live = Ash.load!(send_on_live, :campaign, authorize?: false)
      assert %Campaign{id: live_id} = loaded_on_live.campaign
      assert live_id == live_camp.id
    end
  end

  # ── §5.5 leak duty: relationship load — Send.template ───────────────────────

  describe "§5.5 — an archived Template does not leak via Send.template relationship load" do
    test "Send.template resolves to nil for an archived template (RED); a live template surfaces (CONTROL)" do
      org = mk_org()
      archived_tpl = mk_template(org, "Archived")
      live_tpl = mk_template(org, "Live")
      subscriber = mk_subscriber(org)

      send_on_archived = mk_send(org, %{subscriber_id: subscriber.id, template_id: archived_tpl.id})
      send_on_live = mk_send(org, %{subscriber_id: subscriber.id, template_id: live_tpl.id})

      {:ok, _} = Samen.Archival.archive(archived_tpl, authorize?: false)

      loaded_on_archived = Ash.load!(send_on_archived, :template, authorize?: false)
      assert loaded_on_archived.template == nil

      # CONTROL: a third independent belongs_to consumer (Send -> Template).
      loaded_on_live = Ash.load!(send_on_live, :template, authorize?: false)
      assert %Template{id: live_id} = loaded_on_live.template
      assert live_id == live_tpl.id
    end
  end

  # ── §5.5 leak duty: aggregate — Send :exists on :subscriber ─────────────────

  describe "§5.5 — an archived Subscriber does not leak via an :exists aggregate" do
    test "the :exists aggregate over Send.subscriber is false for an archived subscriber (RED); true for a live one (CONTROL)" do
      org = mk_org()
      archived_sub = mk_subscriber(org, "agg-archived@t37d.example")
      live_sub = mk_subscriber(org, "agg-live@t37d.example")

      send_on_archived = mk_send(org, %{subscriber_id: archived_sub.id})
      send_on_live = mk_send(org, %{subscriber_id: live_sub.id})

      {:ok, _} = Samen.Archival.archive(archived_sub, authorize?: false)

      archived_result =
        Send
        |> Ash.Query.filter(id == ^send_on_archived.id)
        |> Ash.Query.aggregate(:subscriber_live?, :exists, :subscriber)
        |> Ash.read_one!(authorize?: false)

      refute archived_result.aggregates.subscriber_live?

      # CONTROL (anti-tautology): the identical aggregate over a send pointing
      # at a LIVE subscriber reports true — proves `false` above is the
      # archival filter firing, not the aggregate being vacuously false.
      live_result =
        Send
        |> Ash.Query.filter(id == ^send_on_live.id)
        |> Ash.Query.aggregate(:subscriber_live?, :exists, :subscriber)
        |> Ash.read_one!(authorize?: false)

      assert live_result.aggregates.subscriber_live?
    end
  end

  # ── §5.4: no cascade — archiving a subscriber leaves send/email_event/suppression live ─

  describe "§5.4 — Marketing declares no cascades: archiving a subscriber does not touch its non-archivable consumers" do
    test "Send/Suppression rows referencing an archived subscriber stay in their own default reads" do
      org = mk_org()
      subscriber = mk_subscriber(org, "cascade@t37d.example")
      send = mk_send(org, %{subscriber_id: subscriber.id})

      {:ok, sup} =
        Suppression
        |> Ash.Changeset.for_create(:create, %{
          org_id: org,
          subscriber_id: subscriber.id,
          reason: :admin_added
        })
        |> Ash.create(authorize?: false)

      {:ok, _} = Samen.Archival.archive(subscriber, authorize?: false)

      # Neither Send nor Suppression is itself archivable — no cascade declared
      # for Marketing (§5.4) means these rows are simply never touched.
      assert MapSet.member?(live_ids(Send, org), send.id)
      assert MapSet.member?(live_ids(Suppression, org), sup.id)
    end
  end

  # ── §5.9 footnote ‡ — the suppression-unaffected-by-subscriber-archive duty (binding) ─

  describe "§5.9 footnote ‡ — archiving/restoring a subscriber never touches C2 delivery-chokepoint suppression state" do
    setup do
      prev_chokepoint = Application.get_env(:samen_core, Chokepoint)
      prev_check = Application.get_env(:samen_core, SuppressionCheck)

      Application.put_env(:samen_core, Chokepoint, suppression_module: SuppressionCheck)
      Application.put_env(:samen_core, SuppressionCheck, repo: Repo)

      on_exit(fn ->
        if prev_chokepoint,
          do: Application.put_env(:samen_core, Chokepoint, prev_chokepoint),
          else: Application.delete_env(:samen_core, Chokepoint)

        if prev_check,
          do: Application.put_env(:samen_core, SuppressionCheck, prev_check),
          else: Application.delete_env(:samen_core, SuppressionCheck)
      end)

      :ok
    end

    defp dlv_suppression_row_count(org_id, subscriber_id) do
      %{rows: [[count]]} =
        Repo.query!(
          "SELECT count(*) FROM dlv_suppression WHERE dlv_org_id = $1 AND dlv_subscriber_id = $2",
          [Ecto.UUID.dump!(org_id), Ecto.UUID.dump!(subscriber_id)]
        )

      count
    end

    test "a suppressed subscriber stays suppressed through archive AND restore (RED); a non-suppressed subscriber's own state is unaffected either way (CONTROL)" do
      org = mk_org()
      suppressed_sub = mk_subscriber(org, "chokepoint-suppressed@t37d.example")
      control_sub = mk_subscriber(org, "chokepoint-control@t37d.example")

      # Suppress ONLY `suppressed_sub` at the C2 kernel store (dlv_suppression) —
      # a plain Ecto schema with no relationship to the Ash Subscriber resource.
      {:ok, _} =
        DlvSuppression.suppress(Repo, %{
          org_id: org,
          subscriber_id: suppressed_sub.id,
          reason: "manual"
        })

      # Sanity, before any archival: the chokepoint distinguishes the two.
      assert Chokepoint.suppressed?(org, suppressed_sub.id)
      refute Chokepoint.suppressed?(org, control_sub.id)
      assert dlv_suppression_row_count(org, suppressed_sub.id) == 1
      assert dlv_suppression_row_count(org, control_sub.id) == 0

      {:ok, archived_suppressed} = Samen.Archival.archive(suppressed_sub, authorize?: false)
      {:ok, archived_control} = Samen.Archival.archive(control_sub, authorize?: false)

      # RED: archiving does NOT un-suppress — the chokepoint still refuses.
      assert Chokepoint.suppressed?(org, suppressed_sub.id),
             "archiving a subscriber must never lift their suppression"

      # CONTROL: archiving a NON-suppressed subscriber does not spuriously
      # suppress them either — proves the RED above is not just "always true".
      refute Chokepoint.suppressed?(org, control_sub.id)

      # Direct DB proof: archive wrote NOTHING to dlv_suppression in either
      # direction (no new row for the control, no row removed for the suppressed one).
      assert dlv_suppression_row_count(org, suppressed_sub.id) == 1
      assert dlv_suppression_row_count(org, control_sub.id) == 0

      restored_suppressed =
        archived_record(Subscriber, archived_suppressed.id) || archived_suppressed

      restored_control = archived_record(Subscriber, archived_control.id) || archived_control

      {:ok, _} = Samen.Archival.restore(restored_suppressed, authorize?: false)
      {:ok, _} = Samen.Archival.restore(restored_control, authorize?: false)

      # RED (the reverse direction, §5.9 footnote's "un-archiving doesn't
      # re-subscribe"): restoring the subscriber does NOT lift the
      # suppression either.
      assert Chokepoint.suppressed?(org, suppressed_sub.id),
             "restoring a subscriber must never lift their suppression"

      # CONTROL: restore does not spuriously suppress the control subscriber.
      refute Chokepoint.suppressed?(org, control_sub.id)

      assert dlv_suppression_row_count(org, suppressed_sub.id) == 1
      assert dlv_suppression_row_count(org, control_sub.id) == 0
    end
  end

  # ── INV-1: masking holds on an archived vaulted Subscriber, restore never leaks ─

  describe "INV-1 — an archived Subscriber still masks per plane, restore never leaks" do
    test "archived Subscriber keeps its vault token at rest and masks on the operator plane (RED) / clears on tenant (CONTROL)" do
      org = mk_org()
      plaintext = "ada.subscriber@t37d.example"

      subscriber = mk_subscriber(org, plaintext)
      {:ok, _} = Samen.Archival.archive(subscriber, authorize?: false)

      archived =
        Subscriber
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.ensure_selected([:email])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == subscriber.id))

      # INV-1 at rest: the vault column holds a vt_* token even while archived —
      # the archived row is trash, not erasure; tokens stay vaulted (§5.1).
      %{rows: [[stored]]} =
        Repo.query!("SELECT pii_msu_email FROM msu_subscriber WHERE msu_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      # RED (INV-1): operator plane WITHOUT a grant resolves the archived row's
      # field to %Masked{} — never plaintext, never the vt_ token, on any egress.
      masked = resolve_on_plane(archived, Subscriber, :operator, grant: DenyAll).email
      assert_plane_masked!(masked)
      assert to_string(masked) == "••••"
      refute to_string(masked) =~ "vt_"
      refute to_string(masked) =~ plaintext

      # SABOTAGE twin / anti-tautology: the substring scan the RED relies on IS
      # refutable — a modeled plaintext render is detected.
      assert_leak_detected!("<td>#{plaintext}</td>", plaintext)

      # Restore does not leak: an operator (no-grant) read of the restored row
      # still masks.
      {:ok, _} = Samen.Archival.restore(archived, authorize?: false)

      live =
        Subscriber
        |> Ash.Query.ensure_selected([:email])
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.id == subscriber.id))

      assert_plane_masked!(resolve_on_plane(live, Subscriber, :operator, grant: DenyAll).email)
    end
  end
end
