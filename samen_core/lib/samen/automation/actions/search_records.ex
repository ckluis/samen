defmodule Samen.Automation.Actions.SearchRecords do
  @moduledoc """
  The `search_records` READ-effect action (ADR-047 §5.1, batch A3) — org-scoped
  search over the calling actor's own org, registered in the ONE
  `Samen.Automation.Action` registry (never a forked second read-tool allowlist)
  and opted in as an agent tool (`tool_schema/0` + `effect/0 :: :read`).

  ## Two arms, each honest about its availability

    * **Semantic** — `Samen.AI.Embeddings.search/3` (ADR-043 §7): the query embeds
      through the SAME chokepoint as the documents, ranks org-scoped vectors only
      (org B's rows are never even ranked for org A), and every `%Hit{}` snippet is
      masking-safe BY CONSTRUCTION (an embedded field is non-vault by the
      deny-by-default allowlist; a snippet is only ever a `vt_`-free binary).
      Keyless in `:test` (the deterministic embedder); unwired elsewhere ⇒ the arm
      reports `"not_configured"` honestly.
    * **Full-text** — `Samen.Search.query/3` (ADR-027, the tsvector baseline this
      composes with): registered-non-PII-columns-only, org-scoped, ranked. It needs
      host seams (`resources` + the `SearchIndex` registry module + a repo), wired via
      `config :samen_core, Samen.Automation.Actions.SearchRecords, search: [...]`.
      Unwired ⇒ the arm reports `"not_configured"` honestly. Only the registered
      non-PII `display` fields of a hit are carried into the result meta — never the
      resolved record (whose tenant-plane resolution may hold plaintext).

  **Fail-honest floor (ADR-014/024/026):** an arm that did not run NEVER contributes
  hits, and when BOTH arms are unavailable the action returns
  `{:error, :not_configured}` — no empty-`{:ok, ...}` dressed as "searched, nothing
  found". A scope with no org refuses `{:error, :no_org}` (fail-closed, §7.3).

  ## As an agent tool (EG2)

  The tool schema below is a COMPILE-TIME CONSTANT of this module (ADR-047 §4.2's
  static-schema rule — dynamic choices are resolved by calling the tool, never baked
  into a definition). Tool args are untrusted model output: `validate/2` is a
  default-deny allowlist (`"query"` + optional `"limit"`; unknown keys refused,
  bounds enforced) run by the agent engine BEFORE execution — the same validator a
  Workflow changeset would use.
  """

  @behaviour Samen.Automation.Action

  alias Samen.Automation.Context

  @max_query_bytes 500
  @default_limit 5
  @max_limit 20

  # ADR-047 §4.2: a compile-time constant — never derived from tenant data. The
  # chokepoint refuses any tool def that is not byte-identical to a registered
  # action's static schema (`Samen.AI.Agent.Tools.static_def?/1`).
  @tool_schema %{
    name: "search_records",
    description:
      "Search this organization's records (semantic + full-text). Returns ranked hits " <>
        "(resource, id, matched field, snippet). Results never include personal " <>
        "(vault-routed) field values.",
    params: [
      %{name: "query", type: "string", required: true, description: "the search query text"},
      %{
        name: "limit",
        type: "integer",
        required: false,
        description: "max hits per arm (1-#{@max_limit}, default #{@default_limit})"
      }
    ]
  }

  @impl true
  def kind, do: :search_records

  @impl true
  def tool_schema, do: @tool_schema

  @impl true
  def effect, do: :read

  @impl true
  def validate(config, _resource_key) when is_map(config) do
    query = config["query"] || config[:query]
    limit = config["limit"] || config[:limit] || @default_limit

    cond do
      # Default-deny: only the declared arg names may appear (untrusted model output).
      not (config |> Map.keys() |> Enum.all?(&(to_string(&1) in ["query", "limit"]))) ->
        {:error, :invalid_args}

      not is_binary(query) or String.trim(query) == "" or byte_size(query) > @max_query_bytes ->
        {:error, :invalid_query}

      not (is_integer(limit) and limit >= 1 and limit <= @max_limit) ->
        {:error, :invalid_limit}

      true ->
        {:ok, %{"query" => String.trim(query), "limit" => limit}}
    end
  end

  def validate(_config, _resource_key), do: {:error, :invalid_config}

  @impl true
  def run(config, %Context{} = ctx) do
    query = config["query"]
    limit = config["limit"] || @default_limit
    scope = ctx.actor

    with {:ok, _org} <- org_of(scope) do
      {semantic_status, semantic_hits} = semantic_arm(scope, query, limit)
      {text_status, text_hits} = text_arm(scope, query, limit)

      # Fail-honest: BOTH arms unavailable = no search happened — never an {:ok, []}
      # pretending "searched, found nothing" (ADR-014).
      if semantic_status == "not_configured" and text_status == "not_configured" do
        {:error, :not_configured}
      else
        hits = semantic_hits ++ text_hits

        {:ok,
         %{
           kind: :search_records,
           count: length(hits),
           semantic_search: semantic_status,
           text_search: text_status,
           hits: hits
         }}
      end
    end
  end

  # --- the semantic arm (Samen.AI.Embeddings, keyless in :test) --------------------------

  defp semantic_arm(scope, query, limit) do
    case Samen.AI.Embeddings.search(scope, query, limit: limit) do
      {:ok, hits} ->
        {"ok",
         Enum.map(hits, fn hit ->
           %{
             "via" => "semantic",
             "source" => hit.source_resource,
             "id" => hit.source_id,
             "field" => hit.field,
             "distance" => Float.round(hit.distance * 1.0, 4),
             # Masking-safe by construction: a snippet is only ever a vt_-free binary
             # of a non-vault (deny-by-default embeddable) field, or nil.
             "snippet" => hit.snippet
           }
         end)}

      {:error, :not_configured} ->
        {"not_configured", []}

      {:error, _reason} ->
        # A broken arm did no work — reported honestly, never fabricated hits.
        {"error", []}
    end
  rescue
    _ -> {"error", []}
  end

  # --- the full-text arm (Samen.Search — host-wired seams; ADR-027) ----------------------

  defp text_arm(scope, query, limit) do
    case text_seams() do
      nil ->
        {"not_configured", []}

      seams ->
        results =
          Samen.Search.query(scope, query,
            resources: seams[:resources],
            search_index: seams[:search_index],
            repo: seams[:repo],
            limit: limit
          )

        {"ok",
         Enum.map(results, fn result ->
           %{
             "via" => "text",
             "source" => result.resource_name,
             "id" => to_string(result.id),
             "rank" => Float.round(result.rank * 1.0, 4),
             # ONLY the registered non-PII display fields travel — never the resolved
             # record (its tenant-plane resolution may carry plaintext PII).
             "display" => stringify_display(result.display)
           }
         end)}
    end
  rescue
    _ -> {"error", []}
  end

  defp text_seams do
    seams =
      :samen_core
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:search, [])

    if seams != [] and seams[:resources] not in [nil, []] and not is_nil(seams[:search_index]) and
         not is_nil(seams[:repo]) do
      seams
    else
      nil
    end
  end

  # Bounded scalars only — anything richer is dropped, never inspect-ed (the
  # RunRecord.bounded_outcomes posture; the renderer re-applies the same rule).
  defp stringify_display(display) when is_map(display) do
    for {k, v} <- display, is_binary(v) or is_number(v) or is_boolean(v), into: %{} do
      {to_string(k), v}
    end
  end

  defp stringify_display(_), do: %{}

  defp org_of(%Samen.Scope{actor: %{org_id: org}}) when is_binary(org), do: {:ok, org}
  defp org_of(_), do: {:error, :no_org}
end
