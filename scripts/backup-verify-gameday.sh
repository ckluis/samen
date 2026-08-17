#!/usr/bin/env bash
# backup-verify-gameday.sh — L6 / T92 local game-day for backup VERIFICATION.
#
# Exercises Samen.Backup.Verification.verify/1 end-to-end against REAL bytes via
# Samen.Backup.Restore.LocalPgDump, for the three outcomes an operator must trust:
#
#   CLEAN    dump  -> {:ok, _}                       (a good backup restores + matches)
#   CORRUPT  dump  -> {:error, {:restore_failed,_}}  (a torn artifact is caught)
#   MISSING  dump  -> {:error, {:restore_failed, {:artifact_missing,_}}}
#
# This is the LOCAL stand-in for the real quarterly drill (docs/runbooks/backup-
# cadence.md). A real cloud restore target (Neon PITR / S3 artifact, L1/L3) is a
# credential-gated operator TODO and is deliberately NOT wired here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DB="samen_core_gameday_src"
SCRATCH_DB="samen_core_gameday_scratch"
USER_NAME="${USER:-postgres}"
DUMP="$(mktemp -t backup_gameday.XXXXXX).dump"
CORRUPT="${DUMP}.corrupt"

cleanup() {
  dropdb --if-exists "$SRC_DB" >/dev/null 2>&1 || true
  dropdb --if-exists "$SCRATCH_DB" >/dev/null 2>&1 || true
  rm -f "$DUMP" "$CORRUPT"
}
trap cleanup EXIT

for bin in pg_dump pg_restore createdb dropdb psql; do
  command -v "$bin" >/dev/null 2>&1 || { echo "MISSING TOOL: $bin (Postgres client tools required)"; exit 1; }
done

echo "==> Seeding throwaway source DB '$SRC_DB' with real rows"
dropdb --if-exists "$SRC_DB" >/dev/null 2>&1 || true
createdb "$SRC_DB"
psql -d "$SRC_DB" -v ON_ERROR_STOP=1 -c \
  "CREATE TABLE bkp_widget (id int primary key, label text);
   INSERT INTO bkp_widget VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d'),(5,'e');" >/dev/null

echo "==> Taking backup (pg_dump -Fc) -> $DUMP"
pg_dump -Fc -f "$DUMP" "$SRC_DB"

echo "==> Making a CORRUPT copy (truncated to 128 bytes)"
head -c 128 "$DUMP" > "$CORRUPT"

echo "==> Running verify/1 for CLEAN / CORRUPT / MISSING"
cd "$REPO_ROOT/samen_core"
DUMP="$DUMP" CORRUPT="$CORRUPT" SRC_DB="$SRC_DB" SCRATCH_DB="$SCRATCH_DB" USER_NAME="$USER_NAME" \
  mix run -e '
    alias Samen.Backup.Verification
    alias Samen.Backup.Restore.LocalPgDump

    user = System.get_env("USER_NAME")
    {:ok, src} = Postgrex.start_link(hostname: "localhost", username: user, database: System.get_env("SRC_DB"))
    expected = Verification.manifest(%{query: fn s, p ->
      {:ok, r} = Postgrex.query(src, s, p); {:ok, %{rows: r.rows}}
    end}, ["bkp_widget"])
    GenServer.stop(src)

    scratch = System.get_env("SCRATCH_DB")
    run = fn label, path ->
      res = Verification.verify(adapter: LocalPgDump,
              config: %{dump_path: path, scratch_database: scratch},
              expected_manifest: expected)
      IO.puts("  #{label}: #{inspect(res)}")
      res
    end

    clean   = run.("CLEAN  ", System.get_env("DUMP"))
    corrupt = run.("CORRUPT", System.get_env("CORRUPT"))
    missing = run.("MISSING", "/nonexistent/nope.dump")

    ok = match?({:ok, _}, clean) and match?({:error, _}, corrupt) and match?({:error, _}, missing)
    if ok do
      IO.puts("\nBACKUP-VERIFY GAME-DAY: PASSED (clean verified; corrupt + missing correctly refused)")
    else
      IO.puts("\nBACKUP-VERIFY GAME-DAY: FAILED"); System.halt(1)
    end
  '
