defmodule Mix.Tasks.Samen.Verify.SignalsNoPii do
  @shortdoc "Build-time check: no signal argument is PII-typed, and no emit copies a PII attribute."

  @moduledoc """
  `mix samen.verify.signals_no_pii` — no PII in an `Ash.Signals` signal (issue #96 D2).

  Sweeps every resource of the host's configured domains (`:ash_domains`, or `--domain`),
  collects the signal modules they emit to or listen to, and fails the build on:

    * a signal argument whose type classifies `:pii` under `Samen.Pii.Classification`
      (mask-unknown-by-default, so a free `:string` fails too);
    * an `emit` that takes a signal field from a declared `pii_attribute`.

  See `Samen.Signals.NoPii` for why the rule binds every signal, whatever its delivery.

  Zero discovered resources fails closed: a green check on nothing is indistinguishable
  from a green check on a real app. Zero signals over real resources is a clean pass.

  Exits 0 when clean, 1 otherwise (via `Samen.Verifier`).
  """

  use Mix.Task

  @task_name "samen.verify.signals_no_pii"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} = OptionParser.parse(args, strict: [domain: :keep])

    # Every resource of the domains, whatever its data layer — not `Samen.Catalog`'s
    # table-backed subset: any resource can emit or listen to a signal.
    resources =
      opts
      |> Keyword.get_values(:domain)
      |> domains()
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.uniq()

    halt_if_no_resources!(resources)

    Samen.Verifier.halt_if_violations(@task_name, Samen.Signals.NoPii.violations(resources))
  end

  defp domains([]) do
    otp_app = Mix.Project.config()[:app]

    Enum.uniq(
      Application.get_env(otp_app, :ash_domains, []) ++ Application.get_env(:ash, :domains, [])
    )
  end

  defp domains(domain_strings), do: Enum.map(domain_strings, &load!/1)

  defp load!(name) do
    mod = Module.concat([name])

    case Code.ensure_compiled(mod) do
      {:module, ^mod} -> mod
      _ -> Mix.raise("Domain module #{inspect(mod)} could not be compiled/loaded.")
    end
  end

  defp halt_if_no_resources!([]) do
    IO.puts("")

    IO.puts(
      "FAIL: #{@task_name} discovered ZERO resources — cannot check their signals. " <>
        "Configure the host's :ash_domains (or pass --domain). A vacuous check must not " <>
        "pass (fail-closed)."
    )

    IO.puts("")
    :erlang.halt(1)
  end

  defp halt_if_no_resources!(_resources), do: :ok
end
