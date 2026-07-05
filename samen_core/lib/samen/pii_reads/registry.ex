defmodule Samen.PiiReads.Registry do
  @moduledoc """
  The real PII / reveal-action registry the C3 `pii_reads` verifier keys on
  (T1.8b; Gate-0 fix task #6 (a) + (c)).

  The S0.7 spike stubbed both facts (`PiiReads.PiiRegistry` was a hand-written
  seed set, and reveal-scope was a lexical `reveal`-name prefix). Production C3
  derives BOTH from **real Ash introspection** over `pii do … end` declarations:

    * **PII attribute names** — `Samen.Pii.Info.pii_attributes/1` gives the
      logical field names (`:full_name`, `:emails`, `:dob`) and
      `Samen.Pii.Info.vault_routed_columns/1` gives the physical storage names
      (`:pat_full_name`, `:pii_pat_dob`). A leak can reference EITHER (an Ash
      calc reads `record.full_name`; a raw log reads `row.pii_pat_dob`), so the
      taint set is the union. Keying on the **declaration** (not a `pii_` prefix)
      is the whole point — a composite field like `pat_full_name` carries no
      `pii_` prefix but IS vault-routed (plan C3, doc §runs 3).

    * **Reveal actions** — `Samen.Pii.Info.reveal_actions/1` reads the persisted
      first-class `reveal :action` marker (`Samen.Transformers.RevealActions`),
      resolved from DSL state, NOT from the action name. This is the closed
      evasion: a `def reveal_report/1` (or an `action :reveal_report` that was
      never declared `reveal :reveal_report`) is NOT a reveal boundary and its
      sinks are flagged. Only a declared `reveal :name` action suppresses.

  ## Discovery

  Resources are discovered from `config :samen_core, :ash_domains` (the same
  source `Samen.Catalog` uses), so the registry covers every resource the host
  app declares. Pass `:domains` to `build/1` to override (tests inject a fixed
  set). Non-PII resources contribute nothing; resources with no reveal actions
  contribute nothing to the reveal map.
  """

  alias Samen.Pii.Info

  @type t :: %__MODULE__{
          pii_attributes: MapSet.t(atom()),
          reveal_actions_by_module: %{module() => MapSet.t(atom())},
          all_reveal_actions: MapSet.t(atom())
        }

  @enforce_keys [:pii_attributes, :reveal_actions_by_module, :all_reveal_actions]
  defstruct [:pii_attributes, :reveal_actions_by_module, :all_reveal_actions]

  @doc """
  Build the registry from a list of resource modules, or discover them from the
  configured `:ash_domains` when none is given.

  Options:
    * `:resources` — an explicit list of resource modules (bypasses discovery).
    * `:domains`   — a list of Ash domains to introspect (defaults to the
      `:ash_domains` app env).
  """
  @spec build(keyword()) :: t()
  def build(opts \\ []) do
    resources = resolve_resources(opts)

    pii_attributes =
      resources
      |> Enum.flat_map(&pii_names/1)
      |> MapSet.new()

    reveal_by_module =
      resources
      |> Enum.map(fn resource -> {resource, safe_reveal_actions(resource)} end)
      |> Enum.reject(fn {_mod, set} -> MapSet.size(set) == 0 end)
      |> Map.new()

    all_reveal =
      reveal_by_module
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    %__MODULE__{
      pii_attributes: pii_attributes,
      reveal_actions_by_module: reveal_by_module,
      all_reveal_actions: all_reveal
    }
  end

  @doc "True if `name` is a vault-declared PII attribute (logical OR storage name)."
  @spec pii_attribute?(t(), atom()) :: boolean()
  def pii_attribute?(%__MODULE__{pii_attributes: set}, name) when is_atom(name),
    do: MapSet.member?(set, name)

  def pii_attribute?(%__MODULE__{}, _), do: false

  @doc """
  True if `action_name` is a declared reveal action for `module` (the resource
  the source file defines). When `module` is `nil` (the walker could not resolve
  the enclosing module), we fall back to the UNION of all declared reveal actions
  across resources — a conservative allowance that still refuses undeclared names
  (so `reveal_report` is never suppressed, closing the evasion), while not
  over-flagging a legitimately-declared reveal action whose file happens to be
  scanned without a resolvable module binding.
  """
  @spec reveal_action?(t(), module() | nil, atom()) :: boolean()
  def reveal_action?(%__MODULE__{} = reg, nil, action_name) when is_atom(action_name) do
    MapSet.member?(reg.all_reveal_actions, action_name)
  end

  def reveal_action?(%__MODULE__{} = reg, module, action_name)
      when is_atom(module) and is_atom(action_name) do
    case Map.get(reg.reveal_actions_by_module, module) do
      %MapSet{} = set -> MapSet.member?(set, action_name)
      # The enclosing module is not a known Samen resource with reveal actions.
      # It cannot introduce a reveal boundary — deny (its sinks are flagged).
      nil -> false
    end
  end

  # ---------------------------------------------------------------------------

  defp resolve_resources(opts) do
    cond do
      resources = Keyword.get(opts, :resources) ->
        resources

      domains = Keyword.get(opts, :domains) ->
        resources_from_domains(domains)

      true ->
        resources_from_domains(Application.get_env(:samen_core, :ash_domains, []))
    end
  end

  defp resources_from_domains(domains) do
    domains
    |> List.wrap()
    |> Enum.flat_map(fn domain ->
      try do
        Ash.Domain.Info.resources(domain)
      rescue
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # Logical field names + physical storage names, both counted as tainted
  # sources. Guarded so a non-PII resource (no `pii do` block) contributes [].
  defp pii_names(resource) do
    logical = resource |> Info.pii_attributes() |> Enum.map(& &1.name)
    storage = Info.vault_routed_columns(resource)
    logical ++ storage
  rescue
    _ -> []
  end

  defp safe_reveal_actions(resource) do
    Info.reveal_actions(resource)
  rescue
    _ -> MapSet.new()
  end
end
