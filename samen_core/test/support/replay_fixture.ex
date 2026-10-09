defmodule SamenCore.Support.ReplayView do
  @moduledoc """
  ADR-052 P2 fixture: a LiveView-SHAPED module (samen_core has no Phoenix) that declares a
  replay keep-list — `page_title` may keep a bounded string; the `"sort"` event keeps its
  `"field"` param — and handles `save` / `sort` / `validate`.
  """
  use Samen.Replay, keep_assigns: [:page_title], keep_params: %{"sort" => ["field"]}

  def handle_event("save", _params, socket), do: {:noreply, socket}
  def handle_event("sort", _params, socket), do: {:noreply, socket}
  def handle_event("validate", _params, socket), do: {:noreply, socket}
end

defmodule SamenCore.Support.ReplayMixinView do
  @moduledoc """
  ADR-052 P2 fixture: two `use Samen.Replay` declarations (a mixin's + the view's own) merge
  into ONE `__samen_replay__/0`; `"paginate"` is handled by a hook, not a clause, so its label
  comes from the declaration.
  """
  use Samen.Replay, keep_params: %{"paginate" => ["dir"]}
  use Samen.Replay, keep_assigns: [:tab], keep_params: %{"paginate" => ["page"]}
end
