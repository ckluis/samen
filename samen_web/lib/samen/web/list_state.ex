defmodule Samen.Web.ListState do
  @moduledoc """
  The UI state of one `list_view/1` — sort, filter, keyset cursor, page size, and the
  bulk-selection set (ADR-016 §2, WS-A design §1.1).

  This struct is PURE UI state: it carries no records, no scope, no actor, and no PII.
  The cursor is an OPAQUE SERVER-SIDE TERM (`{sort_value, id}` — see `Samen.Web.Reads`):
  it lives only in the LiveView's assigns and never round-trips through the client, so
  it needs no serialization and can never be tampered with from the browser. The
  `cursor_stack` is the trail of prior page cursors, which is what makes "Prev" work
  under keyset pagination (pop = go back one page).

    * `sort`         — `{field :: atom, :asc | :desc}` (single sort — saved views are WS-E)
    * `filter`       — the single filter-box string (`""` = no filter)
    * `cursor`       — the keyset cursor of the CURRENT page (`nil` = first page)
    * `cursor_stack` — cursors of the pages BEFORE the current one (LIFO)
    * `page_size`    — bounded by `Samen.Web.Reads.max_page_size/0`
    * `selected`     — `MapSet` of selected row ids (bulk-action affordance)
  """

  defstruct sort: nil,
            filter: "",
            cursor: nil,
            cursor_stack: [],
            page_size: 50,
            selected: MapSet.new()

  @type t :: %__MODULE__{
          sort: {atom(), :asc | :desc} | nil,
          filter: String.t(),
          cursor: term() | nil,
          cursor_stack: [term()],
          page_size: pos_integer(),
          selected: MapSet.t()
        }
end
