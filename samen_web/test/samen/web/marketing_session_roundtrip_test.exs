defmodule Samen.Web.MarketingSessionRoundtripTest do
  @moduledoc """
  Cold-start session round-trip regression (gate `gate-crm-enrich.md` C1/C2).

  The framework `render_live/3` harness assigns an already-built `%Mount{}` to the socket
  and calls `load/*` directly — it NEVER calls the LiveView `mount/3`, so the
  `mount/3 → assign_mount → Mount.from_session → atomize_labels` path (the one that 500'd
  on a cold BEAM) was untested. This suite drives that EXACT path:

    * build a session with `Mount.to_session/1` carrying `crm_namespace: <Host>.Crm`
      (mirroring how Driftwood wires the Marketing mount);
    * call `CampaignsLive.mount/3` and `SegmentsLive.mount/3` with that session;
    * assert `{:ok, socket}` (a 200), so the load-order-dependent atomization bug
      (`String.to_existing_atom("crm_namespace")` on a key minted only inside `LeadsLive`)
      can never silently return as a green-suite/red-production regression.

  It also asserts the `Mount`-level invariant directly: `from_session/1` resolves EVERY
  framework label key through the compile-time whitelist, so those atoms are resident in
  ANY deserializing process regardless of which LiveView loaded first.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Mount

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id}
  end

  # The Marketing session EXACTLY as the router's `live_session` ships it: a stringified mount
  # (via `to_session/1`) carrying the `crm_namespace` label — the key whose atomization 500'd.
  defp marketing_session do
    mount =
      Mount.new(:marketing, Samen.WebTest.Marketing, Samen.WebTest.Repo,
        labels: %{crm_namespace: Samen.WebTest.Crm}
      )

    %{"samen_mount" => Mount.to_session(mount)}
  end

  # ==========================================================================
  # (a) The regression: mount/3 must NOT crash on the crm_namespace label key
  # ==========================================================================

  test "CampaignsLive.mount/3 returns 200 from a to_session round-trip carrying crm_namespace", %{
    org_id: org_id
  } do
    session = marketing_session()

    assert {:ok, socket} =
             Samen.Web.Marketing.CampaignsLive.mount(%{"org" => org_id}, session, %Phoenix.LiveView.Socket{})

    # The mount deserialized the label key WITHOUT raising, and the CRM namespace survived.
    assert socket.assigns.samen_mount.labels[:crm_namespace] == Samen.WebTest.Crm
    assert socket.assigns.org_id == org_id
  end

  test "SegmentsLive.mount/3 returns 200 from a to_session round-trip carrying crm_namespace", %{
    org_id: org_id
  } do
    session = marketing_session()

    assert {:ok, socket} =
             Samen.Web.Marketing.SegmentsLive.mount(%{"org" => org_id}, session, %Phoenix.LiveView.Socket{})

    assert socket.assigns.samen_mount.labels[:crm_namespace] == Samen.WebTest.Crm
  end

  test "LeadsLive.mount/3 also round-trips (the lens that used to be the only atom minter)", %{
    org_id: org_id
  } do
    session = marketing_session()

    assert {:ok, socket} =
             Samen.Web.Marketing.LeadsLive.mount(%{"org" => org_id}, session, %Phoenix.LiveView.Socket{})

    assert socket.assigns.samen_mount.labels[:crm_namespace] == Samen.WebTest.Crm
  end

  # ==========================================================================
  # (b) The Mount-level invariant: every framework label key round-trips
  # ==========================================================================

  test "from_session/1 resolves the crm_namespace label key via the compile-time whitelist" do
    round =
      Mount.new(:marketing, Some.Host.Marketing, Some.Host.Repo,
        labels: %{crm_namespace: Some.Host.Crm}
      )
      |> Mount.to_session()
      |> Mount.from_session()

    # The key deserialized to the ATOM :crm_namespace (not a string), and the value survived.
    assert Map.has_key?(round.labels, :crm_namespace)
    assert round.labels[:crm_namespace] == Some.Host.Crm
  end

  test "from_session/1 round-trips the full bounded framework label-key set to atoms" do
    labels = Map.new(Mount.label_keys(), fn k -> {k, "v-#{k}"} end)

    round =
      Mount.new(:marketing, Some.Host.Marketing, Some.Host.Repo, labels: labels)
      |> Mount.to_session()
      |> Mount.from_session()

    for k <- Mount.label_keys() do
      assert Map.has_key?(round.labels, k), "label key #{inspect(k)} did not round-trip to an atom"
      assert round.labels[k] == "v-#{k}"
    end
  end
end
