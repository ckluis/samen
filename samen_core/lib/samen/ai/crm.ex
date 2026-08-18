defmodule Samen.AI.Crm do
  @moduledoc """
  D6 — AI on CRM (ADR-043 §6.4, T71): the T68 intelligence verbs applied to CRM objects —
  timeline summary, inbound classify, next-step recommend, sequence draft. Every surface
  here is a THIN grounding wrapper over `Samen.AI.Verbs.run/4` → `Samen.AI.complete/4` →
  `Samen.AI.Chokepoint` (the ONE egress chokepoint; see the `Samen.AI.Verbs` /
  `Samen.AI.Chokepoint` moduledocs). This module NEVER touches a `Samen.AI.Provider`
  callback, NEVER mints a `%Samen.AI.MaskedPayload{}` (so
  `Samen.AI.ChokepointAntiBypassProbeTest`'s full-tree scan covers it like any other
  `samen_core/lib` module — RP-AI-1), and NEVER references `Samen.Delivery` at all — a
  sequence draft is data only, never a send (see `draft_sequence/5`).

  ## Grounding (masked, org-scoped) — mirrors `Samen.AI.SupportOperator.resolve_source/2`

  `ground_and_run/5` reads the named CRM object **org-scoped** (a hard `org_id == ^org`
  filter — org B can never ground on org A's object, exactly the T70 org-isolation
  mechanism) with every public field explicitly selected (so a vault-routed 🔒 field
  reads back as `%Samen.Masked{}`, not `%Ash.NotLoaded{}`, which the chokepoint scrub
  would otherwise refuse fail-closed), then hands it to a T68 verb as a
  `{records, resource}` binding. Every vault-routed field resolves `••••`-masked in the
  AI provider payload (`Samen.AI.Chokepoint`, ADR-043 §6.1) unless a live reveal grant
  AND the `grant_plaintext_egress` host opt-in both apply — the CRM AI surfaces below
  never request that (no `:grant`/`:grant_egress?` is threaded here), so CRM AI egress is
  masked-by-default, full stop.

  ## The four D6 surfaces (ADR-043 §6.4: "timeline summary, sequence drafts, inbound
  classify, next-step recommendations")

    * `summarize_timeline/4` — Summarize verb, grounded on the named CRM object.
    * `classify_inbound/3` — Classify verb over free text (no CRM record binding — an
      inbound message has not been persisted as a CRM object yet; it is the caller's
      own free text, §3.2 step 2d's user-consented-keystrokes class).
    * `recommend_next_step/4` — Recommend verb, grounded on the named CRM object.
    * `draft_sequence/5` — Generate verb, grounded on the named CRM object. ALWAYS
      returns `{:ok, %{status: :draft, body: text, simulated: boolean}}` — a plain map,
      never persisted, never sent; the `:simulated` flag is carried through from the
      `%Completion{}` so a keyless draft still renders the SIMULATED badge. There is no code path from this function (or any function in this
      module) to `Samen.Delivery.Chokepoint.send/2`: this module holds no reference to
      `Samen.Delivery` at all — proved both structurally (grep: this source file
      contains no `Samen.Delivery` reference) and at runtime (the red test asserts
      `Samen.Delivery.FakeProvider.calls() == []` after drafting).

  ## Org-scope + resource-agnostic (≈0-LOC vertical adoption)

  Like `Samen.AI.SupportOperator`, this module is resource-agnostic: `resource` is any
  `use Samen.Resource` CRM object (a vertical's own CRM-scope mount — `Demo.CrmScope.
  Person`, `Driftwood.Crm.*`, `Pawchart.Crm.*`, or samen_core's own CRM scope fixtures).
  No new resource, no new abbrev — a vertical adopts CRM AI at zero authored lines
  beyond calling these functions with its own CRM resource module.
  """

  alias Samen.AI.Verbs

  require Ash.Query

  @doc """
  Summarize a CRM object's timeline/notes (masked-path, org-scoped). `resource` is any
  CRM-scope Ash resource; `id` its primary key in `scope`'s org. `opts[:input]` is an
  optional free-text seed (e.g. a pasted timeline excerpt) — the CRM object's own fields
  are always bound (masked) regardless.
  """
  @spec summarize_timeline(term(), module(), String.t(), keyword()) ::
          {:ok, Samen.AI.Completion.t()} | {:error, term()}
  def summarize_timeline(scope, resource, id, opts \\ []),
    do: ground_and_run(:summarize, scope, resource, id, Keyword.get(opts, :input, ""), opts)

  @doc """
  Classify inbound free text (e.g. an inbound email/message) into `opts[:params][:labels]`
  (the Classify verb's default template substitution). No CRM record binding — see
  moduledoc.
  """
  @spec classify_inbound(term(), String.t(), keyword()) ::
          {:ok, Samen.AI.Completion.t()} | {:error, term()}
  def classify_inbound(scope, input, opts \\ []) when is_binary(input),
    do: Verbs.run(:classify, scope, input, opts)

  @doc "Recommend the next step for a CRM object (masked-path, org-scoped)."
  @spec recommend_next_step(term(), module(), String.t(), keyword()) ::
          {:ok, Samen.AI.Completion.t()} | {:error, term()}
  def recommend_next_step(scope, resource, id, opts \\ []),
    do: ground_and_run(:recommend, scope, resource, id, Keyword.get(opts, :input, ""), opts)

  @doc """
  Draft an outreach sequence for a CRM object. Returns `{:ok, %{status: :draft, body:
  text, simulated: boolean}}` — a plain, non-persisted draft; NEVER sends (see moduledoc).
  A real send path, were one wired for CRM outreach, would need its own E3 approval
  exactly like the D5 support-reply draft (`Samen.AI.SupportOperator`) — out of scope
  here: ADR-043 §6.4 names sequence drafts landing as drafts, not an approval flow, so
  this function stops at the draft.

  The `:simulated` flag is PRESERVED verbatim from the `%Samen.AI.Completion{}` the
  chokepoint stamps by construction (T152) — a keyless/deterministic draft carries
  `simulated: true` all the way to `Samen.Web.AI.Components.ai_result/1`, which draws the
  loud "SIMULATED — not a real model" badge. Dropping this flag here is exactly the
  T155-missed honesty hole (a fake-confident draft rendered as a neutral "Draft"); the
  flag is threaded through so the badge fires, mirroring every OTHER CRM AI surface (which
  returns the `%Completion{}` directly, flag intact).
  """
  @spec draft_sequence(term(), module(), String.t(), String.t(), keyword()) ::
          {:ok, %{status: :draft, body: String.t(), simulated: boolean()}} | {:error, term()}
  def draft_sequence(scope, resource, id, instruction, opts \\ []) when is_binary(instruction) do
    case ground_and_run(:generate, scope, resource, id, instruction, opts) do
      {:ok, completion} ->
        {:ok, %{status: :draft, body: completion.text, simulated: completion.simulated}}

      {:error, _} = err ->
        err
    end
  end

  # --- grounding (masked, org-scoped) -----------------------------------------------------

  defp ground_and_run(verb, scope, resource, id, input, opts) do
    with {:ok, org} <- org_id(scope),
         {:ok, records} <- read_source(org, resource, id, opts) do
      verb_opts = [bindings: [{records, resource}]] ++ Keyword.drop(opts, [:bindings, :input])
      Verbs.run(verb, scope, input, verb_opts)
    end
  end

  # Org-scoped read of the CRM object (the SupportOperator `read_source/4` mirror): the
  # hard `org_id` filter makes org A's object structurally non-existent for org B. Vault-
  # routed fields are select-default-false, so they are explicitly selected to read back as
  # `%Samen.Masked{}` (masked by the chokepoint) rather than `%Ash.NotLoaded{}` (refused
  # fail-closed by the egress scrub).
  defp read_source(org, resource, id, opts) do
    query =
      resource
      |> Ash.Query.filter(org_id == ^org and id == ^id)
      |> ensure_pii_selected(resource)

    read_opts = [authorize?: false] ++ Keyword.take(opts, [:domain])

    case Ash.read(query, read_opts) do
      {:ok, [_ | _] = records} -> {:ok, records}
      {:ok, []} -> {:error, :source_not_found}
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
