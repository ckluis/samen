defmodule Samen.Web.Onboarding.WizardController do
  @moduledoc """
  T110 — the no-JS HTTP POST fallbacks for `Samen.Web.Onboarding.WizardLive`
  (ADR-035 §5 A8). Since ADR-042 the LiveView client ships (`Samen.Web.Layouts`),
  so with JS the wizard's `phx-submit`/`phx-click` controls enhance in place and
  the socket connects; but onboarding is Class A (ADR-042 §5), so its
  controller-POST fallback is a BINDING no-JS floor. Each wizard WRITE gets a real
  `<form method="post">` that a no-JS browser submits natively to an action here;
  each step transition then `redirect/2`s back to `GET /onboarding?...&step=<next>`,
  so the wizard is walkable with no JavaScript. (Skip needs no controller action —
  it is a plain GET `<.link patch>` to the next step: navigation, no write.)

  Mounted by `Samen.Web.Router.samen_onboarding_routes/2`; `private:` carries the
  host's `%Samen.Web.Mount{}` (the `:settings`-kind Identity mount the wizard
  reads/writes over) plus the mount path, so this controller never hardcodes a
  host module — the `SessionController` per-host parameterization precedent.

  ## Actor scope — SESSION-derived (B-SEC / S11)

  These actions reconstruct the SAME own-org actor scope `WizardLive` builds, but the
  org and user are resolved through the framework's own session resolvers
  (`Samen.Web.CurrentOrg.resolve/3` + `Samen.Web.Settings.Reads.current_user_id/3`), NOT
  from the POST body.

  Before this fix `actor_scope/2` was built ENTIRELY from `params["org_id"]`/
  `params["user_id"]` with `verified?: true` hardcoded, and no action ever called
  `fetch_session/1`. `Org`'s `OrgIsSelf` policy compares `actor.org_id == org.id` — with
  both sides sourced from the same attacker-supplied value it is trivially satisfied, so a
  cookieless `curl -X POST /onboarding/name_org -d 'org_id=<victim>&user_id=<anything>&…'`
  renamed / re-planned / completed ANY org, and `invite` minted into any org at that org's
  admin rank. Now: the session is fetched first, the org must resolve through the ONE
  fail-closed resolver (an unauthenticated caller on an armed host resolves `nil` and every
  action refuses), the user id is the session principal, and `verified?` is the REAL
  `Credential.verified_at` with a fail-CLOSED no-principal branch. The body params are kept
  ONLY as redirect-path breadcrumbs, never as identity.

  No credential rides any of these forms (org name / plan key / invite
  email+role), so the escalation's query-string concern does not apply here —
  this is the F2 "wizard dead no-JS" half of T110, not the F1 credential-leak
  half.
  """
  use Phoenix.Controller, formats: [:html]

  alias Samen.Web.Mount
  alias Samen.Web.Onboarding
  alias Samen.Web.Settings.Invitations
  alias Samen.Web.Settings.Reads

  @doc "Step 1 — `POST /onboarding/name_org`: write `Org.name`, advance to the plan step."
  def name_org(conn, %{"org" => %{"name" => name}} = params) do
    {conn, mount, org_id, user_id} = context(conn, params)
    name = String.trim(name || "")

    case authorized_scope(mount, conn, org_id, user_id) do
      nil ->
        redirect(conn, to: step_path(conn, org_id, user_id, "org", "&error=1"))

      scope ->
        case Onboarding.name_org(mount, scope, org_id, name) do
          {:ok, _org} -> redirect(conn, to: step_path(conn, org_id, user_id, "plan"))
          {:error, _reason} -> redirect(conn, to: step_path(conn, org_id, user_id, "org", "&error=1"))
        end
    end
  end

  def name_org(conn, params) do
    {conn, _mount, org_id, user_id} = context(conn, params)
    redirect(conn, to: step_path(conn, org_id, user_id, "org", "&error=1"))
  end

  @doc "Step 2 — `POST /onboarding/plan`: write `Org.plan`, advance to the invite step."
  def select_plan(conn, %{"plan" => %{"key" => key}} = params) do
    {conn, mount, org_id, user_id} = context(conn, params)

    case authorized_scope(mount, conn, org_id, user_id) do
      nil ->
        redirect(conn, to: step_path(conn, org_id, user_id, "plan", "&error=1"))

      scope ->
        case Onboarding.select_plan(mount, scope, org_id, key) do
          {:ok, _org} -> redirect(conn, to: step_path(conn, org_id, user_id, "invite"))
          {:error, _reason} -> redirect(conn, to: step_path(conn, org_id, user_id, "plan", "&error=1"))
        end
    end
  end

  def select_plan(conn, params) do
    {conn, _mount, org_id, user_id} = context(conn, params)
    redirect(conn, to: step_path(conn, org_id, user_id, "plan", "&error=1"))
  end

  @doc "Step 3 — `POST /onboarding/invite`: create a REAL pending Invitation, stay on the invite step."
  def invite(conn, %{"invitation" => invitation} = params) do
    {conn, mount, org_id, user_id} = context(conn, params)

    with true <- is_binary(org_id) and is_binary(user_id),
         {:ok, membership} <- membership(mount, org_id, user_id),
         scope <- invite_scope(user_id, org_id, membership.role, verified?(mount, get_session(conn))),
         {:ok, _invitation, _raw_token} <-
           Invitations.create(mount, scope, Map.get(invitation, "email", ""), Map.get(invitation, "role", "member")) do
      redirect(conn, to: step_path(conn, org_id, user_id, "invite", "&invited=1"))
    else
      _ -> redirect(conn, to: step_path(conn, org_id, user_id, "invite", "&invite_error=1"))
    end
  end

  def invite(conn, params) do
    {conn, _mount, org_id, user_id} = context(conn, params)
    redirect(conn, to: step_path(conn, org_id, user_id, "invite", "&invite_error=1"))
  end

  @doc "`POST /onboarding/finish`: mark the org onboarded; the wizard renders the already-done card."
  def finish(conn, params) do
    {conn, mount, org_id, user_id} = context(conn, params)

    case authorized_scope(mount, conn, org_id, user_id) do
      nil -> :ok
      scope -> _ = Onboarding.complete!(mount, scope, org_id)
    end

    redirect(conn, to: base_path(conn, org_id, user_id))
  end

  # -- private: session-derived context (B-SEC / S11) --------------------------

  # Fetch the session ONCE and derive the acting org + user from it through the framework's
  # own resolvers. `params` reaches the resolvers only as the `?org=`/`?user=` DEV leg, which
  # `Samen.Web.CurrentOrg`/`Samen.Web.Settings.Reads` themselves refuse on an armed host — so
  # the POST body can never name an identity in a real deploy.
  defp context(conn, params) do
    conn = fetch_session(conn)
    mount = conn.private.samen_mount
    session = get_session(conn)

    resolver_params =
      %{}
      |> maybe_put("org", Map.get(params, "org_id"))
      |> maybe_put("user", Map.get(params, "user_id"))

    org_id = Samen.Web.CurrentOrg.resolve(mount, resolver_params, session)
    user_id = Reads.current_user_id(mount, resolver_params, session)

    {conn, mount, org_id, user_id}
  end

  defp maybe_put(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value), do: map

  # The own-org actor scope for the `OrgIsSelf`-policed org writes. `nil` (refuse) unless BOTH
  # the org and the user resolved from the session, and `verified?` is the REAL credential fact
  # (fail-CLOSED with no principal) — never the hardcoded `true` this used to carry.
  defp authorized_scope(mount, conn, org_id, user_id) when is_binary(org_id) and is_binary(user_id) do
    %Samen.Scope{
      actor: %{
        id: user_id,
        org_id: org_id,
        role: :member,
        kind: :tenant,
        plane: :tenant,
        verified?: verified?(mount, get_session(conn))
      }
    }
  end

  defp authorized_scope(_mount, _conn, _org_id, _user_id), do: nil

  defp invite_scope(user_id, org_id, role, verified?) do
    %Samen.Scope{
      actor: %{id: user_id, org_id: org_id, role: role, kind: :tenant, plane: :tenant, verified?: verified?}
    }
  end

  defp membership(mount, org_id, user_id) when is_binary(org_id) and is_binary(user_id) do
    Reads.current_membership(mount, Mount.scope(mount, org_id), user_id, org_id)
  end

  defp membership(_mount, _org_id, _user_id), do: {:error, :not_found}

  # B-SEC / S2 — the no-principal branch is fail-CLOSED on an armed host (see the twin in
  # `Samen.Web.Settings.InvitationsLive`). A legacy BYO principal still reports `true` (a BYO
  # host has no verified state); an UNAUTHENTICATED caller no longer gets `verified?: true` for
  # free, so the ADR-035 §5 A2 capability gate actually binds.
  defp verified?(mount, session) do
    session_mod = Mount.resource(mount, Session)

    case Samen.Web.Auth.resolve_principal(session, %{session: session_mod}) do
      {:ok, %{credential_id: credential_id}} ->
        case Ash.get(Mount.resource(mount, Credential), credential_id, authorize?: false) do
          {:ok, %{verified_at: v}} -> not is_nil(v)
          _ -> false
        end

      {:ok, %{user_id: user_id}} ->
        is_binary(user_id)

      _ ->
        not Samen.Web.CurrentOrg.tenant_gate_armed?(mount)
    end
  rescue
    _ -> not Samen.Web.CurrentOrg.tenant_gate_armed?(mount)
  end

  # -- private: redirect targets ----------------------------------------------

  defp base_path(conn, org_id, user_id) do
    "#{onboarding_path(conn)}?org=#{org_id}&user=#{user_id}"
  end

  defp step_path(conn, org_id, user_id, step, extra \\ "") do
    "#{base_path(conn, org_id, user_id)}&step=#{step}#{extra}"
  end

  defp onboarding_path(conn), do: conn.private[:samen_onboarding_path] || "/onboarding"
end
