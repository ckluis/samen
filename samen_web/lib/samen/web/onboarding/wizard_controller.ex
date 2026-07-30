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

  ## Actor scope — mirrors WizardLive exactly

  These actions reconstruct the SAME own-org actor scope `WizardLive` builds
  from the `org`/`user` context (org naming / plan selection ride `Org`'s
  `OrgIsSelf` policy; the invite step carries the caller's REAL membership role
  for the `Invitation` rank-ceiling policy). This is a faithful copy of the
  existing wizard posture — T110 changes the transport (no-JS POST), never the
  authorization model.

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
  def name_org(conn, %{"org_id" => org_id, "user_id" => user_id, "org" => %{"name" => name}}) do
    mount = conn.private.samen_mount
    name = String.trim(name || "")

    case Onboarding.name_org(mount, actor_scope(org_id, user_id), org_id, name) do
      {:ok, _org} -> redirect(conn, to: step_path(conn, org_id, user_id, "plan"))
      {:error, _reason} -> redirect(conn, to: step_path(conn, org_id, user_id, "org", "&error=1"))
    end
  end

  def name_org(conn, %{"org_id" => org_id, "user_id" => user_id}),
    do: redirect(conn, to: step_path(conn, org_id, user_id, "org", "&error=1"))

  @doc "Step 2 — `POST /onboarding/plan`: write `Org.plan`, advance to the invite step."
  def select_plan(conn, %{"org_id" => org_id, "user_id" => user_id, "plan" => %{"key" => key}}) do
    mount = conn.private.samen_mount

    case Onboarding.select_plan(mount, actor_scope(org_id, user_id), org_id, key) do
      {:ok, _org} -> redirect(conn, to: step_path(conn, org_id, user_id, "invite"))
      {:error, _reason} -> redirect(conn, to: step_path(conn, org_id, user_id, "plan", "&error=1"))
    end
  end

  def select_plan(conn, %{"org_id" => org_id, "user_id" => user_id}),
    do: redirect(conn, to: step_path(conn, org_id, user_id, "plan", "&error=1"))

  @doc "Step 3 — `POST /onboarding/invite`: create a REAL pending Invitation, stay on the invite step."
  def invite(conn, %{"org_id" => org_id, "user_id" => user_id, "invitation" => params}) do
    mount = conn.private.samen_mount
    conn = fetch_session(conn)

    with {:ok, membership} <- membership(mount, org_id, user_id),
         scope <- invite_scope(user_id, org_id, membership.role, verified?(mount, get_session(conn))),
         {:ok, _invitation, _raw_token} <-
           Invitations.create(mount, scope, Map.get(params, "email", ""), Map.get(params, "role", "member")) do
      redirect(conn, to: step_path(conn, org_id, user_id, "invite", "&invited=1"))
    else
      _ -> redirect(conn, to: step_path(conn, org_id, user_id, "invite", "&invite_error=1"))
    end
  end

  def invite(conn, %{"org_id" => org_id, "user_id" => user_id}),
    do: redirect(conn, to: step_path(conn, org_id, user_id, "invite", "&invite_error=1"))

  @doc "`POST /onboarding/finish`: mark the org onboarded; the wizard renders the already-done card."
  def finish(conn, %{"org_id" => org_id, "user_id" => user_id}) do
    mount = conn.private.samen_mount
    _ = Onboarding.complete!(mount, actor_scope(org_id, user_id), org_id)
    redirect(conn, to: base_path(conn, org_id, user_id))
  end

  # -- private: scopes (faithful copies of WizardLive's own helpers) -----------

  defp actor_scope(org_id, user_id) do
    %Samen.Scope{
      actor: %{id: user_id, org_id: org_id, role: :member, kind: :tenant, plane: :tenant, verified?: true}
    }
  end

  defp invite_scope(user_id, org_id, role, verified?) do
    %Samen.Scope{
      actor: %{id: user_id, org_id: org_id, role: role, kind: :tenant, plane: :tenant, verified?: verified?}
    }
  end

  defp membership(mount, org_id, user_id) when is_binary(org_id) and is_binary(user_id) do
    Reads.current_membership(mount, Mount.scope(mount, org_id), user_id, org_id)
  end

  defp membership(_mount, _org_id, _user_id), do: {:error, :not_found}

  defp verified?(mount, session) do
    session_mod = Mount.resource(mount, Session)

    case Samen.Web.Auth.resolve_principal(session, %{session: session_mod}) do
      {:ok, %{credential_id: credential_id}} ->
        case Ash.get(Mount.resource(mount, Credential), credential_id, authorize?: false) do
          {:ok, %{verified_at: v}} -> not is_nil(v)
          _ -> false
        end

      _ ->
        true
    end
  rescue
    _ -> true
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
