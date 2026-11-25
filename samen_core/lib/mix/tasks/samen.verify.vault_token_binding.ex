defmodule Mix.Tasks.Samen.Verify.VaultTokenBinding do
  @shortdoc "Fail build on a vault token stored in a record it does not belong to."

  @moduledoc """
  `mix samen.verify.vault_token_binding` — does every vault token in a domain table belong to
  the record, vault and field that holds it? (evaluation 2026-11-13, vault token binding.)

  `Samen.Vault.Change` binds every `%Masked{}` to the record's subject on write and
  `Samen.Api.PiiResolution` reveals bound-only, so a planted token is refused going forward.
  This verifier finds what is ALREADY in a database (written before the binding, or by a path
  that bypassed Ash). The engine is `Samen.Vault.BindingScan`; classes:

    * `foreign_subject` — the token's vault row belongs to another subject than this record
    * `field_mismatch`  — the token's row is this record's, for another vault or field
    * `dangling_token`  — token-shaped, no `pii_vault` row
    * `non_token_value` — plaintext at rest in a vault column
    * `shared_token`    — the same token in more than one domain cell

  ## Report only

  There is no `--fix`. NULLing a cell is destructive, and re-minting a foreign subject's
  plaintext into this record would launder it and escape that subject's erasure, so a hit is
  reviewed by an owner. The read side already renders a mismatched token masked.

  ## Output

  Resource, field, record id and class — never a token and never a value.

  ## Fail-closed on empty discovery

  Zero discovered resources, or resources with no vault-routed field, or a scan that examined
  no column, would make a pass vacuous: the task exits 1 with a diagnostic (same posture as
  `vault_declared_parity`).

  ## Repo / domain discovery

  Repo(s) from `:ecto_repos` (override with `--repo MyApp.Repo`); resources from the host's
  `:ash_domains`.

  ## Exit code

  0 when clean, 1 on any finding (fail-closed via `:erlang.halt/1`).
  """

  use Mix.Task

  alias Samen.Vault.BindingScan

  @task_name "samen.verify.vault_token_binding"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} = OptionParser.parse(args, strict: [repo: :string])

    resources = discover_resources()
    halt_if_vacuous!(resources)

    repos = resolve_repos(opts)
    halt_if_no_repos!(repos)

    violations =
      Enum.flat_map(repos, fn repo ->
        ensure_repo_started!(repo)
        check(repo, resources)
      end)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Scan `resources` through `repo` and return violation strings (one per finding). Separated from
  `run/1` so tests can call it without `:erlang.halt/1`. Fails closed (raises) when the scan
  examined no column.
  """
  def check(repo, resources, opts \\ []) do
    {findings, %{columns: columns}} = BindingScan.scan(repo, resources, opts)

    if columns == 0 do
      raise "#{@task_name}: no vault-routed column was examined — a vacuous scan must not pass"
    end

    Enum.map(findings, &BindingScan.format/1)
  end

  defp discover_resources do
    otp_app = Mix.Project.config()[:app]

    domains =
      Application.get_env(otp_app, :ash_domains, []) ++
        Samen.HostDomains.registry() ++
        Application.get_env(:ash, :domains, [])

    Samen.Catalog.resource_modules(Enum.uniq(domains))
  end

  defp halt_if_vacuous!(resources) do
    cond do
      resources == [] ->
        fail!("discovered ZERO resources — cannot verify token binding. Configure the host's :ash_domains so the resources are introspectable.")

      Enum.all?(resources, &(Samen.Pii.Info.fields(&1) == [])) ->
        fail!("discovered no vault-routed (pii do) field on any resource — cannot verify token binding.")

      true ->
        :ok
    end
  end

  defp halt_if_no_repos!([]), do: fail!("no :ecto_repos configured. Pass --repo MyApp.Repo to override.")
  defp halt_if_no_repos!(_repos), do: :ok

  defp fail!(message) do
    IO.puts("")
    IO.puts("FAIL: #{@task_name} #{message} A vacuous check must not pass (fail-closed).")
    IO.puts("")
    :erlang.halt(1)
  end

  defp resolve_repos(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        otp_app = Mix.Project.config()[:app]
        Application.get_env(otp_app, :ecto_repos, [])

      repo_str ->
        [Module.concat([repo_str])]
    end
  end

  defp ensure_repo_started!(repo) do
    case repo.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "Could not start repo #{inspect(repo)}: #{inspect(reason)}"
    end
  end
end
