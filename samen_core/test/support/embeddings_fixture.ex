defmodule SamenCore.Support.EmbeddingsDomain do
  @moduledoc "Kernel test fixture domain for the D3 embeddings plane (ADR-043 §7, T67)."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.EmbeddingsDomain.Article)
  end
end

defmodule SamenCore.Support.EmbeddingsDomain.Article do
  @moduledoc """
  T67 embeddings POSITIVE-control fixture — a resource that legitimately DECLARES a non-PII
  field embeddable via the new `use Samen.Resource, embeddable: [...]` DSL.

  `:body` is non-PII free text. The base macro injects `embeddable_fields/0 → [:body]` (reading
  the `samen` section), so:

    * the `Samen.AI.Embeddings` plane embeds `:body` and semantic search finds it — the
      non-vacuous positive control that the refutations elsewhere are not blanket-failing;
    * the `ai_prompt_masking` verifier's (b) cross-check binds to a REAL declaration and stays
      GREEN (a non-PII embeddable field is no violation).

  Postgres-backed (`emb_article`; `use Samen.Resource` injects select-by-default-false core
  columns that ETS rejects, so a real data layer is required). The plane embeds field VALUES off
  records and stores VECTORS keyed by record id + org_id in the plain Ecto `aie_embedding` table.
  It carries no vault field (the vault-routed NEGATIVE control reuses
  `SamenCore.Support.RevealDomain.RevealPerson`, which has a real 🔒 field). NOT registered in
  `:ash_domains` (like `RevealDomain`), so no verifier gate scans it beyond the explicit tests.

  The compile-time refusal (declaring a 🔒 field embeddable) is proven by a scratch-compile red
  path in the test, not a committed fixture — a `use Samen.Resource, embeddable: [🔒]` resource
  cannot compile, so it can never be committed.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.EmbeddingsDomain,
    data_layer: AshPostgres.DataLayer,
    abbrev: "emb",
    embeddable: [:body]

  postgres do
    table("emb_article")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:title, :string, public?: true)
    # The legitimately-declared embeddable field: non-PII free text.
    attribute(:body, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
