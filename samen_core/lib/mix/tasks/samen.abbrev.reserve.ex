defmodule Mix.Tasks.Samen.Abbrev.Reserve do
  @shortdoc "Reserve a permanent host-namespaced storage abbrev (ADR-023 allocator)."

  @moduledoc """
  `mix samen.abbrev.reserve` — the abbrev ALLOCATOR (WS-D D8, ADR-023). The single
  mechanism the generators call to reserve a permanent 3-letter storage abbrev, so a
  builder never hand-edits `priv/abbrev_registry.json`.

  Allocates + commits an entry **append-only** into the host namespace. It is:

    * **idempotent** — the same `--host` + `--abbrev` + `--owner` is a byte no-op;
    * **fail-closed on cross-owner collision** *within a host namespace* (ADR-006
      one-owner-forever, made host-scoped);
    * still checked against the **global cross-host net** (two hosts sharing physical
      infrastructure cannot silently clash on a prefix).

  ## Usage

      # explicit abbrev:
      mix samen.abbrev.reserve --host widgetco --abbrev wid --owner Widgetco.Vertical.Widget

      # let the allocator propose a deterministic, collision-free abbrev:
      mix samen.abbrev.reserve --host widgetco --owner Widgetco.Vertical.Widget --propose

  Options:

    * `--host`   (required) — the owning app's otp_app (e.g. `widgetco`). Namespaces the
      reservation so `demo`'s `cmp` and `driftwood`'s `cmp` are distinct owners.
    * `--owner`  (required) — the fully-qualified owning module (e.g.
      `Widgetco.Vertical.Widget`).
    * `--abbrev` — the explicit 3-letter lowercase abbrev to reserve. Mutually exclusive
      with `--propose`.
    * `--propose` — derive a deterministic, collision-free abbrev instead of passing one.
    * `--registry` — path to the registry file to write. Defaults to the committed
      `samen_core/priv/abbrev_registry.json`. **Probes/tests MUST pass a scratch copy** —
      the committed registry stays byte-untouched from a probe.
    * `--allow-cross-host-reuse` — the EXPLICIT opt-in (T123) for a **deliberate** ADR-025
      Option-B cross-host prefix reuse (two hosts owning the same abbrev for DISTINCT
      modules). WITHOUT it, reserving an abbrev already owned by a different module in
      another host is **refused** — an accidental cross-host collision would persist the
      T47 orphan that trips `flatten_conflicts/1`'s fail-closed raise at compile. Only pass
      this when the cross-host reuse is intentional (it then trips the ADR-025 tripwire).

  Prints the reserved `host/abbrev → owner` triple.
  """

  use Mix.Task

  alias Samen.Abbrev.Allocator
  alias Samen.AbbrevRegistry

  @switches [
    host: :string,
    owner: :string,
    abbrev: :string,
    propose: :boolean,
    registry: :string,
    allow_cross_host_reuse: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    host = require_opt!(opts, :host)
    owner = require_opt!(opts, :owner)
    registry = Keyword.get(opts, :registry, AbbrevRegistry.path())

    explicit = Keyword.get(opts, :abbrev)
    propose? = Keyword.get(opts, :propose, false)

    if explicit && propose? do
      Mix.raise("mix samen.abbrev.reserve: --abbrev and --propose are mutually exclusive")
    end

    abbrev =
      cond do
        explicit ->
          explicit

        propose? ->
          case Allocator.propose(host, owner, AbbrevRegistry.load_namespaced(registry)) do
            {:ok, proposed} -> proposed
            {:error, reason} -> Mix.raise("mix samen.abbrev.reserve: #{reason}")
          end

        true ->
          Mix.raise("mix samen.abbrev.reserve: pass --abbrev <abc> or --propose")
      end

    allow_cross_host_reuse? = Keyword.get(opts, :allow_cross_host_reuse, false)

    try do
      Allocator.reserve!(host, abbrev, owner, registry,
        allow_cross_host_reuse: allow_cross_host_reuse?
      )
    rescue
      e in ArgumentError -> Mix.raise("mix samen.abbrev.reserve: #{Exception.message(e)}")
    end

    Mix.shell().info("samen.abbrev.reserve: reserved #{host}/#{abbrev} -> #{owner}")
    :ok
  end

  defp require_opt!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> Mix.raise("mix samen.abbrev.reserve: missing required --#{key}")
      "" -> Mix.raise("mix samen.abbrev.reserve: --#{key} may not be empty")
      val -> val
    end
  end
end
