defmodule Samen.Web.Board do
  @moduledoc """
  One GROUPED, per-group-bounded read — the value `Samen.Web.Reads.group_by!/3` returns
  to a grouped view (kanban board, calendar, gallery, tree). The generic analogue of
  `Samen.Web.Page`: where `%Page{}` is one keyset window of a flat list, `%Board{}` is an
  ORDERED list of `%Board.Group{}` buckets (group key → its bounded rows), suitable for a
  board whose COLUMNS are the groups (G1 kanban, WS-G) and reusable by calendar/gallery/tree
  later (columns = days / sections / nodes).

  ## Dumb carrier (same masking posture as `%Page{}`)

  The board struct never inspects, coerces, or stringifies a field value. Each group's
  `rows` are whatever the read produced — on the tenant plane, plaintext-resolved records;
  on the operator plane, records whose vaulted fields are `%Samen.Masked{}` (→ `••••`). The
  caller runs `Samen.Api.PiiResolution` over `rows` exactly as a `%Page{}` caller does; the
  board never plaintext-downgrades. The GROUP KEY and COUNT are always a NON-VAULTED field
  (`Samen.Web.Reads.group_by!/3` REFUSES a vault-routed group field), so no plaintext or
  vault token can leak through a column header or count (INV-1).

  ## Bounding (no unbounded board)

  Each `%Board.Group{}` is bounded to `per_group_limit` rows by construction — a hot column
  in a 10k-row pipeline returns at most the cap plus a `has_more` flag and an exact `count`,
  never the whole column. The number of columns is itself bounded (`max_groups`). Total rows
  transferred ≤ `length(groups) * (per_group_limit + 1)`. `next_cursor` on each group is the
  keyset cursor (`Samen.Web.Reads.cursor_for/2`) AFTER that column's last row, so a column is
  keyset-paginatable ("load more in this column") without ever having loaded the full set.
  """

  alias Samen.Web.Board.Group

  defstruct groups: [], group_field: nil, per_group_limit: nil, max_groups: nil

  @type t :: %__MODULE__{
          groups: [Group.t()],
          group_field: atom() | nil,
          per_group_limit: pos_integer() | nil,
          max_groups: pos_integer() | nil
        }

  defmodule Group do
    @moduledoc """
    One bucket of a `%Samen.Web.Board{}` — a group key, its display label, and the group's
    per-group-BOUNDED rows.

      * `key`         — the stored group value the rows share (`nil` = the uncategorized
        bucket: rows whose group field is `NULL`). NEVER a vaulted/plaintext value.
      * `label`       — the caller's display label for the column (defaults to the key).
      * `rows`        — at most `per_group_limit` rows (a dumb list; the caller PII-resolves).
      * `count`       — the EXACT total rows in this group for `scope` (a DB `count`
        aggregate — no row transfer), or `nil` when counting was disabled. Powers a
        "N in stage" / "+M more" header without loading the whole column.
      * `has_more`    — `true` when the group holds MORE than `per_group_limit` rows (the
        `limit(cap + 1)` probe row was seen); the column was capped, not fully loaded.
      * `next_cursor` — the opaque server-side keyset cursor AFTER the last returned row
        (`{sort_value, id}`), so the column is keyset-paginatable later. Never serialized.
    """
    defstruct key: nil, label: nil, rows: [], count: nil, has_more: false, next_cursor: nil

    @type t :: %__MODULE__{
            key: term() | nil,
            label: term() | nil,
            rows: [term()],
            count: non_neg_integer() | nil,
            has_more: boolean(),
            next_cursor: term() | nil
          }
  end
end
