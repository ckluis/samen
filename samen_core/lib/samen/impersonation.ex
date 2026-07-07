defmodule Samen.Impersonation do
  @moduledoc """
  Masked impersonation (T4.1; doc §control "Running the business" lead + the two-planes
  block). The public facade over the impersonation session runtime.

  ## The seam (doc §control)

  > The seam is impersonation: an operator opens a tenant and sees its real UI, but the
  > session carries no reveal grant, so personal data renders •••• by default.

  This module ties three pieces together:

    * `Samen.OperatorPlane.Actor` — the DISTINCT operator actor type (own RBAC, not a
      tenant member). `may_impersonate?/1` gates who can open a session.
    * `Samen.Impersonation.Sessions` — the short-TTL, reason-required, single-org
      session runtime (mirrors T1.6 reveal-grant mechanics: bounded `expires_at`,
      same-tx auto-expire enqueue, deny-on-read per request, no renew-in-place). Every
      open/close/expiry writes a token-only `aud_event` row.
    * `Samen.Impersonation.Scope` — turns an active session into a tenant `%Samen.Scope{}`
      carrying the target org_id + a member-equivalent role but NO reveal grant, so the
      tenant's own policies apply unchanged and PII renders `%Masked{}` (`••••`).

  ## Opening a session (the operator side)

      {:ok, session} =
        Samen.Impersonation.open(operator, org_id, "customer #1234 reported a billing error")

  `open/3` refuses (`{:error, :not_authorized}`) if the operator's role may not
  impersonate, and refuses (`{:error, :reason_required}`) if the reason is blank — the
  reason-for-access is REQUIRED (doc §control).

  ## Acting as the impersonated scope

      {:ok, scope} = Samen.Impersonation.scope(operator, org_id)
      contacts = Ash.read!(Demo.Crm.Contact, scope: scope)   # target org's rows, PII ••••

  `scope/3` re-checks the session is ACTIVE per request (deny-on-read): an expired
  session returns `{:error, :session_inactive}` and the read fails closed.

  ## The reveal path is SEPARATE (doc: "the two paths are mutually exclusive")

  Unmasking a subject under impersonation is NOT part of this module. An operator would
  open the SEPARATE T1.6 second-party reveal path (`Samen.Reveal.Grants`) on top — a
  request → distinct approval → time-boxed grant. Without that grant, impersonation is
  masked, full stop.
  """

  alias Samen.Impersonation.{Sessions, Scope}
  alias Samen.OperatorPlane.Actor

  @doc """
  Open an impersonation session for `operator` over target `org_id` with a REQUIRED
  `reason`. Returns `{:ok, %Session{}}`.

  Refuses:
    * `{:error, :not_authorized}` — the operator's role may not impersonate
      (`:operator_readonly`, or a non-operator actor).
    * `{:error, :reason_required}` — the reason is blank/missing.

  Options are passed through to `Sessions.open/1` (`:window_minutes`, `:repo`).
  """
  @spec open(Actor.t() | term(), binary(), String.t(), keyword()) ::
          {:ok, Samen.Impersonation.Session.t()} | {:error, term}
  def open(operator, org_id, reason, opts \\ []) do
    if Actor.may_impersonate?(operator) do
      Sessions.open(
        %{
          operator_id: operator_id(operator),
          org_id: org_id,
          reason: reason
        }
        |> Map.merge(Map.new(opts))
      )
    else
      {:error, :not_authorized}
    end
  end

  @doc """
  Build the tenant `%Samen.Scope{}` for `operator` impersonating `org_id`. Re-checks
  the session is active per request. Returns `{:ok, scope}` or
  `{:error, :session_inactive}`.
  """
  @spec scope(Actor.t() | term(), binary(), keyword()) ::
          {:ok, Samen.Scope.t()} | {:error, :session_inactive}
  def scope(operator, org_id, opts \\ []) do
    Scope.for_session(operator_id(operator), org_id, opts)
  end

  @doc "Close a session (manual). Delegates to `Sessions.close/2`."
  @spec close(binary(), map()) :: {:ok, Samen.Impersonation.Session.t()} | {:error, term}
  def close(session_id, opts \\ %{}), do: Sessions.close(session_id, opts)

  @doc """
  The tenant-visible list of impersonations against `org_id` (T4.1 clause (c)) — who,
  when, reason, expiry, active?. Delegates to `Sessions.list_for_org/2`.
  """
  @spec list_for_org(binary(), keyword()) :: [map()]
  def list_for_org(org_id, opts \\ []), do: Sessions.list_for_org(org_id, opts)

  @doc """
  The TENANT-PLANE query for clause (c): a tenant lists the impersonations against
  THEIR OWN org, derived from their `%Samen.Scope{}`. The org boundary comes from the
  scope's `actor.org_id` — a tenant can only ever see their own org's impersonations
  (they cannot pass another org's id), mirroring the org-scope idiom.

  Refuses `{:error, :no_org}` for an org-less scope (fail closed). An impersonated
  scope is refused too — an impersonating operator is not the tenant and must not read
  the tenant's impersonation ledger through this path.
  """
  @spec list_for_scope(Samen.Scope.t(), keyword()) :: {:ok, [map()]} | {:error, :no_org}
  def list_for_scope(%Samen.Scope{actor: actor}, opts \\ []) do
    cond do
      Map.get(actor, :impersonation) != nil ->
        {:error, :no_org}

      is_binary(Map.get(actor, :org_id)) ->
        {:ok, Sessions.list_for_org(actor.org_id, opts)}

      true ->
        {:error, :no_org}
    end
  end

  @doc "Is `(operator, org_id)` a live impersonation right now? Delegates to `Sessions.active?/3`."
  @spec active?(Actor.t() | term(), binary(), keyword()) :: boolean()
  def active?(operator, org_id, opts \\ []),
    do: Sessions.active?(operator_id(operator), org_id, opts)

  defp operator_id(%Actor{id: id}), do: id
  defp operator_id(%{id: id}) when is_binary(id), do: id
  defp operator_id(id) when is_binary(id), do: id
end
