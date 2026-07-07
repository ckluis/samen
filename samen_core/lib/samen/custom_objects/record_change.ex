defmodule Samen.CustomObjects.RecordChange do
  @moduledoc """
  Validated-at-write for a Tier-2 `tnt_record` (plan T3.9; vision doc §core
  "tenant Tier-1/2 customization is validated-at-write").

  An `Ash.Resource.Change` on `Samen.CustomObjects.Record`. On `:create`/`:update`
  it runs, in `before_action` (inside the action's Ecto transaction, consistent
  with `Samen.CustomFields.Change` and `Samen.Vault.Change`):

    1. **object gate** — the record's `object_key` must name an *enabled*
       `tnt_object` for the acting org. Writing a record for an object the org
       never defined (or disabled) is rejected (fail closed). This is the Tier-2
       parallel of Tier-1's "no undefined custom field".

    2. **attributes bag** — validated by `Samen.CustomFields.validate_bag/4` (the
       SAME engine T3.8 built) against the object's `tnt_field` rows, keyed on the
       object's synthetic table name (`Samen.CustomObjects.object_table/1`). So an
       undefined key, a wrong-typed value, a constraint violation, or a PII-shaped
       value on a non-`pii_declared` field is REJECTED at write — the Tier-1 red
       paths, reused verbatim for Tier-2.

    3. **refs bag** — every OUT-reference value must be an **opaque ID** (uuid) or
       a bounded token, never a PII-shaped or free-text value. A ref that is
       PII-shaped (`Samen.PiiValueShape`) is rejected: a "reference" can never be a
       vault bypass that smuggles a name across the one-way boundary. Refs are
       stored as data, not FKs (the one-way boundary is structural + verifier-
       enforced elsewhere; this change guards the *value shape* of a ref).

  Rejection is `Ash.Changeset.add_error/2` — the action fails closed and the bad
  record never reaches Postgres.
  """
  use Ash.Resource.Change

  alias Samen.CustomFields
  alias Samen.CustomObjects
  alias Samen.PiiValueShape

  @attrs_attr :attributes
  @refs_attr :refs
  @object_attr :object_key

  # An opaque OUT-reference value is a uuid (a system row id) or a short bounded
  # token. This is the closed set a ref may hold — anything else (a name, an email,
  # free text) is rejected so a ref can't launder PII across the boundary.
  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @token_regex ~r/\A[A-Za-z0-9_\-]{1,64}\z/

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &validate/1)
  end

  defp validate(changeset) do
    org_id = resolve_org_id(changeset)
    object_key = resolve_object_key(changeset)
    repo = repo!(changeset)

    cond do
      is_nil(org_id) ->
        # No org context ⇒ no tenant boundary ⇒ fail closed.
        Ash.Changeset.add_error(changeset,
          field: @attrs_attr,
          message:
            "tnt_record write has no org_id — Tier-2 custom objects are org-scoped " <>
              "and validated against the org's tnt_object/tnt_field definitions; " <>
              "cannot validate a record with no tenant boundary (fail closed)."
        )

      is_nil(object_key) ->
        Ash.Changeset.add_error(changeset,
          field: @object_attr,
          message: "tnt_record write has no object_key (fail closed)."
        )

      not CustomObjects.object_enabled?(org_id, object_key, repo) ->
        # RED PATH: a record for an undefined/disabled object.
        Ash.Changeset.add_error(changeset,
          field: @object_attr,
          message:
            "no enabled tnt_object #{inspect(object_key)} for this org — define the " <>
              "custom object first (Tier-2 is validated-at-write; an undefined " <>
              "object is rejected, fail closed)."
        )

      true ->
        changeset
        |> validate_attributes(org_id, object_key, repo)
        |> validate_refs()
    end
  end

  defp validate_attributes(changeset, org_id, object_key, repo) do
    case Ash.Changeset.fetch_change(changeset, @attrs_attr) do
      :error ->
        changeset

      {:ok, nil} ->
        changeset

      {:ok, bag} when is_map(bag) ->
        table = CustomObjects.object_table(object_key)

        case CustomFields.validate_bag(org_id, table, bag, repo) do
          :ok ->
            changeset

          {:error, violations} ->
            Enum.reduce(violations, changeset, fn {field, reason}, cs ->
              Ash.Changeset.add_error(cs,
                field: @attrs_attr,
                message: "custom-object attribute #{inspect(field)} rejected: #{describe(reason)}"
              )
            end)
        end

      {:ok, other} ->
        Ash.Changeset.add_error(changeset,
          field: @attrs_attr,
          message: "tnt_record attributes must be a map, got: #{inspect(other)}"
        )
    end
  end

  defp validate_refs(changeset) do
    case Ash.Changeset.fetch_change(changeset, @refs_attr) do
      :error ->
        changeset

      {:ok, nil} ->
        changeset

      {:ok, refs} when is_map(refs) ->
        Enum.reduce(refs, changeset, fn {key, value}, cs ->
          case ref_ok(value) do
            :ok ->
              cs

            {:error, reason} ->
              Ash.Changeset.add_error(cs,
                field: @refs_attr,
                message: "tnt_record ref #{inspect(to_string(key))} rejected: #{reason}"
              )
          end
        end)

      {:ok, other} ->
        Ash.Changeset.add_error(changeset,
          field: @refs_attr,
          message: "tnt_record refs must be a map of opaque IDs, got: #{inspect(other)}"
        )
    end
  end

  # A ref value must be an opaque id / bounded token, and must NOT be PII-shaped.
  # (PII-shape is checked first: a value can be both token-shaped and name-shaped —
  # `"john smith"` is not token-shaped anyway, but an SSN `123-45-6789` IS
  # token-shaped, so the PII gate is load-bearing and comes first.)
  defp ref_ok(value) when is_binary(value) do
    case PiiValueShape.classify_id_value(value) do
      {true, shape} ->
        {:error,
         "value is PII-shaped (#{shape}) — a tnt_record ref must be an opaque ID, " <>
           "never a PII value (a reference can't smuggle PII across the one-way boundary)."}

      {false, _} ->
        if Regex.match?(@uuid_regex, value) or Regex.match?(@token_regex, value) do
          :ok
        else
          {:error,
           "value is not an opaque ID (uuid) or bounded token — free text is not a " <>
             "valid OUT-reference."}
        end
    end
  end

  defp ref_ok(value),
    do: {:error, "value must be an opaque-ID string, got: #{inspect(value)}"}

  defp describe({:undefined, msg}), do: msg
  defp describe({:type, expected}), do: "value is not a #{expected}"
  defp describe({:constraint, detail}), do: "constraint violated: #{inspect(detail)}"

  defp describe({:pii_shaped, shape}),
    do:
      "value is PII-shaped (#{shape}) on a field not declared pii_declared: true — " <>
        "a Tier-2 custom-object attribute can never be a vault bypass (containment, fail closed)"

  defp describe(other), do: inspect(other)

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

  defp resolve_object_key(changeset) do
    case Ash.Changeset.fetch_change(changeset, @object_attr) do
      {:ok, value} when not is_nil(value) ->
        to_string(value)

      _ ->
        case Map.get(changeset.data || %{}, @object_attr) do
          nil -> nil
          existing -> to_string(existing)
        end
    end
  end

  defp repo!(changeset) do
    AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate) ||
      Application.get_env(:samen_core, :vault_repo) ||
      raise "Samen.CustomObjects.RecordChange: could not resolve a repo"
  end
end
