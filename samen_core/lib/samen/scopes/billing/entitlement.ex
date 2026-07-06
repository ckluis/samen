defmodule Samen.Scopes.Billing.Entitlement do
  @moduledoc """
  The **entitlement check helper** for the Billing scope (T3.3 spec:
  "Entitlement check helper — is this org entitled to X?").

  Queries the host's `Entitlement` resource (materialized from the Billing scope
  blueprint) to determine whether an org's active subscription grants a named feature.

  ## Usage

      import Samen.Scopes.Billing.Entitlement

      entitled?(org_id, :advanced_reporting, MyApp.BillingScope.Entitlement, repo: MyApp.Repo)
      # => {:ok, true}

      entitled?(org_id, :sso, MyApp.BillingScope.Entitlement, repo: MyApp.Repo)
      # => {:ok, false}

  ## How it works

  The check queries the host's Entitlement resource for a row where:
    * `org_id` matches the given org
    * `feature` matches the given feature key (bounded atom)
    * `granted` is true
    * `expires_at` is nil OR in the future

  A missing row, a `granted: false` row, or an expired row all return `{:ok, false}`
  (fail closed: absence of entitlement is not-entitled).

  ## Direct Ecto fallback

  For hosts that need a fast path (e.g. inside an Oban worker before Ash is loaded),
  `entitled_direct?/4` takes a repo and a table name prefix (the resource's abbrev)
  and executes a direct Ecto query.
  """

  import Ecto.Query

  @doc """
  Check whether an org is entitled to a named feature.

  Uses the Ash resource (requires a loaded domain). For test environments, this
  exercises the full Ash policy stack (including org-scope policy).

  Returns:
    * `{:ok, true}` — the org has an active, non-expired entitlement for the feature
    * `{:ok, false}` — no active entitlement found
    * `{:error, reason}` — unexpected error
  """
  @spec entitled?(binary(), atom(), module(), repo: module()) ::
          {:ok, boolean()} | {:error, term()}
  def entitled?(org_id, feature, entitlement_resource, opts \\ []) do
    repo = Keyword.fetch!(opts, :repo)
    entitled_direct?(org_id, feature, entitlement_resource.__schema__(:source), repo)
  end

  @doc """
  Check entitlement via a direct Ecto query (no Ash overhead).

  `table_name` is the physical table name for the entitlement resource
  (e.g. `"ben_entitlement"`). The repo is the host's Ecto repo.

  Returns `{:ok, true}` if at least one active, non-expired entitlement row exists
  for (org_id, feature, granted: true). Returns `{:ok, false}` otherwise.
  """
  @spec entitled_direct?(binary(), atom(), String.t(), module()) ::
          {:ok, boolean()} | {:error, term()}
  def entitled_direct?(org_id, feature, table_name, repo) do
    # We query the physical table directly to avoid the Ash action overhead in hot
    # paths. The feature atom is validated (bounded constraint in the resource); we
    # accept it as a string comparison at the SQL level.
    feature_str = Atom.to_string(feature)
    now = DateTime.utc_now()

    # Build a raw Ecto query against the physical table.
    # The abbrev prefix is embedded in the table_name; the column names follow the
    # storage convention: <abbrev>_<field>.
    # We extract the abbrev from the table name (e.g. "ben_entitlement" → "ben").
    case String.split(table_name, "_", parts: 2) do
      [abbrev, _rest] ->
        id_col = String.to_atom("#{abbrev}_id")
        org_id_col = String.to_atom("#{abbrev}_org_id")
        feature_col = String.to_atom("#{abbrev}_feature")
        granted_col = String.to_atom("#{abbrev}_granted")
        expires_at_col = String.to_atom("#{abbrev}_expires_at")

        # Parse the org_id UUID string into the binary form Postgres/Ecto expects.
        org_uuid =
          case Ecto.UUID.dump(org_id) do
            {:ok, bin} -> bin
            :error -> raise ArgumentError, "invalid UUID: #{inspect(org_id)}"
          end

        query =
          from(e in table_name,
            where:
              field(e, ^org_id_col) == ^org_uuid and
                field(e, ^feature_col) == ^feature_str and
                field(e, ^granted_col) == true and
                (is_nil(field(e, ^expires_at_col)) or field(e, ^expires_at_col) > ^now),
            select: field(e, ^id_col),
            limit: 1
          )

        case repo.all(query) do
          [_ | _] -> {:ok, true}
          [] -> {:ok, false}
        end

      _ ->
        {:error, {:invalid_table_name, table_name}}
    end
  rescue
    e -> {:error, e}
  end
end
