defmodule Samen.Web.SavedViews.Whitelist do
  @moduledoc """
  The per-surface FIELD WHITELIST for saved views (G10, T58) — the bounded set of
  attributes a stored view-state blob is allowed to reference, per role (sort / filter /
  group / column / date).

  This is the trust boundary for the UNTRUSTED restore: `Samen.Web.SavedViews.Params`
  validates every field reference in a stored (or to-be-stored) params blob against THIS
  whitelist. A reference to a field NOT declared here is DROPPED on restore and REFUSED on
  save — a tampered blob naming an unseen field, an `org_id`, or an injected column can
  never reach a query.

  It carries the concrete `resource` module so `Samen.Pii.Info.vault_routed?/2` can answer
  "is this field vault-routed (🔒)?" — the stored-filter PII gate (a vaulted field may
  never be a stored FILTER/SORT/GROUP/DATE reference; storing its value would persist
  plaintext PII outside the vault, INV-1).

  ## Field roles

    * `sortable`      — fields a saved view may sort by (must be non-vaulted).
    * `filter_fields` — fields the freeform filter box / structured predicates target
      (must be non-vaulted; the read layer already excludes vaulted fields from the box).
    * `groupable`     — fields a board/chart may group by (must be non-vaulted — the read
      layer's `group_by!/aggregate_by!` refuse a vaulted key).
    * `date_fields`   — date/time fields a calendar/timeline may bucket by (non-vaulted).
    * `columns`       — displayed columns. A column MAY be vaulted: it renders through the
      normal masked read path (operator-without-grant sees `••••`), so a vaulted column is
      not a PII leak — masking handles it. Columns are still whitelisted (a tampered blob
      cannot invent a column), just not vault-refused.

  ## Building from a `Samen.Web.ListLive` config (≈0-LOC adoption)

  A list surface already declares `sortable` + `filter_fields` via `use Samen.Web.ListLive`.
  `from_list_config/3` lifts those directly, so adopting saved views on such a surface adds
  no new field declarations — pass only the view-specific extras (groupable/columns/…).
  """

  alias Samen.Web.Reads

  @enforce_keys [:resource]
  defstruct resource: nil,
            sortable: [],
            filter_fields: [],
            groupable: [],
            date_fields: [],
            columns: [],
            default_page_size: nil

  @type field :: atom()
  @type t :: %__MODULE__{
          resource: module(),
          sortable: [field()],
          filter_fields: [field()],
          groupable: [field()],
          date_fields: [field()],
          columns: [field()],
          default_page_size: pos_integer() | nil
        }

  @doc """
  Build a whitelist for `resource` (the concrete, materialized Ash module — the one
  `Samen.Pii.Info.vault_routed?/2` introspects). `opts` are the per-role field lists
  (`:sortable`, `:filter_fields`, `:groupable`, `:date_fields`, `:columns`) plus an
  optional `:default_page_size`.
  """
  @spec new(module(), keyword()) :: t()
  def new(resource, opts \\ []) when is_atom(resource) do
    %__MODULE__{
      resource: resource,
      sortable: atoms(Keyword.get(opts, :sortable, [])),
      filter_fields: atoms(Keyword.get(opts, :filter_fields, [])),
      groupable: atoms(Keyword.get(opts, :groupable, [])),
      date_fields: atoms(Keyword.get(opts, :date_fields, [])),
      columns: atoms(Keyword.get(opts, :columns, [])),
      default_page_size: Keyword.get(opts, :default_page_size)
    }
  end

  @doc """
  Build a whitelist from a resolved `resource` and a `Samen.Web.ListLive` `config` map
  (which already carries `:sortable` + `:filter_fields`), plus per-view `extra` field
  lists (`:groupable`, `:date_fields`, `:columns`). The list surface's own bounded field
  declarations are reused verbatim — adopting saved views adds no new field lists.
  """
  @spec from_list_config(module(), map(), keyword()) :: t()
  def from_list_config(resource, %{} = config, extra \\ []) when is_atom(resource) do
    new(
      resource,
      Keyword.merge(
        [
          sortable: Map.get(config, :sortable, []),
          filter_fields: Map.get(config, :filter_fields, []),
          default_page_size: Map.get(config, :page_size)
        ],
        extra
      )
    )
  end

  @doc """
  Resolve a client-supplied field STRING to a whitelisted atom for `role`, or `nil` if it
  is not in the role's list. NEVER calls `String.to_atom/1` on the input — it matches the
  string against the BOUNDED compile-time atom list (the same discipline
  `Samen.Web.ListLive.bounded_field/2` uses), so a hostile blob can neither mint an atom
  nor name a field outside the whitelist.
  """
  @spec resolve(t(), atom(), String.t() | atom() | nil) :: field() | nil
  def resolve(%__MODULE__{} = wl, role, value) do
    list = role_list(wl, role)
    resolve_in(list, value)
  end

  @doc """
  True if `field` is safe to persist as a FILTER/SORT/GROUP/DATE reference — i.e. it is
  NOT a vault-routed (🔒) attribute of the whitelist's resource. A vaulted reference is
  refused on save (its value would be plaintext PII outside the vault) and dropped on
  restore (INV-1). Columns use `Samen.Pii.Info.vault_routed?/2` too but are ALLOWED to be
  vaulted (they render masked) — see moduledoc.
  """
  @spec non_vaulted?(t(), field()) :: boolean()
  def non_vaulted?(%__MODULE__{resource: resource}, field) when is_atom(field) do
    not Samen.Pii.Info.vault_routed?(resource, field)
  end

  @doc "The clamped default page size for this surface (falls back to `Reads.default_page_size/0`)."
  @spec default_page_size(t()) :: pos_integer()
  def default_page_size(%__MODULE__{default_page_size: nil}), do: Reads.default_page_size()
  def default_page_size(%__MODULE__{default_page_size: n}), do: Reads.bounded_page_size(n)

  # -- internals ---------------------------------------------------------------

  defp role_list(%__MODULE__{} = wl, :sort), do: wl.sortable
  defp role_list(%__MODULE__{} = wl, :filter), do: wl.filter_fields
  defp role_list(%__MODULE__{} = wl, :group), do: wl.groupable
  defp role_list(%__MODULE__{} = wl, :date), do: wl.date_fields
  defp role_list(%__MODULE__{} = wl, :column), do: wl.columns
  defp role_list(_wl, _role), do: []

  defp resolve_in(list, value) when is_atom(value) and not is_nil(value),
    do: if(value in list, do: value, else: nil)

  defp resolve_in(list, value) when is_binary(value),
    do: Enum.find(list, fn f -> Atom.to_string(f) == value end)

  defp resolve_in(_list, _value), do: nil

  defp atoms(list) when is_list(list), do: Enum.filter(list, &is_atom/1)
  defp atoms(_), do: []
end
