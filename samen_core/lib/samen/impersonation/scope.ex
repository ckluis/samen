defmodule Samen.Impersonation.Scope do
  @moduledoc """
  Turn an active impersonation session into a tenant-plane `%Samen.Scope{}` (T4.1
  clause (b); doc §control: the operator "sees its real UI, but the session carries no
  reveal grant, so personal data renders •••• by default … the tenant's own policies
  apply unchanged").

  ## What the impersonation scope IS

  It is a NORMAL tenant `%Samen.Scope{}` — the SAME struct a tenant member carries —
  whose actor map carries:

    * `:org_id`   — the TARGET org from the session. This is the tenant boundary, so
      `Samen.Policy.OrgScope` (the org-scope FilterCheck) narrows every read to the
      target org's rows, exactly as it would for a real member. The impersonating
      operator sees the tenant's REAL data shape (T4.1 clause (e)).
    * `:role`     — `:member` (a member-EQUIVALENT role). The tenant's RBAC applies
      unchanged: an impersonating operator has member-level reach into the tenant,
      NOT owner/admin. Read-heavy support is member-equivalent; nothing here elevates
      to `:admin`/`:owner`.
    * `:id`       — the OPERATOR's id (bounded). So an audit/log of a mutation under
      impersonation attributes to the operator, not to a fake tenant user.
    * `:impersonation` — a marker `%{operator_id, org_id, session_id}` proving this is
      an impersonated scope (a plain member scope has no such key). The plane resolver
      keys on this to keep PII MASKED.

  ## Why the PII stays masked (the whole point)

  The scope carries **NO reveal grant**. The reveal seam (`Samen.Reveal`) is consulted
  independently of the scope: it asks the configured `Samen.Reveal.Grant` model whether
  THIS actor holds a live, distinct-party-approved grant for THIS subject. An
  impersonating operator holds no such grant (unless they open the SEPARATE T1.6 reveal
  path on top), so every vaulted field the impersonating scope reads stays `%Masked{}`
  and renders `••••` through LiveView / JSON / CSV / log — by construction, not by an
  extra strip. The impersonation actor's `:plane` is set to `:operator`, so the API
  egress path (`Samen.Api.PiiResolution`) also treats a vaulted field as ABSENT unless
  a live grant covers the subject — the same egress matrix the tenant/operator key
  classes already use (T3.11).

  ## Fail-closed construction (T4.1 red path: expired denies mid-flight)

  `for_session/1` re-checks the session is ACTIVE (`Samen.Impersonation.Sessions.active?/2`)
  at build time — a per-request check. A caller that builds the scope on every request
  (the intended pattern) gets deny-on-read: the moment `now() > expires_at`, the
  session is inactive and `for_session/1` returns `{:error, :session_inactive}` — the
  operator's request fails closed exactly like no session. This is the "policy checks
  expiry per-request, not per-open" guarantee: rebuild the scope each request and an
  expired session denies mid-flight.
  """

  alias Samen.Impersonation.Session
  alias Samen.Impersonation.Sessions

  @doc """
  Build a tenant `%Samen.Scope{}` from an operator + a target org, validating there is
  an ACTIVE impersonation session for that pair AT BUILD TIME (per-request expiry
  check).

  Returns:
    * `{:ok, %Samen.Scope{}}` — an active session exists; the scope carries the target
      org_id, a `:member` role, the operator id, `:plane => :operator`, and the
      `:impersonation` marker. NO reveal grant.
    * `{:error, :session_inactive}` — no active/unexpired session for this pair
      (fail closed). Covers: never opened, closed, expired mid-flight.

  Options:
    * `:repo` — override the configured repo.
    * `:now`  — inject the clock (for the anti-tautology expiry probe).
  """
  @spec for_session(String.t(), String.t(), keyword()) ::
          {:ok, Samen.Scope.t()} | {:error, :session_inactive}
  def for_session(operator_id, org_id, opts \\ []) when is_binary(operator_id) do
    case Sessions.active_session(operator_id, org_id, opts) do
      %Session{} = session -> {:ok, build(session)}
      nil -> {:error, :session_inactive}
    end
  end

  @doc """
  Build the scope from a loaded session struct WITHOUT re-checking activity. Only for
  callers that already validated activity in the same request. Prefer
  `for_session/3`, which fails closed on an expired session. This raises if the session
  is already closed (a closed session must never produce a usable scope).
  """
  @spec from_session!(Session.t()) :: Samen.Scope.t()
  def from_session!(%Session{closed_at: nil} = session), do: build(session)

  def from_session!(%Session{} = session) do
    raise ArgumentError,
          "cannot build an impersonation scope from a CLOSED session " <>
            "(#{session.id}). A closed session never authorizes a read."
  end

  defp build(%Session{} = session) do
    %Samen.Scope{
      actor: %{
        # The operator's id — a mutation under impersonation attributes to the operator.
        id: session.operator_id,
        # The TARGET org is the tenant boundary — org-scope applies unchanged.
        org_id: to_string(session.org_id),
        # Member-EQUIVALENT role — the tenant's RBAC applies; nothing elevates.
        role: :member,
        membership_id: nil,
        # `:operator` plane → the egress matrix keeps vaulted fields masked/absent
        # unless a live reveal grant covers the subject (T3.11 PiiResolution).
        plane: :operator,
        # The marker proving this scope is impersonated (a plain member scope lacks it).
        impersonation: %{
          operator_id: session.operator_id,
          org_id: to_string(session.org_id),
          session_id: session.id
        }
      }
    }
  end

  @doc "Is this scope an impersonated scope (vs a real tenant member scope)?"
  @spec impersonated?(Samen.Scope.t() | term()) :: boolean()
  def impersonated?(%Samen.Scope{actor: %{impersonation: %{session_id: _}}}), do: true
  def impersonated?(_), do: false
end
