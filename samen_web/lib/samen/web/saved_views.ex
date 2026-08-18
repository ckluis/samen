defmodule Samen.Web.SavedViews do
  @moduledoc """
  The framework SAVED-VIEWS capability (G10, T58) — SAVE and RESTORE a user's list/view
  state (the chosen view TYPE plus its params: sort, filter, group, columns, date field,
  window, caps) as NAMED, PER-USER, ORG-SCOPED saved views.

  This is the thin samen_web wiring over the host-owned `Views.SavedView` resource
  (`Samen.Scopes.Views`). A list surface adopts saved views at ≈0 authored LOC: mount the
  Views scope once, build a `Samen.Web.SavedViews.Whitelist` from the surface's existing
  `Samen.Web.ListLive` config, and call `save/5` / `list/4` / `apply/2`.

  ## Per-user + org-scoped access control (the crux)

  A saved view is PRIVATE to its owner within its org. Isolation is POLICY-ENFORCED on the
  `SavedView` resource by two stacked `FilterCheck`s — `Samen.Policy.OrgScope` (cross-org
  rows do not exist) AND `Samen.Policy.OwnerOnly` (another user's rows do not exist). This
  module never bypasses them: every read AND write runs through `owner_scope/2`, a
  tenant-plane `%Samen.Scope{}` whose `actor.id` is the REAL current user id and whose
  `org_id` is the acting org. (The samen_web tenant plane's DEFAULT actor id is a synthetic
  per-org broker id — not a user — so a per-user resource must build this owner scope; the
  current user id is resolved host-side the same way `Samen.Web.Settings.Reads` resolves it,
  params → session → mount label.)

    * cross-ORG: an actor in org B cannot read/load/update/delete a saved view in org A.
    * cross-USER: user2 cannot read/modify/delete user1's private saved view in the same org.

  A cross-org or cross-user id reads ZERO rows (`{:error, :not_found}`, no existence oracle),
  so `rename`/`delete` on a foreign id are honest no-ops, never a leak or a mutation.

  ## Stored-filter PII safety + untrusted restore

  Serialization + the untrusted-restore whitelist live in `Samen.Web.SavedViews.Params`:

    * a FILTER/SORT/GROUP/DATE reference to a vault-routed (🔒) field is REFUSED on save
      (`{:error, {:vaulted_field, field}}`) — plaintext PII never lands in the params blob;
    * on restore the stored blob is UNTRUSTED — every field reference is re-validated against
      the surface whitelist (an unseen field, an `org_id` override, an injected raw query are
      dropped/ignored) and org/user scope is re-applied from the actor, never the blob.

  ## Masking on restore

  Restoring a saved view produces a sanitized `%Samen.Web.ListState{}` + view params that
  drive a NORMAL org-scoped, plane-masked read via the existing WS-G view components. The
  SavedView row itself carries no PII; masking rides entirely on the domain read path, so an
  operator-without-grant sees `••••` in the restored view exactly as in a live one — a saved
  view is never a masking bypass.
  """

  require Ash.Query

  alias Samen.Web.ListState
  alias Samen.Web.Reads
  alias Samen.Web.SavedViews.Params
  alias Samen.Web.SavedViews.Whitelist

  @doc """
  Build the tenant-plane owner scope for saved-view CRUD: an `actor` carrying the REAL
  `user_id` (for `Samen.Policy.OwnerOnly`) and `org_id` (for `Samen.Policy.OrgScope`), role
  `:member`. This is the ONLY scope this module uses — every read/write is org + user scoped
  by construction.
  """
  @spec owner_scope(String.t(), String.t()) :: Samen.Scope.t()
  def owner_scope(org_id, user_id) when is_binary(org_id) and is_binary(user_id) do
    Samen.Scope.new(%{id: user_id, org_id: org_id, role: :member})
  end

  @doc """
  Save (create) a named view for `user_id` in `org_id`. `attrs` is a map with:

    * `:name`       — the view label (required),
    * `:surface`    — the list/view surface key (required, e.g. `"crm.person"`),
    * `:view_type`  — a bounded view-type atom (default `:table`),
    * `:list_state` — a `%Samen.Web.ListState{}` (sort/filter/page_size/show_archived),
    * `:view_params`— the view-type extras map (`:group_by`, `:columns`, `:date_field`,
      `:filters`, `:window`, `:caps`).

  The params are serialized + STRICTLY validated against `whitelist` (a vaulted or
  non-whitelisted field reference is REFUSED — no plaintext PII is persisted). Returns
  `{:ok, saved_view}` or `{:error, reason}`.
  """
  @spec save(module(), String.t(), String.t(), map(), Whitelist.t()) ::
          {:ok, struct()} | {:error, term()}
  def save(resource, org_id, user_id, attrs, %Whitelist{} = whitelist)
      when is_atom(resource) and is_map(attrs) do
    view_type = Map.get(attrs, :view_type, :table)
    state = Map.get(attrs, :list_state, %ListState{})
    view_params = Map.get(attrs, :view_params, %{})

    with {:ok, name} <- require_string(attrs, :name),
         {:ok, surface} <- require_string(attrs, :surface),
         {:ok, params} <- Params.serialize(view_type, state, view_params, whitelist) do
      resource
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          owner_id: user_id,
          name: name,
          surface: surface,
          view_type: view_type,
          params: params
        },
        scope: owner_scope(org_id, user_id)
      )
      |> Ash.create()
    end
  end

  @doc """
  List `user_id`'s saved views for `surface` in `org_id`, sorted by name. Bounded
  (`Reads.max_page_size/0`) and org + user scoped by policy — another org's or another
  user's views are structurally absent.
  """
  @spec list(module(), String.t(), String.t(), String.t()) :: [struct()]
  def list(resource, org_id, user_id, surface)
      when is_atom(resource) and is_binary(surface) do
    resource
    |> Ash.Query.filter(surface == ^surface)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(Reads.max_page_size())
    |> Ash.read!(scope: owner_scope(org_id, user_id))
  end

  @doc """
  Load ONE saved view by id for `user_id` in `org_id`. `{:ok, saved_view}` or
  `{:error, :not_found}`. A cross-org or cross-user id reads zero rows (no existence oracle).
  """
  @spec get(module(), String.t(), String.t(), String.t()) ::
          {:ok, struct()} | {:error, :not_found}
  def get(resource, org_id, user_id, id) when is_atom(resource) and is_binary(id) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: owner_scope(org_id, user_id))
    |> case do
      [sv | _] -> {:ok, sv}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Restore a loaded `saved_view` into a sanitized `{view_type, %Samen.Web.ListState{}, view_params}`
  triple, validated against `whitelist` (untrusted blob — see `Samen.Web.SavedViews.Params`).
  The view TYPE is taken from the row's enum-constrained column (trusted), not the blob.
  """
  @spec apply(struct(), Whitelist.t()) :: {atom(), ListState.t(), map()}
  def apply(saved_view, %Whitelist{} = whitelist) do
    {_blob_type, state, view_params} = Params.restore(saved_view.params, whitelist)
    {saved_view.view_type, state, view_params}
  end

  @doc """
  Rename `user_id`'s saved view `id` in `org_id`. `{:ok, saved_view}` or `{:error, reason}`
  (a foreign id → `{:error, :not_found}`, never a cross-user mutation).
  """
  @spec rename(module(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, struct()} | {:error, term()}
  def rename(resource, org_id, user_id, id, new_name)
      when is_atom(resource) and is_binary(new_name) do
    with {:ok, sv} <- get(resource, org_id, user_id, id) do
      sv
      |> Ash.Changeset.for_update(:update, %{name: new_name}, scope: owner_scope(org_id, user_id))
      |> Ash.update()
    end
  end

  @doc """
  Delete `user_id`'s saved view `id` in `org_id`. `:ok`, `{:error, :not_found}` (foreign id),
  or `{:error, reason}`. A foreign id is a no-op — never a cross-user/cross-org destroy.
  """
  @spec delete(module(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(resource, org_id, user_id, id) when is_atom(resource) and is_binary(id) do
    with {:ok, sv} <- get(resource, org_id, user_id, id) do
      Ash.destroy(sv, scope: owner_scope(org_id, user_id))
    end
  end

  # -- internals ---------------------------------------------------------------

  defp require_string(attrs, key) do
    case Map.get(attrs, key) do
      v when is_binary(v) ->
        case String.trim(v) do
          "" -> {:error, {:blank, key}}
          _ -> {:ok, v}
        end

      _ ->
        {:error, {:missing, key}}
    end
  end
end
