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

  @select [:filename, :content_type, :size_bytes, :storage_key, :status, :inserted_at]

  @doc """
  Read ONE keyset page of the org's files for `scope` — the `ListLive` reads contract,
  newest-first by default. `filename` is resolved through `PiiResolution` AFTER paging.
  On any read error the page is EMPTY — never unbounded, never a plaintext downgrade.
  """
  def files_page(mount, scope, state) do
    page =
      Mount.resource(mount, File)
      |> Ash.Query.ensure_selected(@select)
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:status, :content_type])

    %{page | items: resolve_pii(page.items, mount, scope)}
  rescue
    _ ->
      %Samen.Web.Page{
        items: [],
        page_size: Samen.Web.Reads.bounded_page_size(state.page_size)
      }
  end

  @doc """
  Read a SINGLE `File` by id for `scope`, with `filename` plane-resolved — `{:ok, file}`
  or `{:error, :not_found}`. Org-scoped: a cross-org id reads zero rows under OrgScope
  and returns `{:error, :not_found}` (no existence oracle).
  """
  def get_file(mount, scope, id) do
    Mount.resource(mount, File)
    |> Ash.Query.ensure_selected(@select)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, scope)
    |> case do
      [file | _] -> {:ok, file}
      [] -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
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
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end
