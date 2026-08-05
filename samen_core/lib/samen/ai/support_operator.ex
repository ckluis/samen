defmodule Samen.AI.SupportOperator do
  @moduledoc """
  The D5 **AI support operator** (ADR-043 §6.3, T70) — given an inbound support item, it
  DRAFTS a reply and enqueues that draft for HUMAN approval. It **never auto-sends**: the
  ONLY path from a draft to `Samen.Delivery.Chokepoint.send/2` is an E3 approval decided by
  a human who is never the requester (`Samen.AI.SupportOperator.ReplyHandler`, ADR-043 §6.3).

  ## What `draft_reply/3` does, in order (and what it deliberately does NOT do)

    1. **Ground (masked).** If an inbound source record is named (`:source_resource` +
       `:source_id`), it is read **org-scoped** (a hard `org_id == ^org` filter — org B can
       never ground on org A's item) and handed to the T68 verb as a `bindings` pair. Every
       vault-routed (🔒) field in that item is `••••`-masked in the provider payload by
       `Samen.AI.Chokepoint` (grants never apply on this operator-plane egress) — the draft
       the human reviews, and what ultimately sends, carries no plaintext and no `vt_*`.
    2. **Draft.** The reply body is composed by a T68 intelligence verb
       (`Samen.AI.Verbs.run/4`, default `:generate`) — whose ONLY provider access is
       `Samen.AI.complete/4` through the masking chokepoint. Keyless in CI (the recording
       Fake); unconfigured outside `:test` ⇒ fail-honest `{:error, :not_configured}`.
    3. **Persist.** The composed reply lands as a `Samen.AI.SupportReplyDraft` row
       (status `:draft`) in the caller's org. This row is the governed domain state the E3
       handler re-derives from — the approval itself stores NO inputs (§4.4).
    4. **Enqueue for approval.** A PENDING approval is opened via `Samen.Approvals.request/2`
       (`kind: "ai_support_reply"`, `subject_ref` = the draft's object-ref,
       `requested_by` = the AI service principal). **Nothing is sent.** `request/2` runs no
       handler — handlers fire only from `approve/3` (a distinct human).

  There is NO code path in this module that reaches `Samen.Delivery.Chokepoint.send/2`. The
  send lives solely in `Samen.AI.SupportOperator.ReplyHandler.on_approve/2`, which the
  approvals engine invokes only when a DISTINCT human approves.

  ## The AI service principal (ADR-043 §6.3)

  The operator drafts as a dedicated, auditable AI service principal
  (`principal_id/0`) on the operator plane — it holds no reveal grants and is **never a
  decider**. The engine's distinct-party rule (`decided_by != requested_by`, enforced at
  BOTH the policy layer and the `apv_distinct_party` DB CHECK) means a self-approval by this
  principal is refused fail-closed; the operator additionally exposes NO approve path of its
  own. A human operator, whose id differs from the principal, is the only party who can
  approve — and the send then fires within the draft's own org.
  """

  alias Samen.AI.{SupportReplyDraft, Verbs}
  alias Samen.Approvals

  require Ash.Query

  # The registered approval kind for a support-reply send (routes to ReplyHandler, operator
  # plane — see config/test.exs and any host's `Samen.Approvals.Registry` wiring).
  @kind "ai_support_reply"

  # The dedicated AI service principal id (ADR-043 §6.3): a stable, auditable, NON-human
  # identity. Distinct from every human operator id, so it can never satisfy the engine's
  # distinct-party check as an approver.
  @principal_id "samen:ai:support-operator"

  @doc "The registered approval `kind` a support-reply draft opens (`\"ai_support_reply\"`)."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc "The AI service principal id the operator drafts as (never a decider, ADR-043 §6.3)."
  @spec principal_id() :: String.t()
  def principal_id, do: @principal_id

  @doc """
  Draft a reply to an inbound support item in `scope`'s org and enqueue it for HUMAN
  approval. Returns `{:ok, %{draft: draft, approval: approval, approval_id: id,
  draft_text: text}}` — with the draft PERSISTED (`:draft`) and a PENDING approval opened,
  and **nothing sent**. Fail-honest on every leg (`{:error, :not_configured}` keyless
  outside `:test`, `{:error, :pii_egress_refused}` on a scrub failure, `{:error,
  :source_not_found}` when the named item is not in this org, `{:error, :no_org}` for an
  org-less scope).

  `attrs` (a map):

    * `:to_subscriber_id` (required) — the recipient subscriber TOKEN
    * `:instruction` / `:input` — free-text drafting instruction (the operator's own prompt)
    * `:verb` — the T68 verb to draft with (default `:generate`)
    * `:source_resource` + `:source_id` — an inbound item to ground on (masked, org-scoped)
    * `:inbound_ref` — an explicit bounded object-ref for the item (else derived from source)
    * `:subject` — an optional reply subject line
    * `:reason` — a bounded approval reason (PII-scanned by the engine)

  `opts` forwards `:provider`/`:env_reader` to the verb and `:approval_resource`/`:repo`/
  `:kinds`/`:domain` to the engine + source read (the host-wired seams).
  """
  @spec draft_reply(term(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def draft_reply(scope, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, org} <- org_id(scope),
         {:ok, {bindings, inbound_ref}} <- resolve_source(org, attrs, opts),
         {:ok, completion} <- compose(scope, attrs, bindings, opts),
         {:ok, draft} <- persist_draft(org, attrs, completion, inbound_ref, opts),
         {:ok, approval} <- open_approval(org, draft, attrs, opts) do
      {:ok,
       %{
         draft: draft,
         approval: approval,
         approval_id: to_string(approval.id),
         draft_text: completion.text
       }}
    end
  end

  @doc "The object-ref string for a draft (`\"samen:<abbrev>:<id>\"`) — the approval subject."
  @spec subject_ref(SupportReplyDraft.t()) :: String.t()
  def subject_ref(%SupportReplyDraft{} = draft),
    do: "samen:#{Samen.Info.abbrev(SupportReplyDraft)}:#{draft.id}"

  # --- 1. ground (masked, org-scoped) ------------------------------------------------------

  defp resolve_source(org, attrs, opts) do
    case {Map.get(attrs, :source_resource), Map.get(attrs, :source_id)} do
      {nil, _} ->
        {:ok, {[], Map.get(attrs, :inbound_ref)}}

      {resource, id} when is_atom(resource) and is_binary(id) ->
        case read_source(org, resource, id, opts) do
          {:ok, [_ | _] = records} ->
            {:ok, {[{records, resource}], Map.get(attrs, :inbound_ref) || object_ref(resource, id)}}

          {:ok, []} ->
            {:error, :source_not_found}

          {:error, _} = err ->
            err
        end

      _ ->
        {:error, :invalid_source}
    end
  end

  # Org-scoped read of the inbound item (the MCP `read_record` mechanism): the hard `org_id`
  # filter makes org A's item structurally non-existent for org B. Vault-routed fields are
  # select-default-false, so they are explicitly selected to read back as `%Samen.Masked{}`
  # (which the chokepoint then masks to `••••`) rather than `%Ash.NotLoaded{}` (which would
  # refuse fail-closed at the egress scrub).
  defp read_source(org, resource, id, opts) do
    query =
      resource
      |> Ash.Query.filter(org_id == ^org and id == ^id)
      |> ensure_pii_selected(resource)

    read_opts = [authorize?: false] ++ Keyword.take(opts, [:domain])

    case Ash.read(query, read_opts) do
      {:ok, records} -> {:ok, records}
      {:error, reason} -> {:error, {:source_read_failed, reason}}
    end
  rescue
    e -> {:error, {:source_read_failed, Exception.message(e)}}
  end

  defp ensure_pii_selected(query, resource) do
    case public_field_names(resource) do
      [] -> query
      fields -> Ash.Query.ensure_selected(query, fields)
    end
  end

  # --- 2. draft (via the T68 verbs → the masking chokepoint) -------------------------------

  defp compose(scope, attrs, bindings, opts) do
    verb = Map.get(attrs, :verb, :generate)
    input = Map.get(attrs, :instruction) || Map.get(attrs, :input) || ""

    verb_opts =
      binding_opt(bindings) ++
        prompt_opt(attrs) ++
        Keyword.take(opts, [:provider, :env_reader])

    Verbs.run(verb, scope, input, verb_opts)
  end

  defp binding_opt([]), do: []
  defp binding_opt(bindings), do: [bindings: bindings]

  defp prompt_opt(attrs) do
    case Map.get(attrs, :prompt) do
      nil -> []
      p -> [prompt: p]
    end
  end

  # --- 3. persist the draft (kernel write, org set from scope — the Approvals precedent) ---

  defp persist_draft(org, attrs, completion, inbound_ref, opts) do
    create_attrs = %{
      org_id: org,
      to_subscriber_id: Map.get(attrs, :to_subscriber_id),
      inbound_ref: inbound_ref,
      subject: Map.get(attrs, :subject),
      body: completion.text,
      requested_by: @principal_id
    }

    read_opts = Keyword.take(opts, [:domain])

    with {:ok, created} <-
           SupportReplyDraft
           |> Ash.Changeset.for_create(:draft, create_attrs, authorize?: false)
           |> Ash.create(read_opts) do
      # `org_id` is a select-default-false core column — reload it selected so the returned
      # draft (and the E3 handler's send) carries the org, never an `%Ash.NotLoaded{}`.
      load_draft(created.id, read_opts)
    end
  end

  # Re-read a draft with the core `org_id` column explicitly selected.
  @doc false
  def load_draft(draft_id, read_opts \\ []) do
    query =
      SupportReplyDraft
      |> Ash.Query.filter(id == ^draft_id)
      |> Ash.Query.ensure_selected([:org_id])

    case Ash.read_one(query, [authorize?: false] ++ Keyword.take(read_opts, [:domain])) do
      {:ok, nil} -> {:error, :draft_not_found}
      {:ok, draft} -> {:ok, draft}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- 4. enqueue for HUMAN approval (opens a PENDING approval; sends NOTHING) -------------

  defp open_approval(org, draft, attrs, opts) do
    # T143: the T70 `Code.ensure_loaded/1` band-aid is GONE — the approvals ENGINE now
    # resolves the OPTIONAL `on_reject/2` via `Code.ensure_loaded?/1` before
    # `function_exported?/3` (`Samen.Approvals.exports?/3`), so a lazily-loaded handler's
    # reject-discards path can no longer be silently skipped. No client-side preload needed.
    Approvals.request(
      %{
        org_id: org,
        kind: @kind,
        subject_ref: subject_ref(draft),
        requested_by: @principal_id,
        reason: Map.get(attrs, :reason)
      },
      Keyword.take(opts, [:approval_resource, :repo, :kinds])
    )
  end

  # --- helpers -----------------------------------------------------------------------------

  defp object_ref(resource, id), do: "samen:#{Samen.Info.abbrev(resource) || "unknown"}:#{id}"

  defp public_field_names(resource) do
    resource |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)
  rescue
    _ -> []
  end

  defp org_id(scope) do
    case extract_org(scope) do
      nil -> {:error, :no_org}
      org -> {:ok, org}
    end
  end

  defp extract_org(%Samen.Scope{actor: %{org_id: org}}) when not is_nil(org), do: org
  defp extract_org(%{actor: %{org_id: org}}) when not is_nil(org), do: org
  defp extract_org(%{org_id: org}) when not is_nil(org), do: org
  defp extract_org(_), do: nil
end
