defmodule Samen.Web.Settings.Profile do
  @moduledoc """
  The framework PROFILE self-edit engine (WS-E E5.1; ADR-029 §2.2; AC-G18-2) — the
  governed write chokepoint the settings Profile surface runs on.

  ## Self-edit routes through the SAME vault chokepoint (the masking watch-list surface)

  A profile self-edit writes the user's OWN vaulted PII (`full_name`, `emails`). It is
  NOT a new PII-write trust surface: `update/4` builds a governed `User` update
  changeset UNDER the acting scope and runs `Ash.update` — so the write travels through
  the exact `Samen.Pii.WriteGuard` + `Samen.Vault.Change` chokepoint the CRUD forms and
  the CSV import already prove:

    * **tenant plane** — the user editing their own profile is on the tenant plane, so
      `WriteGuard` permits the write and `Vault.Change` encrypts `full_name`/`emails`
      to `vt_*` at rest (plaintext nowhere in the raw row);
    * **operator plane** — an operator impersonating that user hits `WriteGuard`'s
      operator-plane refusal — they CANNOT write plaintext into the masked field
      (`{:error, changeset}` with the no-operator-plaintext-write error; the DB is
      unchanged). This is the profile entry on the six-surface masking watch-list.

  This module NEVER builds a raw insert/update, NEVER touches the vault directly, and
  has no operator-plane bypass — the guarantee is by construction (the same chokepoint,
  in the settings surface).

  ## Fields

  `full_name` (`Samen.Type.FullName`) and `emails` (`Samen.Type.Emails`) are composite
  PII casts; `handle` is a non-PII display string. The caller shapes form params into
  the composite maps the governed action casts (`%{first:, last:}` / `[%{address:}]`).
  """

  require Ash.Query

  alias Samen.Web.Mount

  @doc """
  Run a governed self-edit of `user_id`'s profile for `scope`. `attrs` is the
  already-shaped attribute map (`:handle`, `:full_name` as `%{first:, last:}`,
  `:emails` as `[%{address:}]`) — only the KEYS present are updated.

  Returns `{:ok, user}` on success, or `{:error, reason}` (`:not_found` if the user
  is not readable under the scope; an `%Ash.Changeset{}`/`%Ash.Error...{}` when the
  write is refused — an operator-plane plaintext PII write is refused HERE by
  `WriteGuard`, the DB unchanged).
  """
  def update(mount, scope, user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    with {:ok, user} <- fetch_user(mount, scope, user_id) do
      user
      |> Ash.Changeset.for_update(:update, sanitize(attrs), scope: scope)
      |> Ash.update(scope: scope)
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, error} -> {:error, error}
      end
    end
  rescue
    e -> {:error, e}
  end

  def update(_mount, _scope, _user_id, _attrs), do: {:error, :invalid}

  # Read the raw row to update (scope-authorized). We update on the SAME scope the
  # actor read on — the governed changes see the acting actor at build time.
  defp fetch_user(mount, scope, user_id) do
    Mount.resource(mount, User)
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: scope)
    |> case do
      [user | _] -> {:ok, user}
      [] -> {:error, :not_found}
    end
  end

  # Keep ONLY the three editable profile attributes — a profile self-edit can never
  # set org_id/id/status or any other column (deny-by-default; the same posture as the
  # CSV import mapping allowlist).
  @editable [:handle, :full_name, :emails]
  defp sanitize(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {atomize(k), v} end)
    |> Map.take(@editable)
  end

  defp atomize(k) when is_atom(k), do: k
  defp atomize("handle"), do: :handle
  defp atomize("full_name"), do: :full_name
  defp atomize("emails"), do: :emails
  defp atomize(other) when is_binary(other), do: :__ignored__
end
