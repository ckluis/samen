defmodule Samen.Support.Inbound.Sanitize do
  @moduledoc """
  Stored-XSS defense for inbound-email fields (T59; T111 lineage). The inbound
  `subject`, `html_body`/`text_body`, and sender `from_name` are ATTACKER-CONTROLLED
  and are rendered later in the agent-facing ticket UI. T111 (stored-XSS on a
  recipient-derived field) established the discipline: never let attacker HTML reach a
  render sink un-neutralized.

  This module **sanitizes the stored representation at ingest** (one of the two
  T111-endorsed strategies — "sanitize the stored html body" — rather than relying
  solely on render-time escaping). The stored value is inert-at-rest: a `<script>` /
  `<img onerror=…>` in any inbound field cannot execute when an agent later views the
  ticket, regardless of whether the render surface remembers to escape (defense in
  depth — the framework HEEx surfaces auto-escape too).

  ## What it does

  `plain_text/1`:

    1. drops `<script>…</script>` and `<style>…</style>` blocks WHOLESALE (tag AND
       content — an executable payload never survives as visible text either);
    2. strips every remaining `<…>` tag;
    3. HTML-entity-escapes any residual `<`, `>`, `&`, `"`, `'` so a lone/broken
       angle bracket cannot re-open a tag downstream.

  The result contains no live tag, no `onerror=`/`onload=` handler attached to a tag,
  and no bare `<`. It is a safe visible-text projection of the input — lossy by design
  (this is free-text conversation content, not markup we need to preserve).
  """

  @doc """
  Sanitize an untrusted inbound string to inert visible text. `nil` passes through.
  """
  @spec plain_text(String.t() | nil) :: String.t() | nil
  def plain_text(nil), do: nil

  def plain_text(str) when is_binary(str) do
    str
    |> drop_block("script")
    |> drop_block("style")
    |> strip_tags()
    |> escape_residual()
  end

  # Non-binary (defensive) — coerce then sanitize so a malformed adapter value cannot crash.
  def plain_text(other), do: other |> to_string() |> plain_text()

  # Remove `<tag ...>...</tag>` (case-insensitive, dotall) tag AND its content.
  defp drop_block(str, tag) do
    Regex.replace(~r/<#{tag}\b[^>]*>.*?<\/#{tag}\s*>/is, str, " ")
    # An unterminated `<script ...` with no closing tag: drop to end-of-string.
    |> then(fn s -> Regex.replace(~r/<#{tag}\b[^>]*>.*\z/is, s, " ") end)
  end

  # Strip any remaining REAL HTML tag — `<` immediately followed by a tag-name letter
  # or `/` (closing tag) or `!` (comment/doctype). A bare `<` used as a math/less-than
  # (`2 < 3`) is NOT a tag and is left for `escape_residual/1` to neutralize, preserving
  # legitimate free-text content while still killing any executable markup.
  defp strip_tags(str) do
    str
    |> then(&Regex.replace(~r/<!--.*?-->/s, &1, " "))
    |> then(&Regex.replace(~r/<\/?[a-zA-Z!][^>]*>/s, &1, " "))
    # A trailing unterminated real-tag opener (`<img ...` with no closing `>`).
    |> then(&Regex.replace(~r/<\/?[a-zA-Z!][^<]*\z/s, &1, " "))
  end

  # Escape any residual markup-significant characters so nothing can re-form a tag.
  defp escape_residual(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
