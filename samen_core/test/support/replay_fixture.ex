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

defmodule SamenCore.Support.ReplayFixtureDomain do
  @moduledoc "ADR-052 P2 fixture domain (not registered in :ash_domains — a sanitizer input only)."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.ReplayFixtureDomain.Gadget)
  end
end

defmodule SamenCore.Support.ReplayFixtureDomain.Gadget do
  @moduledoc """
  ADR-052 P2 fixture: a table-less resource whose attributes exercise every non-vault branch of
  the sanitizer's record decision — a structural integer (kept), a `sensitive?` structural
  integer (never kept), a freeform string (shape only), an enum atom (kept).
  """
  use Ash.Resource,
    domain: SamenCore.Support.ReplayFixtureDomain,
    data_layer: Ash.DataLayer.Simple

  attributes do
    uuid_primary_key(:id)
    attribute(:count, :integer, public?: true)
    attribute(:secret_count, :integer, public?: true, sensitive?: true)
    attribute(:note, :string, public?: true)
    attribute(:status, :atom, public?: true)
  end
end
