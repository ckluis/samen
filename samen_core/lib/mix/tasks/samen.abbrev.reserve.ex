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
    registry: :string
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

    try do
      Allocator.reserve!(host, abbrev, owner, registry)
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
