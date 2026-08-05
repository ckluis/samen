defmodule Samen.AI.Prompt do
  @moduledoc """
  `Samen.AI.Prompt` — the D3 versioned managed-prompt-template resource (ADR-043 §7.5, T68).

  Org-scoped, catalog-registered (the base macro wires `Samen.Catalog` on every resource —
  nothing extra to do here), keyless (a Prompt is DATA, not an LLM call — no provider is
  ever touched by this module). The "core four" fields per ADR-043 §7.5/§11: `name`,
  `version`, `body`, `org_id` (the last is the universal column every `Samen.Resource`
  injects).

  ## Versioning semantics — "update creates a new immutable version"

  There is NO update/destroy action. Editing a prompt means calling the `:new_version`
  create action again with the same `name`: `Samen.AI.PromptChange` computes the next
  integer `version` for `{org_id, name}` (current max + 1, defaulting to 1) and REFUSES a
  body that carries a `vt_` vault-token sentinel (fail-closed — a committed/managed
  template must never embed a raw vault FK token, ADR-043 §3.4 check (c)) or a body that is
  itself PII-shaped free text (`Samen.Pii.FreeTextScan`, the SAME chokepoint
  `Samen.Approvals` uses to scan its `reason` field). Every prior version row is retained
  UNCHANGED forever — `identities do identity(:name_version, ...) end` makes a second write
  to the SAME `{org_id, name, version}` triple a DB-level conflict, so history can never be
  silently rewritten. `fetch/3` resolves a prompt by exact `{name, version}` (or the latest
  version for a name), returning the EXACT body that version was written with.

  ## The check-(c) seam — `samen_ai_prompt_template_bodies/0`

  `mix samen.verify.ai_prompt_masking`'s check (c) (ADR-043 §3.4) reads this module's
  `samen_ai_prompt_template_bodies/0` — the COMMITTED, authored built-in seed templates the
  six intelligence verbs (`Samen.AI.Verbs`) fall back to when a caller does not reference an
  explicit org-authored `Samen.AI.Prompt` row (framework-first: a vertical gets working
  verbs at ≈0 authored LOC). This is EG5 "authored under the same scrub" — a compile-time,
  committed artifact, not a DB read (parallel to how T67's `embeddable_fields/0` seam reads
  a compile-time DSL declaration, never row data). A future edit that embeds a raw `vt_`
  token in one of these literals is caught by the verifier BEFORE it ships.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.AI.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "aip"

  postgres do
    table("ai_prompt")
    repo(Application.compile_env(:samen_core, :samen_ai_prompt_repo, SamenCore.TestRepo))
  end

  attributes do
    # The managed template's logical name (e.g. "support.triage_summary"). Multiple rows
    # share a name — one per version.
    attribute(:name, :string, public?: true, allow_nil?: false)

    # The immutable integer version, computed by Samen.AI.PromptChange (current max + 1 for
    # {org_id, name}, starting at 1). Never writable directly — writable?: false keeps it out
    # of every action's default `accept`, so only the Change (via force_change_attribute/3)
    # ever sets it.
    attribute(:version, :integer, public?: true, allow_nil?: false, writable?: false)

    # The template body text. PII-scanned + vt_-sentinel-scanned at write (see moduledoc);
    # never itself vault-routed (a Prompt is an AUTHORED artifact, not subject data).
    attribute(:body, :string, public?: true, allow_nil?: false)
  end

  identities do
    # A second write to the SAME {org_id, name, version} triple is a DB-level conflict —
    # history can never be silently overwritten, even under a race in the
    # PromptChange next-version computation (belt to that change's braces).
    identity(:name_version, [:org_id, :name, :version])
  end

  actions do
    defaults([:read])

    create :new_version do
      description(
        "Author a new immutable version of a named prompt template. Computes the next " <>
          "version for {org_id, name}; refuses a vt_-sentinel or PII-shaped body."
      )

      accept([:name, :body, :org_id])
      change(Samen.AI.PromptChange)
      change({Samen.Pii.FreeTextScan, fields: [:body]})
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type(:create) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end

  # --- convenience API (ADR-043 §7.5) -------------------------------------------------------

  require Ash.Query

  @doc """
  Author a new immutable version of `name` in `scope`'s org. Returns `{:ok, %Prompt{}}` (the
  freshly-minted version, e.g. `version: 1` for a brand-new name) or `{:error, reason}` — a
  `vt_`-sentinel/PII-shaped body is refused fail-closed, DB unchanged.
  """
  @spec new_version(Samen.Scope.t(), String.t(), String.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def new_version(%Samen.Scope{} = scope, name, body) when is_binary(name) and is_binary(body) do
    __MODULE__
    |> Ash.Changeset.for_create(
      :new_version,
      %{org_id: scope.actor.org_id, name: to_string(name), body: body},
      scope: scope
    )
    |> Ash.create()
  end

  @doc """
  Fetch a prompt by `name` + `version` (an explicit integer) or `:latest` (the highest
  version for that name), org-scoped through `Samen.Policy.OrgScope` like any other tenant
  read — a foreign org's prompt does not exist for this scope (`{:error, :not_found}`, never
  a leak). Returns `{:ok, %Prompt{}}` or `{:error, :not_found}`.
  """
  @spec fetch(Samen.Scope.t(), String.t(), pos_integer() | :latest) ::
          {:ok, Ash.Resource.record()} | {:error, :not_found} | {:error, term()}
  def fetch(%Samen.Scope{} = scope, name, version \\ :latest) do
    query =
      __MODULE__
      |> Ash.Query.filter(name == ^to_string(name))
      |> Ash.Query.sort(version: :desc)
      |> Ash.Query.limit(1)

    query = if version == :latest, do: query, else: Ash.Query.filter(query, version == ^version)

    case Ash.read(query, scope: scope) do
      {:ok, [prompt]} -> {:ok, prompt}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- the T68 check-(c) seam --------------------------------------------------------------

  # The built-in seed template each of the six verbs (Samen.AI.Verbs) falls back to when no
  # explicit `{name, version}` prompt is referenced. Keys mirror `Samen.AI.Verbs.verbs/0` as
  # `:"<verb>_default"`. Committed, authored artifacts (EG5) — never DB rows.
  @seed_templates [
    {:summarize_default,
     "Summarize the following content in 2-3 concise, factual sentences. Do not invent " <>
       "facts not present in the content.\n\nContent:\n{{input}}"},
    {:extract_default,
     "Extract the requested fields from the content as compact \"field: value\" lines. " <>
       "Fields to extract: {{fields}}\n\nContent:\n{{input}}"},
    {:classify_default,
     "Classify the content into exactly one of the following labels: {{labels}}. Respond " <>
       "with only the chosen label.\n\nContent:\n{{input}}"},
    {:generate_default,
     "Generate content that follows the instructions below precisely and concisely." <>
       "\n\nInstructions:\n{{input}}"},
    {:recommend_default,
     "Given the following context, recommend the single best next action and a " <>
       "one-sentence rationale.\n\nContext:\n{{input}}"},
    {:analyze_default,
     "Analyze the following content and surface the most important insights as a short " <>
       "bulleted list.\n\nContent:\n{{input}}"}
  ]

  @doc """
  The T68 `mix samen.verify.ai_prompt_masking` check-(c) seam (ADR-043 §3.4): the committed,
  authored built-in seed template bodies, as `[{name, body}]`. Reading this at verify time
  (not a DB query — see moduledoc) is what makes check (c) non-vacuous on a real resource: a
  future edit that embeds a `vt_` token in one of these literals fails the verifier.
  """
  @spec samen_ai_prompt_template_bodies() :: [{atom(), String.t()}]
  def samen_ai_prompt_template_bodies, do: @seed_templates
end
