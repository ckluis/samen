defmodule Samen.AI.PromptChange do
  @moduledoc """
  Write-time governance for `Samen.AI.Prompt`'s `:new_version` create action
  (ADR-043 §7.5, T68):

    1. **Refuses a `vt_` vault-token sentinel in `:body`**, fail-closed — a
       committed/managed prompt template must never embed a raw vault FK token
       (the runtime twin of the `mix samen.verify.ai_prompt_masking` check-(c)
       compile-time scan; this catches it for an ORG-AUTHORED prompt row, which the
       compile-time scan cannot see).
    2. **Computes the next immutable `version`** for `{org_id, name}` — current max
       + 1, or 1 for a brand-new name — via `force_change_attribute/3`, so `version`
       is NEVER caller-writable (the attribute is `writable?: false`).

  The PII-SHAPE scan on `:body` (email/SSN/phone value shapes) is a SEPARATE change
  on the resource (`change({Samen.Pii.FreeTextScan, fields: [:body]})`) — the SAME
  chokepoint `Samen.Approvals` uses to scan its `reason` field. Composing two
  changes rather than folding PII-shape scanning in here keeps each concern its own
  reusable unit.
  """
  use Ash.Resource.Change

  require Ash.Query
  require Logger

  @vt_sentinel "vt_"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &prepare/1)
  end

  defp prepare(changeset) do
    with {:ok, body} <- fetch(changeset, :body),
         :ok <- refuse_vt_sentinel(body),
         {:ok, org_id} <- fetch(changeset, :org_id),
         {:ok, name} <- fetch(changeset, :name) do
      Ash.Changeset.force_change_attribute(changeset, :version, next_version(org_id, name))
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset, field: :body, message: error_message(reason))
    end
  end

  defp fetch(changeset, key) do
    case Ash.Changeset.fetch_change(changeset, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp refuse_vt_sentinel(body) when is_binary(body) do
    if String.contains?(body, @vt_sentinel) do
      Logger.warning(
        "Samen.AI.PromptChange: refused a Prompt body carrying a vt_ vault-token sentinel " <>
          "(ADR-043 §3.4 check (c) / §7.5) — a committed/managed template must never embed " <>
          "a raw vault FK token. Refusing the write."
      )

      {:error, :vt_sentinel_in_body}
    else
      :ok
    end
  end

  defp refuse_vt_sentinel(_), do: {:error, :vt_sentinel_in_body}

  defp error_message(:vt_sentinel_in_body),
    do: "prompt body must not contain a vt_ vault-token sentinel (ADR-043 §7.5)"

  defp error_message({:missing, key}), do: "missing required #{key}"

  # current max version for {org_id, name} + 1 (1 for a brand-new name). Runs inside the
  # create's own transaction (AshPostgres wraps single creates); the {org_id, name, version}
  # identity is the belt to this computation's braces under a same-{org,name} race.
  defp next_version(org_id, name) do
    max =
      Samen.AI.Prompt
      |> Ash.Query.filter(org_id == ^org_id and name == ^name)
      |> Ash.Query.select([:version])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.version)
      |> Enum.max(fn -> 0 end)

    max + 1
  end
end
