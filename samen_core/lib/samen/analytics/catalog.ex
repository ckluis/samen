defmodule Samen.Analytics.Catalog do
  @moduledoc """
  The **bounded product-event catalog** (WS-B / G12; ADR-021 §4 "bounded catalog").

  `pae_event_name` is an enum from a REGISTERED catalog — never a freeform string.
  A new product event is a governance act: register its name + its `pae_props` key
  schema HERE (an enum value + a bounded key allowlist), not an arbitrary string a
  caller invents at a call site. This is the deliberate governance cost ADR-021 §4
  accepts in exchange for the token-blind-by-construction moat: an event the catalog
  has never heard of is REFUSED at capture (there is no bucket for it), so the
  cardinality of the ledger's event dimension is bounded and reviewable.

  ## The seed set (design §4.2)

  The framework-emitted seed events every plane/worker inherits at 0 vertical LOC:

    * `session.signed_in`    — a subject completed authentication.
    * `first_run.completed`  — the org finished first-run onboarding.
    * `record.created`       — a governed resource row was created (the kit create path).
    * `search.used`          — a search query ran.
    * `flag.assignment`      — a feature-flag variant was assigned (the §3.4 seam).

  ## Prop-key schema (the structural validation `track/1` enforces)

  Each event declares the CLOSED set of `pae_props` keys it may carry. `track/1`
  refuses a payload with an UNREGISTERED key (default-deny for keys, exactly the
  mask-unknown-by-default discipline applied to the prop schema) — a freeform
  `%{"note" => "..."}` key never reaches the ledger because no seed event declares
  `note`. The keys are bounded LABELS; the VALUES are additionally value-classified
  by `Samen.Analytics.track/1` against the PII oracle (a registered key still cannot
  carry a PII-shaped value). Keys are the WHAT; the PII refusal is the CONTENT gate.
  """

  # name => allowed pae_props key set (MapSet of string keys). A `[]` set means the
  # event carries no props at all (an empty %{} is valid; any key is refused).
  @catalog %{
    "session.signed_in" => MapSet.new([]),
    "first_run.completed" => MapSet.new([]),
    "record.created" => MapSet.new(["resource", "entity_kind"]),
    "search.used" => MapSet.new(["surface", "result_count"]),
    "flag.assignment" => MapSet.new(["flag_name", "variant"])
  }

  @names @catalog |> Map.keys() |> MapSet.new()

  @doc "The full set of registered event-name strings (the bounded enum)."
  @spec names() :: MapSet.t()
  def names, do: @names

  @doc "The registered event names as a sorted list (for the resource enum constraint)."
  @spec name_list() :: [String.t()]
  def name_list, do: @catalog |> Map.keys() |> Enum.sort()

  @doc "Is `name` a registered event? Unregistered names are refused at capture."
  @spec registered?(String.t()) :: boolean()
  def registered?(name) when is_binary(name), do: MapSet.member?(@names, name)
  def registered?(_), do: false

  @doc """
  The allowed `pae_props` key set for `name`, or `{:error, :unregistered_event}`
  for an unknown event. `track/1` uses this to default-deny unregistered keys.
  """
  @spec allowed_keys(String.t()) :: {:ok, MapSet.t()} | {:error, :unregistered_event}
  def allowed_keys(name) when is_binary(name) do
    case Map.fetch(@catalog, name) do
      {:ok, keys} -> {:ok, keys}
      :error -> {:error, :unregistered_event}
    end
  end

  def allowed_keys(_), do: {:error, :unregistered_event}
end
