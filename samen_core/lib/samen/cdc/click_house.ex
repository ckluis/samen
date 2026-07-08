defmodule Samen.Cdc.ClickHouse do
  @moduledoc """
  **Production skeleton** for the real ClickHouse CDC mirror (plan T6.5; doc line
  635). Config-flagged, **NOT connected in this repo** — there is no ClickHouse in
  this environment (plan HARD note), so this module is a documented seam, not a
  faked pass.

  In production the analytics tier is a second Ecto repo backed by the `ecto_ch`
  adapter, fed by native CDC (ClickPipes / PeerDB) mirroring the append-only event
  stream. The safety contract is IDENTICAL to the local simulation
  (`Samen.Cdc.LocalPostgres`): token-blind rows only, never-read-current — because
  `Samen.Cdc.Projection` (the load-bearing mechanism) is adapter-independent.

  ## Operator TODO — real ClickPipes wiring

  To turn this on in a real deployment (doc line 635 "flip on the managed
  clickhouse.com/cloud/postgres path"):

    1. Add `{:ecto_ch, "~> 0.3"}` to the host app's deps.
    2. Define a real repo:

           defmodule MyApp.CdcRepo do
             use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.ClickHouse
           end

    3. Provision a ClickHouse Cloud service and a **ClickPipes** (or PeerDB) CDC
       pipe from the primary Postgres. Scope the pipe's column allow-list to the
       `Samen.Cdc.Projection` output — the pipe must be configured to mirror ONLY
       the projected token-blind columns. A `pii_` plaintext column in the pipe's
       column list is the exact red path the oracle catches; the allow-list is the
       production analogue of the projection's `assert_no_plaintext!/1`.

           # OPERATOR TODO: generate the ClickPipes table+column allow-list from
           #   `Samen.Cdc.Projection.project(resource)` for each mirrored resource,
           #   and diff it against the live pipe config in CI so a new plaintext
           #   column can never be silently added to the pipe.

    4. Wire it:

           config :samen_core, :cdc,
             adapter: Samen.Cdc.ClickHouse,
             repo: MyApp.CdcRepo

    5. Point the destruction oracle's `cdc_mirror` tier at it: `--tiers all` then
       scans the real mirror for token-only + post-shred unrecoverability. Because
       the mirror carries only `vt_*` tokens whose per-subject vault key is
       destroyed on erasure, a shred renders the mirrored rows undecryptable across
       the analytics tier "for free" (doc line 637) — the same key-destruction that
       covers live/replica/backup/rollup/audit.

  ## Why the callbacks raise here

  Every callback raises `:not_connected`: a host that wires this adapter WITHOUT
  completing the ClickPipes/`ecto_ch` steps above must fail LOUDLY, never
  silently pass. The local simulation (`LocalPostgres`) is what runs in CI; this
  skeleton exists so the production shape is real code, reviewable and typed,
  rather than prose.
  """

  @behaviour Samen.Cdc

  @not_connected "Samen.Cdc.ClickHouse is a production SKELETON — ecto_ch is not " <>
                   "connected in this environment. Complete the ClickPipes operator TODO " <>
                   "(see @moduledoc) and use Samen.Cdc.LocalPostgres for local/CI runs."

  @impl Samen.Cdc
  def ensure_mirror(_table, _columns), do: {:error, :not_connected}

  @impl Samen.Cdc
  def mirror_row(_table, _columns, _values, _opts), do: {:error, :not_connected}

  @impl Samen.Cdc
  def mirrored_columns(_table, _opts), do: {:error, :not_connected}

  @impl Samen.Cdc
  def scan_no_plaintext(_subject_id, _opts) do
    # Fail closed: an ENABLED-but-unconnected ClickHouse mirror must NOT report a
    # clean scan — a configured-but-unscanned mirror is a gap (T2.9/T6.5 rule).
    {:leaks, [@not_connected]}
  end

  @impl Samen.Cdc
  def read_current(table, key, _opts) do
    raise Samen.Cdc.NeverReadCurrent.Violation,
      message:
        "read_current/3 on the ClickHouse analytics mirror (table=#{inspect(table)}, " <>
          "key=#{inspect(key)}) — never read a 'current' value from the analytics tier " <>
          "(doc line 635). It is seconds-stale by construction."
  end
end
