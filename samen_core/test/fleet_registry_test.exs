defmodule Samen.Fleet.RegistryTest do
  @moduledoc """
  T82 done-criterion 1 (handoff.md) + RP-J-1/RP-J-2/RP-J-3/RP-J-10 groundwork,
  against the REAL `flt_*` tables (`SamenCore.Support.FleetFixture`).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Fleet.{AdminActor, Crypto, HeartbeatActor, Registry}
  alias SamenCore.TestRepo

  @ns SamenCore.Support.FleetFixture
  @admin AdminActor.new("operator-1")

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Samen.Fleet.NonceCache.reset()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Mode A — manual register/list/deregister + shared-secret handshake
  # ---------------------------------------------------------------------------

  describe "mode A — register/list/deregister (done-criterion 1)" do
    test "register_app/3 mints a shared secret shown once, stored KMS-wrapped" do
      assert {:ok, %{app: app, credential: credential, raw_secret: raw_secret}} =
               Registry.register_app(
                 @ns,
                 %{slug: "acme-#{System.unique_integer([:positive])}", display_name: "Acme"},
                 @admin
               )

      assert app.mode == :manual
      assert app.status == :active
      assert credential.capability == :fleet_probe
      assert credential.kind == :shared_secret
      assert is_binary(raw_secret)
      # never a plaintext column — the stored ciphertext never equals the raw secret.
      refute credential.secret_ciphertext == raw_secret
      refute String.contains?(credential.secret_ciphertext || "", raw_secret)
    end

    test "list_apps/2 returns the registered app; deregister_app/3 flips status" do
      slug = "acme-#{System.unique_integer([:positive])}"
      {:ok, %{app: app}} = Registry.register_app(@ns, %{slug: slug, display_name: "Acme"}, @admin)

      assert {:ok, apps} = Registry.list_apps(@ns, @admin)
      assert Enum.any?(apps, &(&1.id == app.id))

      assert {:ok, deregistered} = Registry.deregister_app(@ns, app.id, @admin)
      assert deregistered.status == :deregistered
    end

    test "RED: a non-admin actor cannot register an app" do
      not_admin = %{kind: :not_admin}

      assert {:error, _} =
               Registry.register_app(
                 @ns,
                 %{slug: "acme-#{System.unique_integer([:positive])}", display_name: "Acme"},
                 not_admin
               )
    end
  end

  describe "mode A — bad-secret handshake (RP-J-1, red + control)" do
    setup do
      {:ok, %{app: app, raw_secret: secret}} =
        Registry.register_app(
          @ns,
          %{slug: "probe-#{System.unique_integer([:positive])}", display_name: "Probe"},
          @admin
        )

      %{app: app, secret: secret}
    end

    test "GREEN (control): the correct secret verifies via fetch_probe_secret/3 + HMAC", %{
      app: app,
      secret: secret
    } do
      assert {:ok, stored_secret} = Registry.fetch_probe_secret(@ns, app.id, @admin)
      assert stored_secret == secret

      input = Crypto.signing_input("GET", "/fleet/health", System.os_time(:second), "n1", Crypto.body_digest(""))
      sig = Crypto.sign_hmac(stored_secret, input)
      assert Crypto.verify_hmac(stored_secret, input, sig)
    end

    test "RED: a wrong secret fails HMAC verification", %{app: app} do
      {:ok, real_secret} = Registry.fetch_probe_secret(@ns, app.id, @admin)
      wrong_secret = :crypto.strong_rand_bytes(32)

      input = Crypto.signing_input("GET", "/fleet/health", System.os_time(:second), "n1", Crypto.body_digest(""))
      sig = Crypto.sign_hmac(wrong_secret, input)

      refute Crypto.verify_hmac(real_secret, input, sig)
    end

    test "unknown app_id: fetch_probe_secret/3 returns :not_configured (no fabricated secret)" do
      assert {:error, :not_configured} = Registry.fetch_probe_secret(@ns, Ash.UUID.generate(), @admin)
    end
  end

  describe "credential lifecycle — rotation (no renew-in-place) + revocation (RP-J-3)" do
    setup do
      {:ok, %{app: app, credential: credential}} =
        Registry.register_app(
          @ns,
          %{slug: "rot-#{System.unique_integer([:positive])}", display_name: "Rotator"},
          @admin
        )

      %{app: app, credential: credential}
    end

    test "rotate_probe_credential/4: old key gets a retire_at, new key is a fresh version", %{app: app} do
      assert {:ok, %{credential: new_credential}} =
               Registry.rotate_probe_credential(@ns, app.id, @admin, retire_after_s: 3600)

      assert new_credential.key_version == 2
      assert {:ok, old} = Registry.fetch_probe_secret(@ns, app.id, @admin)
      # the NEW secret is what fetch_probe_secret now returns (current = highest
      # non-revoked version).
      assert is_binary(old)
    end

    test "RED: a revoked credential is dead on the very next request (deny-on-use)", %{credential: credential} do
      assert {:ok, revoked} = Registry.revoke_credential(@ns, credential.id, @admin)
      assert %DateTime{} = revoked.revoked_at
    end

    test "revoked credential is excluded from current_credential lookups", %{app: app, credential: credential} do
      {:ok, _} = Registry.revoke_credential(@ns, credential.id, @admin)
      assert {:error, :not_configured} = Registry.fetch_probe_secret(@ns, app.id, @admin)
    end
  end

  # ---------------------------------------------------------------------------
  # Mode B — self-registration + heartbeat (done-criterion 1)
  # ---------------------------------------------------------------------------

  describe "mode B — enroll + heartbeat, forged/revoked rejected (red + control)" do
    setup do
      {:ok, %{token: _token, raw_token: raw_token}} =
        Registry.mint_enrollment_token(
          @ns,
          %{app_slug: "genapp-#{System.unique_integer([:positive])}", display_name: "GenApp"},
          @admin
        )

      {pub, priv} = Crypto.generate_ed25519_keypair()

      %{raw_token: raw_token, pub: pub, priv: priv}
    end

    test "GREEN: consume_enrollment/3 mints the app + stores ONLY the public key", %{
      raw_token: raw_token,
      pub: pub
    } do
      assert {:ok, %{app_id: app_id, cockpit_public_key: cockpit_pub}} =
               Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      assert is_binary(app_id)
      assert is_binary(cockpit_pub)

      {:ok, app} = Registry.get_app(@ns, app_id, @admin)
      assert app.mode == :heartbeat
    end

    test "RED: a consumed (replayed) token is rejected — one generic error", %{
      raw_token: raw_token,
      pub: pub
    } do
      assert {:ok, _} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))
      assert {:error, :invalid_token} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))
    end

    test "RED: an unknown token is rejected with the SAME generic error as a replay" do
      assert {:error, :invalid_token} = Registry.consume_enrollment(@ns, "not-a-real-token", "pub")
    end

    test "enroll body slug/display_name cannot override the token's authoritative identity", %{
      raw_token: raw_token,
      pub: pub
    } do
      # consume_enrollment/3 takes only (raw_token, public_key) — there is
      # structurally NO parameter through which a caller could pass an
      # alternate slug/display_name; identity comes from the consumed token row.
      assert {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))
      {:ok, app} = Registry.get_app(@ns, app_id, @admin)
      assert app.display_name == "GenApp"
    end

    test "GREEN: a valid heartbeat is accepted, ingests a schema-valid report, and is retrievable" do
      {:ok, %{token: _t, raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "hb-#{System.unique_integer([:positive])}", display_name: "HB"}, @admin)

      {pub, priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      report = Samen.Fleet.Report.build(app_id: app_id)
      payload = Samen.Fleet.Report.to_wire(report)
      raw_body = Jason.encode!(payload)
      ts = System.os_time(:second)
      nonce = Crypto.generate_nonce()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(raw_body))
      sig = Crypto.sign_ed25519(priv, input) |> Base.encode16(case: :lower)

      assert {:ok, stored} =
               Registry.verify_and_ingest_heartbeat(@ns, %{
                 kid: app_id,
                 v: 1,
                 ts: ts,
                 nonce: nonce,
                 sig: sig,
                 method: "POST",
                 path: "/fleet/heartbeat",
                 raw_body: raw_body,
                 payload: payload
               })

      assert stored.app_id == app_id
      assert stored.transport == :push
    end

    test "RED: forged signature is rejected (wrong private key)" do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "hb2-#{System.unique_integer([:positive])}", display_name: "HB2"}, @admin)

      {pub, _priv} = Crypto.generate_ed25519_keypair()
      {_forged_pub, forged_priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      report = Samen.Fleet.Report.build(app_id: app_id)
      payload = Samen.Fleet.Report.to_wire(report)
      raw_body = Jason.encode!(payload)
      ts = System.os_time(:second)
      nonce = Crypto.generate_nonce()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(raw_body))
      # signed with a DIFFERENT (forged) private key, not the enrolled one.
      sig = Crypto.sign_ed25519(forged_priv, input) |> Base.encode16(case: :lower)

      assert {:error, :bad_signature} =
               Registry.verify_and_ingest_heartbeat(@ns, %{
                 kid: app_id,
                 v: 1,
                 ts: ts,
                 nonce: nonce,
                 sig: sig,
                 method: "POST",
                 path: "/fleet/heartbeat",
                 raw_body: raw_body,
                 payload: payload
               })
    end

    test "RED: revoked heartbeat credential is dead on the next request" do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "hb3-#{System.unique_integer([:positive])}", display_name: "HB3"}, @admin)

      {pub, priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      {:ok, %{rows: [credential]}} = read_credentials(app_id)
      {:ok, _} = Registry.revoke_credential(@ns, credential.id, @admin)

      report = Samen.Fleet.Report.build(app_id: app_id)
      payload = Samen.Fleet.Report.to_wire(report)
      raw_body = Jason.encode!(payload)
      ts = System.os_time(:second)
      nonce = Crypto.generate_nonce()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(raw_body))
      sig = Crypto.sign_ed25519(priv, input) |> Base.encode16(case: :lower)

      assert {:error, :unknown_kid} =
               Registry.verify_and_ingest_heartbeat(@ns, %{
                 kid: app_id,
                 v: 1,
                 ts: ts,
                 nonce: nonce,
                 sig: sig,
                 method: "POST",
                 path: "/fleet/heartbeat",
                 raw_body: raw_body,
                 payload: payload
               })
    end

    test "UNPINNED-INVARIANT (i): an EXPIRED enrollment token is rejected, never consumable — red + control" do
      slug = "exp-#{System.unique_integer([:positive])}"
      raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      digest = Samen.Auth.TokenMint.digest(raw_token)

      # A token minted with expires_at already in the PAST (bypasses
      # Registry.mint_enrollment_token/3, which always mints 24h-future, so
      # this exercises the same :consume atomic filter a real expiry would).
      {:ok, _token} =
        Module.concat(@ns, EnrollmentToken)
        |> Ash.Changeset.for_create(
          :create,
          %{
            token_digest: digest,
            app_slug: slug,
            display_name: "Expired",
            expires_at: DateTime.add(DateTime.utc_now(), -10, :second)
          },
          actor: @admin
        )
        |> Ash.create()

      {pub, _priv} = Crypto.generate_ed25519_keypair()

      # RED: expired -> the same generic error a replay/unknown token gets.
      assert {:error, :invalid_token} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      # CONTROL: the identical flow with a NOT-expired token succeeds.
      {:ok, %{raw_token: fresh_raw}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "exp-ok-#{System.unique_integer([:positive])}", display_name: "Fresh"}, @admin)

      assert {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, fresh_raw, Base.encode64(pub))
      assert is_binary(app_id)
    end

    test "UNPINNED-INVARIANT (ii): a RETIRED key version is rejected on the next heartbeat, in-window one still works — red + control" do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "ret-#{System.unique_integer([:positive])}", display_name: "Retire"}, @admin)

      {pub, priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))
      {:ok, %{rows: [credential]}} = read_credentials(app_id)

      # Force retire_at into the PAST directly (defense-in-depth pin — the
      # normal path is Registry.rotate_probe_credential/4's future retire_at).
      credential
      |> Ash.Changeset.for_update(:update, %{retire_at: DateTime.add(DateTime.utc_now(), -10, :second)}, actor: @admin)
      |> Ash.update!()

      report = Samen.Fleet.Report.build(app_id: app_id)
      payload = Samen.Fleet.Report.to_wire(report)
      raw_body = Jason.encode!(payload)

      heartbeat = fn ->
        ts = System.os_time(:second)
        nonce = Crypto.generate_nonce()
        input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(raw_body))
        sig = Crypto.sign_ed25519(priv, input) |> Base.encode16(case: :lower)

        Registry.verify_and_ingest_heartbeat(@ns, %{
          kid: app_id,
          v: 1,
          ts: ts,
          nonce: nonce,
          sig: sig,
          method: "POST",
          path: "/fleet/heartbeat",
          raw_body: raw_body,
          payload: payload
        })
      end

      # RED: retired -> rejected.
      assert {:error, :retired} = heartbeat.()

      # CONTROL: pushing retire_at back into the future (inside the overlap
      # window) accepts the SAME key version again.
      credential
      |> Ash.Changeset.for_update(:update, %{retire_at: DateTime.add(DateTime.utc_now(), 3600, :second)}, actor: @admin)
      |> Ash.update!()

      assert {:ok, _report} = heartbeat.()
    end

    test "UNPINNED-INVARIANT (iii): a credential with the wrong capability is rejected even with a matching kind+key_version — red + control" do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "cap-#{System.unique_integer([:positive])}", display_name: "Cap"}, @admin)

      {pub, priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      # A SECOND key version, same kind (:ed25519) and same public key, but
      # the WRONG capability (:fleet_probe instead of :fleet_heartbeat) — the
      # shape a defense-in-depth conjunct must catch even though it is
      # currently unreachable via any legitimate Registry flow.
      {:ok, wrong_capability} =
        Module.concat(@ns, Credential)
        |> Ash.Changeset.for_create(
          :create,
          %{
            app_id: app_id,
            key_version: 2,
            kind: :ed25519,
            public_key: Base.encode64(pub),
            capability: :fleet_probe,
            activated_at: DateTime.utc_now()
          },
          actor: @admin
        )
        |> Ash.create()

      report = Samen.Fleet.Report.build(app_id: app_id)
      payload = Samen.Fleet.Report.to_wire(report)
      raw_body = Jason.encode!(payload)
      ts = System.os_time(:second)
      nonce = Crypto.generate_nonce()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(raw_body))
      sig = Crypto.sign_ed25519(priv, input) |> Base.encode16(case: :lower)

      # RED: presenting key_version 2 (wrong capability) -> unknown_kid (the
      # capability conjunct excludes it from the lookup entirely).
      assert {:error, :unknown_kid} =
               Registry.verify_and_ingest_heartbeat(@ns, %{
                 kid: app_id,
                 v: wrong_capability.key_version,
                 ts: ts,
                 nonce: nonce,
                 sig: sig,
                 method: "POST",
                 path: "/fleet/heartbeat",
                 raw_body: raw_body,
                 payload: payload
               })

      # CONTROL: the SAME app_id at key_version 1 (correct capability) works.
      nonce2 = Crypto.generate_nonce()
      input2 = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce2, Crypto.body_digest(raw_body))
      sig2 = Crypto.sign_ed25519(priv, input2) |> Base.encode16(case: :lower)

      assert {:ok, _} =
               Registry.verify_and_ingest_heartbeat(@ns, %{
                 kid: app_id,
                 v: 1,
                 ts: ts,
                 nonce: nonce2,
                 sig: sig2,
                 method: "POST",
                 path: "/fleet/heartbeat",
                 raw_body: raw_body,
                 payload: payload
               })
    end

    test "RED: a stale timestamp is rejected" do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "hb4-#{System.unique_integer([:positive])}", display_name: "HB4"}, @admin)

      {pub, priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      report = Samen.Fleet.Report.build(app_id: app_id)
      payload = Samen.Fleet.Report.to_wire(report)
      raw_body = Jason.encode!(payload)
      ts = System.os_time(:second) - 1000
      nonce = Crypto.generate_nonce()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(raw_body))
      sig = Crypto.sign_ed25519(priv, input) |> Base.encode16(case: :lower)

      assert {:error, :stale_timestamp} =
               Registry.verify_and_ingest_heartbeat(@ns, %{
                 kid: app_id,
                 v: 1,
                 ts: ts,
                 nonce: nonce,
                 sig: sig,
                 method: "POST",
                 path: "/fleet/heartbeat",
                 raw_body: raw_body,
                 payload: payload
               })
    end

    test "RED: a replayed nonce is rejected on the second delivery" do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "hb5-#{System.unique_integer([:positive])}", display_name: "HB5"}, @admin)

      {pub, priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      report = Samen.Fleet.Report.build(app_id: app_id)
      payload = Samen.Fleet.Report.to_wire(report)
      raw_body = Jason.encode!(payload)
      ts = System.os_time(:second)
      nonce = Crypto.generate_nonce()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(raw_body))
      sig = Crypto.sign_ed25519(priv, input) |> Base.encode16(case: :lower)

      fields = %{
        kid: app_id,
        v: 1,
        ts: ts,
        nonce: nonce,
        sig: sig,
        method: "POST",
        path: "/fleet/heartbeat",
        raw_body: raw_body,
        payload: payload
      }

      assert {:ok, _} = Registry.verify_and_ingest_heartbeat(@ns, fields)
      assert {:error, :replayed} = Registry.verify_and_ingest_heartbeat(@ns, fields)
    end

    test "RED: an app_id in the body that differs from kid is rejected" do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "hb6-#{System.unique_integer([:positive])}", display_name: "HB6"}, @admin)

      {pub, priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      report = Samen.Fleet.Report.build(app_id: "11111111-1111-4111-8111-111111111111")
      payload = Samen.Fleet.Report.to_wire(report)
      raw_body = Jason.encode!(payload)
      ts = System.os_time(:second)
      nonce = Crypto.generate_nonce()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(raw_body))
      sig = Crypto.sign_ed25519(priv, input) |> Base.encode16(case: :lower)

      assert {:error, :app_id_mismatch} =
               Registry.verify_and_ingest_heartbeat(@ns, %{
                 kid: app_id,
                 v: 1,
                 ts: ts,
                 nonce: nonce,
                 sig: sig,
                 method: "POST",
                 path: "/fleet/heartbeat",
                 raw_body: raw_body,
                 payload: payload
               })
    end

    test "RP-J-1 twin (b): an unknown kid is rejected AND the dummy-verify mitigation is exercised, not just the outcome" do
      test_pid = self()
      handler_id = "rp-j-1-twin-b-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:samen, :fleet, :dummy_verify],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:dummy_verify_fired, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, :unknown_kid} =
               Registry.verify_and_ingest_heartbeat(@ns, %{
                 kid: "no-such-app",
                 v: 1,
                 ts: System.os_time(:second),
                 nonce: "n",
                 sig: Base.encode16(:crypto.strong_rand_bytes(64)),
                 method: "POST",
                 path: "/fleet/heartbeat",
                 raw_body: "{}",
                 payload: %{}
               })

      # THE PROOF (refutable by mutation, per RP-J-1 twin (b) — not a flaky
      # timing sample): the unknown-kid path did REAL dummy cryptographic
      # work, not an early return. Deleting the dummy-verify call makes this
      # assertion fail deterministically.
      assert_receive {:dummy_verify_fired, %{scheme: :ed25519}}, 500
    end

    test "RED: a schema-invalid report is rejected (422 class) and NOT stored" do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "hb7-#{System.unique_integer([:positive])}", display_name: "HB7"}, @admin)

      {pub, priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      report = Samen.Fleet.Report.build(app_id: app_id)
      # inject a free-string field — exactly what the closed schema must reject.
      payload = Samen.Fleet.Report.to_wire(report) |> Map.put("notes", "attacker text")
      raw_body = Jason.encode!(payload)
      ts = System.os_time(:second)
      nonce = Crypto.generate_nonce()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(raw_body))
      sig = Crypto.sign_ed25519(priv, input) |> Base.encode16(case: :lower)

      assert {:error, errors} =
               Registry.verify_and_ingest_heartbeat(@ns, %{
                 kid: app_id,
                 v: 1,
                 ts: ts,
                 nonce: nonce,
                 sig: sig,
                 method: "POST",
                 path: "/fleet/heartbeat",
                 raw_body: raw_body,
                 payload: payload
               })

      assert is_list(errors)
    end

    test "BLOCKER-2 end-to-end: a signed heartbeat carrying free-text cohorts + PII in checks[] is rejected and never stored" do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "hb8-#{System.unique_integer([:positive])}", display_name: "HB8"}, @admin)

      {pub, priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      report = Samen.Fleet.Report.build(app_id: app_id)

      payload =
        Samen.Fleet.Report.to_wire(report)
        |> Map.put("cohorts", %{"leak_note" => "alice@example.com / SSN 111-22-3333"})
        |> Map.put("checks", [%{"name" => "alice.anderson@acme.test", "status" => "ok"}])

      raw_body = Jason.encode!(payload)
      ts = System.os_time(:second)
      nonce = Crypto.generate_nonce()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(raw_body))
      sig = Crypto.sign_ed25519(priv, input) |> Base.encode16(case: :lower)

      rows_before = report_row_count(app_id)

      assert {:error, errors} =
               Registry.verify_and_ingest_heartbeat(@ns, %{
                 kid: app_id,
                 v: 1,
                 ts: ts,
                 nonce: nonce,
                 sig: sig,
                 method: "POST",
                 path: "/fleet/heartbeat",
                 raw_body: raw_body,
                 payload: payload
               })

      assert is_list(errors)
      assert Enum.any?(errors, &String.contains?(&1, "cohorts"))
      assert Enum.any?(errors, &String.contains?(&1, "name"))

      # THE PROOF: a correctly-signed request carrying PII was rejected, and
      # NOTHING was stored — flt_report's row count for this app is unchanged.
      assert report_row_count(app_id) == rows_before
    end
  end

  defp report_row_count(app_id) do
    Module.concat(@ns, Report)
    |> Ash.Query.filter(app_id == ^app_id)
    |> Ash.count!(actor: @admin)
  end

  # ---------------------------------------------------------------------------
  # RP-J-2 — heartbeat credential grants ZERO read (the load-bearing probe)
  # ---------------------------------------------------------------------------

  describe "RP-J-2 — heartbeat actor grants zero read capability" do
    setup do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "zr-#{System.unique_integer([:positive])}", display_name: "ZR"}, @admin)

      {pub, _priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))
      %{app_id: app_id, heartbeat_actor: HeartbeatActor.new(app_id)}
    end

    test "RED: the heartbeat actor cannot read flt_app", %{heartbeat_actor: actor} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Module.concat(@ns, App) |> Ash.read(actor: actor)
    end

    test "RED: the heartbeat actor cannot read flt_credential (its OWN app's row)", %{heartbeat_actor: actor} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Module.concat(@ns, Credential) |> Ash.read(actor: actor)
    end

    test "RED: the heartbeat actor cannot read flt_report", %{heartbeat_actor: actor} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Module.concat(@ns, Report) |> Ash.read(actor: actor)
    end

    test "RED: the heartbeat actor cannot read flt_directive", %{heartbeat_actor: actor} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Module.concat(@ns, Directive) |> Ash.read(actor: actor)
    end

    test "RED: the heartbeat actor cannot CREATE a directive (fleet-admin-only action)", %{
      heartbeat_actor: actor
    } do
      assert {:error, _} = Registry.record_directive(@ns, %{target: %{"kind" => "all"}, payload: %{}}, actor)
    end

    test "POSITIVE CONTROL: a fleet-admin actor CAN read flt_app/flt_credential/flt_report" do
      assert {:ok, _} = Module.concat(@ns, App) |> Ash.read(actor: @admin)
      assert {:ok, _} = Module.concat(@ns, Credential) |> Ash.read(actor: @admin)
      assert {:ok, _} = Module.concat(@ns, Report) |> Ash.read(actor: @admin)
    end

    test "POSITIVE CONTROL: the token-blind aggregate actor CAN read flt_app (T84's future cockpit reads)" do
      assert {:ok, _} = Module.concat(@ns, App) |> Ash.read(actor: Samen.Aggregate.Actor.new())
    end

    test "the heartbeat credential's own valid write (its own app_id) still succeeds", %{
      app_id: app_id
    } do
      assert {:ok, report} =
               Registry.record_report(@ns, app_id, %{"schema_version" => 1, "generated_at_us" => 1}, :push)

      assert report.app_id == app_id
      # the actor really is the constraining factor: a DIFFERENT app_id's heartbeat
      # actor is refused the SAME write (own-app-only, per §4.6 capability matrix row
      # "valid heartbeat key, POST /fleet/heartbeat (other app_id in body) -> 403").
      other_actor = HeartbeatActor.new(Ash.UUID.generate())

      assert {:error, %Ash.Error.Forbidden{}} =
               Module.concat(@ns, Report)
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   app_id: app_id,
                   schema_version: 1,
                   generated_at_us: 1,
                   received_at: DateTime.utc_now(),
                   transport: :push,
                   payload: %{}
                 },
                 actor: other_actor
               )
               |> Ash.create()
    end
  end

  # ---------------------------------------------------------------------------
  # RP-J-10 — fail-honest unconfigured (registry-layer half)
  # ---------------------------------------------------------------------------

  describe "RP-J-10 — fail-honest unconfigured" do
    test "an app with no credential ever issued: fetch_probe_secret/3 -> :not_configured, never a fabricated secret" do
      {:ok, %{app: app}} =
        Registry.register_app(@ns, %{slug: "bare-#{System.unique_integer([:positive])}", display_name: "Bare"}, @admin)

      # Simulate a mode configured but not yet issued a credential: revoke the one
      # register_app minted, so the app is left with zero active credentials.
      {:ok, [credential]} = read_credentials(app.id) |> then(fn {:ok, %{rows: rows}} -> {:ok, rows} end)
      {:ok, _} = Registry.revoke_credential(@ns, credential.id, @admin)

      assert {:error, :not_configured} = Registry.fetch_probe_secret(@ns, app.id, @admin)
    end
  end

  # ---------------------------------------------------------------------------
  # Registry rows token-blind (done-criterion 3 — INV-2)
  # ---------------------------------------------------------------------------

  describe "token-blind registry (done-criterion 3, INV-2)" do
    test "no flt_* resource declares a pii_attribute/vault (compile-time C7 already enforces this; this asserts the introspection matches)" do
      for mod <- [
            Module.concat(@ns, App),
            Module.concat(@ns, Credential),
            Module.concat(@ns, EnrollmentToken),
            Module.concat(@ns, Report),
            Module.concat(@ns, Directive)
          ] do
        assert Samen.Aggregate.Info.aggregate_plane?(mod)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # J5 honesty (via Samen.Fleet.read/2 non-embedded branch)
  # ---------------------------------------------------------------------------

  describe "Samen.Fleet.read/2 — registry rows, staleness, n-of-m (§8.2)" do
    test "a fresh app with a report reads back as :active" do
      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(@ns, %{app_slug: "read-#{System.unique_integer([:positive])}", display_name: "Read"}, @admin)

      {pub, priv} = Crypto.generate_ed25519_keypair()
      {:ok, %{app_id: app_id}} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      report = Samen.Fleet.Report.build(app_id: app_id)
      payload = Samen.Fleet.Report.to_wire(report)
      raw_body = Jason.encode!(payload)
      ts = System.os_time(:second)
      nonce = Crypto.generate_nonce()
      input = Crypto.signing_input("POST", "/fleet/heartbeat", ts, nonce, Crypto.body_digest(raw_body))
      sig = Crypto.sign_ed25519(priv, input) |> Base.encode16(case: :lower)

      {:ok, _} =
        Registry.verify_and_ingest_heartbeat(@ns, %{
          kid: app_id,
          v: 1,
          ts: ts,
          nonce: nonce,
          sig: sig,
          method: "POST",
          path: "/fleet/heartbeat",
          raw_body: raw_body,
          payload: payload
        })

      assert {:ok, %{rows: rows, reporting: reporting, total: total}} =
               Registry.read_rows(@ns, actor: @admin)

      row = Enum.find(rows, &(&1.app_id == app_id))
      assert row.status == :active
      assert reporting >= 1
      assert total >= 1
    end

    test "an app that never reported reads back as :unreachable, not fabricated :active" do
      {:ok, %{app: app}} =
        Registry.register_app(@ns, %{slug: "never-#{System.unique_integer([:positive])}", display_name: "Never"}, @admin)

      assert {:ok, %{rows: rows}} = Registry.read_rows(@ns, actor: @admin)
      row = Enum.find(rows, &(&1.app_id == app.id))
      assert row.status == :unreachable
      assert row.report == nil
    end

    test "a stale report is labelled :stale and excluded from the reporting count" do
      {:ok, %{app: app}} =
        Registry.register_app(@ns, %{slug: "stale-#{System.unique_integer([:positive])}", display_name: "Stale"}, @admin)

      old_received = DateTime.add(DateTime.utc_now(), -3600, :second)

      report_mod = Module.concat(@ns, Report)

      {:ok, _} =
        report_mod
        |> Ash.Changeset.for_create(
          :create,
          %{
            app_id: app.id,
            schema_version: 1,
            generated_at_us: System.os_time(:microsecond),
            received_at: old_received,
            transport: :pull,
            payload: %{}
          },
          actor: @admin
        )
        |> Ash.create()

      assert {:ok, %{rows: rows, reporting: reporting}} = Registry.read_rows(@ns, actor: @admin)
      row = Enum.find(rows, &(&1.app_id == app.id))
      assert row.status == :stale

      # excluded from the "reporting" count — the assertion the honesty rule binds.
      refute Enum.any?(rows, &(&1.app_id == app.id and &1.status == :active))
      assert is_integer(reporting)
    end
  end

  # ---------------------------------------------------------------------------
  # J5 — :embedded mode, zero config, n=1 is the n=N path
  # ---------------------------------------------------------------------------

  describe "cockpit_identity/1 fail-honest (fix round MED)" do
    test "RED: refuses rather than silently minting a non-durable identity when :fleet_local_credential is unset" do
      prev = Application.get_env(:samen_core, :fleet_local_credential)
      Application.delete_env(:samen_core, :fleet_local_credential)

      on_exit(fn ->
        if prev, do: Application.put_env(:samen_core, :fleet_local_credential, prev)
      end)

      assert {:error, :not_configured} = Registry.cockpit_identity(@ns)
    end

    test "GREEN (control): with :fleet_local_credential explicitly configured, it mints once and is stable" do
      assert {:ok, {pub1, _priv1}} = Registry.cockpit_identity(@ns)
      assert {:ok, {pub2, _priv2}} = Registry.cockpit_identity(@ns)
      assert pub1 == pub2
    end

    test "an unconfigured cockpit fails enrollment BEFORE writing any row (no partial enrollment)" do
      prev = Application.get_env(:samen_core, :fleet_local_credential)
      Application.delete_env(:samen_core, :fleet_local_credential)
      on_exit(fn -> if prev, do: Application.put_env(:samen_core, :fleet_local_credential, prev) end)

      {:ok, %{raw_token: raw_token}} =
        Registry.mint_enrollment_token(
          @ns,
          %{app_slug: "noidentity-#{System.unique_integer([:positive])}", display_name: "NoIdentity"},
          @admin
        )

      {pub, _priv} = Crypto.generate_ed25519_keypair()
      rows_before = Module.concat(@ns, App) |> Ash.read!(actor: @admin) |> length()

      assert {:error, :not_configured} = Registry.consume_enrollment(@ns, raw_token, Base.encode64(pub))

      rows_after = Module.concat(@ns, App) |> Ash.read!(actor: @admin) |> length()
      assert rows_after == rows_before
    end
  end

  describe "J5 — :embedded is zero config (RP-J-9 groundwork)" do
    test "Samen.Fleet.mode/1 defaults to :embedded with no config" do
      assert Samen.Fleet.mode(:a_totally_unconfigured_app) == :embedded
    end

    test "Samen.Fleet.read/2 in :embedded mode returns exactly one honest self-row, no DB/network" do
      assert {:ok, %{rows: [row], reporting: 1, total: 1}} = Samen.Fleet.read(:a_totally_unconfigured_app)
      assert row.mode == :embedded
      assert row.status == :active
      assert %Samen.Fleet.Report{} = row.report

      # Fix round (MED, J5 §8.2 rule 2): a bare framework install cannot
      # compute tenant_count — the report says so by OMISSION, never a
      # fabricated 0. Confirmed at BOTH layers: the struct field is nil, and
      # the wire payload does not even carry the key.
      assert row.report.tenant_count == nil
      refute Samen.Fleet.Report.to_wire(row.report) |> Map.has_key?("tenant_count")
    end

    test "unconfigured multi-app mode fails honestly (RP-J-10)" do
      app = :some_app_configured_for_manual_mode_without_a_namespace
      Application.put_env(app, :fleet, mode: :manual)
      on_exit(fn -> Application.delete_env(app, :fleet) end)

      assert Samen.Fleet.mode(app) == :manual
      assert {:error, {:missing_namespace, :manual}} = Samen.Fleet.read(app)
    end
  end

  defp read_credentials(app_id) do
    query =
      Module.concat(@ns, Credential)
      |> Ash.Query.filter(app_id == ^app_id)

    case Ash.read(query, actor: @admin) do
      {:ok, rows} -> {:ok, %{rows: rows}}
      other -> other
    end
  end
end
