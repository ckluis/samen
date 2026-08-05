defmodule Samen.AI.Analytics do
  @moduledoc """
  D7 — AI analytics over the token-blind AGGREGATE plane (ADR-043 §6.4, T71).

  > Analytics (D7) is the strongest form of the argument: NL questions execute as the
  > aggregate-plane actor, whose queryable schema structurally contains no PII columns —
  > there is no column to leak, so token-blind holds by schema, not by filter.

  `ask/4` answers a natural-language analytics `question` over an aggregate-plane
  `resource` (any `use Samen.Aggregate.Resource` projection — cross-tenant MRR, queue
  depth, health-band distribution, ...): it reads the resource's rows ONLY through
  `Samen.Aggregate.read_all/2` — NEVER a raw `Ash.read`, NEVER with `suppress: false` —
  and hands the (possibly-suppressed) rows to a T68 verb as free text, which routes
  through `Samen.AI.complete/4` → `Samen.AI.Chokepoint` like any other AI-plane surface.
  This module NEVER touches a `Samen.AI.Provider` callback and NEVER mints a
  `%Samen.AI.MaskedPayload{}` (`Samen.AI.ChokepointAntiBypassProbeTest` covers it).

  ## Why an AI analytics answer cannot leak an individual record's value

  Two independent guarantees compose here, neither of which this module implements
  itself — it inherits both by construction:

    1. **Schema-pure by compile-time construction (C7).** `Samen.Aggregate.read_all/2`
       refuses `{:error, :not_aggregate_resource}` for any resource that did not opt into
       the aggregate plane via `use Samen.Aggregate.Resource` — and THAT macro wires
       `Samen.Aggregate.NoPiiTransformer`, which fails the BUILD if the resource declares
       a `pii_attribute`, a vault, a `pii_`-shaped column, or a relationship reaching a
       PII-bearing resource. So this module can **never** be pointed at a tenant-plane
       (potentially PII-bearing) resource — there is no column to leak, full stop
       (`Samen.Aggregate.Info.aggregate_plane?/1` is the gate `read_all/2` checks first,
       before any row is ever fetched).
    2. **Output-privacy floors enforced BEFORE narration (T4.5).** `read_all/2` routes
       every returned row through `Samen.Aggregate.Privacy.apply/3` using the resource's
       `aggregate_cohort_spec/0`: a cohort whose count is `< k` (including the
       count-of-one case — the classic "aggregate leak" this ADR names: a min/max/
       sample-row/count-of-one surfacing an individual record's value under the guise of
       an aggregate) OR whose distinct-sensitive count is `< l` (a homogeneous cohort) has
       its releasable value REPLACED by `%Samen.Aggregate.Suppressed{}` — a struct that
       carries no number, so there is nothing for the narration step to echo. This module
       calls `read_all/2` with the DEFAULT `suppress: true` always (never overridden to
       `false`, which would be the exact aggregate-leak sabotage T71's red-team patch
       demonstrates); by the time a row reaches `render/3`, an unreleasable cell is
       already a `%Suppressed{}`, not a plaintext number.

  Because the narration input is plain aggregate-projection scalars (bounded strings /
  integers / the `Suppressed` sentinel) rather than Ash records, there is nothing to bind
  through `Samen.Api.PiiResolution` (§3.2 step 1 has no vault-routed field to resolve) —
  the free text this module builds is exactly the "catalog-derived / already-governed
  context" class §3.2 step 2 describes, and the chokepoint's `vt_`/shape scrub (step 3)
  still runs over it like any other segment.

  ## `scope` is the CALLER's scope, used ONLY for the narration call

  `scope` is forwarded to `Samen.AI.complete/4` (via `Samen.AI.Verbs.run/4`) for grounding
  metadata on the completion — it is **NOT** used to read the aggregate. The aggregate
  read always runs as the singleton token-blind aggregate actor
  (`Samen.Aggregate.actor/0`, the default `Samen.Aggregate.read_all/2` uses), never the
  caller's own tenant/operator scope — the two-plane mutual exclusion (T4.2/ADR-019): a
  tenant actor cannot borrow the aggregate actor's cross-tenant reach through this module,
  and the aggregate actor never borrows the caller's org.
  """

  alias Samen.Aggregate
  alias Samen.Aggregate.Suppressed
  alias Samen.AI.Verbs

  @doc """
  Answer `question` over `resource`'s aggregate rows. `opts`:

    * `:query` / `:k` / `:l` — forwarded to `Samen.Aggregate.read_all/2` (a preset
      `Ash.Query`, or floor overrides — tests use these; production reads config).
      `:suppress` and `:account` are DELIBERATELY not forwardable here — this module
      always reads with the enforced defaults (`suppress: true`, `account: true`); an
      analytics caller cannot ask for the unsuppressed read through this seam.
    * `:verb` — the T68 verb to narrate with (default `:analyze`).
    * everything else forwards to `Samen.AI.Verbs.run/4` (`:prompt`, `:params`,
      `:provider`, `:env_reader`, ...).

  Returns `{:ok, %Samen.AI.Completion{}}`, `{:error, :not_aggregate_resource}` (resource
  did not opt into the aggregate plane — refused before any row is read),
  `{:error, :no_cohort_spec}` (fail-closed: the resource declares no cohort spec, so no
  cell can be proven safe to release), `{:error, :not_configured}` (keyless, fail-honest),
  or `{:error, :pii_egress_refused}` (the chokepoint scrub).
  """
  @spec ask(term(), module(), String.t(), keyword()) ::
          {:ok, Samen.AI.Completion.t()} | {:error, term()}
  def ask(scope, resource, question, opts \\ []) when is_atom(resource) and is_binary(question) do
    read_opts = Keyword.take(opts, [:query, :k, :l])
    verb = Keyword.get(opts, :verb, :analyze)
    verb_opts = Keyword.drop(opts, [:query, :k, :l, :verb])

    with {:ok, rows} <- Aggregate.read_all(resource, read_opts) do
      Verbs.run(verb, scope, render(question, resource, rows), verb_opts)
    end
  end

  # Render the question + the (already-suppressed) aggregate rows as free text. A
  # %Suppressed{} cell renders its glyph ("⊘") via String.Chars — never the withheld
  # number, because the struct never carries one (Samen.Aggregate.Suppressed moduledoc).
  # A field the aggregate read did not select (e.g. the universal, select-default-false
  # `inserted_at`/`updated_at` columns) comes back `%Ash.NotLoaded{}` — omitted, never
  # raised on (the chokepoint's own "refuse/omit, never crash" posture).
  defp render(question, resource, rows) do
    fields = resource |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)

    body =
      rows
      |> Enum.map(&render_row(&1, fields))
      |> Enum.join("\n")

    "Question: #{question}\n\n" <>
      "Aggregate data (privacy-floor enforced -- a suppressed cell renders " <>
      "\"#{Suppressed.glyph()}\", never the withheld value):\n" <> body
  end

  defp render_row(row, fields) do
    fields
    |> Enum.map(&render_field(&1, Map.get(row, &1)))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp render_field(_field, %Ash.NotLoaded{}), do: nil
  defp render_field(_field, %Ash.ForbiddenField{}), do: nil
  defp render_field(field, value), do: "#{field}=#{value}"
end
