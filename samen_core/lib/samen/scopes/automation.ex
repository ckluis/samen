defmodule Samen.Scopes.Automation do
  @moduledoc """
  The **Automation** universal scope (ADR-039 §3.1 — the ninth scope; WS-E E1/E4/E5).
  Ships as a library-authored blueprint (ADR-004): `use`-ing this module inside a
  host's Ash domain materializes the org-scoped `Workflow`, `Reminder`, and
  `Escalation` resources in the host's namespace, wired to the host's
  `otp_app`/`repo`/`domain`.

  ## What ships

    * `Workflow` (T39) — the E1 rule definition (trigger + conditions + actions)
      with the two-switch kill columns (§8.4) and the AshOban `:schedule_scan`
      trigger (§4.1).
    * `Reminder` (T41) — the E4 first-class reminder (`scheduled -> sent |
      cancelled`), AshOban `:reminder_due` trigger (§6.3).
    * `Escalation` (T41) — the E5 generic escalation primitive (AshStateMachine
      `open -> escalating -> resolved | exhausted | cancelled`), AshOban
      `:escalation_due` trigger (§7.3).
    * `Run` (T42) — the E8 run log (`queued -> running -> succeeded | failed |
      skipped`), written exclusively by the kernel pipeline
      (`Samen.Automation.RunRecord`); read by both the tenant per-workflow run
      list (T118) and the operator health view (T42).

  ## Mounting (the host side)

      defmodule Demo.AutomationScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Automation,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.AutomationScope
      end

  The host must also wire the engine seams + the Oban `:automation` /
  `:automation_timers` queues:

      config :samen_core, Samen.Automation,
        workflow_module: Demo.AutomationScope.Workflow,
        repo: Demo.Repo

      config :samen_core, Samen.Automation.Remind,
        reminder_module: Demo.AutomationScope.Reminder,
        repo: Demo.Repo

      config :samen_core, Samen.Automation.Escalate,
        escalation_module: Demo.AutomationScope.Escalation,
        repo: Demo.Repo

      config :samen_core, Samen.Automation,
        run_module: Demo.AutomationScope.Run

  and register the queues + the AshOban schedules via `AshOban.config/2` (the
  gen-app wiring, a substrate-first follow-up). Every abbrev is registry-checked
  (ADR-023) — the macro never invents one.
  """

  @default_abbrevs %{workflow: "awf", reminder: "arm", escalation: "aes", run: "sar"}

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    workflow_mod = Module.concat(namespace, Workflow)
    reminder_mod = Module.concat(namespace, Reminder)
    escalation_mod = Module.concat(namespace, Escalation)
    run_mod = Module.concat(namespace, Run)

    quote do
      require Samen.Scopes.Automation.Blueprint

      resources do
        resource(unquote(workflow_mod))
        resource(unquote(reminder_mod))
        resource(unquote(escalation_mod))
        resource(unquote(run_mod))
      end

      Samen.Scopes.Automation.Blueprint.define_workflow(
        unquote(workflow_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.workflow)
      )

      Samen.Scopes.Automation.Blueprint.define_reminder(
        unquote(reminder_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.reminder)
      )

      Samen.Scopes.Automation.Blueprint.define_escalation(
        unquote(escalation_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.escalation)
      )

      Samen.Scopes.Automation.Blueprint.define_run(
        unquote(run_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.run)
      )
    end
  end

  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    override =
      Map.new(pairs, fn {k, v} ->
        {Macro.expand(k, caller), Macro.expand(v, caller)}
      end)

    Map.merge(@default_abbrevs, override)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Automation, abbrevs: must be a compile-time map literal " <>
            "(%{workflow: \"awf\"}). Got: #{Macro.to_string(other)}"
  end
end
