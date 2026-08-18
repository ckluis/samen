defmodule Samen.Versioning.SelectForVersion do
  @moduledoc """
  Loads a `versioned` resource's attributes onto the write result so ash_paper_trail can
  build its version diff (ADR-040 §6) — the E7 glue for a samen write result.

  ## Why this exists

  ash_paper_trail's `CreateNewVersion` builds the diff from the action **result**,
  dumping each tracked attribute via `Ash.Type.dump_to_embedded/2`. But a samen create/
  update result does NOT eagerly materialize every attribute:

    * vault-routed (🔒) attributes (`Samen.Type.VaultField`) are deliberately NOT selected
      by default (masking-by-omission — a read never materializes a token unasked); and
    * even `org_id` and other columns can come back as `%Ash.NotLoaded{}` on the write
      result.

  A `%Ash.NotLoaded{}` reaching `dump_to_embedded/2` fails (for a vault field it hits
  `VaultField.dump_to_native/2`'s fail-closed `:error` clause) and aborts the whole write.

  This change adds a **prepended** `after_action` hook (so it runs BEFORE
  `CreateNewVersion`'s version build, which is also an `after_action`) that loads every
  attribute onto `result`. Vault attributes load as `%Samen.Masked{}` — which
  `dump_to_embedded/2` turns back into the bare `vt_*` token — so INV-1 holds by
  construction: the diff records the token, never plaintext, for both `:changes_only` and
  the full-row `:snapshot` reconstruction (§6.3(1)). Non-vault attributes load as their
  values. Added only on `versioned` resources (via `resource.ex`), and only for `:create`/
  `:update`.
  """
  use Ash.Resource.Change

  alias Samen.Masked

  @ctx_flag :samen_versioning_selected

  @impl true
  def change(changeset, _opts, _context), do: maybe_attach(changeset)

  @impl true
  def atomic(changeset, _opts, _context), do: {:ok, maybe_attach(changeset)}

  defp maybe_attach(changeset) do
    if Map.get(changeset.context, @ctx_flag) do
      changeset
    else
      changeset
      |> Ash.Changeset.set_context(%{@ctx_flag => true})
      |> Ash.Changeset.after_action(fn cs, result -> {:ok, load_all(cs, result)} end,
        prepend?: true
      )
    end
  end

  # Materialize every attribute on `result` (vault fields as %Masked{}). Prefer an in-tx
  # load; fall back to the changeset's force-changed values for any field the load leaves
  # NotLoaded (e.g. a vault field on a resource whose read filter would exclude the row).
  defp load_all(changeset, result) do
    names = changeset.resource |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
    actor = changeset.context |> Map.get(:private, %{}) |> Map.get(:actor)

    loaded =
      try do
        Ash.load!(result, names,
          actor: actor,
          authorize?: false,
          tenant: changeset.tenant,
          domain: changeset.domain,
          reuse_values?: true
        )
      rescue
        _ -> result
      end

    Enum.reduce(names, loaded, fn name, acc ->
      case Map.get(acc, name) do
        %Ash.NotLoaded{} ->
          case fallback_value(changeset, name) do
            {:ok, value} -> Map.put(acc, name, value)
            :error -> acc
          end

        _already_loaded ->
          acc
      end
    end)
  end

  # For any attribute the in-tx load could not materialize (e.g. a soft-destroy/archive
  # result the resource's default read filter excludes, so `Ash.load` misses it), fall
  # back to the changeset's own change, then to the pre-write record (`changeset.data`).
  defp fallback_value(changeset, name) do
    with :error <- from_change(changeset, name),
         :error <- from_data(changeset, name) do
      :error
    end
  end

  defp from_change(changeset, name) do
    case Ash.Changeset.fetch_change(changeset, name) do
      {:ok, value} -> {:ok, normalize(value, name)}
      :error -> :error
    end
  end

  defp from_data(%{data: data}, name) when is_struct(data) do
    case Map.get(data, name) do
      %Ash.NotLoaded{} -> :error
      nil -> :error
      value -> {:ok, normalize(value, name)}
    end
  end

  defp from_data(_changeset, _name), do: :error

  defp normalize(%Masked{} = m, _name), do: m
  defp normalize("vt_" <> _ = token, name), do: Masked.new(token, name)
  defp normalize(value, _name), do: value
end
