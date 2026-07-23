defmodule Samen.Web.WebhookSecurityTest do
  @moduledoc """
  T19/B9 — the SHARED webhook ingress security surface, end-to-end through the real
  pipeline (ADR-038 §5). Attacker-first: bad-signature/replay/oversize/forgery-DoS are
  each paired with the green control that a broken (accept-everything / mask-everything)
  implementation would fail (anti-tautology).

  Done-criteria coverage:
    * bad signature ⇒ 400 + NOTHING persisted (red) / valid signature ⇒ 200 + stored (control)
    * stale timestamp ⇒ 400 (anti-replay) ; stripped signature ⇒ 400 (fail-closed)
    * unknown provider ⇒ 404 (fail-closed dispatch)
    * duplicate `{provider, event_id}` (incl. via concurrent tasks) ⇒ exactly ONE
      persisted event, second delivery is a 200 no-op (replay protection)
    * oversized body ⇒ 413 before verify (DLQ-poisoning / DoS bound)
    * per-provider flood guard ⇒ 429 (backpressure) ; per-IP invalid-signature budget
      ⇒ 429 before crypto, isolated per IP (positive control: a fresh IP still 400s)
    * a handler-crash payload lands in the DLQ; the operator view lists it TOKEN-BLIND
      (no plaintext PII, no `vt_` token — the store is redacted by construction, §5.4/§5.5),
      and is replayable

  Vendor-free: the pipeline runs against a CORE-based `TestProvider` (verification via the
  vendor-generic `Samen.Webhook.Signer` primitive) — `samen_web` never deps a vendor pkg.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Test

  alias Samen.Web.RateLimit
  alias Samen.Web.Webhook.Ingress
  alias Samen.WebTest.Repo
  alias Samen.Webhook.{Event, IngestWorker}
  alias Samen.Webhook.Signer

  @secret "whsec_ingress_test_9a8b7c6d5e4f3a2b1c0d"
  @pii_email "leak-jane@example.com"
  @pii_name "Jane Leaky"

  # ---------------------------------------------------------------------------
  # A CORE-only test provider — verification delegates to the vendor-generic
  # Samen.Webhook.Signer, so the full sig-verification code path runs vendor-free.
  # ---------------------------------------------------------------------------
  defmodule TestProvider do
    @moduledoc false
    @behaviour Samen.Billing.Provider
    alias Samen.Billing.ProviderEvent

    @kinds %{
      "checkout.session.completed" => :checkout_completed,
      "invoice.payment_failed" => :invoice_payment_failed
    }

    @impl true
    def configured?(c), do: is_binary(Map.get(c, :webhook_secret)) and Map.get(c, :webhook_secret) != ""

    @impl true
    def verify_and_parse_event(raw, headers, config) do
      secret = Map.get(config, :webhook_secret)

      case header(headers, "webhook-signature") do
        nil ->
          {:error, :malformed}

        sig ->
          case Signer.verify(raw, sig, secret, 300) do
            {:ok, _ts} -> parse(raw)
            {:error, :bad_signature} -> {:error, :invalid_signature}
            {:error, :stale_timestamp} -> {:error, :stale_timestamp}
            {:error, :malformed_header} -> {:error, :malformed}
          end
      end
    end

    @impl true
    def redact_payload(p) when is_map(p), do: Map.drop(p, ["email", "name", :email, :name])

    # unused fail-honest callbacks (kept for the @behaviour)
    @impl true
    def create_checkout_session(_a, _c), do: {:error, :not_configured}
    @impl true
    def create_portal_session(_a, _c), do: {:error, :not_configured}
    @impl true
    def cancel_subscription(_i, _o, _c), do: {:error, :not_configured}
    @impl true
    def change_subscription(_i, _ch, _c), do: {:error, :not_configured}
    @impl true
    def fetch_object(_k, _i, _c), do: {:error, :not_configured}
    @impl true
    def report_usage(_b, _c), do: {:error, :not_configured}

    defp parse(raw) do
      case Jason.decode(raw) do
        {:ok, %{"id" => id, "type" => type} = body} ->
          object = get_in(body, ["data", "object"]) || body

          {:ok,
           %ProviderEvent{
             provider: :test,
             event_id: id,
             kind: Map.get(@kinds, type, :unhandled),
             occurred_at: DateTime.utc_now(),
             provider_refs: %{},
             payload: redact_payload(object)
           }}

        _ ->
          {:error, :malformed}
      end
    end

    defp header(headers, name) do
      Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
    end
  end

  # A dispatch that always crashes — drives an envelope to the DLQ.
  defmodule CrashingDispatch do
    @moduledoc false
    @behaviour Samen.Webhook.Dispatch
    @impl true
    def dispatch(_event, _opts), do: raise("handler boom")
  end

  # ---------------------------------------------------------------------------

  setup do
    Application.put_env(:samen_web, Samen.Web.Webhook,
      repo: Repo,
      providers: %{"test" => {TestProvider, %{webhook_secret: @secret}}},
      max_body_bytes: 4096
    )

    # Default (high) limits so ordinary cases never trip; rate-limit tests override.
    Application.put_env(:samen_web, RateLimit, limits: %{webhook_ingress: {1000, 60_000}, webhook_bad_sig: {60, 60_000}})
    RateLimit.reset()

    on_exit(fn ->
      Application.delete_env(:samen_web, Samen.Web.Webhook)
      Application.delete_env(:samen_web, RateLimit)
      Application.delete_env(:samen_core, :webhook_dispatch)
      RateLimit.reset()
    end)

    :ok
  end

  # -- body + conn helpers -----------------------------------------------------

  defp event_body(overrides \\ %{}) do
    base = %{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => "checkout.session.completed",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => "cs_abc",
          "email" => @pii_email,
          "name" => @pii_name,
          "amount_total" => 4900
        }
      }
    }

    base |> Map.merge(overrides) |> Jason.encode!()
  end

  defp signed(body, opts \\ []) do
    ts = Keyword.get(opts, :ts, System.os_time(:second))
    secret = Keyword.get(opts, :secret, @secret)
    [{"webhook-signature", Signer.sign(body, ts, secret)}, {"content-type", "application/json"}]
  end

  defp post_webhook(provider, raw, headers, opts \\ []) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    conn(:post, "/webhooks/#{provider}", raw)
    |> Map.put(:path_params, %{"provider" => provider})
    |> Map.put(:params, %{"provider" => provider})
    |> Map.put(:remote_ip, ip)
    |> Map.put(:req_headers, headers)
    |> Plug.Conn.assign(:raw_webhook_body, raw)
    |> Ingress.ingest([])
  end

  defp count, do: Repo.aggregate(Event, :count)

  # ===========================================================================
  # Signature verification: bad ⇒ 400 nothing persisted / good ⇒ 200 stored
  # ===========================================================================

  describe "signature verification (red + control)" do
    test "valid signature ⇒ 200 and the envelope is persisted (green control)" do
      body = event_body()
      conn = post_webhook("test", body, signed(body))

      assert conn.status == 200
      assert count() == 1
      [row] = Repo.all(Event)
      assert row.status == "received"
      assert row.domain == "billing"
    end

    test "tampered body ⇒ 400 and NOTHING persisted (red)" do
      body = event_body()
      headers = signed(body)
      tampered = String.replace(body, "4900", "1")

      conn = post_webhook("test", tampered, headers)

      assert conn.status == 400
      assert count() == 0
    end

    test "wrong-secret signature ⇒ 400 and NOTHING persisted (red)" do
      body = event_body()
      conn = post_webhook("test", body, signed(body, secret: "whsec_attacker"))

      assert conn.status == 400
      assert count() == 0
    end

    test "stripped signature header ⇒ 400, fail-closed (red)" do
      body = event_body()
      conn = post_webhook("test", body, [{"content-type", "application/json"}])

      assert conn.status == 400
      assert count() == 0
    end

    test "stale timestamp ⇒ 400, anti-replay (red)" do
      body = event_body()
      conn = post_webhook("test", body, signed(body, ts: System.os_time(:second) - 3600))

      assert conn.status == 400
      assert count() == 0
    end
  end

  # ===========================================================================
  # Unknown provider ⇒ 404 (fail-closed)
  # ===========================================================================

  test "unknown provider ⇒ 404, nothing persisted" do
    body = event_body()
    conn = post_webhook("nope", body, signed(body))

    assert conn.status == 404
    assert count() == 0
  end

  # ===========================================================================
  # Replay protection: duplicate {provider, event_id} ⇒ exactly one row
  # ===========================================================================

  describe "replay protection" do
    test "the same event delivered twice ⇒ 200 then 200 no-op, exactly one persisted" do
      body = event_body()
      headers = signed(body)

      conn1 = post_webhook("test", body, headers)
      conn2 = post_webhook("test", body, headers)

      assert conn1.status == 200
      assert conn2.status == 200
      assert conn2.resp_body == "duplicate"
      assert count() == 1
    end

    test "a DIFFERENT event id IS persisted (control — the store is not frozen)" do
      b1 = event_body()
      b2 = event_body()

      post_webhook("test", b1, signed(b1))
      post_webhook("test", b2, signed(b2))

      assert count() == 2
    end

    test "concurrent duplicate deliveries collide at the unique index ⇒ exactly one row" do
      # DataCase already runs the sandbox in {:shared, self()} mode, so the Task
      # children below share this process's connection; the DB unique index is the
      # race arbiter that keeps exactly one row.
      body = event_body()
      headers = signed(body)

      results =
        1..8
        |> Task.async_stream(fn _ -> post_webhook("test", body, headers).status end,
          max_concurrency: 8,
          ordered: false
        )
        |> Enum.map(fn {:ok, s} -> s end)

      assert Enum.all?(results, &(&1 == 200))
      assert count() == 1
    end
  end

  # ===========================================================================
  # Oversized payload ⇒ 413 (DoS / DLQ-poisoning bound)
  # ===========================================================================

  test "oversized body ⇒ 413 before verify, nothing persisted" do
    big = event_body(%{"pad" => String.duplicate("x", 5000)})
    conn = post_webhook("test", big, signed(big))

    assert conn.status == 413
    assert count() == 0
  end

  # ===========================================================================
  # Rate limiting (ADR-038 §6.3)
  # ===========================================================================

  describe "rate limits" do
    test "per-provider flood guard ⇒ 429 over limit; nothing persisted for the over-limit request" do
      Application.put_env(:samen_web, RateLimit, limits: %{webhook_ingress: {3, 60_000}, webhook_bad_sig: {60, 60_000}})
      RateLimit.reset()

      statuses =
        for _ <- 1..4 do
          b = event_body()
          post_webhook("test", b, signed(b)).status
        end

      assert statuses == [200, 200, 200, 429]
      # Only the 3 under-limit deliveries persisted; the 429'd one did not.
      assert count() == 3
    end

    test "per-IP invalid-signature budget ⇒ 429 before crypto, isolated per IP (control)" do
      Application.put_env(:samen_web, RateLimit, limits: %{webhook_ingress: {1000, 60_000}, webhook_bad_sig: {2, 60_000}})
      RateLimit.reset()

      body = event_body()
      bad = signed(body, secret: "whsec_attacker")

      s1 = post_webhook("test", body, bad, ip: {10, 0, 0, 1}).status
      s2 = post_webhook("test", body, bad, ip: {10, 0, 0, 1}).status
      s3 = post_webhook("test", body, bad, ip: {10, 0, 0, 1}).status

      assert s1 == 400
      assert s2 == 400
      # Over the per-IP budget ⇒ 429 BEFORE the crypto work.
      assert s3 == 429

      # Positive control: a FRESH IP is not charged against the attacker's budget.
      assert post_webhook("test", body, bad, ip: {10, 0, 0, 2}).status == 400
    end
  end

  # ===========================================================================
  # DLQ: handler-crash ⇒ :dead ; operator view lists it token-blind ; replayable
  # ===========================================================================

  describe "dead-letter queue + operator view (token-blind)" do
    setup do
      # Ingest a real, signed event so its stored payload is redacted by the pipeline.
      body = event_body()
      assert post_webhook("test", body, signed(body)).status == 200
      [row] = Repo.all(Event)
      %{event: row}
    end

    test "a crashing handler on the final attempt dead-letters the envelope", %{event: event} do
      Application.put_env(:samen_core, :webhook_dispatch, CrashingDispatch)

      job = %Oban.Job{
        args: %{"event_id" => event.id, "repo" => to_string(Repo)},
        attempt: 1,
        max_attempts: 1
      }

      assert {:error, _reason} = IngestWorker.perform(job)

      dead = Event.get(Repo, event.id)
      assert dead.status == "dead"
      assert is_binary(dead.last_error)
      # The error summary never echoes the payload (§5.3).
      refute dead.last_error =~ @pii_email
    end

    test "the default dispatch processes the envelope (control — DLQ is not the only outcome)", %{event: event} do
      job = %Oban.Job{args: %{"event_id" => event.id, "repo" => to_string(Repo)}, attempt: 1, max_attempts: 1}
      assert :ok = IngestWorker.perform(job)
      assert Event.get(Repo, event.id).status == "processed"
    end

    test "the operator DLQ view lists the dead envelope TOKEN-BLIND (no plaintext PII, no vt_ token)", %{event: event} do
      # Force it dead.
      Application.put_env(:samen_core, :webhook_dispatch, CrashingDispatch)
      job = %Oban.Job{args: %{"event_id" => event.id, "repo" => to_string(Repo)}, attempt: 1, max_attempts: 1}
      IngestWorker.perform(job)

      html =
        render_live(
          Samen.Web.Operator.WebhookDlqLive,
          build_operator_mount(Ecto.UUID.generate()),
          []
        )

      # The envelope is visible (bounded, non-PII identifiers).
      assert html =~ event.event_id
      assert html =~ "test"
      assert html =~ "dead"

      # TOKEN-BLIND: the redacted store means no PII and no vault token can render.
      # (`\bvt_` word-boundary so a legit `evt_`-prefixed event id is not a false hit.)
      refute html =~ @pii_email
      refute html =~ @pii_name
      refute html =~ ~r/\bvt_/
    end

    test "sabotage twin — the token-blind probe is refutable: an un-redacted payload WOULD be caught", %{event: event} do
      # Prove the DOM scan is non-vacuous: seed a sibling envelope whose stored payload
      # still carries the PII (a modeled redaction failure) and show the SAME scan trips.
      {:ok, :inserted, leaked} =
        Event.insert_received(Repo, %{
          provider: "test",
          event_id: "evt_leak_#{System.unique_integer([:positive])}",
          kind: "checkout_completed",
          domain: "billing",
          occurred_at: DateTime.utc_now(),
          payload: %{"email" => @pii_email, "name" => @pii_name}
        })

      _ = event

      html =
        render_live(Samen.Web.Operator.WebhookDlqLive, build_operator_mount(Ecto.UUID.generate()), [])

      # The leak IS detected by the same assertion the real test relies on — so the
      # real test's `refute html =~ @pii_email` is a genuine gate, not a tautology.
      assert html =~ @pii_email, "the scan must be able to detect a leak, else the token-blind assertion is vacuous"
      assert leaked.status == "received"
    end

    test "an operator replay resets a dead envelope to :received (idempotent re-run)", %{event: event} do
      Application.put_env(:samen_core, :webhook_dispatch, CrashingDispatch)
      job = %Oban.Job{args: %{"event_id" => event.id, "repo" => to_string(Repo)}, attempt: 1, max_attempts: 1}
      IngestWorker.perform(job)
      assert Event.get(Repo, event.id).status == "dead"

      {:ok, replayed} = Event.reset_for_replay(Repo, Event.get(Repo, event.id))
      assert replayed.status == "received"
      assert replayed.last_error == nil
    end
  end

  # ===========================================================================
  # Worker enqueue is TOKEN-ONLY (never the payload)
  # ===========================================================================

  test "the processing job carries token-only args (the row id), never the payload" do
    changeset = IngestWorker.new(%{"event_id" => "whk_123"})
    args = Ecto.Changeset.get_field(changeset, :args)

    assert Map.keys(args) == ["event_id"]
    assert args["event_id"] == "whk_123"
    refute Map.has_key?(args, "payload")
  end
end
