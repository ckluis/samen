defmodule Samen.Auth.SessionCreate do
  @moduledoc """
  ADR-035 §4.3/§5 A4 — mint a fresh `Identity.Session` row for a just-authenticated
  credential. Mirrors the `Samen.Auth.TokenMint` discipline (32 random bytes,
  URL-safe base64; the RAW token is handed back ONCE and never persisted — only
  its SHA-256 digest lands on the row), extended with the session-specific rules
  §4.3 assigns:

    * **Sliding 60-day expiry** — EVERY session row gets `expires_at = now + 60
      days` at create (and slides again on `Samen.Auth.SessionResolve.touch/2`).
      The remember-me/ordinary-sign-in distinction lives entirely in which
      COOKIES the web layer writes (`samen_web`'s job) — not in this row's
      lifetime; both cookies name the SAME row (one list entry, one revocation).
    * **Org-level concurrent-session cap (spec-questions c3)** — OPTIONAL, `nil`
      by default (unlimited). When any org the credential belongs to (via
      Membership → User → Credential) sets `Org.max_concurrent_sessions`, the
      MOST RESTRICTIVE (smallest) non-nil cap across those orgs governs; at
      create time, the credential's oldest live sessions are evicted (revoked)
      so the post-create live count never exceeds the cap.
  """

  require Ash.Query

  alias Samen.Auth.TokenMint

  @default_ttl_seconds 60 * 24 * 60 * 60

  @type mods :: %{
          required(:session) => module(),
          required(:org) => module(),
          required(:membership) => module(),
          required(:user) => module()
        }

  @doc "The default (and, today, only) session sliding TTL — 60 days, in seconds."
  @spec default_ttl_seconds() :: pos_integer()
  def default_ttl_seconds, do: @default_ttl_seconds

  @doc """
  Mint a fresh live `Identity.Session` row for `credential_id`. `opts`:

    * `:device_label` — a bounded label already derived by `Samen.Auth.DeviceLabel`
      (this module never sees/stores a raw user-agent).
    * `:ttl_seconds` — override the default 60-day sliding window (tests only).

  Enforces the org-level concurrent-session cap (eviction) BEFORE minting, so
  the new session never itself gets evicted. Returns `{:ok, session, raw_token}`
  — the RAW token is returned exactly once; only its digest is persisted.
  """
  @spec create(mods(), String.t(), keyword()) :: {:ok, term(), String.t()} | {:error, term()}
  def create(%{} = mods, credential_id, opts \\ []) when is_binary(credential_id) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    device_label = Keyword.get(opts, :device_label)

    case org_session_cap(mods, credential_id) do
      nil -> :ok
      cap -> evict_to_cap(mods.session, credential_id, cap)
    end

    raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    expires_at = DateTime.utc_now() |> DateTime.add(ttl_seconds, :second)

    result =
      mods.session
      |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:credential_id, credential_id)
      |> Ash.Changeset.force_change_attribute(:token_digest, TokenMint.digest(raw_token))
      |> Ash.Changeset.force_change_attribute(:expires_at, expires_at)
      |> Ash.Changeset.force_change_attribute(:device_label, device_label)
      |> Ash.Changeset.force_change_attribute(:revoked_at, nil)
      |> Ash.create()

    case result do
      {:ok, session} -> {:ok, session, raw_token}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- org-level cap resolution --------------------------------------------------

  # The MOST RESTRICTIVE (smallest) non-nil `max_concurrent_sessions` across every
  # org this credential holds a Membership in (via its per-org Users) — `nil` when
  # no such org sets a cap (the c3 default: unlimited).
  defp org_session_cap(mods, credential_id) do
    user_ids =
      mods.user
      |> Ash.Query.filter(credential_id == ^credential_id)
      |> Ash.Query.select([:id])
      # authz-scope: authorization-boundary read — enumerates THIS credential's own users
      # (credential_id pin, the caller's own credential); org-less BY DESIGN (a credential's
      # session cap spans every org it holds a membership in), never a cross-tenant row set
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    case user_ids do
      [] ->
        nil

      user_ids ->
        org_ids =
          mods.membership
          |> Ash.Query.filter(user_id in ^user_ids)
          |> Ash.Query.select([:org_id])
          # authz-scope: authorization-boundary read — the memberships of THIS credential's
          # own users (user_id pin, derived one read up); org-less BY DESIGN (resolves which
          # orgs the credential belongs to), never a cross-tenant row set
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.org_id)
          |> Enum.uniq()

        case org_ids do
          [] ->
            nil

          org_ids ->
            mods.org
            |> Ash.Query.filter(id in ^org_ids and not is_nil(max_concurrent_sessions))
            |> Ash.Query.select([:max_concurrent_sessions])
            |> Ash.read!(authorize?: false)
            |> Enum.map(& &1.max_concurrent_sessions)
            |> case do
              [] -> nil
              caps -> Enum.min(caps)
            end
        end
    end
  end

  # Evict (revoke) the credential's OLDEST live sessions so at most `cap - 1`
  # remain live going into the imminent new-session create (post-create count
  # == cap, never more). `cap - 1` can be 0 (cap 1 ⇒ every existing live session
  # is evicted — the new sign-in is the sole survivor).
  #
  # ADR-035 §4.3 A4 (T104) — the sort is a STRICT TOTAL ORDER: primarily the
  # microsecond-precision `inserted_at` (Identity.Session widens it to
  # `:utc_datetime_usec` precisely so same-second sign-ins carry a sub-second
  # creation-order key), with the unique UUID `id` as the final tiebreak for the
  # astronomically-rare same-µs collision. Without a tiebreak, same-second
  # sessions tied and Postgres returned them in arbitrary order, so an ARBITRARY
  # (not the genuinely-oldest) session was evicted — the correctness gap this
  # task fixes. NOTE: eviction is still read-then-evict (not row-locked), so two
  # TRULY concurrent logins can momentarily overshoot the cap before both prune
  # (the T04 TOCTOU) — the ADR does not require atomic eviction; what it requires,
  # and what this now guarantees, is that the ORDERING is deterministic.
  defp evict_to_cap(session_mod, credential_id, cap) do
    keep = max(cap - 1, 0)

    live =
      session_mod
      |> Ash.Query.filter(credential_id == ^credential_id and is_nil(revoked_at))
      |> Ash.Query.select([:id, :inserted_at])
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      # authz-scope: login-time session-cap eviction keyed on the unique credential id — bounded
      # to that credential's OWN live sessions (org-less spine rows), never a cross-tenant row set
      |> Ash.read!(authorize?: false)

    excess = length(live) - keep

    if excess > 0 do
      now = DateTime.utc_now()

      live
      |> Enum.take(excess)
      |> Enum.each(fn session ->
        session
        |> Ash.Changeset.for_update(:revoke, %{revoked_at: now}, authorize?: false)
        |> Ash.update!()
      end)
    end

    :ok
  end
end
