defmodule Samen.AbbrevRegistry do
  @moduledoc """
  The **abbrev registry**: a committed, permanent record mapping every 3-letter
  storage abbrev to the resource module that owns it (A5 in the plan; doc
  §"Self-qualifying storage" — "no rename drift"; memory: "permanent/never-recycled
  like a ticker").

  ## Why a committed file

  A resource's abbrev is projected into the DB column names, CDC rows, logs, and
  catalog. Once data exists under `com_name`, that prefix can never change without
  rewriting history — so abbrevs are treated exactly like stock tickers:
  **permanent, never recycled, one owner forever.** The registry is the durable
  source of truth for that invariant, committed to the repo (`priv/abbrev_registry.json`)
  and checked at compile time by `Samen.Verifiers.AbbrevRegistry`.

  ## Format

      {
        "abbrevs": {
          "com": "MyApp.Crm.Contact",
          "cpy": "MyApp.Crm.Company"
        }
      }

  Keys are abbrevs (3-letter lowercase); values are the owning resource module's
  fully-qualified name.

  ## Invariants enforced by the verifier

    * every abbrev is **3-letter lowercase** (`^[a-z]{3}$`);
    * **no collision** — two resources may not claim the same abbrev;
    * **no rename** — a resource may not change the abbrev it is registered under;
    * **registered** — a resource whose abbrev is missing from the registry fails
      compile (you must commit the registry entry to permanently reserve it).

  Removing/recycling is prevented by the same rules: the registry is append-mostly,
  and an abbrev listed for resource A cannot be handed to resource B.
  """

  @registry_path Path.join([:code.priv_dir(:samen_core) |> to_string(), "abbrev_registry.json"])

  @abbrev_pattern ~r/\A[a-z]{3}\z/

  @doc "Absolute path to the committed registry file."
  @spec path() :: String.t()
  def path, do: @registry_path

  @doc "The 3-letter-lowercase pattern every abbrev must match."
  @spec pattern() :: Regex.t()
  def pattern, do: @abbrev_pattern

  @doc """
  Loads the registry as a `%{abbrev => owner_module_string}` map.

  Raises if the file is missing or malformed — a corrupt registry must never
  fail *open* (an unreadable registry cannot be allowed to silently permit any
  abbrev). Callers in the compile path surface this as a build failure.
  """
  @spec load() :: %{optional(String.t()) => String.t()}
  def load do
    load(@registry_path)
  end

  @doc "Loads the registry from an explicit path (used in tests)."
  @spec load(String.t()) :: %{optional(String.t()) => String.t()}
  def load(registry_path) do
    case File.read(registry_path) do
      {:ok, contents} ->
        decode!(contents, registry_path)

      {:error, reason} ->
        raise """
        Samen abbrev registry missing or unreadable at #{registry_path} \
        (#{:file.format_error(reason)}). The registry is the permanent source of \
        truth for storage abbrevs and must be committed to the repo. Refusing to \
        compile — a missing registry cannot be allowed to permit arbitrary abbrevs.
        """
    end
  end

  defp decode!(contents, registry_path) do
    case Jason.decode(contents) do
      {:ok, %{"abbrevs" => abbrevs}} when is_map(abbrevs) ->
        abbrevs

      {:ok, _other} ->
        raise "Samen abbrev registry at #{registry_path} must be a JSON object with an \"abbrevs\" map."

      {:error, %Jason.DecodeError{} = err} ->
        raise "Samen abbrev registry at #{registry_path} is not valid JSON: #{Exception.message(err)}"
    end
  end

  @doc """
  Returns the owner module name (string) registered for `abbrev`, or `nil`.
  """
  @spec owner(String.t()) :: String.t() | nil
  def owner(abbrev), do: Map.get(load(), abbrev)

  @doc "True if `abbrev` matches the 3-letter-lowercase permanence pattern."
  @spec valid_shape?(term()) :: boolean()
  def valid_shape?(abbrev) when is_binary(abbrev), do: Regex.match?(@abbrev_pattern, abbrev)
  def valid_shape?(_), do: false

  @doc """
  Validates that `resource` (module name string) may use `abbrev` against a loaded
  registry map. Returns `:ok` or `{:error, reason_string}`. Pure — no file IO — so
  it is unit-testable and reusable by the compile-time verifier.

  Fails (never open) when:

    * `abbrev` is not 3-letter lowercase;
    * `abbrev` is registered to a **different** resource (collision / recycle);
    * `abbrev` is **absent** from the registry (unreserved).
  """
  @spec validate(map(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate(registry, abbrev, resource)
      when is_map(registry) and is_binary(abbrev) and is_binary(resource) do
    cond do
      not valid_shape?(abbrev) ->
        {:error,
         "abbrev #{inspect(abbrev)} for #{resource} is not 3 lowercase letters " <>
           "(^[a-z]{3}$). Storage abbrevs are permanent, ticker-like identifiers."}

      not Map.has_key?(registry, abbrev) ->
        {:error,
         "abbrev #{inspect(abbrev)} for #{resource} is not in the abbrev registry " <>
           "(#{@registry_path}). Abbrevs are permanent and must be reserved: add " <>
           "\"#{abbrev}\": \"#{resource}\" to the \"abbrevs\" map and commit it. " <>
           "This prevents two resources ever racing for the same prefix."}

      Map.fetch!(registry, abbrev) != resource ->
        {:error,
         "abbrev #{inspect(abbrev)} is registered to #{Map.fetch!(registry, abbrev)}, " <>
           "not #{resource}. Abbrevs are permanent and never recycled — you cannot " <>
           "reuse an abbrev for a second resource, nor change a resource's abbrev. " <>
           "Pick a new, unused 3-letter abbrev."}

      true ->
        :ok
    end
  end
end
