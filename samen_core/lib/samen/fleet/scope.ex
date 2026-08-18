defmodule Samen.Fleet.Scope do
  @moduledoc """
  The **fleet registry** blueprint (ADR-044 §4.1, WS-J J1) — ships as a
  library-authored blueprint (ADR-004), the same shape as `Samen.Scopes.Mailbox`/
  `Samen.Scopes.Views`: `use`-ing this module inside a host's Ash domain expands into
  five host-owned resources in the host's namespace (`App`, `Credential`,
  `EnrollmentToken`, `Report`, `Directive`), each a normal `use
  Samen.Aggregate.Resource` with the host's `otp_app`/`repo`/`domain`.

  Only a fleet **cockpit** mounts this (per the vocabulary in ADR-044 §3.1: "any
  product that mounts `samen_operator_routes(..., fleet_cockpit: true)` is a
  cockpit"). A plain reporting-only app (mode A/B, not hosting a cockpit) never
  mounts this — it only calls `samen_fleet_routes()` (the reporting-side router
  macro, `samen_web`) and holds its OWN local credential via
  `Samen.Fleet.LocalCredential`.

  ## Mounting (the cockpit host side)

      defmodule MyApp.Fleet do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Fleet.Scope,
          otp_app: :my_app,
          repo: MyApp.Repo,
          namespace: MyApp.Fleet,
          abbrevs: %{app: "fap", credential: "fcr", enrollment_token: "fet",
                     report: "frp", directive: "fdv"}
      end

  ## Abbrevs (permanent, registry-checked)

  No scope-default: `abbrevs:` is REQUIRED and every host takes fresh
  allocator-proposed abbrevs reserved via `mix samen.abbrev.reserve` (ADR-023).
  `samen_core`'s own test fixture (`SamenCore.Support.FleetFixture`) uses:

    * `Samen.Fleet.Scope`(App/Credential/EnrollmentToken/Report/Directive) →
      `fap`/`fcr`/`fet`/`frp`/`fdv`
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    abbrevs = resolve_abbrevs(Keyword.fetch!(opts, :abbrevs), __CALLER__)

    app_mod = Module.concat(namespace, App)
    credential_mod = Module.concat(namespace, Credential)
    token_mod = Module.concat(namespace, EnrollmentToken)
    report_mod = Module.concat(namespace, Report)
    directive_mod = Module.concat(namespace, Directive)

    quote do
      require Samen.Fleet.Scope.Blueprint

      resources do
        resource(unquote(app_mod))
        resource(unquote(credential_mod))
        resource(unquote(token_mod))
        resource(unquote(report_mod))
        resource(unquote(directive_mod))
      end

      Samen.Fleet.Scope.Blueprint.define_app(
        unquote(app_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.app)
      )

      Samen.Fleet.Scope.Blueprint.define_credential(
        unquote(credential_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.credential)
      )

      Samen.Fleet.Scope.Blueprint.define_enrollment_token(
        unquote(token_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.enrollment_token)
      )

      Samen.Fleet.Scope.Blueprint.define_report(
        unquote(report_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.report)
      )

      Samen.Fleet.Scope.Blueprint.define_directive(
        unquote(directive_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.directive)
      )
    end
  end

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    Map.new(pairs, fn {k, v} -> {Macro.expand(k, caller), Macro.expand(v, caller)} end)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Fleet.Scope, abbrevs: must be a compile-time map literal " <>
            "(%{app: \"fap\", credential: \"fcr\", enrollment_token: \"fet\", " <>
            "report: \"frp\", directive: \"fdv\"}). Got: #{Macro.to_string(other)}"
  end
end
