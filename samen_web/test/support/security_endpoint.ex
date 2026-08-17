defmodule Samen.WebTest.SecurityHost do
  @moduledoc """
  The test-support HOST seams for the B-SEC LiveView-driving red-path suite
  (`tenant_authz_live_test.exs`).

  ## Why this exists (the S5 coverage gap this closes)

  Every phase-1 tenant-authn proof — `Samen.Web.TenantAuthnCoverageTest`,
  `PawChart.TenantAuthnProdPathTest`, `Driftwood.AuthProdPathTest` — asserted the property
  against `Samen.Web.CurrentOrg.resolve/3` as a UNIT FUNCTION. **No test in the repo drove a
  tenant LiveView through the real router/endpoint**, so the class stayed open one callback
  later (`handle_params/3` on the dead render) behind a green gate. This module + the endpoint
  below are the missing harness: a REAL compiled `Phoenix.Endpoint` + router mounting the REAL
  framework tenant macros, so `Phoenix.LiveViewTest.live/2` and a plain dead-render
  `Phoenix.ConnTest.get/2` can reproduce the confirmed attacks end-to-end.

  The host is a FICTIONAL app (`:samen_web_security_test_host`) whose `:auth_required?` flag the
  suite arms/disarms in isolation — never poisoning `:samen_web` for other suites.
  """

  @otp_app :samen_web_security_test_host

  @doc "The fictional host otp_app whose `:auth_required?` flag the suite arms/disarms."
  def otp_app, do: @otp_app

  @doc "Arm the host (prod posture — the tenant gate engages)."
  def arm!, do: Application.put_env(@otp_app, :auth_required?, true)

  @doc "Disarm the host (the sanctioned dev/dogfood posture)."
  def disarm!, do: Application.put_env(@otp_app, :auth_required?, false)

  @doc """
  The `:authorized_orgs` membership seam — the BYO-auth shape `Samen.Web.CurrentOrg` calls with
  the authenticated principal id appended. Backed by app env so a test can grant a principal
  membership in exactly the orgs it means to.
  """
  def authorized_org_ids(user_id),
    do: Application.get_env(:samen_web, :security_test_authorized_orgs, %{})[user_id] || []

  @doc "Grant `user_id` membership in `org_ids` for the duration of a test."
  def grant!(user_id, org_ids) do
    current = Application.get_env(:samen_web, :security_test_authorized_orgs, %{})
    Application.put_env(:samen_web, :security_test_authorized_orgs, Map.put(current, user_id, org_ids))
  end

  @doc "Clear every granted membership."
  def revoke_all!, do: Application.put_env(:samen_web, :security_test_authorized_orgs, %{})
end

defmodule Samen.WebTest.SecurityRouter do
  @moduledoc """
  A REAL router mounting the REAL framework tenant route macros over the samen_web test host's
  materialized scopes, driftwood-shaped (the `:authn` + `:authorized_orgs` seams present).

  Mounted through the macros — NOT hand-written `live/3` routes — so whatever `on_mount` the
  macro emits is what this suite exercises. If someone removes
  `{Samen.Web.TenantAuthz, :require_tenant}` from a macro, the red paths here go green-for-the-
  attacker and the suite fails.
  """
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Samen.Web.Router

  @labels %{
    otp_app: :samen_web_security_test_host,
    title: "Security Probe",
    authn: {:app_env, :samen_web_security_test_host, :auth_required?},
    authorized_orgs: {Samen.WebTest.SecurityHost, :authorized_org_ids, []}
  }

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
  end

  scope "/" do
    pipe_through(:browser)

    samen_module_routes(:crm, Samen.WebTest.Crm, repo: Samen.WebTest.Repo, labels: @labels)

    samen_settings_routes(:settings, Samen.WebTest.Operator,
      repo: Samen.WebTest.Repo,
      labels: @labels,
      spine_totp: true
    )

    # ADR-045 §4.4 (S1a) — a tenant MODULE surface (flags) with the `:identity_namespace` seam
    # wired to the Operator/Identity namespace, so an armed host derives the acting principal's
    # REAL `Identity.Membership` role for its admin-gated `write_scope` (a member's flag toggle is
    # refused; an admin's succeeds — driven end-to-end in `tenant_authz_live_test.exs`).
    samen_flags_routes(:flags, Samen.WebTest.Primitives,
      repo: Samen.WebTest.Repo,
      labels: Map.put(@labels, :identity_namespace, Samen.WebTest.Operator)
    )

    # ADR-047 A6 (the A5 verifier's third "could not prove here"): the AI kit — and with it
    # the A5 AGENT surfaces `/ai/agents` + `/ai/agents/:id` — was mounted by no router this
    # LiveView-DRIVING harness covers, so the tenant authn gate on those two routes was only
    # ever verified structurally. Mounting the macro here puts them under the same armed
    # dead-render red paths every other tenant surface rides. Cheap, and it closes the gap.
    samen_ai_routes(:ai, Samen.WebTest.Crm,
      repo: Samen.WebTest.Repo,
      labels: Map.put(@labels, :identity_namespace, Samen.WebTest.Operator)
    )
  end
end

defmodule Samen.WebTest.SecurityErrorHTML do
  @moduledoc false
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule Samen.WebTest.SecurityEndpoint do
  @moduledoc """
  A minimal `Phoenix.Endpoint` for the B-SEC red-path suite — the ONLY endpoint in `samen_web`.
  `server: false`: it is driven entirely by `Phoenix.ConnTest` / `Phoenix.LiveViewTest`, never a
  listening socket.
  """
  use Phoenix.Endpoint, otp_app: :samen_web

  socket("/live", Phoenix.LiveView.Socket)

  # REQUIRED for the red paths to be non-vacuous: `Plug.Parsers` is what calls
  # `Plug.Conn.fetch_query_params/1`, so without it a `?org=<victim>` never reaches the
  # LiveView's `params` at all and every attack would "pass" for the wrong reason.
  plug(Plug.Parsers, parsers: [:urlencoded, :multipart], pass: ["*/*"])

  plug(Plug.Session,
    store: :cookie,
    key: "_samen_web_security_test",
    signing_salt: "sec-probe-salt",
    same_site: "Lax"
  )

  plug(Samen.WebTest.SecurityRouter)
end
