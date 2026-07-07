defmodule Samen.Aggregate.Suppressed do
  @moduledoc """
  `%Suppressed{}` — the **aggregate cell's fail-closed value** when a privacy floor
  fires (T4.5 clauses (a)+(b); doc §control ∴ block + the "Token-blind isn't
  inference-blind" honest edge).

  > the aggregate plane enforces today a minimum-cohort and minimum-distinct floor
  > (k-anonymity + l-diversity) …

  This is the direct analogue of `Samen.Masked` for the OUTPUT-privacy half of the
  two-plane story. Where `%Masked{}` is the vault field's normal value on the tenant
  plane (input privacy — a subject's PII never renders unless a grant reveals it),
  `%Suppressed{}` is an aggregate cell's value when its cohort is **too small
  (k-anonymity) or too homogeneous (l-diversity)** to release without re-identifying
  a subject.

  A `Suppressed` value carries only the *reason* the cell was withheld (`:k_anonymity`
  or `:l_diversity`) and the floor's parameters (`k` / `l` and the observed cohort
  metric) — it **never carries the underlying value**. There is therefore no value to
  leak by any serialization path. Rendering is `"⊘"` (the "suppressed" glyph)
  everywhere:

    - `String.Chars` (`to_string/1`, interpolation) → `"⊘"`
    - `Inspect` (`inspect/1`, logger `~p`) → `#Suppressed<k_anonymity ⊘>`
    - `Jason.Encoder` (JSON API / webhook payloads) → `{"suppressed": true, "reason": …}`

  ## Why a struct, not `nil` / `0`

  Returning `nil` or `0` for a suppressed cell is a leak by another name: a caller
  differencing two near-identical cohorts (the differencing attack the doc names)
  learns that a cell *dropped below the floor* — and `0` is indistinguishable from a
  real zero-count, which itself can be re-identifying. A distinct sentinel makes the
  suppression **explicit and inspectable** (a dashboard renders "⊘ suppressed" and can
  explain why) while never exposing the count-of-one value that triggered it. The
  observed metric it carries (`observed`) is the cohort SIZE that fell below `k`, or
  the DISTINCT-COUNT that fell below `l` — surfacing *that a floor fired* is the point
  of the honest posture; it is not the sensitive value itself.

  Fail closed: a cell is suppressed by REPLACING its value, so a serialization path
  that forgot about suppression (a raw `Jason.encode!`, a CSV row) still cannot emit
  the withheld number — it structurally isn't in the struct.
  """

  @glyph "⊘"

  @enforce_keys [:reason]
  defstruct reason: nil, k: nil, l: nil, observed: nil

  @type reason :: :k_anonymity | :l_diversity
  @type t :: %__MODULE__{
          reason: reason(),
          k: pos_integer() | nil,
          l: pos_integer() | nil,
          observed: non_neg_integer() | nil
        }

  @doc "The canonical suppression glyph."
  @spec glyph() :: String.t()
  def glyph, do: @glyph

  @doc """
  A k-anonymity suppression: the cohort count `observed` fell below the minimum
  cohort size `k`. Includes the count-of-one case (`observed == 1`).
  """
  @spec k_anonymity(pos_integer(), non_neg_integer()) :: t()
  def k_anonymity(k, observed) when is_integer(k) and is_integer(observed) do
    %__MODULE__{reason: :k_anonymity, k: k, observed: observed}
  end

  @doc """
  An l-diversity suppression: the cohort's count of DISTINCT sensitive values
  (`observed`) fell below the minimum `l`. This catches the homogeneity attack — a
  k-sized cohort where every member shares the sensitive value (`observed == 1`).
  """
  @spec l_diversity(pos_integer(), non_neg_integer()) :: t()
  def l_diversity(l, observed) when is_integer(l) and is_integer(observed) do
    %__MODULE__{reason: :l_diversity, l: l, observed: observed}
  end

  @doc "Is this value a suppressed aggregate cell? (structural guard for tests/callers)"
  @spec suppressed?(term()) :: boolean()
  def suppressed?(%__MODULE__{}), do: true
  def suppressed?(_), do: false

  defimpl String.Chars do
    def to_string(%Samen.Aggregate.Suppressed{}), do: Samen.Aggregate.Suppressed.glyph()
  end

  defimpl Inspect do
    def inspect(%Samen.Aggregate.Suppressed{reason: reason}, _opts) do
      # NEVER include the withheld value (there is none in the struct); surface only
      # the reason + glyph so a log line reads as a suppression, not a value.
      "#Suppressed<#{reason} #{Samen.Aggregate.Suppressed.glyph()}>"
    end
  end

  defimpl Jason.Encoder do
    def encode(%Samen.Aggregate.Suppressed{reason: reason}, opts) do
      # A machine-readable suppression marker for JSON API / webhook consumers. Carries
      # the reason (so a client can render "suppressed for privacy") but NOT the value.
      Jason.Encode.map(%{"suppressed" => true, "reason" => Atom.to_string(reason)}, opts)
    end
  end
end
