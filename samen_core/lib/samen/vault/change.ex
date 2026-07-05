defmodule Samen.Vault.Change do
  @moduledoc """
  The resource ↔ vault integration (Gate-0 vault-stack fix, mandatory P0).

  A global `Ash.Resource.Change` (`Samen.Resource` injects it into every resource
  that has a `pii do` block) that makes vault routing **transparent** on the real
  Ash `:create` / `:update` actions:

    * **On write** — for each vault-routed `pii_attribute` the changeset sets, it
      1. resolves the row's **subject_id** (the crypto-shred unit — the resource's
         primary key), forcing/generating it on create if absent;
      2. calls `Samen.Vault.store_fields/4`, which encrypts each plaintext value
         under the subject DEK into a `pii_vault` row (ciphertext + token);
      3. **replaces the domain column value with the opaque `vt_*` token**
         (`force_change_attribute`), so the domain table only ever receives a
         token — never plaintext. `Samen.Type.VaultField.dump_to_native/2` is the
         last-line guard: it refuses to write a non-token, so even a bug that
         skipped this change fails closed rather than leaking plaintext.

    * **On read** — no per-resource hook is needed: the vault column's type
      (`Samen.Type.VaultField`) presents `%Samen.Masked{}` from the stored token
      via `cast_stored`, so `Ash.read` returns `%Masked{}` as the field's normal
      value. `Samen.Vault.materialize/2` remains available for callers holding a
      raw struct (e.g. from a non-Ash query), but the type covers the Ash path.

  The subject key + ciphertext write happen in `before_action`, inside the same
  Ecto transaction Ash opens for the action, so a failed insert rolls back the
  vault rows too (via the repo's transaction) — no orphan ciphertext, no
  half-tokenized domain row.
  """
  use Ash.Resource.Change

  alias Samen.Pii.Info
  alias Samen.Masked

  @impl true
  def change(changeset, _opts, _context) do
    fields = Info.fields(changeset.resource)

    if fields == [] do
      changeset
    else
      Ash.Changeset.before_action(changeset, fn cs -> route_fields(cs, fields) end)
    end
  end

  # Route every set PII field's plaintext into the vault, replacing the column
  # value with the token. Fields the changeset did not touch are left alone (their
  # existing token stays); an explicit `nil` clears the field (no vault row).
  defp route_fields(changeset, fields) do
    repo = repo!(changeset)
    subject_id = resolve_subject_id(changeset)

    # Collect the (field, plaintext) pairs the caller actually set to a non-token
    # plaintext value. A %Masked{} or a raw token means "already vaulted, leave it".
    to_vault =
      fields
      |> Enum.flat_map(fn field ->
        case fetch_plaintext(changeset, field.name) do
          {:set, %Masked{}} -> []
          {:set, "vt_" <> _} -> []
          {:set, nil} -> []
          {:set, plaintext} -> [{field, plaintext}]
          :unset -> []
        end
      end)

    if to_vault == [] do
      changeset
    else
      changeset = ensure_subject_attr(changeset, subject_id)
      do_vault(changeset, subject_id, to_vault, repo)
    end
  end

  defp do_vault(changeset, subject_id, to_vault, repo) do
    # Group by vault so store_fields batches per subject/vault under one DEK unwrap.
    to_vault
    |> Enum.group_by(fn {field, _pt} -> field.vault end)
    |> Enum.reduce_while(changeset, fn {vault_name, entries}, cs ->
      pairs = Enum.map(entries, fn {field, pt} -> {field.name, dump_plaintext(pt)} end)

      case Samen.Vault.store_fields(subject_id, vault_name, pairs, repo) do
        {:ok, tokens} ->
          updated =
            Enum.reduce(entries, cs, fn {field, _pt}, acc ->
              token = Map.fetch!(tokens, field.name)
              Ash.Changeset.force_change_attribute(acc, field.name, Masked.new(token, field.name))
            end)

          {:cont, updated}

        {:error, reason} ->
          {:halt, Ash.Changeset.add_error(cs, field: :vault, message: "vault store failed: #{inspect(reason)}")}
      end
    end)
  end

  # The plaintext value the caller set for a field, if any. We read the CASTED
  # attribute value on the changeset (VaultField.cast_input passes plaintext
  # through unchanged), distinguishing "set to nil" from "not set at all".
  defp fetch_plaintext(changeset, name) do
    case Ash.Changeset.fetch_change(changeset, name) do
      {:ok, value} -> {:set, value}
      :error -> :unset
    end
  end

  # Convert a plaintext value into the binary the vault encrypts. Composite PII
  # structs / maps are JSON-encoded so reveal can round-trip them; scalars are
  # stringified. (reveal returns the same binary; a host that needs the typed
  # value decodes it — the vault stores opaque bytes.)
  defp dump_plaintext(value) when is_binary(value), do: value

  defp dump_plaintext(%Date{} = d), do: Date.to_iso8601(d)
  defp dump_plaintext(%DateTime{} = d), do: DateTime.to_iso8601(d)

  defp dump_plaintext(value) when is_struct(value) do
    value |> Map.from_struct() |> Jason.encode!()
  end

  defp dump_plaintext(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp dump_plaintext(value), do: to_string(value)

  # subject_id = the resource's primary key value (the crypto-shred unit). On
  # create it may be unset (DB default gen_random_uuid()); we generate + force it
  # so the ciphertext and the domain row share the same subject.
  defp resolve_subject_id(changeset) do
    pk = pk_attr(changeset.resource)

    case Ash.Changeset.fetch_change(changeset, pk) do
      {:ok, value} when not is_nil(value) ->
        to_string(value)

      _ ->
        case Map.get(changeset.data || %{}, pk) do
          nil -> Ash.UUID.generate()
          existing -> to_string(existing)
        end
    end
  end

  # On create, force the generated pk so the row and its ciphertext share the
  # subject. On update the pk is already the data's pk (unchanged).
  defp ensure_subject_attr(changeset, subject_id) do
    pk = pk_attr(changeset.resource)

    cond do
      not is_nil(Map.get(changeset.data || %{}, pk)) ->
        changeset

      match?({:ok, v} when not is_nil(v), Ash.Changeset.fetch_change(changeset, pk)) ->
        changeset

      true ->
        Ash.Changeset.force_change_attribute(changeset, pk, subject_id)
    end
  end

  defp pk_attr(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [pk] -> pk
      [pk | _] -> pk
      [] -> :id
    end
  end

  defp repo!(changeset) do
    AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate) ||
      Application.get_env(:samen_core, :vault_repo) ||
      raise "Samen.Vault.Change: could not resolve a repo for #{inspect(changeset.resource)}"
  end
end
