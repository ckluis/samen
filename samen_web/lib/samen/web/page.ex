defmodule Samen.Web.Page do
  @moduledoc """
  One keyset-paginated page of already-read (and, where applicable, already
  PII-RESOLVED) records — the value a `Reads` function returns to a LiveView and the
  value `Samen.UI.list_view/1` renders (ADR-016 §3, WS-A design §1.1).

  `items` are whatever the read produced: on the tenant plane, plaintext-resolved
  records; on the operator plane, records whose vaulted fields are `%Samen.Masked{}`
  (→ `••••` via `Phoenix.HTML.Safe`). The page struct itself never inspects, coerces,
  or stringifies a field value — it is a dumb carrier.

  Cursors are OPAQUE SERVER-SIDE TERMS (`{sort_value, id}`) that never leave the
  server (see `Samen.Web.ListState`). `has_more` is derived from the read's
  `limit(page_size + 1)` probe row.

  `error` is `nil` for every page a read actually produced (including an honestly empty
  one). A read that FAILED returns an empty page with `error: :unavailable`
  (`Samen.Web.Reads.Guard.page/4`), so a screen can tell "no rows" from "could not read"
  without a new return shape; `Samen.Web.ListLive` turns it into the kit error state.
  """

  defstruct items: [],
            cursor: nil,
            next_cursor: nil,
            prev_cursor: nil,
            has_more: false,
            page_size: 50,
            sort: nil,
            filter: "",
            total_estimate: nil,
            error: nil

  @type t :: %__MODULE__{
          items: [term()],
          cursor: term() | nil,
          next_cursor: term() | nil,
          prev_cursor: term() | nil,
          has_more: boolean(),
          page_size: pos_integer(),
          sort: {atom(), :asc | :desc} | nil,
          filter: String.t(),
          total_estimate: non_neg_integer() | nil,
          error: nil | :unavailable
        }
end
