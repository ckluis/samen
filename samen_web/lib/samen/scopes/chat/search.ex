defmodule Samen.Scopes.Chat.Search.Hit do
  @moduledoc """
  One chat full-history search hit (T61 / C7). `record` is the matched `ChatMessage`
  ALREADY resolved through `Samen.Api.PiiResolution` on the actor's plane; `snippet` is a
  bounded excerpt built ONLY from a body the actor was authorized to read (a masked /
  forbidden body is never matched and never excerpted). Render `snippet` through an
  escaping component (`Samen.Scopes.Chat.SearchComponents.search_results/1`) — the stored
  chat text is untrusted.
  """
  @enforce_keys [:id, :thread_id, :record, :snippet]
  defstruct [:id, :thread_id, :record, :snippet]

  @type t :: %__MODULE__{
          id: term(),
          thread_id: term(),
          record: struct(),
          snippet: String.t()
        }
end

defmodule Samen.Scopes.Chat.Search do
  @moduledoc """
  Full-history chat search, PII-MASKED at query time (T61 / C7). The security crux: chat
  message `body` is VAULT-ROUTED 🔒 PII. A naive full-text index over the body would leak
  vaulted content OR build a presence-oracle. This module is the provably-safe design.

  ## The safe design — MATCH AUTHORITY == READ AUTHORITY (no oracle)

  Search does NOT tsvector-index the body (the body column holds ciphertext at rest, and
  `Samen.Scopes.Primitives.SearchIndexGuard` structurally REFUSES registering any
  `pii_attribute` column into the `SearchIndex` — so the vaulted body can never enter an
  index as plaintext). Instead, `query/4`:

    1. **Org-scoped candidate read (by construction).** Reads a BOUNDED, keyset-ordered
       window of the actor's OWN org messages via `Ash.read!(scope: scope)` — the
       resource's `OrgScope` read policy applies, so org A's search can NEVER see org B's
       messages.
    2. **Resolve on the actor's plane.** Every candidate is projected through
       `Samen.Api.PiiResolution.resolve/4` on the acting scope's plane — exactly the
       kernel masking chokepoint. Tenant (and operator-WITH-grant) get the plaintext body;
       operator-WITHOUT-grant gets `%Samen.Masked{}` (`••••`).
    3. **Match over the RESOLVED value.** The term is matched against the body the actor is
       AUTHORIZED to read. A `%Masked{}` / `%Ash.ForbiddenField{}` body is treated as
       unmatchable (never coerced to a string to test), so:

         * an operator-WITHOUT-grant matches ZERO vaulted bodies — it cannot get a hit, a
           snippet, a `vt_*` token, NOR confirm presence/absence of a substring. Searching
           for a PII substring that IS present and one that is NOT are INDISTINGUISHABLE
           (both `[]`) — there is **no match-oracle**.
         * a tenant / operator-WITH-grant matches over its own plaintext and gets a
           plaintext snippet — because it was already authorized to READ that body.

  So a plane can only MATCH content it may READ. This is option (1) of the T61 brief
  (resolve-on-plane + the same masking applied to results) fused with option (3) (a
  no-grant actor's search does not match vaulted bodies at all).

  ## Bounded (reuse the Reads discipline)

  The candidate window is `Samen.Web.Reads.bounded_page_size/1`-clamped (1..200) and
  keyset-ordered `inserted_at desc`; returned hits are capped by `:limit` (default 20).
  No unbounded scan, no full-table dump. A blank term fails closed to `[]`.

  ## Framework-first / first client

  Lives in the `Samen.Scopes.Chat` library — a vertical that `use Samen.Scopes.Chat`s
  (driftwood is the first client) adopts full-history masked search at ≈0 authored LOC;
  the web wiring passes the mount's `message_resource` + `:repo`.
  """

  alias Samen.Scopes.Chat.Search.Hit

  @default_limit 20
  @default_max_scan 200
  @snippet_window 160

  @doc """
  Search `term` across the actor's org chat history, returning masked-safe `%Hit{}`s.

    * `scope`            — the acting `%Samen.Scope{}` (carries the plane + org).
    * `message_resource` — the host's mounted `ChatMessage` module.
    * `term`             — the search term (blank → `[]`, fail-closed).
    * `opts`:
      * `:repo`      — REQUIRED. The vault repo `PiiResolution` resolves through.
      * `:grant`     — optional reveal authority forwarded to `PiiResolution` (an
        operator-WITH-grant that may read the body may therefore match it). Defaults to
        the global `Samen.Reveal.grant_checker/0` (DenyAll) — a no-grant operator.
      * `:limit`     — max hits returned (default #{@default_limit}).
      * `:max_scan`  — candidate window size, clamped to 1..200 (default #{@default_max_scan}).
  """
  @spec query(map(), module(), term(), keyword()) :: [Hit.t()]
  def query(scope, message_resource, term, opts \\ []) do
    case normalize(term) do
      "" ->
        []

      needle ->
        repo = Keyword.fetch!(opts, :repo)
        grant = Keyword.get(opts, :grant)
        limit = Keyword.get(opts, :limit, @default_limit)
        max_scan = Samen.Web.Reads.bounded_page_size(Keyword.get(opts, :max_scan, @default_max_scan))

        message_resource
        |> candidate_window(scope, max_scan)
        |> resolve_on_plane(message_resource, scope, repo, grant)
        |> Enum.reduce_while([], fn record, acc ->
          case matched_snippet(record, needle) do
            nil -> {:cont, acc}
            snippet -> {:cont, [to_hit(record, snippet) | acc]}
          end
          |> bound(limit)
        end)
        |> Enum.reverse()
    end
  end

  # -- candidate read: org-scoped + keyset-bounded -----------------------------

  defp candidate_window(message_resource, scope, max_scan) do
    message_resource
    |> Ash.Query.new()
    |> Ash.Query.ensure_selected([:body])
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(max_scan)
    |> Ash.read!(scope: scope)
  end

  # -- per-plane resolution (the masking chokepoint) ---------------------------

  defp resolve_on_plane(rows, message_resource, scope, repo, grant) do
    resolve_opts = if grant, do: [repo: repo, grant: grant], else: [repo: repo]
    Samen.Api.PiiResolution.resolve(rows, message_resource, actor_of(scope), resolve_opts)
  end

  # -- match over the RESOLVED value + safe snippet ----------------------------

  # Match ONLY over a body the actor was authorized to read (a real binary). A masked /
  # forbidden body is unmatchable — never coerced to a string to test — so a no-grant
  # actor can neither match nor build a presence-oracle.
  defp matched_snippet(record, needle) do
    case authorized_body(record) do
      nil ->
        nil

      body ->
        if String.contains?(String.downcase(body), needle), do: excerpt(body, needle), else: nil
    end
  end

  defp authorized_body(%{body: body}) when is_binary(body), do: body
  defp authorized_body(_), do: nil

  # A bounded excerpt centered on the match. Returned as a plain string — the rendering
  # component (`search_results/1`) HTML-escapes it, so attacker chat markup is inert.
  defp excerpt(body, needle) do
    down = String.downcase(body)
    idx = :binary.match(down, needle) |> case_index()
    half = div(@snippet_window, 2)
    start = max(idx - half, 0)
    slice = String.slice(body, start, @snippet_window)
    prefix = if start > 0, do: "…", else: ""
    suffix = if start + @snippet_window < String.length(body), do: "…", else: ""
    prefix <> slice <> suffix
  end

  defp case_index({idx, _len}), do: idx
  defp case_index(_), do: 0

  defp to_hit(record, snippet) do
    %Hit{
      id: Map.get(record, :id),
      thread_id: Map.get(record, :thread_id),
      record: record,
      snippet: snippet
    }
  end

  # -- bounding + helpers ------------------------------------------------------

  defp bound({:cont, acc}, limit) when length(acc) >= limit, do: {:halt, acc}
  defp bound(step, _limit), do: step

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(%{actor: actor}) when is_map(actor), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp normalize(term) when is_binary(term), do: term |> String.trim() |> String.downcase()
  defp normalize(nil), do: ""
  defp normalize(term), do: term |> to_string() |> String.trim() |> String.downcase()
end
