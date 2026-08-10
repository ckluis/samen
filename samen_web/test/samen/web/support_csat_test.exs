defmodule Samen.Web.SupportCsatTest do
  @moduledoc """
  T79 (spec §I6 macros composer palette + CSAT loop closed) — done-criteria
  2 + 3: "CSAT chain test: resolved ticket → survey email via chokepoint →
  score submission link records on Csat → operator analytics reflect it
  (end-to-end, time-travel)." + "Survey link tokenized single-use (reuse red
  test); suppression honored on survey sends."

  Mirrors `Samen.Delivery.LifecycleTest`'s CaptureAdapter harness (the
  chokepoint precedent) combined with `Samen.Web.SupportKbComposerTest`'s
  LiveView-event harness (the public redemption page).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Delivery.{Message, Provider}
  alias Samen.Delivery.Lifecycle.EmailWorker
  alias Samen.Scopes.Support.CsatSurvey
  alias Samen.Web.Support.CsatRespondLive
  alias Samen.Web.Support.Reads
  alias Samen.Web.Mount

  # A bogus "Csat" resource (a bare module, NOT an Ash resource) — pointing the CSAT
  # write leg at it forces `create_csat/4` to fail, exercising the L7 POST-consume
  # write-failure path deterministically without a real DB blip.
  defmodule BrokenCsat do
  end

  # A configured adapter that CAPTURES the send config it received (Chokepoint.send/2
  # dispatches deliver/2 synchronously in-process, so self() is the test process) —
  # the SAME shape `Samen.Delivery.LifecycleTest.CaptureAdapter` uses.
  defmodule CaptureAdapter do
    use Provider
    @impl true
    def configured?(_config), do: true
    @impl true
    def deliver(%Message{} = m, config) do
      send(self(), {:captured, config})
      {:ok, %{provider_id: "cap-#{m.send_id}"}}
    end
  end

  # A configured adapter that must NEVER be called (the suppression proof —
  # `Chokepoint.send/2` refuses BEFORE `deliver/2`, so this adapter existing
  # and being wired is exactly what makes the suppression assertion
  # non-vacuous: if suppression were silently dropped, THIS would fire).
  defmodule NeverCalledAdapter do
    use Provider
    @impl true
    def configured?(_config), do: true
    @impl true
    def deliver(%Message{}, _config), do: send(self(), :should_never_be_called) && {:ok, %{}}
  end

  setup do
    prev = Application.get_env(:samen_core, EmailWorker)
    prev_suppression = Application.get_env(:samen_core, Samen.Delivery.Chokepoint)

    on_exit(fn ->
      restore(EmailWorker, prev)
      restore(Samen.Delivery.Chokepoint, prev_suppression)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, val), do: Application.put_env(:samen_core, key, val)

  defp configure_capture_adapter do
    Application.put_env(:samen_core, EmailWorker, adapter: CaptureAdapter, adapter_config: %{})
  end

  defp resolve_ticket(mount, org_id, ticket_id) do
    scope = Mount.scope(mount, org_id)
    Reads.update_ticket_status(mount, scope, ticket_id, "resolved")
  end

  # Extracts the raw survey token from the captured email content's link
  # (`.../support/csat/<token>`) — the ONLY place the raw token ever appears
  # (never persisted; see `Samen.Scopes.Support.CsatSurvey` moduledoc).
  defp extract_token(text_body) do
    [_, token] = Regex.run(~r{/support/csat/([A-Za-z0-9_-]+)}, text_body)
    token
  end

  # A plain mount/3 round trip — the SAME `TicketLive.load/3` direct-call
  # idiom `support_kb_composer_test.exs` already uses; `CsatRespondLive.
  # mount/3` has no side effects beyond `CsatSurvey.preview/2` (non-mutating).
  defp csat_respond_mount_socket(mount, token) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)

    {:ok, socket} = CsatRespondLive.mount(%{"token" => token}, Mount.to_session(mount) |> then(&%{"samen_mount" => &1}), socket)

    socket
  end

  defp event(module, socket, name, params) do
    {:noreply, socket} = module.handle_event(name, params, socket)
    socket
  end

  # ---------------------------------------------------------------------------
  describe "the full CSAT loop: resolved ticket -> survey -> response -> analytics" do
    test "end-to-end: chokepoint send -> redeem -> Csat row -> csat_avg reflects it" do
      configure_capture_adapter()
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      mount = build_mount(:support)

      # Before resolution: no survey has gone out, no response exists.
      assert Reads.metrics(mount, Mount.scope(mount, org_id)).csat_avg == nil

      # 1. Resolved ticket -> survey email via chokepoint.
      assert {:ok, resolved} = resolve_ticket(mount, org_id, ticket.id)
      assert resolved.status == :resolved
      assert %DateTime{} = resolved.resolved_at

      assert_receive {:captured, config}
      assert config.subject == "How did we do?"
      token = extract_token(config.text_body)
      assert is_binary(token)

      # 2. The score-submission link (public, unauthenticated) records on Csat.
      socket = csat_respond_mount_socket(mount, token)
      assert socket.assigns.state == :form

      socket =
        event(CsatRespondLive, socket, "submit_survey", %{"score" => "5", "comments" => "Great support!"})

      assert socket.assigns.state == :thanks

      [csat] = Reads.csats(mount, Mount.scope(mount, org_id))
      assert csat.score == 5
      assert csat.comments == "Great support!"
      assert csat.ticket_id == ticket.id
      assert csat.channel == :email

      # Also lands on the ticket detail page's "somewhere honest" spot.
      assert Reads.csat_for_ticket(mount, Mount.scope(mount, org_id), ticket.id).score == 5

      # 3. Operator analytics (the tenant-facing CSAT avg tile) reflect it.
      assert Reads.metrics(mount, Mount.scope(mount, org_id)).csat_avg == 5.0
    end

    test "REUSE RED TEST: the SAME token cannot be redeemed twice" do
      configure_capture_adapter()
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      mount = build_mount(:support)

      {:ok, _resolved} = resolve_ticket(mount, org_id, ticket.id)
      assert_receive {:captured, config}
      token = extract_token(config.text_body)

      socket = csat_respond_mount_socket(mount, token)
      socket = event(CsatRespondLive, socket, "submit_survey", %{"score" => "4", "comments" => nil})
      assert socket.assigns.state == :thanks

      before_count = Reads.csats(mount, Mount.scope(mount, org_id)) |> length()

      # Replay: a fresh mount with the SAME raw token must be honestly invalid,
      # and must NOT create a second Csat row.
      replay_socket = csat_respond_mount_socket(mount, token)
      assert replay_socket.assigns.state == :invalid

      replay_socket = event(CsatRespondLive, replay_socket, "submit_survey", %{"score" => "1", "comments" => nil})
      assert replay_socket.assigns.state == :invalid

      after_count = Reads.csats(mount, Mount.scope(mount, org_id)) |> length()
      assert after_count == before_count
    end

    test "an unknown/garbage token is honestly invalid, never crashes" do
      %{org_id: org_id} = Seeds.seed_all()
      mount = build_mount(:support)
      _ = org_id

      socket = csat_respond_mount_socket(mount, "not-a-real-token")
      assert socket.assigns.state == :invalid
    end

    test "TIME-TRAVEL: an expired token is honestly invalid" do
      configure_capture_adapter()
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      mount = build_mount(:support)

      {:ok, _resolved} = resolve_ticket(mount, org_id, ticket.id)
      assert_receive {:captured, config}
      token = extract_token(config.text_body)

      # Time-travel the minted token 31 days into the past (past its 30-day TTL)
      # WITHOUT sleeping — a direct, governed update on the persisted row (never
      # hand-editing consumed_at; only expires_at, simulating elapsed time).
      [token_row] =
        Samen.WebTest.Support.CsatSurveyToken
        |> Ash.Query.filter(is_nil(consumed_at))
        |> Ash.read!(authorize?: false)

      token_row
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(
        :expires_at,
        DateTime.utc_now() |> DateTime.add(-31 * 24 * 60 * 60, :second)
      )
      |> Ash.update!(authorize?: false)

      socket = csat_respond_mount_socket(mount, token)
      assert socket.assigns.state == :invalid

      assert Reads.csats(mount, Mount.scope(mount, org_id)) == []
    end
  end

  # ---------------------------------------------------------------------------
  describe "suppression honored on survey sends" do
    test "a suppressed org/token never reaches the adapter's deliver/2; sent_at stays nil" do
      Application.put_env(:samen_core, EmailWorker, adapter: NeverCalledAdapter, adapter_config: %{})

      Application.put_env(:samen_core, Samen.Delivery.Chokepoint,
        suppression_module: Samen.Web.SupportCsatTest.AlwaysSuppressed
      )

      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      mount = build_mount(:support)

      {:ok, _resolved} = resolve_ticket(mount, org_id, ticket.id)

      refute_received :should_never_be_called

      [token_row] =
        Samen.WebTest.Support.CsatSurveyToken
        |> Ash.Query.filter(ticket_id == ^ticket.id)
        |> Ash.Query.ensure_selected([:sent_at])
        |> Ash.read!(authorize?: false)

      assert token_row.sent_at == nil
    end
  end

  defmodule AlwaysSuppressed do
    def suppressed?(_org_id, _subscriber_id), do: true
  end

  # ---------------------------------------------------------------------------
  describe "honest-empty / keyless states" do
    test "no delivery adapter configured -> honestly BLOCKED, never a fake sent" do
      # Default test-suite state: EmailWorker has no configured adapter and no
      # marketing-adapter fallback wired for THIS test's org.
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      mount = build_mount(:support)

      assert {:ok, _resolved} = resolve_ticket(mount, org_id, ticket.id)

      [token_row] =
        Samen.WebTest.Support.CsatSurveyToken
        |> Ash.Query.filter(ticket_id == ^ticket.id)
        |> Ash.Query.ensure_selected([:sent_at])
        |> Ash.read!(authorize?: false)

      # Minted (the token row exists — the mint half never lies either way),
      # but genuinely NOT sent (fail-honest, ADR-014 Invariant D1).
      assert token_row.sent_at == nil
    end

    test "no CSAT responses yet -> csat_avg is nil, never a fabricated number" do
      %{org_id: org_id} = Seeds.seed_all()
      mount = build_mount(:support)

      assert Reads.metrics(mount, Mount.scope(mount, org_id)).csat_avg == nil
      assert Reads.csats(mount, Mount.scope(mount, org_id)) == []
    end

    test "a ticket touched but NOT transitioning into :resolved never mints a survey" do
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      mount = build_mount(:support)
      scope = Mount.scope(mount, org_id)

      {:ok, _} = Reads.update_ticket_status(mount, scope, ticket.id, "pending")

      assert Samen.WebTest.Support.CsatSurveyToken
             |> Ash.Query.filter(ticket_id == ^ticket.id)
             |> Ash.read!(authorize?: false) == []
    end

    test "a ticket already resolved touched again (resolved -> resolved) does not re-mint a survey" do
      configure_capture_adapter()
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      mount = build_mount(:support)
      scope = Mount.scope(mount, org_id)

      {:ok, _} = Reads.update_ticket_status(mount, scope, ticket.id, "resolved")
      assert_receive {:captured, _config}

      {:ok, _} = Reads.update_ticket_status(mount, scope, ticket.id, "resolved")
      refute_receive {:captured, _config2}, 100

      tokens =
        Samen.WebTest.Support.CsatSurveyToken
        |> Ash.Query.filter(ticket_id == ^ticket.id)
        |> Ash.read!(authorize?: false)

      assert length(tokens) == 1
    end

    # P11 (phase6-punchlist) — pin the resolved-transition guard on the
    # force_change_attribute path (the exact path T79's verifier reasoned about but
    # left sabotage-UNPINNED).
    #
    # HONEST FINDING (documented in the gate report): `force_change_attribute(:status,
    # :resolved)` on an ALREADY-`:resolved` ticket leaves `changing_attribute?(:status)`
    # == FALSE and `attributes` == %{} — Ash ELIDES a same-value force-change. So the two
    # transition conjuncts (`changing_attribute?` and `previous_status != :resolved`) are
    # mutually REDUNDANT for the same-value case: dropping either one ALONE leaves the
    # other holding, so a single-conjunct sabotage would be VACUOUS (anti-tautology). This
    # test therefore pins the transition-detection guard AS A WHOLE — that a re-save of an
    # already-resolved ticket does NOT re-dispatch a survey — and sabotage 153 removes the
    # detection (fire on any resolved-status write) to prove the guard is load-bearing.
    test "P11 FORCE-CHANGE DIRECT: an already-resolved ticket force_change'd back to :resolved does NOT re-mint a CSAT token" do
      configure_capture_adapter()
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      mount = build_mount(:support)
      scope = Mount.scope(mount, org_id)

      # First real resolution mints exactly one token.
      {:ok, resolved} = Reads.update_ticket_status(mount, scope, ticket.id, "resolved")
      assert resolved.status == :resolved
      assert_receive {:captured, _config}

      assert Samen.WebTest.Support.CsatSurveyToken
             |> Ash.Query.filter(ticket_id == ^ticket.id)
             |> Ash.read!(authorize?: false)
             |> length() == 1

      # THE PIN: force `:status` back in as `:resolved` on the already-resolved ticket and
      # run the real `:update` action (the CsatSurveyDispatch change fires here). With the
      # transition guard present: no re-dispatch, no second token.
      {:ok, _} =
        resolved
        |> Ash.Changeset.for_update(:update, %{}, scope: scope)
        |> Ash.Changeset.force_change_attribute(:status, :resolved)
        |> Ash.update()

      refute_receive {:captured, _config2}, 100

      assert Samen.WebTest.Support.CsatSurveyToken
             |> Ash.Query.filter(ticket_id == ^ticket.id)
             |> Ash.read!(authorize?: false)
             |> length() == 1
    end
  end

  # ---------------------------------------------------------------------------
  describe "org-scope pin — csat_for_ticket/3" do
    test "a two-org pin: org B's scope never reads org A's ticket's CSAT response" do
      configure_capture_adapter()
      %{org_id: org_a, support: %{ticket: ticket_a}} = Seeds.seed_all()
      %{org_id: org_b} = Seeds.seed_all()
      mount = build_mount(:support)

      {:ok, _} = resolve_ticket(mount, org_a, ticket_a.id)
      assert_receive {:captured, config}
      token = extract_token(config.text_body)

      socket = csat_respond_mount_socket(mount, token)
      socket = event(CsatRespondLive, socket, "submit_survey", %{"score" => "3", "comments" => nil})
      assert socket.assigns.state == :thanks

      # Reading org A's ticket's CSAT under org B's scope -> nil (no existence oracle).
      assert Reads.csat_for_ticket(mount, Mount.scope(mount, org_b), ticket_a.id) == nil
      # The SAME read under org A's own scope -> the real response.
      assert Reads.csat_for_ticket(mount, Mount.scope(mount, org_a), ticket_a.id).score == 3
    end
  end

  # ---------------------------------------------------------------------------
  # L7 (phase6-edges F3) — a POST-consume write failure must return a DISTINCT
  # reason ({:write_failed, _}), never the load-bearing :invalid_token (the token
  # WAS valid). Single-use security is unchanged: the atomic burn-before-write
  # still holds, so a token is not replayable after a SUCCESSFUL response.
  defp good_mods do
    %{
      csat_survey_token: Samen.WebTest.Support.CsatSurveyToken,
      csat: Samen.WebTest.Support.Csat
    }
  end

  # Mint a real, PENDING survey token row (same private-column force-change shape as
  # `CsatSurvey.send_survey/3`) and return the raw token value.
  defp mint_token!(org_id, ticket_id) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    expires =
      DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    Samen.WebTest.Support.CsatSurveyToken
    |> Ash.Changeset.for_create(:create, %{org_id: org_id}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:ticket_id, ticket_id)
    |> Ash.Changeset.force_change_attribute(:token_digest, Samen.Auth.TokenMint.digest(raw))
    |> Ash.Changeset.force_change_attribute(:expires_at, expires)
    |> Ash.create!(authorize?: false)

    raw
  end

  describe "L7: a failed Csat write after consume is DISTINCT from an invalid token" do
    test "a write failure AFTER consume ⇒ {:error, {:write_failed, _}} (never :invalid_token), and the token is spent" do
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      raw = mint_token!(org_id, ticket.id)

      broken_mods = %{good_mods() | csat: BrokenCsat}

      # THE PIN: the token was valid; the WRITE failed — a distinct reason ({:write_failed,
      # _}), never the load-bearing :invalid_token (which the assert pattern excludes).
      assert {:error, {:write_failed, _reason}} = CsatSurvey.respond(broken_mods, raw, 5, "great")

      # The atomic burn-before-write HELD: the token is now spent, so a retry (even with
      # a working csat resource) is honestly invalid — single-use is not weakened.
      assert {:error, :invalid_token} = CsatSurvey.respond(good_mods(), raw, 5, "great")
    end

    test "a genuinely unknown/invalid token still returns :invalid_token (contract unchanged)" do
      assert {:error, :invalid_token} = CsatSurvey.respond(good_mods(), "not-a-real-token", 5, nil)
    end

    test "a SUCCESSFUL response still burns the token — no replay after success (security intact)" do
      %{org_id: org_id, support: %{ticket: ticket}} = Seeds.seed_all()
      raw = mint_token!(org_id, ticket.id)

      assert {:ok, _csat} = CsatSurvey.respond(good_mods(), raw, 5, "great")
      # Replay of a SUCCESSFULLY-consumed token is refused — the load-bearing single-use.
      assert {:error, :invalid_token} = CsatSurvey.respond(good_mods(), raw, 5, "great")
    end
  end
end
