defmodule Samen.CustomFields.Change do
  @moduledoc """
  Validated-at-write for the Tier-1 custom bag (plan T3.8 (b); vision doc
  §core "tenant Tier-1/2 customization is validated-at-write").

  A global `Ash.Resource.Change` injected by `Samen.Transformers.MaterializeCustomFields`
  onto every resource that carries a `:custom` jsonb bag. On `:create` / `:update`,
  if the changeset sets the bag, this change validates the WHOLE bag against the
  org's `tnt_field` definitions (`Samen.CustomFields.validate_bag/4`) in
  `before_action` — inside the action's Ecto transaction — and **rejects** the
  write if:

    * a key has no `tnt_field` definition (uncatalogued custom field), or
    * a value fails its declared type / constraint, or
    * a value is PII-shaped on a field not declared `pii_declared: true`
      (containment — a Tier-1 field can never be a silent vault bypass).

  Rejection is an `Ash.Changeset.add_error/2`, so the action fails closed and the
  bad bag never reaches Postgres.

  ## Why `before_action` and not `validate`

  The check needs the resolved `org_id` (the tenant boundary the bag definitions
  are scoped to) and a repo, both available on the changeset. Doing it in
  `before_action` keeps it inside the transaction Ash opens, consistent with
  `Samen.Vault.Change`, so a rejection rolls nothing back and an accepted bag
  commits with the row.
  """
  use Ash.Resource.Change

  alias Samen.CustomFields

  @bag_attr :custom

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &validate/1)
  end

  defp validate(changeset) do
    case Ash.Changeset.fetch_change(changeset, @bag_attr) do
      :error ->
        # Bag not touched by this write — nothing to validate.
        changeset

      {:ok, nil} ->
        changeset

      {:ok, bag} when is_map(bag) ->
        do_validate(changeset, bag)

      {:ok, other} ->
        Ash.Changeset.add_error(changeset,
          field: @bag_attr,
          message: "custom bag must be a map, got: #{inspect(other)}"
        )
    end
  end

  defp do_validate(changeset, bag) do
    org_id = resolve_org_id(changeset)
    table = table_name(changeset.resource)
    repo = repo!(changeset)

    cond do
      is_nil(org_id) ->
        # No org context ⇒ no tenant boundary ⇒ fail closed: a custom write with
        # no org can't be validated against org-scoped definitions.
        Ash.Changeset.add_error(changeset,
          field: @bag_attr,
          message:
            "custom bag write has no org_id — Tier-1 custom fields are org-scoped " <>
              "and validated against the org's tnt_field definitions; cannot validate " <>
              "a bag with no tenant boundary (fail closed)."
        )

      is_nil(table) ->
        changeset

      true ->
        case CustomFields.validate_bag(org_id, table, bag, repo) do
          :ok ->
            changeset

          {:error, violations} ->
            Enum.reduce(violations, changeset, fn {field, reason}, cs ->
              Ash.Changeset.add_error(cs,
                field: @bag_attr,
                message: "custom field #{inspect(field)} rejected: #{describe(reason)}"
              )
            end)
        end
    end
  end

  defp describe({:undefined, msg}), do: msg
  defp describe({:type, expected}), do: "value is not a #{expected}"
  defp describe({:constraint, detail}), do: "constraint violated: #{inspect(detail)}"

  defp describe({:pii_shaped, shape}),
    do:
      "value is PII-shaped (#{shape}) on a field not declared pii_declared: true — " <>
        "a Tier-1 custom field can never be a vault bypass (containment, fail closed)"

  defp describe(other), do: inspect(other)

  # org_id resolves from the changeset attribute (set explicitly or by policy) or,
  # on update, from the existing row's data.
  defp resolve_org_id(changeset) do
    case Ash.Changeset.fetch_change(changeset, :org_id) do
      {:ok, value} when not is_nil(value) ->
        to_string(value)

      _ ->
        case Map.get(changeset.data || %{}, :org_id) do
          nil -> nil
          existing -> to_string(existing)
        end
    end
  end

  defp table_name(resource) do
    try do
      AshPostgres.DataLayer.Info.table(resource)
    rescue
      _ -> nil
    end
  end

  defp repo!(changeset) do
    AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate) ||
      Application.get_env(:samen_core, :vault_repo) ||
      raise "Samen.CustomFields.Change: could not resolve a repo for #{inspect(changeset.resource)}"
  end
end
