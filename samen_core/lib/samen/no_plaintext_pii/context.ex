defmodule Samen.NoPlaintextPii.Context do
  @moduledoc """
  The shared read-model every `Samen.NoPlaintextPii.Tier` receives.

  Built once by `Samen.NoPlaintextPii.build_context/1`, it carries:

    * `repo` — the Ecto repo the DB-tier scans query.
    * `resources` — the Ash resources discovered from `:ash_domains`.
    * `vault_routed` — a `MapSet` of `{table_name, column_name}` for every
      vault-routed `pii_attribute` storage column. These MUST be token columns.
    * `non_pii_exempt` — a `MapSet` of `{table_name, column_name}` for every
      VALID registered `non_pii!` override (distinct reviewer). These are
      plaintext-at-rest by design → exempt-but-listed (doc D8).
    * `deps` — the app dependency list (for the config-level opentelemetry check).

  ## Plaintext-PII-type classification

  `plaintext_pii_type?/1` is the load-bearing predicate the DB-tier scans use: a
  physical column whose *declared/stored type* is a plaintext PII type is a leak.
  A column is safe iff its type is a TOKEN type (`Samen.Type.VaultField`, or a
  raw `vt_*`-holding string that a vault-routed declaration owns) OR its type is a
  structurally-non-PII scalar (`Samen.Pii.Classification` says `:non_pii`) OR it
  is an explicitly-exempt `non_pii!` column.

  The classifier keys on `Samen.Pii.Classification` — the SAME mask-unknown-by-
  default oracle the C4 verifier uses — so an unknown/custom type is treated as
  PII (fail safe), never waved through.
  """

  alias Samen.Pii.Classification
  alias Samen.Pii.Info, as: PiiInfo
  alias Samen.NonPii

  @enforce_keys [:repo, :resources, :vault_routed, :non_pii_exempt, :deps]
  defstruct [:repo, :resources, :vault_routed, :non_pii_exempt, :deps]

  @type t :: %__MODULE__{
          repo: module() | nil,
          resources: [module()],
          vault_routed: MapSet.t({String.t(), String.t()}),
          non_pii_exempt: MapSet.t({String.t(), String.t()}),
          deps: [atom()]
        }

  @doc """
  Build the shared context.

  Options:
    * `:repo` — override the DB repo (defaults to the configured verify repo).
    * `:resources` — explicit resource list (bypasses domain discovery).
    * `:domains` — explicit domain list (defaults to `:ash_domains`).
    * `:deps` — explicit dependency atom list (defaults to `Mix` project deps);
      used by the config-level opentelemetry check so tests can inject a dep set.
  """
  @spec build(keyword()) :: t()
  def build(opts \\ []) do
    resources = resolve_resources(opts)

    %__MODULE__{
      repo: Keyword.get(opts, :repo) || default_repo(),
      resources: resources,
      vault_routed: vault_routed_set(resources),
      non_pii_exempt: non_pii_exempt_set(opts),
      deps: Keyword.get(opts, :deps) || project_deps()
    }
  end

  @doc """
  Is `{table_name, column_name}` a vault-routed storage column?

  Vault-routed columns are token columns by construction (`Samen.Type.VaultField`)
  — the DB-tier scans treat them as safe (they hold `vt_*` tokens, never
  plaintext).
  """
  @spec vault_routed?(t(), String.t(), String.t()) :: boolean()
  def vault_routed?(%__MODULE__{vault_routed: set}, table, column),
    do: MapSet.member?(set, {table, column})

  @doc "Is `{table_name, column_name}` a valid registered `non_pii!` exemption?"
  @spec non_pii_exempt?(t(), String.t(), String.t()) :: boolean()
  def non_pii_exempt?(%__MODULE__{non_pii_exempt: set}, table, column),
    do: MapSet.member?(set, {table, column})

  @doc """
  Does a dependency named `dep` (atom) appear in this project's dependency graph?
  Used by the config-level `opentelemetry_ecto` check.
  """
  @spec dep_present?(t(), atom()) :: boolean()
  def dep_present?(%__MODULE__{deps: deps}, dep) when is_atom(dep), do: dep in deps

  @doc """
  Is `type` a plaintext PII type? (Mask-unknown-by-default via
  `Samen.Pii.Classification`.)

  Accepts either a resolved Ash type module (`Ash.Type.String`), a short type atom
  (`:string`), or a type string as stored in the catalog (`"String"`, `"Date"`).

  A TOKEN type (`Samen.Type.VaultField`) is NOT plaintext PII (it holds `vt_*`).
  """
  @spec plaintext_pii_type?(term()) :: boolean()
  def plaintext_pii_type?(Samen.Type.VaultField), do: false

  def plaintext_pii_type?(type) when is_binary(type) do
    # Catalog stores the type trimmed of the "Ash.Type." prefix (Samen.Catalog).
    plaintext_pii_type?(resolve_type_string(type))
  end

  def plaintext_pii_type?(type), do: Classification.pii?(type)

  # ---------------------------------------------------------------------------

  defp resolve_type_string("VaultField"), do: Samen.Type.VaultField
  defp resolve_type_string("Samen.Type.VaultField"), do: Samen.Type.VaultField

  defp resolve_type_string(str) do
    # Try to resolve back to an Ash.Type module ("String" -> Ash.Type.String).
    # A bare short name maps via Ash.Type.get_type when possible; otherwise the
    # module concat is attempted; unknown strings fall through to a raw atom,
    # which Classification treats as PII by default (fail safe).
    mod = Module.concat(["Ash", "Type", str])

    cond do
      Code.ensure_loaded?(mod) -> mod
      true -> str |> Macro.underscore() |> String.to_atom()
    end
  end

  defp resolve_resources(opts) do
    cond do
      resources = Keyword.get(opts, :resources) ->
        resources

      domains = Keyword.get(opts, :domains) ->
        Samen.Catalog.resource_modules(List.wrap(domains))

      true ->
        Samen.Catalog.resource_modules(configured_domains())
    end
  end

  defp configured_domains do
    (Application.get_env(:samen_core, :ash_domains, []) ++
       Application.get_env(:ash, :domains, []))
    |> Enum.uniq()
  end

  defp vault_routed_set(resources) do
    resources
    |> Enum.flat_map(fn resource ->
      table = table_name(resource)

      if table do
        resource
        |> PiiInfo.fields()
        |> Enum.map(fn field -> {table, to_string(field.storage_name)} end)
      else
        []
      end
    end)
    |> MapSet.new()
  end

  defp non_pii_exempt_set(opts) do
    entries =
      case Keyword.get(opts, :non_pii_entries) do
        nil -> safe_registry_entries()
        list -> list
      end

    entries
    |> Enum.filter(fn e -> e.cleared_by != e.reviewed_by end)
    |> Enum.map(fn e -> {e.table_name, e.column_name} end)
    |> MapSet.new()
  end

  defp safe_registry_entries do
    NonPii.entries()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp table_name(resource) do
    AshPostgres.DataLayer.Info.table(resource)
  rescue
    _ -> nil
  end

  defp project_deps do
    Mix.Project.config()[:deps]
    |> List.wrap()
    |> Enum.map(&elem(&1, 0))
  rescue
    _ -> []
  end

  defp default_repo do
    Application.get_env(:samen_core, :verify_repo) ||
      Application.get_env(:samen_core, :non_pii_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo)
  end
end
