defmodule Samen.Web.Files.Reads do
  @moduledoc """
  The framework files read layer (WS-E E2.1; ADR-026) — bounded reads + PII resolution.

  ## MASKING INVARIANT

  `filename` on the `File` resource is vaultable (a filename can be PII; a patient
  record, a legal document). This module calls `Samen.Api.PiiResolution.resolve/4` on
  every result set so the filename is resolved per the caller's plane:

    * **Tenant plane** — the org reads its own data: filename in the clear.
    * **Operator plane** — impersonation session: filename renders `%Samen.Masked{}`
      (→ `••••`) if the host has vaulted the attribute.

  This module NEVER calls `Samen.Vault.reveal/3`, NEVER unwraps a `%Samen.Masked{}`,
  and has no "show plaintext" path. On any resolver error the field stays `%Masked{}`
  (no plaintext downgrade).

  ## Read bounds

  `files_page/3` funnels through `Samen.Web.Reads.page!/3` and is bounded by
  construction (keyset, capped page size). `get_file/3` applies `Ash.Query.limit(1)`.
  """

  require Ash.Query

  alias Samen.Web.Mount
  alias Samen.Web.Reads.Guard

  @select [:filename, :content_type, :size_bytes, :storage_key, :status, :inserted_at]

  @doc """
  Read ONE keyset page of the org's files for `scope` — the `ListLive` reads contract,
  newest-first by default. `filename` is resolved through `PiiResolution` AFTER paging.
  On any read error the page is EMPTY — never unbounded, never a plaintext downgrade.
  """
  def files_page(mount, scope, state) do
    Guard.page(:files_page, scope, state, fn ->
      page =
        Mount.resource(mount, File)
        |> Ash.Query.ensure_selected(@select)
        |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:status, :content_type])

      %{page | items: resolve_pii(page.items, mount, scope)}
    end)
  end

  @doc """
  Read a SINGLE `File` by id for `scope`, with `filename` plane-resolved — `{:ok, file}`
  or `{:error, :not_found}`. Org-scoped: a cross-org id reads zero rows under OrgScope
  and returns `{:error, :not_found}` (no existence oracle).
  """
  def get_file(mount, scope, id) do
    case get_file_result(mount, scope, id) do
      {:ok, file} -> {:ok, file}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Tagged sibling of `get_file/3` (WP6): `{:ok, file}`, `{:error, :not_found}` for a missing,
  malformed-id or denied record (no existence oracle), and `{:error, :unavailable}` ONLY when the
  read FAILED — a failed read is not "File not found".
  """
  def get_file_result(mount, scope, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, rows} <-
           Guard.run(:files_get_file, scope, fn ->
             Mount.resource(mount, File)
             |> Ash.Query.ensure_selected(@select)
             |> Ash.Query.filter(id == ^uuid)
             |> Ash.Query.limit(1)
             |> Ash.read!(scope: scope)
             |> resolve_pii(mount, scope)
           end) do
      case rows do
        [file | _] -> {:ok, file}
        [] -> {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :not_found}
      {:error, :unavailable} = unavailable -> unavailable
    end
  end

  # -- private -------------------------------------------------------------------

  # Resolve vaulted fields through the shared chokepoint. Resource + repo from the
  # mount. Fail-safe: on any resolver error the fields stay %Masked{} — no plaintext
  # downgrade, never a raise.
  defp resolve_pii(records, mount, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Mount.resource(mount, File),
      actor_of(scope),
      repo: mount.repo
    )
  rescue
    e ->
      # Fail-closed (no plaintext downgrade), but not silent: a resolver outage is logged.
      Guard.report(:files_resolve_pii, scope, e)
      records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end
