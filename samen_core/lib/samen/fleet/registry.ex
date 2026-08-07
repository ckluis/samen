defmodule Samen.Fleet.Registry do
  @moduledoc """
  The **cockpit-side** registry kernel (ADR-044 §4, WS-J J1) — operates over the
  five `flt_*` resources of a `Samen.Fleet.Scope`-mounted `namespace` (an Ash
  domain module, e.g. `SamenCore.Support.FleetFixture`). Every function derives its
  resource modules via `Module.concat(namespace, X)`.

  **Placement note.** This module is COCKPIT-side only. The APP-side (reporting
  side) credential verification for `GET /fleet/health` / `POST /fleet/directive`
  never touches this module or the `flt_*` tables — it verifies against
  `Samen.Fleet.LocalCredential` (what THIS app holds about itself). See that
  module's moduledoc for the split.

  Admin-gated mutations (register/deregister an app, issue/rotate/revoke a
  credential, mint an enrollment token, record a directive) take an `actor` and run
  it through the real Ash policy stack (`Samen.Policy.FleetAdminOnly`) — no
  `authorize?: false` bypass. The token-consuming enroll transaction and the
  credential-verified heartbeat ingest run with the atomic match / verified
  credential AS the authorization event (ADR-035 §4.2 pattern), exactly like
  `Samen.Auth.TokenConsume`/`Samen.Identity.Register`.
  """

  alias Samen.Fleet.{Crypto, HeartbeatActor, NonceCache}

  require Ash.Query

  @default_stale_after_s 300
  @default_retire_s 86_400
  @default_heartbeat_interval_s 60
  @enrollment_ttl_s 86_400

  # ---------------------------------------------------------------------------
  # Resource resolution
  # ---------------------------------------------------------------------------

  defp app_res(ns), do: Module.concat(ns, App)
  defp credential_res(ns), do: Module.concat(ns, Credential)
  defp token_res(ns), do: Module.concat(ns, EnrollmentToken)
  defp report_res(ns), do: Module.concat(ns, Report)
  defp directive_res(ns), do: Module.concat(ns, Directive)

  # ---------------------------------------------------------------------------
  # Mode A — manual registration + shared-secret handshake (§4.2)
  # ---------------------------------------------------------------------------

  @doc """
  Register an app in mode A. Mints a 32-random-byte shared secret, returns it
  ONCE, and stores it KMS-wrapped (never plaintext). `actor` must be an admitted
  `Samen.Fleet.AdminActor` — enforced by `Samen.Policy.FleetAdminOnly` (a real
  policy check, not a bypass).
  """
  @spec register_app(module(), map(), term()) :: {:ok, map()} | {:error, term()}
  def register_app(ns, %{slug: slug, display_name: display_name} = attrs, actor) do
    with {:ok, app} <-
           app_res(ns)
           |> Ash.Changeset.for_create(
             :create,
             %{
               slug: slug,
               display_name: display_name,
               mode: :manual,
               base_url: Map.get(attrs, :base_url),
               status: :active,
               registered_at: DateTime.utc_now(),
               stale_after_s: Map.get(attrs, :stale_after_s, @default_stale_after_s)
             },
             actor: actor
           )
           |> Ash.create(),
         {:ok, %{credential: credential, raw_secret: raw_secret}} <-
           issue_probe_credential(ns, app.id, actor) do
      {:ok, %{app: app, credential: credential, raw_secret: raw_secret}}
    end
  end

  @doc """
  Issue (or re-issue, key_version+1) a mode-A `:fleet_probe` shared secret for
  `app_id`. Two writes (create then update the ciphertext): the KMS-wrap subject
  is `"flt:credential:<app_id>:<credential_id>"`, and `credential_id` is only
  known once Ash has minted it — there is no earlier point at which the subject
  could be computed.
  """
  @spec issue_probe_credential(module(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def issue_probe_credential(ns, app_id, actor) do
    key_version = next_key_version(ns, app_id, actor)
    raw_secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    with {:ok, credential} <-
           credential_res(ns)
           |> Ash.Changeset.for_create(
             :create,
             %{
               app_id: app_id,
               key_version: key_version,
               kind: :shared_secret,
               capability: :fleet_probe,
               activated_at: DateTime.utc_now()
             },
             actor: actor
           )
           |> Ash.create(),
         {:ok, wrapped} <- wrap_secret(credential_subject(app_id, credential.id), raw_secret),
         {:ok, updated} <-
           credential
           |> Ash.Changeset.for_update(:update, %{secret_ciphertext: wrapped}, actor: actor)
           |> Ash.update() do
      {:ok, %{credential: updated, raw_secret: raw_secret}}
    end
  end

  @doc """
  Operator-issued rotation (§4.5 — "No renew-in-place"): mint `key_version+1`,
  set the CURRENT active credential's `retire_at` (default 24h overlap), then a
  standing sweep (T84/ops) revokes it once `retire_at` passes. There is no
  app-initiated rotate verb (ADR §4.5 — deliberately not built).
  """
  @spec rotate_probe_credential(module(), String.t(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def rotate_probe_credential(ns, app_id, actor, opts \\ []) do
    retire_s = Keyword.get(opts, :retire_after_s, @default_retire_s)

    with {:ok, current} <- current_credential(ns, app_id, :fleet_probe, actor),
         {:ok, _retired} <-
           current
           |> Ash.Changeset.for_update(
             :update,
             %{retire_at: DateTime.add(DateTime.utc_now(), retire_s, :second)},
             actor: actor
           )
           |> Ash.update() do
      issue_probe_credential(ns, app_id, actor)
    end
  end

  @doc "Revoke a credential — deny-on-use, re-checked per request (§4.5)."
  @spec revoke_credential(module(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def revoke_credential(ns, credential_id, actor) do
    with {:ok, credential} <- Ash.get(credential_res(ns), credential_id, actor: actor) do
      credential
      |> Ash.Changeset.for_update(:update, %{revoked_at: DateTime.utc_now()}, actor: actor)
      |> Ash.update()
    end
  end

  @doc "Register/list/deregister — the plain CRUD half of §4."
  @spec list_apps(module(), term()) :: {:ok, [map()]} | {:error, term()}
  def list_apps(ns, actor) do
    case app_res(ns) |> Ash.read(actor: actor) do
      {:ok, apps} -> {:ok, apps}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_app(module(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def get_app(ns, app_id, actor), do: Ash.get(app_res(ns), app_id, actor: actor)

  @spec deregister_app(module(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def deregister_app(ns, app_id, actor) do
    with {:ok, app} <- get_app(ns, app_id, actor) do
      app
      |> Ash.Changeset.for_update(:update, %{status: :deregistered}, actor: actor)
      |> Ash.update()
    end
  end

  @doc """
  Verify an inbound mode-A pull/directive request against `app_id`'s CURRENT
  `:fleet_probe` credential — the COCKPIT-side symmetric-secret check
  (`kid` = `app_id`). Returns `{:ok, shared_secret}` or
  `{:error, :unknown_kid | :revoked | :retired | :bad_signature}`. The
  unknown-`kid` dummy-verify is performed by the CALLER (this returns
  `:unknown_kid` immediately when no credential row exists; the caller is
  responsible for still calling `Samen.Fleet.Crypto.dummy_verify_hmac/1` so the
  branch costs the same wall-clock — §4.4).
  """
  @spec fetch_probe_secret(module(), String.t(), term()) :: {:ok, binary()} | {:error, term()}
  def fetch_probe_secret(ns, app_id, actor) do
    with {:ok, credential} <- current_credential(ns, app_id, :fleet_probe, actor) do
      unwrap_secret(credential_subject(app_id, credential.id), credential.secret_ciphertext)
    end
  end

  # ---------------------------------------------------------------------------
  # Mode B — opt-in self-registration + heartbeat (§4.3)
  # ---------------------------------------------------------------------------

  @doc "Mint a single-use enrollment token (ADR-035 §4.2 verbatim, §4.3 step 1)."
  @spec mint_enrollment_token(module(), map(), term()) :: {:ok, map()} | {:error, term()}
  def mint_enrollment_token(ns, %{app_slug: slug, display_name: display_name}, actor) do
    raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    digest = Samen.Auth.TokenMint.digest(raw_token)
    expires_at = DateTime.add(DateTime.utc_now(), @enrollment_ttl_s, :second)

    with {:ok, token} <-
           token_res(ns)
           |> Ash.Changeset.for_create(
             :create,
             %{
               token_digest: digest,
               app_slug: slug,
               display_name: display_name,
               expires_at: expires_at
             },
             actor: actor
           )
           |> Ash.create() do
      {:ok, %{token: token, raw_token: raw_token}}
    end
  end

  @doc """
  Consume an enrollment token + mint the app's mode-B credential (§4.3 step 3).
  `raw_token` + `public_key` (base64, the app's OWN newly-generated Ed25519
  public key) come off the wire — everything else (`slug`/`display_name`) is
  read from the CONSUMED TOKEN, never the request body (§4.3, §5.2: "identity
  comes from the token, never from the request").

  Atomic single-use consume mirrors `Samen.Auth.TokenConsume.consume_once/3`
  exactly: one `UPDATE ... WHERE token_digest = $1 AND consumed_at IS NULL AND
  expires_at > now() RETURNING`. Zero rows ⇒ one generic `{:error, :invalid_token}`
  (never distinguishing consumed vs expired vs unknown).
  """
  @spec consume_enrollment(module(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :invalid_token | term()}
  def consume_enrollment(ns, raw_token, public_key_b64) when is_binary(raw_token) do
    digest = Samen.Auth.TokenMint.digest(raw_token)
    now = DateTime.utc_now()

    result =
      token_res(ns)
      |> Ash.Query.filter(token_digest == ^digest and is_nil(consumed_at) and expires_at > ^now)
      |> Ash.bulk_update(:consume, %{consumed_at: now},
        authorize?: false,
        strategy: [:atomic],
        return_records?: true,
        return_errors?: true
      )

    case result do
      %Ash.BulkResult{status: :success, records: [token | _]} ->
        finish_enrollment(ns, token, public_key_b64)

      _ ->
        {:error, :invalid_token}
    end
  end

  defp finish_enrollment(ns, token, public_key_b64) do
    # cockpit_identity/1 is checked FIRST, before any row is written: it can
    # now fail-honestly ({:error, :not_configured} — fix round MED), and an
    # enrollment must not half-complete (token consumed, app+credential rows
    # written) only to fail on the response the caller actually needs.
    with {:ok, {cockpit_pub, _priv}} <- cockpit_identity(ns),
         {:ok, app} <-
           app_res(ns)
           |> Ash.Changeset.for_create(
             :create,
             %{
               slug: token.app_slug,
               display_name: token.display_name,
               mode: :heartbeat,
               status: :active,
               registered_at: DateTime.utc_now(),
               stale_after_s: @default_stale_after_s
             },
             authorize?: false
           )
           |> Ash.create(),
         {:ok, _} <-
           token
           |> Ash.Changeset.for_update(:record_consumed_app, %{consumed_app_id: app.id},
             authorize?: false
           )
           |> Ash.update(),
         {:ok, _credential} <-
           credential_res(ns)
           |> Ash.Changeset.for_create(
             :create,
             %{
               app_id: app.id,
               key_version: 1,
               kind: :ed25519,
               public_key: public_key_b64,
               capability: :fleet_heartbeat,
               activated_at: DateTime.utc_now()
             },
             authorize?: false
           )
           |> Ash.create() do
      {:ok,
       %{
         app_id: app.id,
         cockpit_public_key: Base.encode64(cockpit_pub),
         heartbeat_interval_s: @default_heartbeat_interval_s,
         stale_after_s: @default_stale_after_s
       }}
    end
  end

  @doc """
  This cockpit's OWN Ed25519 identity — generated ONCE and persisted via
  `Samen.Fleet.LocalCredential` (keyed on the cockpit's `namespace`), reused for
  every enroll response + every mode-B directive push. Returns
  `{:ok, {public_key, private_key}}` or `{:error, :not_configured}`.

  ## Fail-honest fix (fix round, MED — the `Samen.Files.Storage.S3`/
  `Samen.Delivery.Smtp` class)

  This function used to mint a fresh keypair into the DEFAULT
  `Samen.Fleet.LocalCredential.Agent` implementation whenever nothing had been
  stored yet — but that implementation's own moduledoc says "not durable
  across a BEAM restart". A production cockpit that never explicitly
  configured `:fleet_local_credential` would therefore mint a NEW identity on
  every restart and hand the new public key to every future enroll response,
  while every PREVIOUSLY enrolled app still holds the OLD `cockpit_public_key`
  — cockpit→app directive verification then fails silently, forever, with no
  error anywhere. That is exactly the lie CLAUDE.md's fail-honest rule
  forbids: a stub claiming durable success for work it did not durably do.

  Now it refuses (`{:error, :not_configured}`) unless the host has
  EXPLICITLY set `config :samen_core, :fleet_local_credential, SomeModule` —
  checked directly (not through `LocalCredential.impl/0`'s own default, which
  exists for the OTHER, deliberately-optional app-side credential path). A
  test/dev host opts in explicitly, the same way `Samen.Delivery.FakeProvider`
  is explicitly wired rather than silently defaulted to.
  """
  @spec cockpit_identity(module()) :: {:ok, {binary(), binary()}} | {:error, :not_configured}
  def cockpit_identity(ns) do
    case Application.get_env(:samen_core, :fleet_local_credential) do
      nil ->
        {:error, :not_configured}

      _explicitly_configured ->
        host = cockpit_local_host(ns)

        case Samen.Fleet.LocalCredential.fetch(host) do
          {:ok, %{kind: :ed25519_cockpit, public_key: pub, private_key: priv}} ->
            {:ok, {pub, priv}}

          {:error, :not_configured} ->
            {pub, priv} = Crypto.generate_ed25519_keypair()

            :ok =
              Samen.Fleet.LocalCredential.put(host, %{
                kind: :ed25519_cockpit,
                public_key: pub,
                private_key: priv
              })

            {:ok, {pub, priv}}
        end
    end
  end

  defp cockpit_local_host(ns), do: Module.concat(ns, :__fleet_cockpit_identity__)

  @doc """
  Verify + ingest a mode-B heartbeat (§4.3 step 4). `fields` carries the parsed
  `Samen-Fleet-v1` header (`kid` = `app_id`, `v` = key_version, `ts`, `nonce`,
  `sig`) plus `method`/`path`/`raw_body` and the DECODED JSON `payload` (with a
  top-level `app_id` the caller extracts pre-verify, for the §4.6 app_id-mismatch
  check).

  Returns `{:ok, report}` | `{:error, reason}` where `reason` is one of
  `:unknown_kid | :revoked | :retired | :bad_signature | :stale_timestamp |
  :replayed | :app_id_mismatch | {:invalid_schema, [String.t()]}`. On EVERY
  error path this function itself never writes anything — a malformed/forged
  report is never stored (§5.2 point 4 / RP-J-3/RP-J-10).
  """
  @spec verify_and_ingest_heartbeat(module(), map()) :: {:ok, map()} | {:error, term()}
  def verify_and_ingest_heartbeat(ns, fields) do
    %{kid: kid, v: v, ts: ts, nonce: nonce, sig: sig, method: method, path: path, raw_body: raw_body} =
      fields

    signing_input = Crypto.signing_input(method, path, ts, nonce, Crypto.body_digest(raw_body))

    with {:ok, credential} <- lookup_current_heartbeat_credential(ns, kid, v, signing_input),
         :ok <- verify_heartbeat_signature(credential, signing_input, sig),
         true <- Crypto.fresh_timestamp?(ts) || {:error, :stale_timestamp},
         :ok <- NonceCache.check_and_put(kid, nonce),
         {:ok, payload} <- fetch_payload(fields),
         :ok <- app_id_matches?(payload, kid),
         :ok <- Samen.Fleet.Report.validate_wire(payload) do
      record_report(ns, kid, payload, :push)
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :bad_signature}
    end
  end

  defp fetch_payload(%{payload: payload}) when is_map(payload), do: {:ok, payload}
  defp fetch_payload(_), do: {:error, :malformed_payload}

  defp app_id_matches?(%{"app_id" => app_id}, kid) when app_id == kid, do: :ok
  defp app_id_matches?(_, _), do: {:error, :app_id_mismatch}

  defp lookup_current_heartbeat_credential(ns, kid, v, signing_input) do
    query =
      credential_res(ns)
      |> Ash.Query.filter(
        app_id == ^kid and key_version == ^v and kind == :ed25519 and
          capability == :fleet_heartbeat and is_nil(revoked_at)
      )

    case Ash.read(query, authorize?: false) do
      {:ok, [credential]} ->
        cond do
          not_nil_and_passed?(credential.retire_at) -> {:error, :retired}
          true -> {:ok, credential}
        end

      _ ->
        # Timing-oracle mitigation (§4.4): do the SAME shape of work as a
        # known-kid-bad-signature path before returning.
        _ = Crypto.dummy_verify_ed25519(signing_input)
        {:error, :unknown_kid}
    end
  end

  defp not_nil_and_passed?(nil), do: false
  defp not_nil_and_passed?(%DateTime{} = dt), do: DateTime.compare(dt, DateTime.utc_now()) == :lt

  defp verify_heartbeat_signature(credential, signing_input, sig_hex) do
    with {:ok, sig} <- Base.decode16(sig_hex, case: :mixed),
         pub <- Base.decode64!(credential.public_key),
         true <- Crypto.verify_ed25519(pub, signing_input, sig) do
      :ok
    else
      _ -> {:error, :bad_signature}
    end
  end

  # ---------------------------------------------------------------------------
  # Reports (§4.7, §8.2) — shared write chokepoint for :pull and :push transports.
  # ---------------------------------------------------------------------------

  @doc """
  Store a schema-VALID report. Callers MUST validate via
  `Samen.Fleet.Report.Schema.validate/1` BEFORE calling this (both
  `verify_and_ingest_heartbeat/2` and a future `:pull` scheduler do) — this
  function does not re-validate, so it is only ever reached with a conforming
  payload (a non-conforming payload never gets this far — §5.2 point 4).
  """
  @spec record_report(module(), String.t(), map(), :pull | :push) ::
          {:ok, map()} | {:error, term()}
  def record_report(ns, app_id, payload, transport) do
    actor = if transport == :push, do: HeartbeatActor.new(app_id), else: nil

    report_res(ns)
    |> Ash.Changeset.for_create(
      :create,
      %{
        app_id: app_id,
        schema_version: Map.get(payload, "schema_version", 1),
        generated_at_us: Map.get(payload, "generated_at_us", System.os_time(:microsecond)),
        received_at: DateTime.utc_now(),
        transport: transport,
        payload: payload
      },
      actor: actor,
      authorize?: not is_nil(actor)
    )
    |> Ash.create()
  end

  # ---------------------------------------------------------------------------
  # Directives (§4.1 storage only — §7 fan-out engine is T84's)
  # ---------------------------------------------------------------------------

  @spec record_directive(module(), map(), term()) :: {:ok, map()} | {:error, term()}
  def record_directive(ns, %{target: target, payload: payload}, actor) do
    directive_res(ns)
    |> Ash.Changeset.for_create(
      :create,
      %{
        fleet_revision: next_fleet_revision(ns, actor),
        target: target,
        payload: payload,
        published_by: actor_id(actor),
        published_at: DateTime.utc_now()
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp next_fleet_revision(ns, actor) do
    case directive_res(ns) |> Ash.read(actor: actor) do
      {:ok, []} -> 1
      {:ok, directives} -> (directives |> Enum.map(& &1.fleet_revision) |> Enum.max()) + 1
      _ -> 1
    end
  end

  defp actor_id(%Samen.Fleet.AdminActor{principal_id: id}), do: id
  defp actor_id(_), do: "unknown"

  # ---------------------------------------------------------------------------
  # Fleet-wide read (Samen.Fleet.read/2's non-embedded branch, §8.2)
  # ---------------------------------------------------------------------------

  @doc """
  The registry rows for a cockpit `namespace` — J5 honesty rules 3/6 applied
  cockpit-side: staleness from `received_at` (never the producer's
  `generated_at_us`, §4.6), a revoked/deregistered app's last report EXCLUDED
  from `reporting` (never silently retained, never silently dropped from the
  row list — rule 6).
  """
  @spec read_rows(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_rows(ns, opts) do
    actor = Keyword.get(opts, :actor, Samen.Aggregate.Actor.new())

    with {:ok, apps} <- app_res(ns) |> Ash.read(actor: actor) do
      rows = Enum.map(apps, &build_row(ns, &1, actor))
      reporting = Enum.count(rows, &(&1.status in [:active]))
      {:ok, %{rows: rows, reporting: reporting, total: length(rows)}}
    end
  end

  defp build_row(ns, app, actor) do
    latest = latest_report(ns, app.id, actor)
    now = DateTime.utc_now()

    status =
      cond do
        app.status == :deregistered -> :deregistered
        app.status == :suspended -> :revoked
        is_nil(latest) -> :unreachable
        stale?(latest.received_at, app.stale_after_s, now) -> :stale
        true -> :active
      end

    %{
      app_id: app.id,
      slug: app.slug,
      display_name: app.display_name,
      mode: app.mode,
      status: status,
      transport: latest && latest.transport,
      received_at: latest && latest.received_at,
      stale_after_s: app.stale_after_s,
      report: latest && latest.payload
    }
  end

  defp stale?(received_at, stale_after_s, now) do
    DateTime.diff(now, received_at, :second) > stale_after_s
  end

  defp latest_report(ns, app_id, actor) do
    query =
      report_res(ns)
      |> Ash.Query.filter(app_id == ^app_id)
      |> Ash.Query.sort(received_at: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, actor: actor) do
      {:ok, [report]} -> report
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Internal — KMS wrap/unwrap for the mode-A shared secret
  # ---------------------------------------------------------------------------

  defp credential_subject(app_id, credential_id), do: "flt:credential:#{app_id}:#{credential_id}"

  # Uses Samen.Fleet.Crypto.wrap_credential/2 — a DELIBERATE second AEAD, never
  # Samen.Kms.Crypto.decrypt/2 (Samen.Chokepoint's single-decrypt invariant is
  # Samen.Vault's alone; see Samen.Fleet.Crypto's moduledoc).
  defp wrap_secret(subject, plaintext) do
    kms = Samen.Kms.adapter()

    with {:ok, _wrapped_dek} <- kms.generate_subject_key(subject),
         {:ok, dek} <- kms.unwrap(subject) do
      {:ok, Crypto.wrap_credential(dek, plaintext) |> Base.encode64()}
    end
  end

  defp unwrap_secret(subject, ciphertext_b64) do
    kms = Samen.Kms.adapter()

    with {:ok, dek} <- kms.unwrap(subject),
         {:ok, blob} <- Base.decode64(ciphertext_b64),
         {:ok, plaintext} <- Crypto.unwrap_credential(dek, blob) do
      {:ok, plaintext}
    else
      :error -> {:error, :decrypt_failed}
      other -> other
    end
  end

  defp current_credential(ns, app_id, capability, actor) do
    query =
      credential_res(ns)
      |> Ash.Query.filter(app_id == ^app_id and capability == ^capability and is_nil(revoked_at))
      |> Ash.Query.sort(key_version: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, actor: actor) do
      {:ok, [credential]} -> {:ok, credential}
      {:ok, []} -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_key_version(ns, app_id, actor) do
    query = credential_res(ns) |> Ash.Query.filter(app_id == ^app_id)

    case Ash.read(query, actor: actor) do
      {:ok, []} -> 1
      {:ok, credentials} -> (credentials |> Enum.map(& &1.key_version) |> Enum.max()) + 1
      _ -> 1
    end
  end
end
