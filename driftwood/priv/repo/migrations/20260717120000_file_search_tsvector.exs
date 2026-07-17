defmodule Driftwood.Repo.Migrations.FileSearchTsvector do
  @moduledoc """
  WS-E E4.1 (ADR-027) — the tsvector-populate trigger + GIN functional index for the
  framework-owned searchable column: `ffl_file`'s non-PII `filename` + `content_type`.

  This is the FRAMEWORK-OWNED searchable column the E4 design bounds the trigger to
  (ADR-027 §4). Two parts:

    * a BEFORE INSERT/UPDATE trigger that keeps `ffl_search_vector` populated with the
      `to_tsvector` of the non-PII `filename`/`content_type` (observable materialization
      of what is indexed — the "tsvector-populate trigger" the design names). `coalesce`
      makes it null-safe; no insert/update path can fail on it.
    * a GIN FUNCTIONAL index on the SAME expression the kernel `Samen.Search` engine
      builds at query time (`to_tsvector('english', coalesce(filename,'') || ' ' ||
      coalesce(content_type,''))`), so a File search registering both non-PII columns is
      index-backed.

  Only `filename`/`content_type` are indexed — both non-PII (the `SearchIndexGuard`
  refuses a vault-routed column, so a tsvector can never index ciphertext). Other
  resources are searchable via the same query-time expression and get their own GIN
  index as a documented follow-on when a host registers them (E4-P2 carry).
  """
  use Ecto.Migration

  @config "english"

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION ffl_file_search_vector_update() RETURNS trigger AS $$
    BEGIN
      NEW.ffl_search_vector :=
        to_tsvector('#{@config}',
          coalesce(NEW.ffl_filename, '') || ' ' || coalesce(NEW.ffl_content_type, ''))::text;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER ffl_file_search_vector_trg
    BEFORE INSERT OR UPDATE OF ffl_filename, ffl_content_type ON ffl_file
    FOR EACH ROW EXECUTE FUNCTION ffl_file_search_vector_update();
    """)

    execute("""
    CREATE INDEX ffl_file_search_gin_idx ON ffl_file
    USING gin (to_tsvector('#{@config}',
      coalesce(ffl_filename, '') || ' ' || coalesce(ffl_content_type, '')));
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS ffl_file_search_gin_idx")
    execute("DROP TRIGGER IF EXISTS ffl_file_search_vector_trg ON ffl_file")
    execute("DROP FUNCTION IF EXISTS ffl_file_search_vector_update()")
  end
end
