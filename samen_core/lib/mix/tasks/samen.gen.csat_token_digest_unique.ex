defmodule Mix.Tasks.Samen.Gen.CsatTokenDigestUnique do
  @shortdoc "Write the retrofit migration that makes every CSAT survey-token digest unique."

  @moduledoc """
  `mix samen.gen.csat_token_digest_unique` — the retrofit for an app generated BEFORE the CSAT survey-token digest was
  unique. The survey link is a random 32-byte token stored as a SHA-256 digest; `preview` reads the row by digest with
  `limit(1)` and `respond` consumes by digest. The index on the digest was a PLAIN one, so one-row-per-digest was luck,
  not a guarantee. The template change sits inside the app's FIRST migration, which an existing app has already run.
  Run this inside the app, then `mix ecto.migrate`.

  It shares its engine with `mix samen.gen.api_key_digest_unique` (`Mix.Tasks.Samen.Gen.ApiKeyDigestUnique.run_kind/2`)
  and behaves the same way: ONE migration, `<ts>_csat_token_digest_unique.exs`, with `concurrent_unique_index/3` per
  table (`CREATE UNIQUE INDEX CONCURRENTLY`, outside the DDL transaction), a duplicate pre-count that RAISES naming the
  table and column without deleting or printing anything, and literal table, column and index names. Because the new
  unique index serves the same lookup, the plain `<table>_digest_idx` the first migration created is dropped after it
  is built, and `down` rebuilds it first.

  Which tables: every resource of the app's `:ash_domains` whose table ends in `_csat_survey_token` and that has a
  `*_token_digest` attribute (`--domain`, repeatable), plus any `--key table:column` (when given, ONLY these are used).
  A table that already has the unique index in the app's migrations is skipped; with nothing left it writes nothing.

  ## Usage

      mix samen.gen.csat_token_digest_unique [--out path] [--timestamp 20261120100000] [--domain MyApp.Support …] [--key table:column …]
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Tasks.Samen.Gen.ApiKeyDigestUnique.run_kind(argv, :csat)
end
