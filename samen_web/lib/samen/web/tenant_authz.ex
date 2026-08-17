defmodule Samen.Web.TenantAuthz do
  @moduledoc """
  The TENANT-plane authentication + org-AUTHORITY gate (B-SEC / S1·S1a·S2·S3, the luminary
  pre-merge BLOCKER). The tenant-plane twin of `Samen.Web.Operator.Authz`'s T146 hook.

  ## The hole this closes (CONFIRMED LIVE, 7/7 red paths)

  Every framework tenant route macro emitted a bare `live_session … session: %{"samen_mount" =>
  …}` with **no `on_mount`**. `Samen.Web.CurrentOrg.resolve/3` — the entire tenant authentication
  boundary — ran in `mount/3` and correctly returned `nil` for an unauthenticated caller on an
  armed host. But in `phoenix_live_view` 1.2.9 `handle_params/3` runs on the INITIAL DEAD RENDER
  (`deps/phoenix_live_view/lib/phoenix_live_view/static.ex:155,320-355`
  `call_mount_and_handle_params!/5`), one callback later, and 42 framework tenant LiveViews then
  did `org_id = Map.get(params, "org") || socket.assigns.org_id` — OVERWRITING the fail-closed
  answer with a raw client value. `Samen.Web.Plane.scope/2` fabricates the tenant actor from
  whatever org id it is handed, and the tenant `write_scope/2` helpers elevate it to `:admin`, so
  a cookieless `curl '…/crm/contacts?org=<victim>'` read another org's PII in the clear and a
  connected socket performed admin-rank writes into it.

  An `on_mount` `:halt` is the ONLY thing that preempts `handle_params/3` on the dead render.
  There was none. This module is it.

  ## What the hook does (three properties, all strictly narrowing)

    1. **AUTHENTICATE from the SESSION.** On a mount whose tenant gate is ARMED
       (`Samen.Web.CurrentOrg.tenant_gate_armed?/1`) a session carrying NO principal — neither the
       legacy BYO `samen_current_user` key nor the framework spine's `samen_session_token` —
       `:halt`s and redirects to the host's login path. Nothing renders, `handle_params/3` never
       runs, the dead-render vector is closed at the route.
    2. **PIN THE ORG AUTHORITY.** It resolves the org once, fail-closed, through the ONE resolver
       (`CurrentOrg.resolve/3`) and pins BOTH the answer (`:samen_tenant_org_id`) and the
       principal's authorized org set (`:samen_authorized_orgs`) into the socket.
       `CurrentOrg.reresolve/2` — which every tenant `handle_params/3` now calls — validates a
       `?org=` against that pinned set, so the client param is a SELECTOR among orgs the caller
       already holds, never an IDENTITY. This is exactly the discipline the operator drill-ins
       (`operator/activity_live.ex`, `operator/deliverability_live.ex`) already state.
    3. **NEVER self-elevate.** The hook derives no role and grants none. It only decides WHICH
       org — the provenance question `Samen.Policy.OrgScope` delegates to its caller.

  ## What it deliberately does NOT change

    * **The DISARMED (dev/dogfood) posture is untouched.** A host with `auth_required?` false
      keeps the sanctioned ADR-031 `?org=` convenience identity: the hook `:cont`s with
      `:samen_authorized_orgs` set to `:unconstrained` and `reresolve/2` behaves byte-for-byte as
      the old idiom did. This gate makes ARMED hosts strictly stricter; it makes nothing looser.
    * **The OPERATOR plane is untouched.** An operator-plane mount (`plane: :operator` — the
      masked impersonation drill-ins) is authorized by T146 (`Samen.Web.Operator.Authz`) and T150
      (`Samen.Web.Operator.Impersonation.gate/3`), which re-derive from the session principal and
      re-check scope on every write. The hook `:cont`s those unchanged (`:unconstrained`) rather
      than layering a second, disagreeing org answer over them.
    * **The masking model is untouched.** This module reads and writes no vault field, produces
      no actor, and never touches `actor.plane` — `Samen.Api.PiiResolution` remains the single
      clear-vs-`••••` decision (ADR-010 §5).
  """
  use Phoenix.Component

  alias Samen.Web.{CurrentOrg, Mount}

  @default_login_path "/login"

  @doc """
  The `on_mount {Samen.Web.TenantAuthz, :require_tenant}` hook every framework TENANT
  `live_session` carries (attached by the route macros in `Samen.Web.Router`, so adopting it is
  ≈0 authored LOC for a vertical — the framework-first posture).

    * `{:halt, redirect}` — armed tenant mount, NO authenticated principal in the session. This
      is the leg that preempts `handle_params/3` on the dead render.
    * `{:cont, socket}` with `:samen_authorized_orgs` (a list, or `:unconstrained`) and
      `:samen_tenant_org_id` assigned — everything else.
  """
  @spec on_mount(atom(), map() | atom(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:require_tenant, params, session, socket) when is_map(session) do
    mount = Mount.from_session(session["samen_mount"] || %{})
    params = if is_map(params), do: params, else: %{}

    cond do
      # The operator plane authorizes through T146/T150, which re-derive from the session
      # principal and re-check scope per write. Leave that path byte-for-byte unchanged.
      operator_plane?(mount) ->
        {:cont, unconstrained(socket, mount, session)}

      # The explicitly DISARMED dev/dogfood posture — the sanctioned ADR-031 `?org=` convenience.
      not CurrentOrg.tenant_gate_armed?(mount) ->
        {:cont, unconstrained(socket, mount, session)}

      # ARMED + no authenticated principal → render NOTHING. This is the halt that closes the
      # `handle_params`-on-dead-render bypass.
      not CurrentOrg.principal?(mount, session) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: login_path(mount))}

      true ->
        {:cont,
         socket
         |> assign(:samen_authorized_orgs, CurrentOrg.authorized_orgs(mount, session))
         |> assign(:samen_tenant_org_id, CurrentOrg.resolve(mount, params, session))
         # ADR-045 §4.4 — pin the authenticated principal (resolved through the Identity spine)
         # so the tenant `write_scope` helpers (`Samen.Web.TenantRole`) can derive the REAL
         # `Identity.Membership` role on an armed host instead of self-elevating `:member` to
         # `:admin` (S1a).
         |> assign(:samen_tenant_principal, CurrentOrg.principal_id(mount, session))}
    end
  end

  # No session map at all (never produced by a framework route) — fail closed.
  def on_mount(:require_tenant, _params, _session, socket),
    do: {:halt, Phoenix.LiveView.redirect(socket, to: @default_login_path)}

  # A6 (ADR-047, the A5 verifier's R-A5-3): even on the DISARMED / operator-plane legs the
  # principal is resolved from the SIGNED SESSION when one is present — never from a param,
  # and never invented. This grants nothing (org authority stays `:unconstrained` exactly as
  # before, and `Samen.Web.TenantRole.role_for/4` still returns `:admin` on both legs, so the
  # disarmed posture is byte-for-byte unchanged); it only stops discarding the identity of a
  # human who IS signed in, which is what surfaces recording a CONSENT (the agent decision
  # card) need in order to name a person rather than a per-org pseudo-principal. No session
  # principal ⇒ still nil ⇒ those surfaces still fail closed.
  defp unconstrained(socket, mount, session) do
    socket
    |> assign(:samen_authorized_orgs, :unconstrained)
    |> assign_new(:samen_tenant_org_id, fn -> nil end)
    |> assign_new(:samen_tenant_principal, fn -> CurrentOrg.principal_id(mount, session) end)
  end

  defp operator_plane?(%Mount{plane: %{kind: :operator}}), do: true
  defp operator_plane?(%Mount{scope_kind: k}) when k in [:operator, :aggregate], do: true
  defp operator_plane?(_), do: false

  defp login_path(%Mount{} = mount), do: Mount.label(mount, :login_path, @default_login_path)
end
