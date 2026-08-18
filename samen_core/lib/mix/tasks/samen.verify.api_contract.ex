defmodule Mix.Tasks.Samen.Verify.ApiContract do
  @shortdoc "Verify api_contract: diff live contract vs committed snapshot. Fails on structural breaks."

  @moduledoc """
  `mix samen.verify.api_contract --version v1` — verifier C6 (plan §C6;
  doc §scale "The external surface"; vision-doc api_contract code block).

  ## What it checks

  Diffs the LIVE public API contract (introspected from the running app's
  AshJsonApi resources) against a committed snapshot (`api_contract.v1.json`).

  FAILS (exit 1) on un-versioned STRUCTURAL breaks to the v1 contract:

    - `field_removed` — a previously exposed field is no longer in `show_fields`
    - `type_narrowed` — an exposed field's Ash type changed
    - `route_dropped` — a previously declared route (`GET /contacts`, `GET /users/:id`,
      …) is no longer present
    - `required_arg_added` — an action now requires an argument that was previously
      optional or absent

  PASSES on additive-only changes (backward-compatible):

    - New field added (not yet in the snapshot → additive)
    - New route added
    - New resource added to the API
    - New optional argument added

  ## Semantic breaks explicitly out of scope

  A semantic break keeps the same shape (same type, same field name) but changes
  the meaning or unit (e.g. `amount` changes from "dollars" to "cents"). The diff
  cannot detect this — it remains the author's responsibility. Each diagnostic
  states this note explicitly.

  ## Snapshot file location

  Default: `<project_root>/api_contract.v1.json` (the root of the Mix project
  running the task). Override with `--snapshot path/to/file.json`.

  In the demo the snapshot lives at `demo/api_contract.v1.json`.

  ## Flags

    * `--version v1`          — the contract version to check (required)
    * `--snapshot <path>`     — path to the snapshot file (default: `api_contract.<version>.json`)
    * `--update`              — regenerate the snapshot from the live contract and write it;
                                exits 0 (does NOT diff)
    * `--domains A,B,C`       — comma-separated list of Ash domain module names to introspect
                                (default: all `:ash_domains` from the host app config)

  ## Snapshot format

  The snapshot is deterministic JSON (sorted keys + sorted arrays — same convention
  as `schema.dict.json`). Resources are sorted by `type`; routes by `method` then
  `path`; fields by `name`.

  ## Non-emptiness floor (fail-closed on empty discovery)

  An EMPTY live contract means introspection discovered ZERO AshJsonApi
  resources — a mis-keyed `:ash_domains` (or a snapshot builder swallowing
  every resource) would otherwise let `--update` write an empty snapshot and
  every future diff green vacuously (empty vs empty, forever). The task FAILS
  CLOSED (exit 1) before writing or diffing when the live contract has no
  resources — the same non-emptiness floor as
  `samen.verify.vault_declared_parity`, `samen.verify.oban_queues`, and
  `samen.verify.erasure_completeness`.

  ## Exit code

  - 0 — clean (no structural breaks, or `--update` wrote a new snapshot)
  - 1 — structural break(s) found (fail-closed via `:erlang.halt/1`)
  - 1 — snapshot file not found (must run `--update` first to create it)
  - 1 — the live contract discovered ZERO resources (a vacuous check must not pass)

  ## Example

      # Check the live contract against the committed v1 snapshot:
      mix samen.verify.api_contract --version v1

      # Re-snapshot after a planned, versioned API change:
      mix samen.verify.api_contract --version v1 --update

      # Check a specific snapshot path:
      mix samen.verify.api_contract --version v1 --snapshot priv/api_contract.v1.json
  """

  use Mix.Task

  @task_name "samen.verify.api_contract"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} =
      OptionParser.parse(args,
        strict: [
          version: :string,
          snapshot: :string,
          update: :boolean,
          domains: :string
        ]
      )

    version = Keyword.get(opts, :version) || abort("--version is required (e.g. --version v1)")

    snapshot_path =
      Keyword.get(opts, :snapshot) || default_snapshot_path(version)

    domains = resolve_domains(opts)
    update? = Keyword.get(opts, :update, false)

    # Build the live snapshot from the running app.
    live_snapshot = Samen.ApiContract.snapshot(domains, version)

    # X9 floor — BEFORE both branches: --update must never persist an empty
    # snapshot, and diff must never green an empty-vs-empty contract.
    halt_if_empty_contract!(live_snapshot)

    if update? do
      write_snapshot!(snapshot_path, live_snapshot)
      IO.puts("#{@task_name}: snapshot written to #{snapshot_path}")
    else
      # Diff mode — requires an existing snapshot file.
      stored_snapshot = load_snapshot!(snapshot_path)
      do_diff(live_snapshot, stored_snapshot, version)
    end
  end

  @doc """
  Run the diff check programmatically (without triggering `:erlang.halt/1`).

  Returns `{:ok, []}` on clean, `{:error, violations}` on structural breaks.
  Used by tests to assert violations without spawning a child process.
  """
  def check(live_snapshot, stored_snapshot) do
    Samen.ApiContract.diff(live_snapshot, stored_snapshot)
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp do_diff(live_snapshot, stored_snapshot, version) do
    case Samen.ApiContract.diff(live_snapshot, stored_snapshot) do
      {:ok, []} ->
        IO.puts("#{@task_name} --version #{version}: OK — no structural breaks found.")

      {:error, violations} ->
        Samen.Verifier.halt_if_violations(@task_name, violations)
    end
  end

  # X9 non-emptiness floor: `Snapshot.resource_entry/1` rescues per-resource
  # introspection failures into absence, and a mis-keyed :ash_domains yields []
  # outright — either way an empty live contract pins NOTHING. Writing it
  # (--update) or diffing it against an empty stored snapshot would green
  # vacuously forever. Same fail-closed shape as
  # `vault_declared_parity.halt_if_no_resources!/1`.
  defp halt_if_empty_contract!(live_snapshot) do
    if (live_snapshot["resources"] || []) == [] do
      IO.puts("")

      IO.puts(
        "FAIL: #{@task_name} discovered ZERO AshJsonApi resources — cannot verify the " <>
          "API contract. Configure the host's :ash_domains (or pass --domains) so the " <>
          "JSON:API resources are introspectable. A vacuous contract check must not " <>
          "pass (fail-closed)."
      )

      IO.puts("")
      :erlang.halt(1)
    end
  end

  defp resolve_domains(opts) do
    case Keyword.get(opts, :domains) do
      nil ->
        otp_app = Mix.Project.config()[:app]
        Application.get_env(otp_app, :ash_domains, [])

      domains_str ->
        domains_str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&Module.concat([&1]))
    end
  end

  defp default_snapshot_path(version) do
    project_root = File.cwd!()
    Path.join(project_root, "api_contract.#{version}.json")
  end

  defp load_snapshot!(path) do
    unless File.exists?(path) do
      abort(
        "Snapshot file not found: #{path}\n" <>
          "Run `mix samen.verify.api_contract --version v1 --update` to create it."
      )
    end

    path
    |> File.read!()
    |> Samen.ApiContract.decode!()
  end

  defp write_snapshot!(path, snapshot) do
    json = Samen.ApiContract.encode!(snapshot)
    File.write!(path, json)
  end

  defp abort(message) do
    IO.puts("#{@task_name}: ERROR — #{message}")
    :erlang.halt(1)
  end
end
