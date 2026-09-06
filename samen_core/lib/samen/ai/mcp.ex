defmodule Samen.AI.Mcp do
  @moduledoc """
  The D4 MCP server (ADR-043 §9; T69) — a **governed, grant-gated read/propose window**
  onto an org's data for an external agent, never a write path. This module is the
  protocol-agnostic tool engine + JSON-RPC dispatcher; the HTTP + SSE transport (the
  per-operator token → actor plug, the streamable session) is `Samen.Web.AI.McpPlug`
  (samen_web), so a vertical mounts the server at ≈0 authored LOC (INV-5).

  ## The `:mcp` SURFACE owns these four (T183; ADR-047 §5.1a)

  `tool_names/0` below is the `:mcp` registry inside `Samen.AI.ToolSurface` — the one
  surface-scoped abstraction the ADR-047 agent loop resolves through as well. `call_tool/4`
  asks it BEFORE dispatching, so a tool belonging to another surface (`:tenant`, `:ci_eval`,
  `:operator`) is refused by name here rather than merely falling off the end of the dispatch
  list. This module still OWNS its four tools; it no longer answers cross-surface questions.

  ## Four tools, all read-or-propose (ADR-043 §9 — "never write")

    * **browse** — navigate the org's data. With no `resource` arg it serves the T66
      runtime catalog (`Samen.AI.Catalog`, metadata only — never sample values, §8); with
      a `resource` arg it lists that resource's records org-scoped, every vault-routed (🔒)
      field MASKED at the boundary.
    * **search** — semantic search via the T67 embeddings plane
      (`Samen.AI.Embeddings.search/3`), org-scoped through the hard `aie_org_id` filter:
      org B's vectors are never returned — never even ranked — for org A (§7.3).
    * **drafts** — compose draft content via the T68 intelligence verbs
      (`Samen.AI.Verbs`), optionally grounded on a masked record. Composes only; persists
      nothing that acts (the §6.3 draft class).
    * **action-proposals** — propose a mutating action for HUMAN approval. Opens (or returns
      the pending) T34 approval via the Gate face (`kind: "<resource>:<action>"`,
      `subject_ref` = the record's object-ref) through `Samen.Approvals.request/2`, and
      **NEVER executes**: the proposal alone changes nothing; a human — never the token's
      principal (requester≠approver) — approves in the samen UI, and only then does the E3
      Gate re-invoke the action as the requester within the requester's own policy envelope.

  ## EG4 — every tool output routes through the chokepoint `:mcp` scrub

  EVERY value a tool emits passes `Samen.AI.Chokepoint.seal(:mcp, …)`:

    * record projections resolve their vault-routed fields through the chokepoint's
      `:bindings` egress path (`seal(:mcp, [], bindings: [{records, resource}])`), which
      returns each 🔒 field as `%Samen.Masked{}` → `"••••"` — never plaintext, never a
      `vt_*` token — on EVERY plane;
    * the fully-assembled structured result is then re-sealed `seal(:mcp, [], meta: …)`, so
      the chokepoint's own fail-closed metadata scrub (T65-F8) refuses any stray `vt_*`
      sentinel or un-rendered vault struct anywhere in the payload (`{:error,
      :pii_egress_refused}`).

  This module never hand-masks and never bypasses: the `"••••"` an agent sees is minted by
  the chokepoint, not by this module.

  ## GRANTS NEVER UNLOCK MCP (ADR-043 §7.2, INV-7)

  `:mcp` is a persisted/external egress class. `Samen.AI.Chokepoint.grant_egress?/2` returns
  `false` for every non-`:complete` kind, so even an actor holding a live reveal grant with
  the `grant_plaintext_egress` host opt-in ON gets MASKED data over MCP — the grant only ever
  admits plaintext to an ephemeral `:complete` payload. An external agent holding a valid
  token sees exactly what that operator would see in the UI, minus reveal.

  ## Org-scope is non-negotiable

  Every tool is org-scoped off the calling `scope`'s org. `browse`-records and `search` filter
  on the scope's `org_id` (the "correct filter parameter" mechanism the embeddings plane and
  the custom-object catalog already use — `Samen.AI.Embeddings`/`Samen.AI.Catalog`), and a
  scope with no org is refused fail-closed (`{:error, :no_org}`). An MCP session bound to org
  A can never browse/search/draft/propose over org B's data.

  ## Keyless / fail-honest

  The only external LLM access is through the existing keyless kernel path (`Samen.AI.complete/4`
  via the verbs): unwired in `:test` ⇒ the recording Fake; unwired elsewhere ⇒
  `{:error, :not_configured}` (never a fake `{:ok, _}`). MCP itself is entirely local HTTP
  (§4) — keyless by nature.

  ## Deferred sub-decisions resolved here (ADR-043 §11)

    * **MCP token storage shape** — reuses the host's existing per-operator API-token
      resource (the demo `KeyAuthPlug` SHA-256 digest-lookup precedent) via the transport
      plug's actor-resolver seam; NO new Ash resource, NO new allocator abbrev.
    * **SSE session bookkeeping** — the streamable HTTP transport is stateless per request
      (each POST is a self-contained JSON-RPC call resolved against the token's scope);
      `Samen.Web.AI.McpPlug` owns the SSE framing.
  """

  require Ash.Query

  alias Samen.AI.{Catalog, Chokepoint, Embeddings, Verbs}
  alias Samen.Approvals
  alias Samen.Pii.Info

  @protocol_version "2025-03-26"
  @server_name "samen-mcp"
  @server_version "1.0.0"

  @mask Samen.Masked.mask()

  @doc "The MCP protocol version this server speaks (`AshAi.Mcp` reference, §9)."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc "The bounded server-info map returned from `initialize`."
  @spec server_info() :: map()
  def server_info, do: %{"name" => @server_name, "version" => @server_version}

  # ==========================================================================
  # Tool catalogue — the MCP `tools/list` surface (JSON-Schema input shapes).
  # ==========================================================================

  @tool_names ~w(browse search drafts action_proposals)

  @doc "The four tool names this server exposes."
  @spec tool_names() :: [String.t()]
  def tool_names, do: @tool_names

  @doc """
  The MCP tool definitions (`{name, description, inputSchema}`), the `tools/list` payload.
  Read-or-propose only — no tool mutates.
  """
  @spec tools() :: [map()]
  def tools do
    [
      %{
        "name" => "browse",
        "description" =>
          "Navigate the org's data. Omit `resource` to list the runtime catalog " <>
            "(resources + fields, metadata only). Pass `resource` (a table name or module) " <>
            "to list that resource's records; vault-routed fields are masked (••••).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "resource" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 200}
          }
        }
      },
      %{
        "name" => "search",
        "description" =>
          "Semantic (vector) search over the org's embedded records. Returns ranked hits " <>
            "(resource, id, field, distance); org-scoped — never crosses orgs.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 200}
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "drafts",
        "description" =>
          "Compose draft content with an intelligence verb (#{Enum.join(verb_strings(), ", ")}). " <>
            "Optionally ground on a record via `resource` + `record_id` (its vault fields are " <>
            "masked in both the model prompt and the returned source preview). Composes only — " <>
            "persists nothing.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "verb" => %{"type" => "string", "enum" => verb_strings()},
            "input" => %{"type" => "string"},
            "prompt" => %{"type" => "string"},
            "resource" => %{"type" => "string"},
            "record_id" => %{"type" => "string"}
          },
          "required" => ["verb", "input"]
        }
      },
      %{
        "name" => "action_proposals",
        "description" =>
          "Propose a mutating action on a record for HUMAN approval. Opens a pending approval " <>
            "and returns its id; NEVER executes the action. A human approves in the UI, then " <>
            "the action runs as the requester within their own policy envelope.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "resource" => %{"type" => "string"},
            "action" => %{"type" => "string"},
            "record_id" => %{"type" => "string"},
            "reason" => %{"type" => "string"}
          },
          "required" => ["resource", "action", "record_id"]
        }
      }
    ]
  end

  # ==========================================================================
  # JSON-RPC dispatch (the transport hands a decoded request map here).
  # ==========================================================================

  @doc """
  Handle one decoded JSON-RPC request for `scope` (the token's actor). Returns
  `{:reply, response_map}` (to serialize back) or `:noreply` (a notification).

  `opts` carries the host wiring the tools need (`:resources`/`:domains`/`:repo`/
  `:approval_resource`/`:kinds`) plus test seams (`:grant`, `:grant_egress?`, `:vault`).
  """
  @spec handle_rpc(term(), map(), keyword()) :: {:reply, map()} | :noreply
  def handle_rpc(scope, %{"method" => method} = req, opts) do
    id = Map.get(req, "id")

    case method do
      "initialize" ->
        {:reply, ok_result(id, initialize_result())}

      "notifications/initialized" ->
        :noreply

      "ping" ->
        {:reply, ok_result(id, %{})}

      "tools/list" ->
        {:reply, ok_result(id, %{"tools" => tools()})}

      "tools/call" ->
        params = Map.get(req, "params", %{})
        name = Map.get(params, "name")
        args = Map.get(params, "arguments", %{}) || %{}

        {:reply, ok_result(id, tool_call_result(scope, name, args, opts))}

      other ->
        {:reply, error_result(id, -32_601, "method not found: #{inspect(other)}")}
    end
  end

  def handle_rpc(_scope, _req, _opts),
    do: {:reply, error_result(nil, -32_600, "invalid request")}

  defp initialize_result do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => server_info()
    }
  end

  # A tools/call result is ALWAYS a valid JSON-RPC result object; a tool-execution failure is
  # reported IN the result (`isError: true`), the MCP convention — never a transport error.
  defp tool_call_result(scope, name, args, opts) do
    case call_tool(scope, name, args, opts) do
      {:ok, data} -> tool_ok(data)
      {:error, reason} -> tool_error(reason)
    end
  end

  # ==========================================================================
  # Tool dispatch (also the direct, transport-free surface the tests drive).
  # ==========================================================================

  @doc """
  Invoke a tool by name for `scope`. `{:ok, structured_data}` or a fail-honest
  `{:error, reason}`. Every success path has already been sealed through the chokepoint
  `:mcp` scrub — the returned data carries no plaintext vault value and no `vt_*` token.
  """
  @spec call_tool(term(), String.t() | nil, map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call_tool(scope, name, args, opts) do
    # T183 (ADR-047 §5.1a): the SURFACE gate, ahead of dispatch. `Samen.AI.ToolSurface` is the
    # one registry abstraction the agent loop resolves through too, so a tool registered for
    # the tenant plane (or the CI eval lane) is REFUSED here by name — `{:tool_off_surface,
    # name, :mcp}` — instead of being reported as `{:unknown_tool, …}`, i.e. merely absent. A
    # name registered nowhere is still `{:unknown_tool, name}`, unchanged.
    case Samen.AI.ToolSurface.resolve(:mcp, name) do
      {:ok, :mcp} -> dispatch_tool(scope, name, args, opts)
      {:ok, _foreign_owner} -> {:error, {:tool_off_surface, name, :mcp}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_tool(scope, "browse", args, opts), do: browse(scope, args, opts)
  defp dispatch_tool(scope, "search", args, opts), do: search(scope, args, opts)
  defp dispatch_tool(scope, "drafts", args, opts), do: drafts(scope, args, opts)

  defp dispatch_tool(scope, "action_proposals", args, opts),
    do: action_proposals(scope, args, opts)

  # Fail-closed: a name the :mcp registry admits but this module cannot dispatch never
  # degrades into a silent no-op or a fake {:ok, _}.
  defp dispatch_tool(_scope, name, _args, _opts), do: {:error, {:unknown_tool, name}}

  # --- browse ------------------------------------------------------------------------------

  @doc false
  def browse(scope, args, opts) do
    case fetch(args, "resource") do
      nil -> browse_catalog(scope, opts)
      resource_ref -> browse_records(scope, resource_ref, args, opts)
    end
  end

  # Catalog navigation — metadata only (never a sample value, §8), org-scoped for the
  # org-variant custom-object half. Sealed through the :mcp metadata scrub.
  defp browse_catalog(scope, opts) do
    catalog_opts = Keyword.take(opts, [:domains, :resources, :repo])

    data = %{
      "kind" => "catalog",
      "schema" => Catalog.schema(catalog_opts),
      "custom_objects" => Catalog.custom_objects(org_id_or_nil(scope), catalog_opts)
    }

    seal_meta(data)
  end

  # Records mode — org-scoped list with vault fields masked at the boundary.
  defp browse_records(scope, resource_ref, args, opts) do
    with {:ok, org} <- org_id(scope),
         {:ok, resource} <- resolve_resource(resource_ref, opts),
         {:ok, records} <- read_records(org, resource, limit(args), opts),
         {:ok, projected} <- mask_records(scope, records, resource, opts) do
      seal_meta(%{
        "kind" => "records",
        "resource" => inspect(resource),
        "count" => length(projected),
        "records" => projected
      })
    end
  end

  # --- search ------------------------------------------------------------------------------

  @doc false
  def search(scope, args, opts) do
    query = fetch(args, "query") || ""
    search_opts = Keyword.take(opts, [:repo, :embedder]) ++ [limit: limit(args)]

    with {:ok, _org} <- org_id(scope),
         {:ok, hits} <- Embeddings.search(scope, query, search_opts) do
      seal_meta(%{
        "kind" => "search_results",
        "count" => length(hits),
        "hits" => Enum.map(hits, &hit_map/1)
      })
    end
  end

  defp hit_map(%Embeddings.Hit{} = h) do
    %{
      "resource" => h.source_resource,
      "id" => to_string(h.source_id),
      "field" => to_string(h.field),
      "distance" => h.distance
    }
  end

  # --- drafts ------------------------------------------------------------------------------

  @doc false
  def drafts(scope, args, opts) do
    with {:ok, _org} <- org_id(scope),
         {:ok, verb} <- fetch_verb(args) do
      input = fetch(args, "input") || ""

      # Optional record grounding: the record's vault fields are masked in BOTH the model
      # prompt (the verb's :complete seal) and the returned source preview (the :mcp seal).
      case grounding_records(scope, args, opts) do
        {:ok, {records, resource}} ->
          verb_opts =
            [bindings: [{records, resource}]] ++
              prompt_opt(args) ++ Keyword.take(opts, [:provider, :env_reader])

          with {:ok, completion} <- Verbs.run(verb, scope, input, verb_opts),
               {:ok, preview} <- mask_records(scope, records, resource, opts) do
            seal_meta(%{
              "kind" => "draft",
              "verb" => to_string(verb),
              "draft" => completion.text,
              "source" => preview
            })
          end

        {:ok, :none} ->
          verb_opts = prompt_opt(args) ++ Keyword.take(opts, [:provider, :env_reader])

          with {:ok, completion} <- Verbs.run(verb, scope, input, verb_opts) do
            seal_meta(%{"kind" => "draft", "verb" => to_string(verb), "draft" => completion.text})
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp grounding_records(scope, args, opts) do
    case {fetch(args, "resource"), fetch(args, "record_id")} do
      {nil, _} ->
        {:ok, :none}

      {resource_ref, record_id} when is_binary(record_id) ->
        with {:ok, org} <- org_id(scope),
             {:ok, resource} <- resolve_resource(resource_ref, opts),
             {:ok, [_ | _] = records} <- read_record(org, resource, record_id, opts) do
          {:ok, {records, resource}}
        else
          {:ok, []} -> {:error, :not_found}
          {:error, _} = err -> err
        end

      _ ->
        {:ok, :none}
    end
  end

  defp prompt_opt(args) do
    case fetch(args, "prompt") do
      p when is_binary(p) and p != "" -> [prompt: p]
      _ -> []
    end
  end

  # --- action proposals (HUMAN-GATED; never executes) --------------------------------------

  @doc false
  def action_proposals(scope, args, opts) do
    with {:ok, org} <- org_id(scope),
         {:ok, resource} <- resolve_resource(fetch(args, "resource"), opts),
         {:ok, action} <- fetch_action(args),
         {:ok, record_id} <- fetch_record_id(args) do
      kind = Approvals.Gate.kind_for(resource, action)
      subject_ref = object_ref(resource, record_id)

      attrs = %{
        org_id: org,
        kind: kind,
        subject_ref: subject_ref,
        requested_by: actor_id(scope),
        reason: fetch(args, "reason")
      }

      # request/2 ONLY opens (or returns the existing) pending approval. It runs NO handler —
      # handlers fire solely from approve/3 (a human, distinct-party). So proposing changes
      # nothing on the subject: the MCP path structurally cannot auto-execute a mutation.
      case Approvals.request(attrs, approvals_opts(opts)) do
        {:ok, approval} ->
          seal_meta(%{
            "kind" => "action_proposal",
            "status" => to_string(approval.state),
            "approval_id" => to_string(approval.id),
            "proposed" => kind,
            "subject_ref" => subject_ref,
            "executed" => false,
            "note" => "awaiting human approval — the proposal alone changes nothing"
          })

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp approvals_opts(opts), do: Keyword.take(opts, [:approval_resource, :repo, :kinds])

  # ==========================================================================
  # The chokepoint :mcp egress seals (EG4) — the ONLY way data leaves a tool.
  # ==========================================================================

  # Seal a fully-assembled structured result through the :mcp metadata scrub (T65-F8): a stray
  # vt_* sentinel or un-rendered vault struct ANYWHERE in `data` refuses fail-closed. On success
  # the (already-safe) data is returned as-is.
  defp seal_meta(data) do
    case Chokepoint.seal(:mcp, [], meta: %{payload: data}) do
      {:ok, _sealed} -> {:ok, data}
      {:error, _} = err -> err
    end
  end

  # Project records to masked maps. The 🔒 field VALUES come ONLY from the chokepoint's :mcp
  # bindings resolution (masked ••••, grants never apply); non-PII public fields are clear.
  defp mask_records(scope, records, resource, opts) do
    records = List.wrap(records)
    pii_fields = pii_field_names(resource)
    nonpii_fields = public_field_names(resource) -- pii_fields

    seal_opts =
      [actor: scope, bindings: [{records, resource}]] ++
        Keyword.take(opts, [:grant, :grant_egress?, :repo, :vault])

    with {:ok, payload} <- Chokepoint.seal(:mcp, [], seal_opts) do
      chunks = chunk_pii(payload.segments, pii_fields, length(records))

      projected =
        records
        |> Enum.zip(chunks)
        |> Enum.map(fn {rec, pii_values} ->
          base = %{"id" => to_wire(Map.get(rec, :id))}
          nonpii = Map.new(nonpii_fields, fn f -> {to_string(f), to_wire(Map.get(rec, f))} end)
          pii = pii_fields |> Enum.zip(pii_values) |> Map.new(fn {f, v} -> {to_string(f), to_wire(v)} end)

          base |> Map.merge(nonpii) |> Map.merge(pii)
        end)

      # Belt: re-scrub the assembled projection through the :mcp metadata scrub.
      with {:ok, _} <- Chokepoint.seal(:mcp, [], meta: %{records: projected}) do
        {:ok, projected}
      end
    end
  end

  # The chokepoint returns pii field values flat, in (record × pii_field) order.
  defp chunk_pii(_segments, [], record_count), do: List.duplicate([], record_count)
  defp chunk_pii(segments, pii_fields, _record_count), do: Enum.chunk_every(segments, length(pii_fields))

  # ==========================================================================
  # Reads (org-scoped by hard `org_id` filter — the embeddings/custom-object mechanism).
  # ==========================================================================

  defp read_records(org, resource, lim, opts) do
    query =
      resource
      |> Ash.Query.filter(org_id == ^org)
      |> Ash.Query.limit(lim)
      |> ensure_pii_selected(resource)

    do_read(query, opts)
  end

  defp read_record(org, resource, record_id, opts) do
    query =
      resource
      |> Ash.Query.filter(org_id == ^org and id == ^record_id)
      |> ensure_pii_selected(resource)

    do_read(query, opts)
  end

  # Vault-routed fields are select-default-false (`use Samen.Resource`), so they read back as
  # `%Ash.NotLoaded{}` unless selected — and the chokepoint egress resolver only masks a
  # `%Samen.Masked{}` (a NotLoaded struct would REFUSE fail-closed). Ensure they are selected
  # so they come back as `%Samen.Masked{}` and the chokepoint masks them to `••••`.
  defp ensure_pii_selected(query, resource) do
    case public_field_names(resource) do
      [] -> query
      fields -> Ash.Query.ensure_selected(query, fields)
    end
  end

  defp do_read(query, opts) do
    read_opts = [authorize?: false] ++ Keyword.take(opts, [:domain])

    # authz-scope: generic read helper — `query` arrives already org-pinned by every caller
    # (`read_object`/`read_record` each apply `Ash.Query.filter(org_id == ^org …)` above), a
    # cross-function pin this frame cannot see; no unpinned caller path reaches here
    case Ash.read(query, read_opts) do
      {:ok, records} -> {:ok, records}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  rescue
    e -> {:error, {:read_failed, Exception.message(e)}}
  end

  # ==========================================================================
  # Resource resolution (name/table/module → an introspectable Ash resource).
  # ==========================================================================

  defp resolve_resource(nil, _opts), do: {:error, :missing_resource}

  defp resolve_resource(ref, opts) when is_binary(ref) do
    available = available_resources(opts)

    match =
      Enum.find(available, fn res ->
        ref == inspect(res) or ref == safe_table_name(res) or ref == to_string(res)
      end)

    case match do
      nil -> {:error, {:unknown_resource, ref}}
      res -> {:ok, res}
    end
  end

  defp resolve_resource(_ref, _opts), do: {:error, :missing_resource}

  defp available_resources(opts) do
    cond do
      is_list(opts[:resources]) ->
        opts[:resources]

      is_list(opts[:domains]) ->
        Enum.flat_map(opts[:domains], &safe_domain_resources/1)

      true ->
        :samen_core
        |> Application.get_env(:ash_domains, [])
        |> Enum.flat_map(&safe_domain_resources/1)
    end
  end

  defp safe_domain_resources(domain) do
    Ash.Domain.Info.resources(domain)
  rescue
    _ -> []
  end

  defp safe_table_name(resource) do
    Samen.Catalog.table_name(resource)
  rescue
    _ -> nil
  end

  # ==========================================================================
  # Field introspection + wire rendering.
  # ==========================================================================

  defp pii_field_names(resource) do
    resource |> Info.pii_attributes() |> Enum.map(& &1.name)
  rescue
    _ -> []
  end

  defp public_field_names(resource) do
    resource |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)
  rescue
    _ -> []
  end

  # Render a resolved value to a wire-safe scalar. The chokepoint already turned every 🔒 field
  # into "••••"; this only guards against a non-PII value that is not a plain scalar (a
  # DateTime, an enum atom) leaking a struct into the JSON payload (and the :mcp metadata scrub
  # would refuse a struct anyway). Never fabricates a value.
  defp to_wire(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp to_wire(%Samen.Masked{}), do: @mask
  defp to_wire(%Ash.ForbiddenField{}), do: @mask
  defp to_wire(%Ash.NotLoaded{}), do: nil
  defp to_wire(v) when is_atom(v), do: to_string(v)
  defp to_wire(%Date{} = v), do: Date.to_iso8601(v)
  defp to_wire(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp to_wire(%NaiveDateTime{} = v), do: NaiveDateTime.to_iso8601(v)
  defp to_wire(v), do: inspect(v)

  # ==========================================================================
  # Arg / scope helpers.
  # ==========================================================================

  defp fetch(args, key) when is_map(args), do: Map.get(args, key) || Map.get(args, to_string(key))
  defp fetch(_args, _key), do: nil

  defp limit(args) do
    case fetch(args, "limit") do
      n when is_integer(n) and n > 0 -> min(n, 200)
      n when is_binary(n) -> parse_limit(n)
      _ -> 20
    end
  end

  defp parse_limit(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> min(i, 200)
      _ -> 20
    end
  end

  defp fetch_verb(args) do
    verb = fetch(args, "verb")

    case Enum.find(Verbs.verbs(), &(to_string(&1) == verb)) do
      nil -> {:error, {:unknown_verb, verb}}
      v -> {:ok, v}
    end
  end

  defp fetch_action(args) do
    case fetch(args, "action") do
      a when is_binary(a) and a != "" ->
        try do
          {:ok, String.to_existing_atom(a)}
        rescue
          ArgumentError -> {:error, {:unknown_action, a}}
        end

      _ ->
        {:error, :missing_action}
    end
  end

  defp fetch_record_id(args) do
    case fetch(args, "record_id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_record_id}
    end
  end

  defp verb_strings, do: Enum.map(Verbs.verbs(), &to_string/1)

  defp object_ref(resource, id) do
    "samen:#{Samen.Info.abbrev(resource) || "unknown"}:#{id}"
  end

  defp org_id(scope) do
    case extract_org(scope) do
      nil -> {:error, :no_org}
      org -> {:ok, org}
    end
  end

  defp org_id_or_nil(scope), do: extract_org(scope)

  defp extract_org(%Samen.Scope{actor: %{org_id: org}}) when not is_nil(org), do: org
  defp extract_org(%{actor: %{org_id: org}}) when not is_nil(org), do: org
  defp extract_org(%{org_id: org}) when not is_nil(org), do: org
  defp extract_org(_), do: nil

  defp actor_id(%Samen.Scope{actor: %{id: id}}) when is_binary(id), do: id
  defp actor_id(%{actor: %{id: id}}) when is_binary(id), do: id
  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_), do: nil

  # ==========================================================================
  # JSON-RPC envelope + MCP tool-result shaping.
  # ==========================================================================

  defp ok_result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_result(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp tool_ok(data) do
    %{
      "content" => [%{"type" => "text", "text" => encode(data)}],
      "structuredContent" => data,
      "isError" => false
    }
  end

  defp tool_error(reason) do
    %{
      "content" => [%{"type" => "text", "text" => "tool error: #{inspect(reason)}"}],
      "isError" => true
    }
  end

  defp encode(data) do
    case Jason.encode(data) do
      {:ok, json} -> json
      {:error, _} -> inspect(data)
    end
  end
end
