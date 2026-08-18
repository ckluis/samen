defmodule Samen.AI.Embedder.Deterministic do
  @moduledoc """
  The keyless, deterministic embedding engine (ADR-043 §4; M9 keyless CI) — the embeddings
  analog of `Samen.AI.Provider.Fake`. It is a `Samen.AI.Provider` so it dispatches through the
  ONE provider-invocation site (`Samen.AI.Chokepoint`), and it is the embedder an UNWIRED /
  keyless embeddings call resolves to in CI (`Samen.AI.Embeddings.embedder_for/2`): ZERO API
  keys, ZERO live calls, ZERO external dependency.

  ## Deterministic hashing embedder (same text ⇒ same vector)

  `embed/2` projects each sealed segment to a fixed-dimension (`dim/0 = #{64}`) vector by a
  stable bag-of-tokens hash: each whitespace token is SHA-256-hashed into a bucket in
  `0..dim-1` with a signed contribution, then the vector is L2-normalized. There is NO
  semantic quality (that is the `SAMEN_AI_LIVE=1` lane against a real embeddings model) — but
  it is *stable* and *content-sensitive*: identical text ⇒ identical vector (distance 0),
  shared tokens ⇒ nearer vectors, disjoint text ⇒ farther. That is exactly enough to make the
  T67 tests REAL in CI: ranking-shape (a query finds its own document first), org-scoping
  (org B's rows never rank for org A because they are filtered before ranking, not because the
  embedder is blind), and no-PII-in-vector (the chokepoint refuses before we are ever called).

  ## Fail-honest (ADR-014/024/026 — the `Samen.AI.Provider` contract)

  `complete/2` returns `{:error, :not_implemented}` — this engine embeds, it does not
  complete, and it says so honestly rather than fabricating a completion. A canned `{:ok, _}`
  is the exact lie the sabotage harness exists to catch.

  ## MaskedPayload-only, by construction

  Both callbacks pattern-match `%Samen.AI.MaskedPayload{}` in the head — a raw string/map
  refuses by `FunctionClauseError`, so even the keyless embedder cannot be handed unsealed
  content. It is invoked ONLY by the chokepoint (`Samen.AI.Chokepoint.embed/4`), whose
  fail-closed `:embed` scrub has already refused any vault-routed / `vt_*`-bearing input
  (§7.2) before a single byte reaches `embed/2`.
  """

  @behaviour Samen.AI.Provider

  alias Samen.AI.MaskedPayload

  # The fixed embedding dimension. Deferred to T67 per ADR-043 §11 — 64 is small enough to keep
  # CI fast and the `aie_embedding.aie_embedding vector(64)` column tight, wide enough that the
  # per-token bucket projection separates distinct documents. The `Samen.AI.Embeddings`
  # migration MUST match this (`vector(#{64})`); `dim/0` is the single source of truth both
  # read, so the column width and the embedder can never silently drift.
  @dim 64

  @doc "The fixed embedding dimension (the single source of truth for the vector column width)."
  @spec dim() :: pos_integer()
  def dim, do: @dim

  @impl Samen.AI.Provider
  def embed(%MaskedPayload{} = payload, config) when is_map(config) do
    case Map.get(config, :error) do
      nil -> {:ok, Enum.map(payload.segments, &vector/1)}
      err -> {:error, err}
    end
  end

  @impl Samen.AI.Provider
  def complete(%MaskedPayload{}, config) when is_map(config) do
    # Fail-honest: this engine has no completion capability (embed-only). NEVER a canned ok.
    {:error, :not_implemented}
  end

  @impl Samen.AI.Provider
  def simulated?, do: true

  @doc """
  Embed a single already-scrubbed segment to a `dim/0`-length unit vector. Public so the
  `Samen.AI.Embeddings` plane can embed a query string the same way it embedded documents
  (identical projection ⇒ a self-query lands at distance 0).
  """
  @spec vector(term()) :: [float()]
  def vector(segment) do
    text = to_string_safe(segment)

    raw =
      text
      |> tokenize()
      |> Enum.reduce(zeros(), fn token, acc -> add_token(acc, token) end)

    normalize(raw)
  end

  # --- projection --------------------------------------------------------------------------

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
  end

  # Each token contributes ±1 to a hashed bucket: bucket = hash mod dim; sign = a second hash
  # bit. A stable, order-independent bag-of-tokens projection (the "hashing trick").
  defp add_token(acc, token) do
    <<h::unsigned-integer-size(64), s::unsigned-integer-size(8), _::binary>> =
      :crypto.hash(:sha256, token)

    bucket = rem(h, @dim)
    delta = if rem(s, 2) == 0, do: 1.0, else: -1.0
    List.update_at(acc, bucket, &(&1 + delta))
  end

  defp zeros, do: List.duplicate(0.0, @dim)

  # L2-normalize so cosine/L2 distance ranks by direction, and an all-empty (tokenless) text
  # maps to the zero vector (a stable, valid `vector` — distance is defined, just uninformative).
  defp normalize(vec) do
    mag = :math.sqrt(Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end))
    if mag == 0.0, do: vec, else: Enum.map(vec, &(&1 / mag))
  end

  defp to_string_safe(seg) when is_binary(seg), do: seg
  defp to_string_safe(seg) when is_number(seg), do: to_string(seg)
  defp to_string_safe(seg) when is_atom(seg), do: Atom.to_string(seg)
  defp to_string_safe(seg), do: inspect(seg)
end
