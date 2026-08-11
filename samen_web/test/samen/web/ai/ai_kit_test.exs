defmodule Samen.Web.AI.KitTest do
  @moduledoc """
  T155 — the tenant-plane AI UI kit: all five surfaces render tenant-scoped, SIMULATED vs
  live is signposted from the T152 `%Completion{}.simulated` flag, `:not_configured` renders
  `Samen.AI.configuration_hint/0` VERBATIM (never a fake-confident answer), the analytics
  ask-box honestly refuses a tenant plane (T144 token-blind gate), search shows the T152 Hit
  snippet with no `vt_*`/plaintext leak, and the org-scoped reads the kit owns
  (`crm_preview/4`, `list_drafts/2`) never cross orgs.
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.LiveViewTest

  alias Samen.Web.AI.Components
  alias Samen.Web.AI.Server
  alias Samen.Web.Mount
  alias Samen.WebTest.Seeds

  setup do
    %{org_id: org_id, crm: crm} = Seeds.seed_all()
    %{org_id: org_id, person: crm.person}
  end

  defp ai_mount(org_id, plane, extra_labels \\ %{}) do
    plane_struct =
      case plane do
        :tenant -> Samen.Web.Plane.tenant()
        :operator -> Samen.Web.Plane.operator("op-1", org_id, "test-session")
      end

    labels = Map.merge(%{ai_crm_resource: Samen.WebTest.Crm.Person}, extra_labels)
    Mount.new(:ai, Samen.WebTest.Crm, Samen.WebTest.Repo, plane: plane_struct, labels: labels)
  end

  # --- All five surfaces render tenant-scoped -----------------------------------------------

  test "all five AI surfaces render tenant-scoped", %{org_id: org_id} do
    mount = ai_mount(org_id, :tenant, %{ai_aggregate_resource: Samen.WebTest.Crm.Company})

    assert render_live(Samen.Web.AI.VerbsLive, mount, [org_id]) =~ "AI · Verbs"
    assert render_live(Samen.Web.AI.SearchLive, mount, [org_id]) =~ "AI · Semantic search"
    assert render_live(Samen.Web.AI.CrmLive, mount, [org_id]) =~ "AI · CRM"
    assert render_live(Samen.Web.AI.AnalyticsLive, mount, [org_id]) =~ "AI · Analytics"
    assert render_live(Samen.Web.AI.SupportDraftLive, mount, [org_id]) =~ "AI · Support draft"
  end

  # --- SIMULATED signposting (the load-bearing honesty; T152 flag) --------------------------

  test "the verbs surface signposts a keyless result as SIMULATED (not real)", %{org_id: org_id} do
    mount = ai_mount(org_id, :tenant)

    html =
      render_live(Samen.Web.AI.VerbsLive, mount, [
        org_id,
        [verb: :summarize, input: "Summarize this account.", run: true]
      ])

    assert html =~ "SIMULATED"
    assert html =~ ~s(data-simulated="true")
    refute html =~ ~s(data-simulated="false")
  end

  test "ai_result renders a live (non-simulated) completion with a Live badge, never SIMULATED" do
    completion = %Samen.AI.Completion{text: "A real answer.", simulated: false, model: "m-1"}
    html = render_component(&Components.ai_result/1, %{result: {:ok, completion}, id: "r"})

    assert html =~ "Live model"
    assert html =~ ~s(data-simulated="false")
    refute html =~ "SIMULATED"
  end

  # --- H5: a SIMULATED draft MUST carry the loud badge (no badgeless simulated path) --------

  test "ai_result renders a SIMULATED draft_sequence result with the loud SIMULATED badge (H5)" do
    # `Samen.AI.Crm.draft_sequence/5` preserves the T152 `:simulated` flag through its
    # plain-map conversion — a keyless draft (`simulated: true`) MUST render the loud
    # "SIMULATED — not a real model" badge, never a neutral "Draft" pill (the T155-missed
    # honesty hole where simulated output was laundered as an ordinary draft).
    result = {:ok, %{status: :draft, body: "Hi Dana — checking in on the Chicago lane.", simulated: true}}
    html = render_component(&Components.ai_result/1, %{result: result, id: "r"})

    assert html =~ "SIMULATED — not a real model"
    assert html =~ ~s(data-simulated="true")
    assert html =~ "Chicago lane"
  end

  test "ai_result renders a NON-simulated draft as a neutral Draft, never SIMULATED (H5 positive control)" do
    # The anti-tautology twin: a genuine (non-simulated) draft is the neutral "Draft" pill
    # and carries NO SIMULATED badge — proving the badge above is driven by the flag, not
    # unconditionally stamped on every draft.
    result = {:ok, %{status: :draft, body: "A real-model draft.", simulated: false}}
    html = render_component(&Components.ai_result/1, %{result: result, id: "r"})

    assert html =~ "Draft"
    refute html =~ "SIMULATED"
  end

  # --- :not_configured renders the configuration_hint VERBATIM, never a fake answer ---------

  test "ai_result on :not_configured renders configuration_hint VERBATIM, no fabricated answer" do
    html = render_component(&Components.ai_result/1, %{result: {:error, :not_configured}, id: "r"})

    # The hint text, verbatim (the provider-config path), and NOT presented as an answer.
    assert html =~ "No AI provider is wired"
    assert html =~ "config :samen_core, Samen.AI"
    assert html =~ "this is not an answer"
    # It must render the EXACT hint string the kernel exposes.
    assert html =~ String.slice(Server.configuration_hint(), 0, 60)
    refute html =~ ~s(data-simulated=)
  end

  test "the machine error stays the bare :not_configured atom (contract unchanged)" do
    # env forced to :prod → unwired provider is fail-honest, not the keyless Fake.
    assert {:error, :not_configured} =
             Samen.AI.Verbs.run(:summarize, %Samen.Scope{actor: %{org_id: "x"}}, "hi",
               env_reader: fn -> :prod end
             )
  end

  # --- Analytics ask-box: honest refusal on the tenant plane (T144), never fabricated -------

  test "the analytics ask-box honestly refuses a tenant-plane caller (no fabricated aggregate)",
       %{org_id: org_id} do
    mount = ai_mount(org_id, :tenant, %{ai_aggregate_resource: Samen.WebTest.Crm.Company})

    html =
      render_live(Samen.Web.AI.AnalyticsLive, mount, [
        org_id,
        [question: "what is total MRR?", run: true]
      ])

    assert html =~ "Requires platform/operator authority"
    assert html =~ ~s(data-state="unauthorized")
  end

  # --- Semantic search: T152 Hit snippet renders, simulated ranking badge, no leak ----------

  test "semantic search renders the T152 Hit snippet + a SIMULATED ranking badge, no vt_ leak",
       %{org_id: org_id} do
    mount = ai_mount(org_id, :tenant)
    scope = Mount.scope(mount, org_id)

    # Seed one org-scoped embedding through the governed kernel unit (a declared-embeddable,
    # non-vault field — Post.title). The snippet is masking-safe by construction.
    {:ok, _} =
      Samen.AI.Embeddings.embed_field(
        scope,
        Samen.WebTest.Cms.Post,
        "post-1",
        :title,
        "freight logistics rate quote",
        org_id: org_id,
        repo: Samen.WebTest.Repo
      )

    html = render_live(Samen.Web.AI.SearchLive, mount, [org_id, [q: "freight quote"]])

    assert html =~ "freight logistics rate quote"
    assert html =~ "SIMULATED ranking"
    refute html =~ "vt_"
  end

  # --- Org-scope pins on the kit's own reads (drop-filter-flips-this-test) -------------------

  test "crm_preview is org-scoped: another org's record is not found", %{person: person} do
    other_org = Ash.UUID.generate()
    mount = ai_mount(other_org, :tenant)

    # The person exists — but in a DIFFERENT org than the caller's scope.
    assert {:error, :not_found} =
             Server.crm_preview(mount, other_org, Samen.WebTest.Crm.Person, person.id)
  end

  test "crm_preview returns the record for its OWN org (positive control)", %{org_id: org_id, person: person} do
    mount = ai_mount(org_id, :tenant)
    assert {:ok, fields} = Server.crm_preview(mount, org_id, Samen.WebTest.Crm.Person, person.id)
    assert fields[:__id__] == person.id
  end

  # --- PP-16: a persisted SIMULATED support draft renders the loud badge in the tenant list ---

  defp render_support_drafts(org_id, drafts) do
    mount = ai_mount(org_id, :tenant)

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Samen.Web.AI.SupportDraftLive.load(org_id)
    |> Phoenix.Component.assign(:drafts, drafts)
    |> then(&render_html(Samen.Web.AI.SupportDraftLive, &1.assigns))
  end

  test "PP-16: a persisted SIMULATED support draft renders the loud SIMULATED badge in the list", %{org_id: org_id} do
    draft = %Samen.AI.SupportReplyDraft{
      id: Ash.UUID.generate(),
      status: :draft,
      body: "fake-completion:deadbeefdeadbeef",
      simulated: true
    }

    html = render_support_drafts(org_id, [draft])

    assert html =~ "SIMULATED — not a real model"
    assert html =~ ~s(data-simulated="true")
  end

  test "PP-16 positive control: a NON-simulated persisted draft shows NO SIMULATED badge", %{org_id: org_id} do
    draft = %Samen.AI.SupportReplyDraft{
      id: Ash.UUID.generate(),
      status: :draft,
      body: "A real-model draft.",
      simulated: false
    }

    html = render_support_drafts(org_id, [draft])

    # The draft row still renders — only the SIMULATED badge is absent (badge is flag-driven).
    assert html =~ "ai-draft-#{draft.id}"
    refute html =~ "SIMULATED"
    assert html =~ ~s(data-simulated="false")
  end
end
