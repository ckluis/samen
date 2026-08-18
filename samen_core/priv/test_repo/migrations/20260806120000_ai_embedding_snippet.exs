defmodule SamenCore.TestRepo.Migrations.AiEmbeddingSnippet do
  @moduledoc """
  T152 (DOGFOOD W2, B-W2-3): add `aie_snippet` to `aie_embedding` so a `%Samen.AI.Embeddings.Hit{}`
  is SELF-DESCRIBING — a caller sees WHAT matched without a second fetch of the source row.

  ## Why storing a snippet beside the vector is masking-safe (the deny-by-default argument)

  The original `aie_embedding` migration deliberately persisted "NEVER the source TEXT". That
  posture was defense-in-depth, NOT a correctness requirement — and it is satisfied here by the
  SAME construction that makes embedding safe: a field is embeddable ONLY if it is DECLARED
  embeddable AND is NOT vault-routed (`Samen.AI.Embeddings.assert_embeddable/2` + the
  `EmbeddableNoPii` compile verifier + the `ai_prompt_masking` ci.sh verifier + the chokepoint
  `:embed` scrub — four layers). So an embedded field is **non-PII by construction**, and a
  bounded excerpt of it carries no 🔒 value, no `%Samen.Masked{}`, and no `vt_*` token. The
  snippet follows the exact lifecycle of the vector it sits beside (embed-on-write upsert), so
  it never drifts past the deny-by-default guarantee. `Samen.AI.Embeddings.snippet_of/1` is the
  belt to this brace: it stores a snippet only for a `vt_`-free binary and `nil` for anything
  else (a masked/non-binary value ⇒ no snippet at all).

  Nullable: rows embedded before this migration (and any non-binary field value) simply carry a
  `NULL` snippet — the Hit's `:snippet` is then `nil`, never a fabricated excerpt.
  """
  use Ecto.Migration

  def up do
    alter table(:aie_embedding) do
      add(:aie_snippet, :text)
    end
  end

  def down do
    alter table(:aie_embedding) do
      remove(:aie_snippet)
    end
  end
end
