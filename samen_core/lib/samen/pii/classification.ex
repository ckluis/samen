defmodule Samen.Pii.Classification do
  @moduledoc """
  The type classification registry — **MASK-UNKNOWN-BY-DEFAULT** (plan D9; vision
  doc §limits keystone: "The privacy DSL is only as safe as its coverage").

  Every attribute type in the foundry is classified `:pii` or `:non_pii`. The
  load-bearing rule is the *default*: a type that is **not explicitly classified**
  — a custom/unknown Ash type the registry has never heard of — is treated as
  **PII** (masked). Coverage gaps fail *safe*, never *open*. This is the honest
  edge the vision doc stakes the privacy story on: "unknown types default to PII."

  ## Why default-PII and not default-plain

  If an unclassified type defaulted to non-PII, a developer introducing a new
  composite type (say `%Passport{}`) would get a silently-plain column until
  someone remembered to classify it — a leak by omission. Defaulting to PII means
  the *safe* outcome is the *automatic* one: the new type is masked/vaulted until
  a reviewer explicitly clears it as `:non_pii`. You opt **out** of protection,
  never into it.

  ## Three sources of truth, in precedence order

    1. **Composite PII types** (`Samen.Type.FullName/Emails/Phones` and any type
       that itself declares `samen_pii_class/0 => :pii`) — always `:pii`.
    2. **The explicit registry** below — the known scalar Ash primitives that are
       *not* PII by nature (`:boolean`, `:integer`, `:uuid`, timestamps, …).
       These are the only types allowed to be plain without a review.
    3. **Everything else → `:pii`** (the mask-unknown-by-default keystone).

  A type may self-classify by exporting `samen_pii_class/0` (returning `:pii` or
  `:non_pii`); this is how the composite types opt in and how a host application's
  custom type can declare its own class without editing this module.

  ## The `:non_pii` self-classification is reviewer-gated (ADR-034)

  Self-classifying `:pii` opts a type *into* protection and is always honored — no
  gate. Self-classifying `:non_pii` opts a whole type *out* of masking (every
  column plaintext/unmasked) and is the dangerous direction: left ungoverned it is
  a **single-party escape hatch** — one developer could wave an entire type out of
  the mask-unknown-by-default keystone with no second reviewer, while opting a
  single *column* out already demands the two-distinct-party `non_pii!` clearance
  (`Samen.NonPii.register/1`, which fails closed on `cleared_by == reviewed_by`).

  So a type's `:non_pii` self-classification is honored **only** when the type
  module carries a valid, two-distinct-party clearance in
  `Samen.NonPii.TypeClearance` (a config allowlist — `classify/1` is hot/pure and
  must never hit the DB). An ungoverned or self-reviewed `:non_pii`
  self-classification falls through to the **PII default** (masked) — fail-closed,
  the same safe direction the keystone already picks for unknown types. This makes
  opting a type out exactly as hard as opting a column out: two distinct parties.

  ## Relationship to the verifiers

  This registry is the *classification oracle* the C4 `pii_classify` verifier
  (T1.8c) consults. `pii_classify` scans NEW plain-typed columns and, for any
  type this registry calls `:pii`, fails the build until the field is declared in
  a `pii do` block or cleared by a review-gated `non_pii!` override. This module
  answers only the question "is THIS type PII?"; the verifier owns the scan and
  the override flow.
  """

  # Scalar Ash primitives that are structurally NOT PII. These are the only
  # non-PII defaults; anything not here (and not self-classifying as :non_pii)
  # is PII. Kept deliberately conservative — when in doubt, it is NOT on this list.
  @non_pii_scalars MapSet.new([
                     Ash.Type.Boolean,
                     Ash.Type.Integer,
                     Ash.Type.Float,
                     Ash.Type.Decimal,
                     Ash.Type.UUID,
                     Ash.Type.UUIDv7,
                     Ash.Type.Atom,
                     Ash.Type.UtcDatetime,
                     Ash.Type.UtcDatetimeUsec,
                     Ash.Type.NaiveDatetime,
                     Ash.Type.Time,
                     Ash.Type.DurationName
                   ])

  @doc """
  Classify a type as `:pii` or `:non_pii`.

  Accepts either a short Ash type name (`:string`, `:boolean`) or a resolved
  type module (`Ash.Type.String`, `Samen.Type.FullName`). Mask-unknown-by-default:
  anything not provably `:non_pii` is `:pii`.

  ## Examples

      iex> Samen.Pii.Classification.classify(:boolean)
      :non_pii

      iex> Samen.Pii.Classification.classify(Samen.Type.FullName)
      :pii

      # a custom/unknown type the registry has never seen → PII by default
      iex> Samen.Pii.Classification.classify(Some.Unregistered.Type)
      :pii
  """
  @spec classify(atom() | module()) :: :pii | :non_pii
  def classify(type) do
    module = resolve(type)

    cond do
      # (1) type self-classifies :pii (composite PII types + host custom types) —
      # opting INTO protection is always honored, no gate.
      self_class(module) == :pii ->
        :pii

      # (2) type self-classifies :non_pii — opting a whole type OUT of masking.
      # Honored ONLY behind a valid two-distinct-party clearance (ADR-034);
      # otherwise it falls through to the mask-unknown-by-default PII result.
      self_class(module) == :non_pii and Samen.NonPii.TypeClearance.cleared?(module) ->
        :non_pii

      # (3) a known non-PII scalar primitive
      is_atom(module) and MapSet.member?(@non_pii_scalars, module) ->
        :non_pii

      # (4) MASK-UNKNOWN-BY-DEFAULT — everything else is PII. This is also where an
      # UNGOVERNED :non_pii self-classification lands (fail-closed → treated as PII).
      true ->
        :pii
    end
  end

  @doc "Convenience: `true` iff `classify/1` returns `:pii`."
  @spec pii?(atom() | module()) :: boolean()
  def pii?(type), do: classify(type) == :pii

  @doc """
  Is this type explicitly classified (either self-classifying or in the non-PII
  registry)? `false` means "unclassified — falls through to the PII default."

  The C4 verifier uses this to distinguish a *deliberately* plain column from one
  that is plain only because its type is unknown (which the default masks).
  """
  @spec classified?(atom() | module()) :: boolean()
  def classified?(type) do
    module = resolve(type)

    case self_class(module) do
      # Self-classifying :pii is always an explicit classification.
      :pii ->
        true

      # A :non_pii self-classification counts as "classified" ONLY when it is
      # governed by a valid clearance (ADR-034). An ungoverned one is treated
      # exactly like an unknown type: it falls through to the PII default, so it
      # is NOT explicitly classified.
      :non_pii ->
        Samen.NonPii.TypeClearance.cleared?(module)

      nil ->
        is_atom(module) and MapSet.member?(@non_pii_scalars, module)
    end
  end

  # Resolve a short type name to its Ash type module. Unknown short names and
  # bare modules pass through unchanged (and thus classify as PII by default).
  defp resolve(type) when is_atom(type) do
    try do
      Ash.Type.get_type(type)
    rescue
      _ -> type
    end
  end

  defp resolve(type), do: type

  # A type may export `samen_pii_class/0 => :pii | :non_pii` to self-classify.
  # Guarded by ensure_compiled so it works during compilation.
  defp self_class(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_compiled(module),
         true <- function_exported?(module, :samen_pii_class, 0),
         class when class in [:pii, :non_pii] <- module.samen_pii_class() do
      class
    else
      _ -> nil
    end
  end

  defp self_class(_), do: nil
end
