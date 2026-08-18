defmodule Samen.Web.Tree do
  @moduledoc """
  One HIERARCHICAL, DEPTH-BOUNDED + CYCLE-SAFE read — the value `Samen.Web.Reads.tree!/3`
  returns to a tree view (`Samen.UI.tree/1`, G6/WS-G). The hierarchical analogue of
  `Samen.Web.Board`: where `%Board{}` is an ORDERED set of per-column-bounded buckets, a
  `%Tree{}` is a FOREST of `%Tree.Node{}` — each node a record plus its per-parent-BOUNDED,
  depth-limited children (loaded from a self-referential parent pointer, e.g. Work `Task`'s
  `:parent_id`). First client: the Work Task tree (`Samen.Web.Work.TaskTreeLive`).

  ## Dumb carrier (same masking posture as `%Board{}`/`%Page{}`)

  The tree struct never inspects, coerces, or stringifies a field value. Each node's `record`
  is whatever the read produced — on the tenant plane, plaintext-resolved; on the operator
  plane, records whose vaulted fields are `%Samen.Masked{}` (→ `••••`). The caller runs
  `Samen.Api.PiiResolution` over the records exactly as a `%Page{}`/`%Board{}` caller does; the
  tree never plaintext-downgrades. The STRUCTURAL key (`parent_field`) is always a non-vaulted
  attribute (`tree!/3` REFUSES a vault-routed parent field), so no plaintext or vault token can
  drive the hierarchy (INV-1).

  ## Bounding (no unbounded tree) — three independent hard bounds

    * **Per-parent (per-level) cap** — each node's children are read with a
      `limit(sibling_limit + 1)` probe, so a node with thousands of children returns at most
      `sibling_limit` (`has_more_children` + exact `child_count` power a "+N more" affordance),
      never the whole fan-out (the board's per-column cap, applied per node).
    * **Depth cap** — the walk descends at most `max_depth` levels; a node at the boundary that
      still has children is a `truncated: :depth` node (offer a "drill in here" link), never an
      unbounded descent.
    * **Total-node budget** — a hard `max_nodes` cap across the whole walk; once exhausted, the
      next node is a `truncated: :budget` leaf. Worst-case nodes materialized ≤ `max_nodes`.

  ## Cycle safety

  A corrupted self-referential chain (a node that is its own transitive ancestor via bad
  `parent_id` data — the CycleGuard prevents this on WRITE, but a read must never TRUST the
  data) is detected by a `visited` id set threaded through the walk: a node whose id was
  already expanded higher on the path is a `truncated: :cycle` leaf and is NOT descended into —
  the walk always terminates, never stack-overflows or infinite-loops.
  """

  alias Samen.Web.Tree.Node

  defstruct roots: [],
            parent_field: nil,
            node_count: 0,
            sibling_limit: nil,
            max_depth: nil,
            max_nodes: nil,
            truncated?: false

  @type t :: %__MODULE__{
          roots: [Node.t()],
          parent_field: atom() | nil,
          node_count: non_neg_integer(),
          sibling_limit: pos_integer() | nil,
          max_depth: pos_integer() | nil,
          max_nodes: pos_integer() | nil,
          truncated?: boolean()
        }

  defmodule Node do
    @moduledoc """
    One node of a `%Samen.Web.Tree{}` — a record, its depth, and its per-parent-BOUNDED,
    depth-limited children.

      * `record`            — the row (a dumb term; the caller PII-resolves it). NEVER inspected.
      * `id`                — the record's `:id` (a non-PII opaque uuid; the DOM/tree key and the
        `visited` cycle-detection key).
      * `depth`             — 0 for a top-level (root) node, +1 per level down.
      * `children`          — at most `sibling_limit` loaded child nodes (`[]` for a leaf OR a
        `truncated` node whose children were NOT loaded).
      * `child_count`       — the EXACT number of direct children for `scope` (a DB `count`
        aggregate — no row transfer), or `nil` when counting was disabled / the node was not
        expanded. Powers a "+N more" without loading the whole fan-out.
      * `has_more_children` — `true` when the node holds MORE than `sibling_limit` direct
        children (the `limit(cap + 1)` probe row was seen); the level was capped.
      * `expandable?`       — `true` when there is (or may be) more to see below this node: it
        has loaded children, was capped (`has_more_children`), or was `truncated` by
        depth/budget. `false` for a genuine leaf and for a `:cycle` node.
      * `truncated`         — `nil` (fully expanded within bounds) | `:depth` (hit `max_depth`) |
        `:budget` (hit `max_nodes`) | `:cycle` (id already on the path — bad data, refused).
    """
    defstruct record: nil,
              id: nil,
              depth: 0,
              children: [],
              child_count: nil,
              has_more_children: false,
              expandable?: false,
              truncated: nil

    @type t :: %__MODULE__{
            record: term(),
            id: term(),
            depth: non_neg_integer(),
            children: [t()],
            child_count: non_neg_integer() | nil,
            has_more_children: boolean(),
            expandable?: boolean(),
            truncated: nil | :depth | :budget | :cycle
          }
  end
end
